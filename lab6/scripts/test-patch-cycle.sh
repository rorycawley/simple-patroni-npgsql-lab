#!/usr/bin/env bash
set -uo pipefail

# AC-1: a complete rolling minor upgrade, invisible to the client.
#
# The four-step order from README.md, performed end to end with the real Npgsql
# client committing throughout:
#
#   1. standby A     patch, restart through Patroni, wait for streaming
#   2. standby B     the same -- only after A is streaming again
#   3. switchover    move the leader to an already-patched standby
#   4. old primary   now a standby: patch it the same way
#
# "Invisible" is asserted in transactions, not in uptime. The client used here is
# the one the design names, running on the application VM, crossing the same
# network, firewall and pg_hba rules as any real client -- and it does NOT retry
# writes, only connections, so a failed transaction is a real one.
#
# The phase begins by putting every node back on the build version, downgrading
# any that are ahead. That makes the run repeatable, and it makes the emitted
# cost a COMPLETE cycle rather than however much happened to be left over from an
# earlier phase.
#
# The backup timers are deliberately left running. A patch window colliding with
# a scheduled backup is an ordinary Tuesday, and nothing in this series has
# tested it. Whatever that collision does is REPORTED here rather than gated,
# because a finding belongs in the runbook and a guess does not.

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly VM_NAMES=(lab6-pg1 lab6-pg2 lab6-pg3)
readonly VM_PREFIX="lab6-"
readonly STANZA=lab6
readonly PATRONI_CONFIG=/etc/patroni/patroni.yml
readonly PGBIN=/usr/pgsql-18/bin
readonly BUILD_VERSION="${LAB6_PG_VERSION:-18.4}"
readonly TARGET_VERSION="${LAB6_PG_TARGET_VERSION:-18.6}"
readonly CLIENT=/opt/lab6-client/Lab4.Client

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }
[[ -f "$LAB_DIR/.env" ]] || { echo "Run make create_vms first" >&2; exit 1; }
# shellcheck disable=SC1091
source "$LAB_DIR/.env"

failures=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; failures=$((failures + 1)); }
on() { local vm="$1"; shift; limactl shell --tty=false "$vm" "$@" 2>/dev/null; }

patroni_json() {
  local out vm
  for vm in "${VM_NAMES[@]}"; do
    if out="$(on "$vm" sudo -u postgres patronictl -c "$PATRONI_CONFIG" list --format=json)"; then
      [[ -n "$out" ]] && { printf '%s' "$out"; return 0; }
    fi
  done
  return 1
}
leader_of() { jq -r '.[] | select(.Role | test("Leader")) | .Member' <<< "$1"; }
installed_on() { on "$VM_PREFIX$1" rpm -q --qf '%{VERSION}' percona-postgresql18-server 2>/dev/null; }
running_on() { on "$VM_PREFIX$1" sudo -u postgres "$PGBIN/psql" -tAc 'SHOW server_version' 2>/dev/null | awk '{print $1}'; }

pg_packages() {  # $1 = version
  printf '%s' "percona-postgresql18-server-$1* percona-postgresql18-$1* percona-postgresql18-contrib-$1* percona-postgresql18-libs-$1*"
}

wait_streaming() {  # $1 = member
  local i
  for ((i = 1; i <= 90; i++)); do
    [[ "$(jq -r --arg m "$1" '.[] | select(.Member == $m) | .State' <<< "$(patroni_json)")" == "streaming" ]] && return 0
    sleep 2
  done
  return 1
}

