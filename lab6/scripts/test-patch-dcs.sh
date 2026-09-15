#!/usr/bin/env bash
set -uo pipefail

# AC-5: etcd and Patroni upgraded ONE MEMBER AT A TIME, with quorum intact
# throughout and Patroni never losing the DCS.
#
# These share a node with PostgreSQL but not a lifecycle, and the design says
# plainly why they are never patched in the same window: an unhealthy DCS at the
# moment Patroni is asked to move a leader. So this phase deliberately touches
# neither PostgreSQL nor its version.
#
# The gap has to be MANUFACTURED here. Only PostgreSQL was pinned at build time,
# so etcd and Patroni installed whatever was newest and there is nothing left to
# upgrade to. Rather than skip the criterion or mime it, the phase steps both
# packages back one release -- one member at a time, so even the setup keeps
# quorum -- and then measures the upgrade back. This is the same risk AC-4 named:
# a version test with no version to move to passes because nothing happened.
#
# "Quorum never lost" is sampled, not inferred. A background sampler asks etcd
# how many members are healthy every second for the whole run, because checking
# before and after would miss exactly the window the phase exists to watch.

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly VM_NAMES=(lab6-pg1 lab6-pg2 lab6-pg3)
readonly VM_PREFIX="lab6-"
readonly STANZA=lab6
readonly PATRONI_CONFIG=/etc/patroni/patroni.yml
readonly PKI=/etc/lab6/pki
readonly ETCD_BACK=3.5.30
readonly PATRONI_BACK=4.1.4

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }
[[ -f "$LAB_DIR/.env" ]] || { echo "Run make create_vms first" >&2; exit 1; }
# shellcheck disable=SC1091
source "$LAB_DIR/.env"
readonly GW="${LAB6_GATEWAY_IP:-${PG1_IP%.*}.1}"
readonly MIMIR="http://$GW:${LAB6_MIMIR_PORT:-9019}"

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
rule_state() {
  curl -s --max-time 12 "$MIMIR/prometheus/api/v1/rules" 2>/dev/null \
    | jq -r --arg n "$1" '[.data.groups[]?.rules[]? | select(.name == $n)][0].state // "absent"'
}
rpm_ver() { on "$VM_PREFIX$1" rpm -q --qf '%{VERSION}' "$2" 2>/dev/null; }

# How many etcd members answer as healthy, asked from a node that is not being
# touched. Returns a bare count so the sampler can record it cheaply.
healthy_count() {  # $1 = vm to ask from
  on "$1" sudo etcdctl --endpoints="https://127.0.0.1:2379" \
    --cacert=$PKI/ca.crt --cert=$PKI/etcd.crt --key=$PKI/etcd.key \
    endpoint health --cluster -w json 2>/dev/null \
    | jq -r '[.[] | select(.health == true)] | length' 2>/dev/null
}

# dnf with retries and surfaced errors. These mirrors intermittently serve an
# HTML error page instead of repomd.xml, and a swallowed failure here would mean
# a node reporting "upgraded" while running the old package.
dnf_do() {  # $1 = vm, $2 = op, rest = packages
  local vm="$1" op="$2"; shift 2
  local i out
  for i in 1 2 3; do
    # shellcheck disable=SC2086
    out="$(on "$vm" sudo dnf -y $( ((i > 1)) && echo --refresh ) "$op" "$@" 2>&1)" && return 0
    sleep 5
  done
  echo "      dnf $op failed on $vm:" >&2
  grep -iE "^error" <<< "$out" | head -2 | sed 's/^/        /' >&2
  return 1
}

echo
echo "=== A healthy cluster, and a gap that has to be made ==="
cluster="$(patroni_json)" || { echo "  FAIL: no Patroni cluster answered" >&2; exit 1; }
leader="$(leader_of "$cluster")"
members="$(jq -r '.[].Member' <<< "$cluster")"
echo "  leader is $leader"
[[ "$(healthy_count "$VM_PREFIX$leader")" == "3" ]] \
  && pass "all three etcd members are healthy before anything is touched" \
  || fail "etcd is not fully healthy; refusing to measure quorum from a degraded start"

