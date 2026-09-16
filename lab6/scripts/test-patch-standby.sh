#!/usr/bin/env bash
set -uo pipefail

# AC-3 and AC-7, on the smallest complete step of the procedure: ONE standby,
# patched the way the runbook will tell an operator to patch it.
#
# The claim is narrow and worth proving before anything larger is attempted. A
# minor upgrade replaces binaries and needs a restart; the restart goes through
# `patronictl`, and the leader key must not move. With `primary_start_timeout: 0`
# the difference between restarting through Patroni and around it is an
# unnecessary election, which P2 measures. This phase establishes that the safe
# form really is safe, so that P2's number has something to be compared against.
#
# Two assertions here cannot be made any later. Between installing the new
# packages and restarting, the node runs OLD binaries from disk that no longer
# exist as files -- that gap is the whole reason a restart is required, and it is
# invisible once the restart has happened. And once the standby is on the new
# minor while the leader is still on the old one, the cluster is genuinely
# mixed-version: that is what makes a rolling upgrade possible at all, and it is
# asserted by writing on one version and reading it back on the other rather than
# by trusting the documentation.

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly VM_NAMES=(lab6-pg1 lab6-pg2 lab6-pg3)
readonly VM_PREFIX="lab6-"
readonly STANZA=lab6
readonly PATRONI_CONFIG=/etc/patroni/patroni.yml
readonly BUILD_VERSION="${LAB6_PG_VERSION:-18.4}"
readonly TARGET_VERSION="${LAB6_PG_TARGET_VERSION:-18.6}"

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }
[[ -f "$LAB_DIR/.env" ]] || { echo "Run make create_vms first" >&2; exit 1; }

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
# The version PostgreSQL is RUNNING, which is not the version installed on disk.
running_version() { on "$1" sudo -u postgres psql -tAc 'SHOW server_version' 2>/dev/null | awk '{print $1}'; }
installed_version() { on "$1" rpm -q --qf '%{VERSION}' percona-postgresql18-server 2>/dev/null; }

echo
echo "=== A settled cluster, and a standby below the upgrade version ==="
cluster="$(patroni_json)" || { echo "  FAIL: no Patroni cluster answered" >&2; exit 1; }
leader="$(jq -r '.[] | select(.Role == "Leader") | .Member' <<< "$cluster")"
[[ -n "$leader" ]] || { echo "  FAIL: no leader" >&2; exit 1; }
# EVERY node is levelled to the build version, not just the target. Stepping back
# only the standby leaves the leader on the new version, so upgrading the standby
# produces a cluster where both run the same thing -- and the mixed-version
# assertion below, which is half the point of this phase, has nothing to observe.
#
# Standalone on a fresh build this is a no-op. Inside `make check`, after phases
# that leave every node upgraded, it is what makes the phase repeatable. Setup
# belongs in the phase rather than in the operator's head.
for m in $(jq -r '.[].Member' <<< "$cluster"); do
  if [[ "$(installed_version "$VM_PREFIX$m")" != "$BUILD_VERSION" ]]; then
    echo "  $m is on $(installed_version "$VM_PREFIX$m"); stepping it back to $BUILD_VERSION"
    on "$VM_PREFIX$m" sudo dnf -y downgrade \
      "percona-postgresql18-server-${BUILD_VERSION}*" "percona-postgresql18-${BUILD_VERSION}*" \
      "percona-postgresql18-contrib-${BUILD_VERSION}*" "percona-postgresql18-libs-${BUILD_VERSION}*" >/dev/null 2>&1
    on "$VM_PREFIX$(jq -r '.[] | select(.Role | test("Leader")) | .Member' <<< "$(patroni_json)")" \
      sudo -u postgres patronictl -c "$PATRONI_CONFIG" restart "$STANZA" "$m" --force >/dev/null 2>&1
    for _ in {1..60}; do
      [[ "$(jq -r --arg m "$m" '.[] | select(.Member == $m) | .State' <<< "$(patroni_json)")" =~ ^(streaming|running)$ ]] && break
      sleep 3
    done
  fi
done