# One node, patched the way P1 proved safe: packages first, then a restart
# THROUGH Patroni, then wait for it to be streaming again before touching
# anything else. Step 2 of the order depends on this returning only when the
# node is genuinely back.
patch_member() {  # $1 = member, $2 = version
  local m="$1" v="$2" cur op leader out ok i
  cur="$(installed_on "$m")"
  # dnf refuses `upgrade` to a lower version and `downgrade` to a higher one, so
  # the direction is derived from what is actually installed rather than assumed
  # from which phase happens to be calling. `sort -V` compares versions as
  # versions: a string comparison would put 18.10 below 18.4.
  if [[ "$(printf '%s\n%s\n' "$cur" "$v" | sort -V | tail -1)" == "$v" ]]; then op=upgrade; else op=downgrade; fi

  # Retried, and a failure is SURFACED rather than discarded. A mirror served an
  # HTML error page instead of repomd.xml here and failed step 4 of a cycle; the
  # first version of this function threw dnf's output away and reported success
  # because the node was still streaming -- a patch step that could not fail to
  # patch. `--refresh` on the retry is what cleared it, the cached metadata being
  # the poisoned copy.
  ok=""
  for i in 1 2 3; do
    # shellcheck disable=SC2046
    out="$(on "$VM_PREFIX$m" sudo dnf -y $( ((i > 1)) && echo --refresh ) "$op" $(pg_packages "$v") 2>&1)" \
      && { ok=yes; break; }
    sleep 5
  done
  if [[ -z "$ok" ]]; then
    echo "      dnf $op failed on $m after 3 attempts:" >&2
    grep -iE "^error|failed" <<< "$out" | head -2 | sed 's/^/        /' >&2
    return 1
  fi

  leader="$(leader_of "$(patroni_json)")"
  on "$VM_PREFIX$leader" sudo -u postgres patronictl -c "$PATRONI_CONFIG" \
    restart "$STANZA" "$m" --force >/dev/null 2>&1
  wait_streaming "$m" || return 1

  # What makes this function honest: it claims to have patched, so it checks the
  # RUNNING version is the one asked for. Streaming again proves the node came
  # back, not that anything changed.
  [[ "$(running_on "$m")" == "$v" ]]
}

echo
echo "=== Every node back on $BUILD_VERSION, so the cost below is a COMPLETE cycle ==="
cluster="$(patroni_json)" || { echo "  FAIL: no Patroni cluster answered" >&2; exit 1; }
for m in $(jq -r '.[].Member' <<< "$cluster"); do
  v="$(installed_on "$m")"
  if [[ "$v" == "$BUILD_VERSION" ]]; then
    pass "$m is already on $BUILD_VERSION"
  else
    echo "  $m is on $v; downgrading to $BUILD_VERSION so the cycle starts level"
    patch_member "$m" "$BUILD_VERSION" \
      && pass "$m downgraded to $(running_on "$m") and streaming again" \
      || fail "$m did not come back after being downgraded"
  fi
done

echo
echo "=== The client starts committing, and does not stop until the cycle is over ==="
soak_log="$(mktemp "${TMPDIR:-/tmp}/lab6-soak.XXXXXX")"
soak_stop="${soak_log}.stop"
(
  while [[ ! -f "$soak_stop" ]]; do
    if out="$(limactl shell --tty=false lab6-app1 sudo env \
        LAB6_PG_HOSTS="${PG1_IP},${PG2_IP},${PG3_IP}" \
        LAB6_PGPASS=/etc/lab6/client/pgpass \
        LAB6_CA=/etc/lab6/client/ca.crt \
        "$CLIENT" write 2>/dev/null)" && grep -q '"ok":true' <<< "$out"; then
      echo ok
    else
      echo "FAILED ${out:-no-output}"
    fi
  done
) >> "$soak_log" 2>&1 &
soak_pid=$!
sleep 12
(( $(grep -c '^ok' "$soak_log") > 0 )) \
  && pass "the client is committing ($(grep -c '^ok' "$soak_log") so far) before anything is touched" \
  || fail "the client is not committing even on a healthy cluster; the probe is broken, not the cluster"

backups_before="$(on "$VM_PREFIX$(leader_of "$(patroni_json)")" \
  sudo -u postgres pgbackrest info --stanza="$STANZA" --output=json 2>/dev/null \
  | jq -r '[.[0].backup[]?] | length')"

cycle_start=$SECONDS
echo
echo "=== Steps 1 and 2: both standbys, one at a time ==="
cluster="$(patroni_json)"
original_leader="$(leader_of "$cluster")"
step_n=0
for m in $(jq -r '.[] | select(.Role | test("Leader") | not) | .Member' <<< "$cluster"); do
  step_n=$((step_n + 1))
  t0=$SECONDS
  patch_member "$m" "$TARGET_VERSION" \
    && pass "step $step_n: $m patched to $(running_on "$m") and streaming again in $((SECONDS - t0))s" \
    || fail "step $step_n: $m did not return to streaming"
done

echo
echo "=== Step 3: switchover to an already-patched standby ==="
cluster="$(patroni_json)"
candidate="$(jq -r --arg v "$TARGET_VERSION" '.[] | select(.Role | test("Leader") | not) | .Member' <<< "$cluster" | head -1)"
[[ "$(running_on "$candidate")" == "$TARGET_VERSION" ]] \
  && pass "the candidate $candidate is already on $TARGET_VERSION, as the order requires" \
  || fail "the candidate $candidate runs $(running_on "$candidate"); promoting an unpatched node is the wrong order"