for pkg in etcd percona-patroni; do
  newest="$(on "$VM_PREFIX$leader" sudo dnf -q repoquery --latest-limit=1 --qf '%{version}' "$pkg" 2>/dev/null | tr -d '[:space:]')"
  [[ -n "$newest" ]] \
    && pass "$pkg: newest available is $newest" \
    || fail "could not ask the repository about $pkg -- not evidence that nothing newer exists"
done

echo
echo "=== Step back one release, one member at a time ==="
# Setup, but performed the same way as the real thing: never two members at once,
# because a DCS that loses quorum during its own maintenance is the failure this
# criterion is about.
for m in $members; do
  dnf_do "$VM_PREFIX$m" downgrade "etcd-$ETCD_BACK*" "percona-patroni-$PATRONI_BACK*" \
    && on "$VM_PREFIX$m" sudo systemctl restart etcd percona-patroni >/dev/null 2>&1
  sleep 8
  h="$(healthy_count "$VM_PREFIX$leader")"
  [[ "${h:-0}" -ge 2 ]] \
    && pass "$m stepped back to etcd $(rpm_ver "$m" etcd) / patroni $(rpm_ver "$m" percona-patroni), quorum held at $h" \
    || fail "$m: only ${h:-0} members healthy during the step back"
done

settled=""
for _ in {1..30}; do
  [[ "$(healthy_count "$VM_PREFIX$leader")" == "3" && \
     "$(jq -r '[.[] | select(.State == "streaming")] | length' <<< "$(patroni_json)")" == "2" ]] \
    && { settled=yes; break; }
  sleep 5
done
[[ -n "$settled" ]] \
  && pass "the cluster is healthy again on the older packages, so the upgrade starts from health" \
  || fail "the cluster did not settle after the step back"

echo
echo "=== First: prove the sampler can SEE a member go down ==="
# Without this, "quorum never dropped below two" is worth nothing -- a broken
# probe that always answers 3 would satisfy it just as well. The instrument is
# checked against a member that really is stopped, on a node that is not the one
# being asked.
victim="$(printf '%s\n' $members | grep -v "^$leader$" | head -1)"
on "$VM_PREFIX$victim" sudo systemctl stop etcd >/dev/null 2>&1
sleep 3
seen_down="$(healthy_count "$VM_PREFIX$leader")"
on "$VM_PREFIX$victim" sudo systemctl start etcd >/dev/null 2>&1
[[ "${seen_down:-3}" == "2" ]] \
  && pass "with etcd stopped on $victim the sampler reported 2 of 3: it can detect a loss" \
  || fail "the sampler reported ${seen_down:-?} while a member was stopped; it cannot see what it claims to watch"
for _ in {1..20}; do
  [[ "$(healthy_count "$VM_PREFIX$leader")" == "3" ]] && break
  sleep 3
done
pass "and $victim is healthy again, so the measured run starts from three"

echo
echo "=== Sampling quorum every second, for the whole upgrade ==="
sample_log="$(mktemp "${TMPDIR:-/tmp}/lab6-quorum.XXXXXX")"
sample_stop="${sample_log}.stop"
# Asked from the LEADER's node, which this phase upgrades last, so the sampler
# itself is not the thing being restarted for most of the run.
(
  while [[ ! -f "$sample_stop" ]]; do
    printf '%s\n' "$(healthy_count "$VM_PREFIX$leader")"
    sleep 1
  done
) >> "$sample_log" 2>&1 &
sample_pid=$!
sleep 5

echo
echo "=== Upgrade each member in turn ==="
upgrade_start=$SECONDS
order="$(printf '%s\n' $members | grep -v "^$leader$"; printf '%s\n' "$leader")"
for m in $order; do
  t0=$SECONDS
  if dnf_do "$VM_PREFIX$m" upgrade etcd percona-patroni; then
    on "$VM_PREFIX$m" sudo systemctl restart etcd >/dev/null 2>&1
    sleep 5
    on "$VM_PREFIX$m" sudo systemctl restart percona-patroni >/dev/null 2>&1
    # Wait for this member to be back in the cluster before touching the next.
    ok=""
    for _ in {1..40}; do
      st="$(jq -r --arg m "$m" '.[] | select(.Member == $m) | .State' <<< "$(patroni_json)")"
      [[ "$st" == "streaming" || "$st" == "running" ]] && { ok=yes; break; }
      sleep 3
    done
    [[ -n "$ok" ]] \
      && pass "$m upgraded to etcd $(rpm_ver "$m" etcd) / patroni $(rpm_ver "$m" percona-patroni) and rejoined in $((SECONDS - t0))s" \
      || fail "$m did not rejoin after its upgrade"
  else
    fail "$m: the upgrade itself failed"
  fi
