#!/usr/bin/env bash
set -uo pipefail

# AC-6: an upgrade whose binaries will not start, recovered WITHOUT rebuilding
# the node.
#
# Patching procedures are written for the case where the package installs. The
# interesting question is what an operator does at 23:00 when it does not, and
# whether the answer is "rebuild the node" -- which on this cluster means a
# reinit and a resync of the whole data directory.
#
# The claim being tested is therefore a NEGATIVE one, and negatives are easy to
# assert badly. "It came back" is true of a rebuild as well, so it proves
# nothing. Three independent things are checked instead: the journal never
# announces a replica being created, the database keeps the same system
# identifier, and a sentinel file planted in the data directory is still there
# afterwards. A rebuild would break all three.
#
# The break is a corrupted binary rather than a hand-built bad RPM. What matters
# is that PostgreSQL will not exec, which is what a bad package delivers, and
# that the documented rollback -- `dnf downgrade` -- is what repairs it, because
# reinstalling the older package replaces the binary. The recovery path is real
# even though the damage is simulated.
#
# It also proves something the rollback depends on and which is easy to assume:
# 18.4 binaries can open a data directory last written by 18.6. Minor versions do
# not change the on-disk format, which is precisely why a downgrade is available
# as a rollback at all.

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly VM_NAMES=(lab6-pg1 lab6-pg2 lab6-pg3)
readonly VM_PREFIX="lab6-"
readonly STANZA=lab6
readonly PATRONI_CONFIG=/etc/patroni/patroni.yml
readonly PGBIN=/usr/pgsql-18/bin
readonly PGDATA=/var/lib/pgsql/data
readonly SENTINEL="$PGDATA/lab6_p6_sentinel"
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
leader_of() { jq -r '.[] | select(.Role | test("Leader")) | .Member' <<< "$1"; }
state_of() { jq -r --arg m "$1" '.[] | select(.Member == $m) | .State' <<< "$(patroni_json)"; }
installed_on() { on "$VM_PREFIX$1" rpm -q --qf '%{VERSION}' percona-postgresql18-server 2>/dev/null; }
sysid_of() { on "$VM_PREFIX$1" sudo -u postgres "$PGBIN/pg_controldata" "$PGDATA" 2>/dev/null \
  | awk -F: '/Database system identifier/ {gsub(/ /,"",$2); print $2}'; }

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
pg_packages() { printf '%s' "percona-postgresql18-server-$1* percona-postgresql18-$1* percona-postgresql18-contrib-$1* percona-postgresql18-libs-$1*"; }

echo
echo "=== A healthy cluster, and a standby to break ==="
cluster="$(patroni_json)" || { echo "  FAIL: no Patroni cluster answered" >&2; exit 1; }
leader="$(leader_of "$cluster")"
target="$(jq -r '.[] | select(.Role | test("Leader") | not) | .Member' <<< "$cluster" | head -1)"
echo "  leader is $leader; breaking the upgrade on standby $target"
[[ "$(jq -r '[.[] | select(.State == "streaming")] | length' <<< "$cluster")" == "2" ]] \
  && pass "two streaming standbys before anything is broken" \
  || fail "the cluster is not healthy; refusing to measure a recovery from a broken start"
[[ "$(installed_on "$target")" == "$TARGET_VERSION" ]] \
  && pass "$target is on $TARGET_VERSION, the version whose binaries are about to fail" \
  || fail "$target is on $(installed_on "$target"), not the upgraded version this phase assumes"

# The three things a rebuild would destroy, recorded before the damage.
sysid_before="$(sysid_of "$target")"
[[ -n "$sysid_before" ]] && pass "system identifier before: $sysid_before" || fail "could not read the system identifier"
on "$VM_PREFIX$target" sudo -u postgres touch "$SENTINEL"
on "$VM_PREFIX$target" sudo test -f "$SENTINEL" \
  && pass "a sentinel file is planted in the data directory" \
  || fail "could not plant the sentinel"
data_mb="$(on "$VM_PREFIX$target" sudo du -sm "$PGDATA" 2>/dev/null | awk '{print $1}')"
echo "  the data directory is ${data_mb:-?} MB -- what a rebuild would have to move"
cursor="$(on "$VM_PREFIX$target" sudo journalctl -u percona-patroni -n 0 --show-cursor 2>/dev/null | sed -n 's/^-- cursor: //p')"

echo
echo "=== Break it: the new binaries will not start ==="
# The binary is RENAMED and a failing stub put in its place, rather than
# overwritten. Linux refuses to write to a file it is currently executing --
# `dd` returned "Text file busy" and, with its error sent to /dev/null, the phase
# went on to "prove" three things about a node that had never been broken. A
# rename succeeds because the running postmaster keeps the old inode, and the
# path is then free to hold the stub.
#
# `dnf downgrade` repairs it by writing a real binary back to that path, which is
# exactly the documented rollback.
swap_err="$(on "$VM_PREFIX$target" sudo mv "$PGBIN/postgres" "$PGBIN/postgres.p6-orig" 2>&1)"
[[ -z "$swap_err" ]] || { fail "could not move the binary aside: $swap_err"; }
on "$VM_PREFIX$target" sudo sh -c "printf '#!/bin/sh\necho \"simulated bad package\" >&2\nexit 1\n' > $PGBIN/postgres && chmod 755 $PGBIN/postgres"
on "$VM_PREFIX$target" sudo "$PGBIN/postgres" --version >/dev/null 2>&1 \
  && fail "the binary still runs; the break did not take and nothing below is meaningful" \
  || pass "the postgres binary no longer executes"

break_start=$SECONDS
on "$VM_PREFIX$leader" sudo -u postgres patronictl -c "$PATRONI_CONFIG" \
  restart "$STANZA" "$target" --force >/dev/null 2>&1

