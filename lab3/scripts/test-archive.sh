#!/usr/bin/env bash
set -uo pipefail

# AC-6: archiving survives a promotion, and the recoverable window is measured.
#
# This is the criterion a single-node pgBackRest guide would never raise.
# Archiving is a property of the PRIMARY, and the primary moves. A backup regime
# that works until the first failover and then silently stops is the exact shape
# of failure Lab 5 exists to detect -- and the reason its headline metric is the
# age of the last successful backup rather than any error count.
#
# The measurement matters as much as the assertion. "How far past the last backup
# can recovery reach" is what turns a backup schedule into an RPO, and SLA.md
# currently records that row as not established.

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly VM_NAMES=(lab3-pg1 lab3-pg2 lab3-pg3)
readonly VM_PREFIX="lab3-"
readonly STANZA=lab3
readonly PATRONI_CONFIG=/etc/patroni/patroni.yml
readonly PGBIN=/usr/pgsql-18/bin
readonly TIMERS=(lab3-backup-full.timer lab3-backup-incr.timer lab3-dump.timer)

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }
[[ -f "$LAB_DIR/.env" ]] || { echo "Run make create_vms first" >&2; exit 1; }

failures=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; failures=$((failures + 1)); }
on() { local vm="$1"; shift; limactl shell --tty=false "$vm" "$@" 2>/dev/null; }

restore_timers() {
  local vm timer
  for vm in "${VM_NAMES[@]}"; do
    for timer in "${TIMERS[@]}"; do on "$vm" sudo systemctl start "$timer" >/dev/null 2>&1; done
  done
}
trap restore_timers EXIT

patroni_json() {
  local out vm
  for vm in "${VM_NAMES[@]}"; do
    if out="$(on "$vm" sudo -u postgres patronictl -c "$PATRONI_CONFIG" list --format=json)"; then
      printf '%s\n' "$out"; return 0
    fi
  done
  return 1
}
leader_vm() {
  printf '%s%s\n' "$VM_PREFIX" \
    "$(jq -r '.[] | select(.Role | test("Leader")) | .Member' <<< "$(patroni_json)")"
}
repo_json() {
  local vm
  for vm in "${VM_NAMES[@]}"; do
    on "$vm" sudo -u postgres pgbackrest --stanza="$STANZA" --output=json info && return 0
  done
  return 1
}
wait_for_quorum() {
  local primary states
  for _ in {1..45}; do
    primary="$(leader_vm)"
    states="$(on "$primary" sudo -u postgres "$PGBIN/psql" -Atc \
      "select string_agg(sync_state, ',' order by application_name) from pg_stat_replication")"
    [[ "$states" == "quorum,quorum" ]] && return 0
    sleep 2
  done
  return 1
}

# The timers fire every couple of minutes here. A backup landing in the middle of
# a promotion assertion makes it flaky for reasons unrelated to the property.
echo
echo "=== Quiescing the backup timers ==="
for vm in "${VM_NAMES[@]}"; do
  for timer in "${TIMERS[@]}"; do on "$vm" sudo systemctl stop "$timer" >/dev/null 2>&1; done
done
wait_for_quorum || { echo "cluster was not settled before the test" >&2; exit 1; }

before_leader="$(leader_vm)"
echo "  leader is ${before_leader#$VM_PREFIX}"

echo
echo "=== A backup exists to archive past ==="
on "$before_leader" sudo -u postgres pgbackrest --stanza="$STANZA" --type=full backup >/dev/null 2>&1
info="$(repo_json)"
last_backup_stop="$(jq -r '.[0].backup[-1].timestamp.stop' <<< "$info")"
wal_before="$(jq -r '.[0].archive[-1].max' <<< "$info")"
[[ -n "$wal_before" && "$wal_before" != null ]] \
  && pass "archive reaches $wal_before before the promotion" \
  || { fail "no archived WAL before the promotion"; exit 1; }

echo
echo "=== Promote a different node, mid-cycle ==="
target=""
for vm in "${VM_NAMES[@]}"; do [[ "$vm" != "$before_leader" ]] && { target="$vm"; break; }; done
on "$before_leader" sudo -u postgres patronictl -c "$PATRONI_CONFIG" switchover \
  --leader "${before_leader#$VM_PREFIX}" --candidate "${target#$VM_PREFIX}" --force >/dev/null 2>&1

after_leader=""
for _ in {1..45}; do
  after_leader="$(leader_vm 2>/dev/null)"
  [[ "$after_leader" == "$target" ]] && break
  sleep 2