done
upgrade_elapsed=$((SECONDS - upgrade_start))

touch "$sample_stop"
wait "$sample_pid" 2>/dev/null

echo
echo "=== AC-5: quorum was never lost ==="
samples="$(grep -cE '^[0-9]+$' "$sample_log")"
worst="$(grep -E '^[0-9]+$' "$sample_log" | sort -n | head -1)"
below="$(awk '/^[0-9]+$/ && $1 < 2' "$sample_log" | wc -l | tr -d ' ')"
echo "  $samples samples taken during the upgrade; fewest healthy members seen: ${worst:-?}"
[[ "${below:-1}" == "0" ]] \
  && pass "never fewer than two members healthy: quorum held for the entire sequence" \
  || fail "quorum dropped below two on $below sample(s): a leader could not have moved during that window"
[[ "${worst:-0}" -ge 2 ]] \
  && pass "the worst moment still had ${worst} of 3, which is a quorum" \
  || fail "the worst moment had only ${worst:-0} healthy members"
# Stated rather than glossed: each sample costs about a second of etcdctl
# startup, so a restart shorter than that can pass between two samples unseen.
# What is proven is that no sample caught a loss of quorum, by an instrument just
# shown capable of catching one -- not that no member was ever briefly absent.
echo "  (samples are ~1s apart; a shorter dip could fall between two of them)"
rm -f "$sample_log" "$sample_stop"

echo
echo "=== And Patroni never lost the DCS ==="
for r in EtcdQuorumLost PatroniLostDcs; do
  [[ "$(rule_state "$r")" != "firing" ]] \
    && pass "$r is not firing" \
    || fail "$r fired during a one-at-a-time upgrade, which is the thing it warns about"
done
still_leader="$(leader_of "$(patroni_json)")"
[[ -n "$still_leader" ]] \
  && pass "the cluster still has a leader ($still_leader): the DCS stayed usable throughout" \
  || fail "there is no leader after the upgrade"

echo
echo "=== Every member ended on the newest packages ==="
for m in $members; do
  e="$(rpm_ver "$m" etcd)"; p="$(rpm_ver "$m" percona-patroni)"
  [[ "$e" != "$ETCD_BACK" && "$p" != "$PATRONI_BACK" ]] \
    && pass "$m: etcd $e, patroni $p" \
    || fail "$m is still on etcd $e / patroni $p"
done

echo
echo "=== AC-7, and PostgreSQL deliberately untouched ==="
final="$(patroni_json)"
[[ "$(jq -r '[.[] | select(.Role | test("Leader"))] | length' <<< "$final")" == "1" ]] \
  && pass "exactly one leader" || fail "leader count is not 1"
recovered=""
for _ in {1..40}; do
  [[ "$(jq -r '[.[] | select(.State == "streaming")] | length' <<< "$(patroni_json)")" == "2" ]] \
    && { recovered=yes; break; }
  sleep 5
done
[[ -n "$recovered" ]] && pass "two streaming standbys" || fail "the cluster is left degraded"
pgv="$(on "$VM_PREFIX$(leader_of "$final")" sudo -u postgres /usr/pgsql-18/bin/psql -tAc 'SHOW server_version' 2>/dev/null | awk '{print $1}')"
pass "PostgreSQL is still $pgv, untouched: etcd and PostgreSQL were not patched in one window"

echo
echo "  P5: etcd $ETCD_BACK -> $(rpm_ver "$leader" etcd) and patroni $PATRONI_BACK -> $(rpm_ver "$leader" percona-patroni)"
echo "      across three members in ${upgrade_elapsed}s, quorum never below ${worst:-?}/3"
echo
(( failures == 0 )) && { echo "PASS"; exit 0; }
echo "FAILED: $failures problem(s)" >&2
exit 1