# Re-read: levelling the leader can in principle move the key, and every step
# below is written in terms of who holds it now.
cluster="$(patroni_json)"
leader="$(jq -r '.[] | select(.Role | test("Leader")) | .Member' <<< "$cluster")"
target="$(jq -r '.[] | select(.Role | test("Leader") | not) | .Member' <<< "$cluster" | head -1)"
built_version="$(installed_version "$VM_PREFIX$target")"
for m in $(jq -r '.[].Member' <<< "$cluster"); do
  [[ "$(installed_version "$VM_PREFIX$m")" == "$BUILD_VERSION" ]] \
    && pass "$m is on $BUILD_VERSION" \
    || fail "$m is on $(installed_version "$VM_PREFIX$m"), so the cluster is not level"
done
echo "  leader is $leader; patching standby $target"

# The leader key, not merely the leader's name. A leader that steps down and is
# re-elected has the same name and a different key holder, and only the DCS can
# tell the difference.
tl_before="$(jq -r --arg l "$leader" '.[] | select(.Member == $l) | .TL' <<< "$cluster")"
echo "  leader key held by $leader on timeline $tl_before"

echo
echo "=== Install the new binaries, and do NOT restart ==="
# Deliberately split from the restart. This is the only moment the gap is
# observable, and the gap is the reason the procedure has a restart step at all.
upgrade_out="$(on "$VM_PREFIX$target" sudo dnf -y upgrade \
  "percona-postgresql18-server-${TARGET_VERSION}*" \
  "percona-postgresql18-${TARGET_VERSION}*" \
  "percona-postgresql18-contrib-${TARGET_VERSION}*" \
  "percona-postgresql18-libs-${TARGET_VERSION}*" 2>&1)"
rc=$?
(( rc == 0 )) \
  && pass "packages upgraded on $target" \
  || { fail "dnf upgrade failed on $target"; sed -n '1,6p' <<< "$upgrade_out" | sed 's/^/      /' >&2; }

now_installed="$(installed_version "$VM_PREFIX$target")"
[[ "$now_installed" == "$TARGET_VERSION" ]] \
  && pass "$target has $TARGET_VERSION on disk" \
  || fail "$target still reports $now_installed installed"

still_running="$(running_version "$VM_PREFIX$target")"
[[ "$still_running" == "$built_version" ]] \
  && pass "but it is still RUNNING $still_running: new binaries on disk change nothing until a restart" \
  || fail "$target reports running $still_running before any restart, which should be impossible"

# It must also still be a working standby while mid-upgrade. Replacing the files
# under a running postmaster does not disturb it, and a procedure that lost the
# standby here would be unusable.
state_mid="$(jq -r --arg m "$target" '.[] | select(.Member == $m) | .State' <<< "$(patroni_json)")"
[[ "$state_mid" == "streaming" ]] \
  && pass "and it is still streaming with its binaries replaced underneath it" \
  || fail "$target is '$state_mid' after the package upgrade, before any restart"

echo
echo "=== Restart it THROUGH Patroni ==="
restart_start=$SECONDS
on "$VM_PREFIX$leader" sudo -u postgres patronictl -c "$PATRONI_CONFIG" \
  restart "$STANZA" "$target" --force >/dev/null 2>&1 \
  && pass "patronictl restart returned success" \
  || fail "patronictl restart failed"

back=""
for _ in {1..90}; do
  st="$(jq -r --arg m "$target" '.[] | select(.Member == $m) | .State' <<< "$(patroni_json)")"
  [[ "$st" == "streaming" ]] && { back=yes; break; }
  sleep 2
done
restart_elapsed=$((SECONDS - restart_start))
[[ -n "$back" ]] \
  && pass "$target is streaming again ${restart_elapsed}s after the restart began" \
  || fail "$target did not return to streaming"

upgraded_running="$(running_version "$VM_PREFIX$target")"
[[ "$upgraded_running" == "$TARGET_VERSION" ]] \
  && pass "and it is now RUNNING $upgraded_running: the restart is what applied the upgrade" \
  || fail "$target is running $upgraded_running after the restart, expected $TARGET_VERSION"