t0=$SECONDS
on "$VM_PREFIX$original_leader" sudo -u postgres patronictl -c "$PATRONI_CONFIG" \
  switchover "$STANZA" --leader "$original_leader" --candidate "$candidate" --force >/dev/null 2>&1
moved=""
for _ in {1..60}; do
  [[ "$(leader_of "$(patroni_json)")" == "$candidate" ]] && { moved=yes; break; }
  sleep 2
done
switch_elapsed=$((SECONDS - t0))
[[ -n "$moved" ]] \
  && pass "the leader moved to $candidate in ${switch_elapsed}s, a controlled handover" \
  || fail "the leader did not move to $candidate"

echo
echo "=== Step 4: the old primary, now a standby ==="
wait_streaming "$original_leader" \
  && pass "$original_leader rejoined as a standby" \
  || fail "$original_leader did not rejoin as a standby"
t0=$SECONDS
patch_member "$original_leader" "$TARGET_VERSION" \
  && pass "step 4: $original_leader patched to $(running_on "$original_leader") and streaming again in $((SECONDS - t0))s" \
  || fail "step 4: $original_leader did not return to streaming"
cycle_elapsed=$((SECONDS - cycle_start))

echo
echo "=== AC-1: what the client saw ==="
touch "$soak_stop"
wait "$soak_pid" 2>/dev/null
committed="$(grep -c '^ok' "$soak_log")"
failed="$(grep -c '^FAILED' "$soak_log")"
(( failed == 0 )) \
  && pass "$committed transactions committed, ZERO failed, across the whole cycle" \
  || fail "$failed of $((committed + failed)) transactions FAILED during the cycle"
if (( failed > 0 )); then
  grep '^FAILED' "$soak_log" | head -3 | sed 's/^/      /' >&2
fi

echo
echo "=== Every node ended on the new version ==="
for m in $(jq -r '.[].Member' <<< "$(patroni_json)"); do
  r="$(running_on "$m")"
  [[ "$r" == "$TARGET_VERSION" ]] \
    && pass "$m runs $r" \
    || fail "$m runs $r, not $TARGET_VERSION"
done

echo
echo "=== AC-7: the cluster is not left degraded ==="
final="$(patroni_json)"
[[ "$(jq -r '[.[] | select(.Role | test("Leader"))] | length' <<< "$final")" == "1" ]] \
  && pass "exactly one leader" || fail "leader count is not 1"
[[ "$(jq -r '[.[] | select(.State == "streaming")] | length' <<< "$final")" == "2" ]] \
  && pass "two streaming standbys" || fail "the cluster is left degraded"
dcs="$(on "$VM_PREFIX$(leader_of "$final")" sudo -u postgres patronictl -c "$PATRONI_CONFIG" show-config 2>/dev/null)"
grep -q "synchronous_mode_strict: true" <<< "$dcs" \
  && pass "quorum commit is still strict" || fail "strict mode was lost"

echo
echo "=== Reported, not gated: the backup timers were live throughout ==="
backups_after="$(on "$VM_PREFIX$(leader_of "$final")" \
  sudo -u postgres pgbackrest info --stanza="$STANZA" --output=json 2>/dev/null \
  | jq -r '[.[0].backup[]?] | length')"
echo "  backups in the repository: ${backups_before:-?} before, ${backups_after:-?} after"
if [[ "${backups_after:-0}" -gt "${backups_before:-0}" ]]; then
  echo "  a scheduled backup ran DURING the patch cycle and completed"
else
  echo "  no scheduled backup happened to land inside the window"
fi
if "$SCRIPT_DIR/repo-verify.sh" "$VM_PREFIX$(leader_of "$final")" "$STANZA" >/dev/null 2>&1; then
  pass "and the repository still verifies after being patched around"
else
  fail "the repository does not verify after the cycle"
fi
failed_units="$(on "$VM_PREFIX$(leader_of "$final")" systemctl list-units --state=failed --no-legend 2>/dev/null | grep -c "lab6-" || true)"
[[ "${failed_units:-0}" == "0" ]] \
  && pass "no lab6 backup unit is in a failed state" \
  || echo "  FINDING: ${failed_units} lab6 unit(s) failed during the window -- this belongs in the runbook"

rm -f "$soak_log" "$soak_stop"
echo
echo "  P3: complete cycle $BUILD_VERSION -> $TARGET_VERSION across three nodes in ${cycle_elapsed}s"
echo "      switchover ${switch_elapsed}s, $committed client transactions, $failed failed"
echo
(( failures == 0 )) && { echo "PASS"; exit 0; }
echo "FAILED: $failures problem(s)" >&2
exit 1