done
[[ "$after_leader" == "$target" ]] \
  && pass "the leader moved to ${target#$VM_PREFIX}" \
  || { fail "promotion did not reach $target"; exit 1; }
wait_for_quorum || fail "the cluster did not settle after the promotion"

echo
echo "=== The NEW primary archives into the SAME stanza, with no gap ==="
# Commit something that only exists after the promotion, then force the segment
# out so we are measuring archiving rather than waiting on archive_timeout.
probe="archive-probe-$$"
on "$after_leader" sudo -u postgres "$PGBIN/psql" -d appdb -Atc \
  "insert into public.ha_probe (probe_id, client_name, server_address)
   values ('$probe', 'archive-probe', '127.0.0.1')" >/dev/null 2>&1

commit_epoch="$(on "$after_leader" sudo -u postgres "$PGBIN/psql" -Atc "select extract(epoch from now())::bigint")"
target_wal="$(on "$after_leader" sudo -u postgres "$PGBIN/psql" -Atc \
  "select pg_walfile_name(pg_current_wal_lsn())")"
on "$after_leader" sudo -u postgres "$PGBIN/psql" -Atc "select pg_switch_wal()" >/dev/null 2>&1

archived_epoch=""
for _ in {1..60}; do
  if on "$after_leader" sudo -u postgres pgbackrest --stanza="$STANZA" \
       repo-ls "archive/$STANZA" --recurse --output=json 2>/dev/null | grep -q "$target_wal"; then
    archived_epoch="$(on "$after_leader" sudo -u postgres "$PGBIN/psql" -Atc \
      "select extract(epoch from now())::bigint")"
    break
  fi
  sleep 1
done

if [[ -n "$archived_epoch" ]]; then
  pass "the segment written after the promotion reached the repository: $target_wal"
else
  fail "the segment written after the promotion never reached the repository"
fi

after_info="$(repo_json)"
stanzas="$(jq -r '.[].name' <<< "$after_info" | sort -u | tr '\n' ' ')"
[[ "$stanzas" == "$STANZA " ]] \
  && pass "still one stanza, still '$STANZA': the new primary did not start a second history" \
  || fail "stanza set is now '$stanzas'"

on "$after_leader" sudo -u postgres pgbackrest --stanza="$STANZA" check >/dev/null 2>&1 \
  && pass "pgbackrest check passes on the new primary" \
  || fail "pgbackrest check fails on the new primary"

on "$after_leader" sudo -u postgres pgbackrest --stanza="$STANZA" verify >/dev/null 2>&1 \
  && pass "the archive verifies across the promotion: no gap, no corruption" \
  || fail "verify failed after the promotion; the WAL sequence is not intact"

echo
echo "=== The repository survives the node that wrote it ==="
# AC-2's live half: the backups were taken by the OLD leader. They must still be
# there, and readable, from a node that did not write them.
old_labels="$(jq -r '.[0].backup[].label' <<< "$info" | sort)"
now_labels="$(jq -r '.[0].backup[].label' <<< "$after_info" | sort)"
if comm -23 <(printf '%s\n' "$old_labels") <(printf '%s\n' "$now_labels") | grep -q .; then
  fail "a backup taken by the old leader is missing after the promotion"
else
  pass "every backup taken by the old leader is still listed from the new one"
fi

echo
echo "=== The next backup is taken by the NEW leader ==="
for vm in "${VM_NAMES[@]}"; do
  on "$vm" sudo systemctl start "lab3-backup@incr.service" >/dev/null 2>&1
done
if on "$after_leader" journalctl -u "lab3-backup@incr.service" -n 20 --no-pager | grep -q "Leader confirmed"; then
  pass "the promoted node took the next backup; the job followed the leader"
else
  fail "the promoted node did not take the next backup"
fi

echo
echo "=== The recoverable window, measured ==="
if [[ -n "$archived_epoch" ]]; then
  lag=$(( archived_epoch - commit_epoch ))
  gap=$(( commit_epoch - last_backup_stop ))
  echo "  a transaction committed after the promotion was archived off-host in ${lag}s"
  echo "  it was committed ${gap}s after the last base backup, and is recoverable regardless"
  echo "  unforced, archive_timeout bounds the same window at 60s"
  pass "recovery reaches past the last backup to within ${lag}s of a commit"
else
  fail "cannot measure the window: the segment never arrived"
fi

wait_for_quorum || fail "the cluster did not return to full redundancy"

echo
(( failures == 0 )) && { echo "PASS"; exit 0; }
echo "FAILED: $failures problem(s)" >&2
exit 1