echo
echo "=== AC-3: the leader key never moved ==="
after="$(patroni_json)"
leader_after="$(jq -r '.[] | select(.Role == "Leader") | .Member' <<< "$after")"
tl_after="$(jq -r --arg l "$leader_after" '.[] | select(.Member == $l) | .TL' <<< "$after")"
[[ "$leader_after" == "$leader" ]] \
  && pass "$leader is still the leader" \
  || fail "the leader moved from $leader to $leader_after: the restart cost an election"
[[ "$tl_after" == "$tl_before" ]] \
  && pass "timeline is unchanged at $tl_after, so nothing was promoted" \
  || fail "timeline moved $tl_before -> $tl_after: something was promoted"

echo
echo "=== The cluster is genuinely mixed-version, and replicates anyway ==="
# The property that makes a rolling upgrade possible. Asserted by moving a row
# across the version boundary rather than by citing the release notes.
lv="$(running_version "$VM_PREFIX$leader")"
tv="$(running_version "$VM_PREFIX$target")"
[[ "$lv" != "$tv" ]] \
  && pass "leader runs $lv, patched standby runs $tv" \
  || fail "both run $lv: the cluster is not mixed-version, so nothing is being tested"

probe="patch_probe_$$"
on "$VM_PREFIX$leader" sudo -u postgres psql -qAt -d appdb \
  -c "CREATE TABLE IF NOT EXISTS $probe (id int)" -c "INSERT INTO $probe VALUES (1)" >/dev/null 2>&1
replicated=""
for _ in {1..30}; do
  got="$(on "$VM_PREFIX$target" sudo -u postgres psql -tAc "SELECT count(*) FROM $probe" -d appdb 2>/dev/null)"
  [[ "$got" == "1" ]] && { replicated=yes; break; }
  sleep 2
done
[[ -n "$replicated" ]] \
  && pass "a row written on $lv arrived on $tv: replication crosses the version boundary" \
  || fail "the row never arrived: mixed-version replication is not working"
on "$VM_PREFIX$leader" sudo -u postgres psql -qAt -d appdb -c "DROP TABLE IF EXISTS $probe" >/dev/null 2>&1

echo
echo "=== AC-7: the cluster is not left degraded ==="
final="$(patroni_json)"
leaders="$(jq -r '[.[] | select(.Role == "Leader")] | length' <<< "$final")"
streaming="$(jq -r '[.[] | select(.State == "streaming")] | length' <<< "$final")"
[[ "$leaders" == "1" && "$streaming" == "2" ]] \
  && pass "one leader and two streaming standbys" \
  || fail "expected 1 leader and 2 streaming, got $leaders and $streaming"

paused="$(on "$VM_PREFIX$leader" sudo -u postgres patronictl -c "$PATRONI_CONFIG" list 2>/dev/null | grep -ci "maintenance mode" || true)"
(( paused == 0 )) \
  && pass "the cluster is not paused" \
  || fail "the cluster is PAUSED: automatic failover is off, which runbook 3 exists to catch"

dcs="$(on "$VM_PREFIX$leader" sudo -u postgres patronictl -c "$PATRONI_CONFIG" show-config 2>/dev/null)"
grep -q "synchronous_mode: quorum" <<< "$dcs" \
  && pass "quorum commit is still configured" \
  || fail "synchronous_mode is not quorum after the patch"
grep -q "synchronous_mode_strict: true" <<< "$dcs" \
  && pass "and still strict, so the durability guarantee has no exception" \
  || fail "synchronous_mode_strict is not true after the patch"

for m in $(jq -r '.[].Member' <<< "$final"); do
  on "$VM_PREFIX$m" test -c /dev/watchdog \
    && pass "$m: /dev/watchdog is present" \
    || fail "$m: no /dev/watchdog, so this node cannot be promoted"
done
on "$VM_PREFIX$leader" sudo journalctl -u percona-patroni --no-pager -n 400 2>/dev/null \
  | grep -qi "watchdog.*not usable" \
  && fail "the leader logged that its watchdog is not usable" \
  || pass "the leader reports no watchdog fault"

echo
echo "  P1: $target patched $built_version -> $TARGET_VERSION in ${restart_elapsed}s, leader key never moved"
echo
(( failures == 0 )) && { echo "PASS"; exit 0; }
echo "FAILED: $failures problem(s)" >&2
exit 1