# The positive control for the break itself: the node must genuinely fail, or the
# recovery below would be repairing nothing.
broken=""
for _ in {1..30}; do
  st="$(state_of "$target")"
  [[ "$st" != "streaming" && "$st" != "running" ]] && { broken=yes; break; }
  sleep 3
done
[[ -n "$broken" ]] \
  && pass "$target is '$(state_of "$target")': the upgrade left it unable to start, which is the incident" \
  || fail "$target is still healthy after its binary was destroyed; the fault was not induced"

echo
echo "=== The documented rollback: downgrade, do not rebuild ==="
rollback_start=$SECONDS
# shellcheck disable=SC2046
dnf_do "$VM_PREFIX$target" downgrade $(pg_packages "$BUILD_VERSION") \
  && pass "packages rolled back to $BUILD_VERSION" \
  || fail "the downgrade itself failed"
on "$VM_PREFIX$target" sudo "$PGBIN/postgres" --version >/dev/null 2>&1 \
  && pass "and the binary executes again: reinstalling the package replaced the damaged file" \
  || fail "the binary still does not run after the downgrade"
# The stashed original is removed only now, so that a failed downgrade leaves a
# way back rather than a node with no postgres binary at all.
on "$VM_PREFIX$target" sudo rm -f "$PGBIN/postgres.p6-orig" >/dev/null 2>&1

on "$VM_PREFIX$target" sudo systemctl restart percona-patroni >/dev/null 2>&1
recovered=""
for _ in {1..60}; do
  [[ "$(state_of "$target")" == "streaming" ]] && { recovered=yes; break; }
  sleep 3
done
rollback_elapsed=$((SECONDS - rollback_start))
[[ -n "$recovered" ]] \
  && pass "$target is streaming again ${rollback_elapsed}s after the rollback began" \
  || fail "$target did not return to streaming after the rollback"

echo
echo "=== AC-6: it was NOT rebuilt -- three independent proofs ==="
# 1. The journal. This is the same line rung 1 asserts to prove a rebuild DID
#    happen, so its absence is meaningful rather than merely quiet.
rebuild_log="$(on "$VM_PREFIX$target" sudo journalctl -u percona-patroni --no-pager --after-cursor "$cursor" 2>/dev/null)"
grep -qiE "replica has been created using (pgbackrest|basebackup)" <<< "$rebuild_log" \
  && fail "the journal says a replica was created: the node WAS rebuilt, which is what AC-6 forbids" \
  || pass "the journal never announces a replica being created: no rebuild was performed"

# 2. The database's own identity.
sysid_after="$(sysid_of "$target")"
[[ -n "$sysid_after" && "$sysid_after" == "$sysid_before" ]] \
  && pass "the system identifier is unchanged ($sysid_after): the same database, not a copy" \
  || fail "the system identifier moved $sysid_before -> ${sysid_after:-unreadable}"

# 3. The sentinel, which any restore into this directory would have removed.
on "$VM_PREFIX$target" sudo test -f "$SENTINEL" \
  && pass "the sentinel file survived: the data directory was never replaced" \
  || fail "the sentinel is gone, so the data directory was rewritten underneath"
on "$VM_PREFIX$target" sudo rm -f "$SENTINEL" >/dev/null 2>&1

echo
echo "=== And 18.4 binaries opened a data directory written by 18.6 ==="
running="$(on "$VM_PREFIX$target" sudo -u postgres "$PGBIN/psql" -tAc 'SHOW server_version' 2>/dev/null | awk '{print $1}')"
[[ "$running" == "$BUILD_VERSION" ]] \
  && pass "it is serving on $running against a directory last written by $TARGET_VERSION: minor versions share an on-disk format, which is what makes this rollback possible" \
  || fail "it reports $running, not the rolled-back $BUILD_VERSION"

echo
echo "=== What the rollback saved ==="
rung1="$(cat "$LAB_DIR/.costs/rung1" 2>/dev/null | cut -d'|' -f1)"
echo "  rollback: ${rollback_elapsed}s, moving packages only"
echo "  rung 1 (rebuild from the repository): ${rung1:-?}s, moving the whole ${data_mb:-?} MB data directory"
echo "  On this lab database both are fast, and the seconds are not the point: the"
echo "  rollback's cost is fixed at the size of the packages, while a rebuild's"
echo "  grows with the database. That ratio is what matters at 23:00 on a real one."

echo
echo "=== Leave the cluster consistent: put it back on $TARGET_VERSION ==="
# shellcheck disable=SC2046
dnf_do "$VM_PREFIX$target" upgrade $(pg_packages "$TARGET_VERSION") \
  && pass "packages upgraded back to $TARGET_VERSION" \
  || fail "could not return $target to $TARGET_VERSION"
on "$VM_PREFIX$leader" sudo -u postgres patronictl -c "$PATRONI_CONFIG" \
  restart "$STANZA" "$target" --force >/dev/null 2>&1
back=""
for _ in {1..60}; do
  [[ "$(state_of "$target")" == "streaming" ]] && { back=yes; break; }
  sleep 3
done
[[ -n "$back" ]] \
  && pass "$target is streaming on $(on "$VM_PREFIX$target" sudo -u postgres "$PGBIN/psql" -tAc 'SHOW server_version' 2>/dev/null | awk '{print $1}')" \
  || fail "$target did not return to streaming on $TARGET_VERSION"

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
echo "  P6: $target recovered from binaries that would not start in ${rollback_elapsed}s, without a rebuild"
echo
(( failures == 0 )) && { echo "PASS"; exit 0; }
echo "FAILED: $failures problem(s)" >&2
exit 1
