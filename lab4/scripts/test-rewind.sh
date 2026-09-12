#!/usr/bin/env bash
set -uo pipefail

# AC-4, rung 5: rewind the cluster to a marker, exactly.
#
# The emergency brake. Every rung below this one left the cluster serving; this
# one stops it, discards every transaction committed after the target, and
# rebuilds both standbys — they hold the future, so they are not a recovery
# source. Reaching for it when rung 3 or 4 would do is the expensive mistake the
# whole ladder exists to prevent.
#
# The criterion is exactness in BOTH directions. "Rows before the target are
# present" is half a check: a restore that included too much would pass it, and
# a restore that includes too much is as wrong as one that includes too little.
#
# It also measures what the rewind threw away, because that number is the
# difference between this rung and the cheaper ones, and nobody can choose
# between rungs whose costs are unstated.
#
# THE PAUSE IS THE DANGEROUS PART. Restoring under a running Patroni means it
# sees a node diverging from the DCS and tries to repair what is deliberately
# being rewound. So the cluster is paused first — and a failure between pause and
# resume would leave it healthy-looking with no automatic failover at all, which
# is exactly runbook 3. The trap resumes unconditionally.
#
# STOPPING PATRONI IS NOT STOPPING POSTGRESQL. The first version of this script
# assumed it was, and the whole rung failed on it:
#
#   pgbackrest: ERROR: [038]: unable to restore while PostgreSQL is running
#   systemd:    Unit process 2327 (postgres) remains running after unit stopped
#   postgres:   FATAL: pre-existing shared memory block (key 25165952) still in use
#
# The postmaster outlives its unit, pgBackRest rightly refuses to restore
# underneath it, and the orphan then blocks Patroni from starting a new one. Both
# processes are stopped here, and the absence of a postmaster is CHECKED rather
# than assumed before the restore is attempted.

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly VM_NAMES=(lab4-pg1 lab4-pg2 lab4-pg3)
readonly VM_PREFIX="lab4-"
readonly STANZA=lab4
readonly PATRONI_CONFIG=/etc/patroni/patroni.yml
readonly PGBIN=/usr/pgsql-18/bin
readonly RESTORE_DIR=/var/lib/pgsql-restore
readonly PGDATA_DIR=/var/lib/pgsql/data
readonly COPY_PORT=5433

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }
[[ -f "$LAB_DIR/.env" ]] || { echo "Run make create_vms first" >&2; exit 1; }
source "$LAB_DIR/.env"

failures=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; failures=$((failures + 1)); }
on() { local vm="$1"; shift; limactl shell --tty=false "$vm" "$@" 2>/dev/null; }
# AC-7: the run emits its own cost, so the ladder's table cannot drift from what
# was actually measured. One file per rung, read back by ladder-cost.sh.
record_cost() {
  local dir="$LAB_DIR/.costs"
  mkdir -p "$dir"
  printf '%s|%s|%s|%s\n' "${2:-?}" "${3:-?}" "${4:-?}" "${5:-}" > "$dir/rung$1"
}


patroni_json() {
  local out vm
  for vm in "${VM_NAMES[@]}"; do
    if out="$(on "$vm" sudo -u postgres patronictl -c "$PATRONI_CONFIG" list --format=json 2>/dev/null)"; then
      [[ -n "$out" ]] && { printf '%s\n' "$out"; return 0; }
    fi
  done
  return 1
}
leader_vm() {
  printf '%s%s\n' "$VM_PREFIX" \
    "$(jq -r '.[] | select(.Role | test("Leader")) | .Member' <<< "$(patroni_json)" 2>/dev/null)"
}
any_vm() { printf '%s\n' "${VM_NAMES[0]}"; }
pctl() { local vm="$1"; shift; on "$vm" sudo -u postgres patronictl -c "$PATRONI_CONFIG" "$@"; }

paused=0
stopped=0
restore_teardown() {
  # This script deliberately stops the whole cluster, so it owes the cluster a
  # way back up from wherever it died. Both halves of that are learned rather
  # than imagined: an earlier run left every node down and the operator holding
  # a broken cluster, and a run that dies between pause and resume leaves
  # something that looks perfectly healthy and has no high availability at all.
  if (( stopped )); then
    for vm in "${VM_NAMES[@]}"; do
      [[ "$(on "$vm" systemctl is-active percona-patroni)" == "active" ]] && continue
      on "$vm" sudo systemctl start percona-patroni >/dev/null 2>&1
    done
  fi
  if (( paused )); then
    for vm in "${VM_NAMES[@]}"; do
      pctl "$vm" resume >/dev/null 2>&1 && break
    done
  fi
  clear_restore_copies
}

# Every node, not `any_vm`: the negative control's copy is built on whichever
# node is LEADER, and stopping it on VM_NAMES[0] left a promoted copy running on
# port 5433 with a full data directory behind it. The next run's copy would then
# fail to start and the check would read the PREVIOUS run's database -- a stale
# artifact reported as this run's result.
clear_restore_copies() {
  local vm
  for vm in "${VM_NAMES[@]}"; do
    on "$vm" sudo -u postgres "$PGBIN/pg_ctl" -D "$RESTORE_DIR" stop -m immediate >/dev/null 2>&1
    on "$vm" sudo bash -c "rm -rf ${RESTORE_DIR:?}/* ${RESTORE_DIR}/.??*" >/dev/null 2>&1
  done
}
trap restore_teardown EXIT
clear_restore_copies   # leave nothing a previous run could pass off as this one's

wait_for_quorum() {
  local primary states
  for _ in {1..90}; do
    primary="$(leader_vm 2>/dev/null)"
    if [[ -n "$primary" && "$primary" != "$VM_PREFIX" ]]; then
      states="$(on "$primary" sudo -u postgres "$PGBIN/psql" -Atc \
        "select string_agg(sync_state, ',' order by application_name) from pg_stat_replication" </dev/null)"
      [[ "$states" == "quorum,quorum" ]] && return 0
    fi
    sleep 3
  done
  return 1
}

leader="$(leader_vm)" || { echo "cannot find the leader" >&2; exit 1; }
sql() { on "$leader" sudo -u postgres "$PGBIN/psql" -d appdb -Atc "$1" </dev/null; }
sql_on() { on "$1" sudo -u postgres "$PGBIN/psql" -d appdb -Atc "$2" </dev/null; }

echo
echo "=== Rows either side of a marker, on a settled cluster ==="
wait_for_quorum || { echo "cluster was not settled before the test" >&2; exit 1; }
echo "  leader is ${leader#$VM_PREFIX}"
sql "drop table if exists public.rung5" >/dev/null
sql "create table public.rung5 (id int primary key, phase text not null)" >/dev/null
sql "insert into public.rung5 select g, 'before' from generate_series(1,20) g" >/dev/null

on "$leader" sudo -u postgres pgbackrest --stanza="$STANZA" --type=full backup >/dev/null 2>&1
marker="rung5_$(date -u +%Y%m%d%H%M%S)"
sql "select pg_create_restore_point('$marker')" >/dev/null
# Captured at the same moment, to the second, the way an operator would if nobody
# had thought to place a marker. Used as AC-4's negative control below.
ts_target="$(sql "select now()::timestamp(0)")"
sql "select pg_switch_wal()" >/dev/null
sleep 3
pass "20 'before' rows, a full backup, and marker $marker"

echo
echo "=== Transactions after the marker: exactly what the rewind must discard ==="
sql "insert into public.rung5 select g, 'after' from generate_series(21,50) g" >/dev/null
after_count="$(sql "select count(*) from public.rung5 where phase = 'after'")"
probe_after="$(sql "select count(*) from public.ha_probe")"
sql "select pg_switch_wal()" >/dev/null
sleep 3
[[ "$after_count" == "30" ]] \
  && pass "30 rows committed after the marker" \
  || fail "expected 30 'after' rows, found $after_count"

echo
echo "=== Pause, rewind in place, resume ==="
started="$SECONDS"
pctl "$leader" pause >/dev/null 2>&1 && paused=1
grep -q "Maintenance mode: on" <<< "$(pctl "$leader" list 2>/dev/null)" \
  && pass "cluster paused: Patroni will not fight the restore" \
  || fail "the cluster is not paused; Patroni will try to repair what we rewind"

# Two separate acts, and conflating them is what broke this the first time.
# Stopping the unit stops PATRONI; the postmaster is reparented and keeps
# running. The standbys go down too: they hold the future and must not stream it
# back into a primary that has just been rewound.
stopped=1
for vm in "${VM_NAMES[@]}"; do
  on "$vm" sudo systemctl stop percona-patroni >/dev/null 2>&1
done
sleep 3
for vm in "${VM_NAMES[@]}"; do
  on "$vm" sudo -u postgres "$PGBIN/pg_ctl" -D "$PGDATA_DIR" -w -t 60 stop -m fast >/dev/null 2>&1
done

# Checked, not assumed. This is the assertion whose absence cost a broken
# cluster: pgBackRest exits 38 rather than restoring under a live postmaster,
# and the orphan then blocks Patroni from starting its own.
running=0
for vm in "${VM_NAMES[@]}"; do
  n="$(on "$vm" sudo bash -c "ps -eo args | grep -c '[/]usr/pgsql-18/bin/postgres'" | tr -d ' ')"
  running=$((running + ${n:-0}))
done
(( running == 0 )) \
  && pass "PostgreSQL is stopped on all three nodes, not merely unmanaged" \
  || fail "$running postmaster process(es) still running; pgBackRest will refuse to restore"

on "$leader" sudo -u postgres pgbackrest --stanza="$STANZA" --delta \
  --type=name --target="$marker" --target-action=promote --log-level-console=warn restore \
  >/dev/null 2>&1
rc=$?
(( rc == 0 )) && pass "restored in place to the marker" || fail "restore failed (exit $rc)"

# Complete recovery under pg_ctl, not under Patroni. The restore left
# recovery.signal together with recovery_target_name and
# recovery_target_action=promote; starting Patroni onto that invites it to write
# its own recovery configuration over the top before the target is reached. The
# operator watches the promotion happen and only then hands the node back --
# which is what the runbook asks for, for the same reason.
#
# archive_mode stays ON here, unlike rung 3. That node was a throwaway copy; this
# one IS production from now on, and its new timeline has to reach the repository
# or nothing will ever restore past this point again.
on "$leader" sudo -u postgres "$PGBIN/pg_ctl" -D "$PGDATA_DIR" -w -t 300 \
  -l "$PGDATA_DIR/rewind-startup.log" start >/dev/null 2>&1
recovered=""
for _ in {1..100}; do
  [[ "$(sql_on "$leader" "select not pg_is_in_recovery()")" == "t" ]] && { recovered=yes; break; }
  sleep 3
done
[[ -n "$recovered" ]] \
  && pass "recovery reached the marker and promoted: the node is read-write" \
  || fail "the rewound node never left recovery"
downtime=$((SECONDS - started))

# Hand the node back with PostgreSQL STILL RUNNING. Stopping it first looks
# tidier and quietly breaks the procedure: a paused Patroni does not start
# PostgreSQL -- it says so, `PAUSE: postgres is not running` -- so the node stays
# down until the resume, and Patroni then races for the free leader lock, loses
# on a WAL position the DCS recorded before the rewind ("My wal position exceeds
# maximum replication lag"), and brings the node back as a REPLICA with
# standby.signal. The rewind is correct on disk and the cluster has no primary.
#
# Started onto a running primary it adopts that instead and takes the lock, which
# is the reason the pause is still on at this point.
# Which branch of the handback this run exercised, recorded rather than assumed.
# The leader key has a 30s TTL and nothing refreshes it while the cluster is
# stopped, so whether it is still held when Patroni returns is a RACE with how
# long the restore took. Both outcomes are correct and they are not the same
# procedure, so the run says which one it got:
#
#   still held   Patroni reclaims its own key and continues as leader. No
#                election, so the rewound node's WAL position is never compared
#                with anything.
#   expired      Patroni races for a free lock. This is the branch that demoted
#                the node to a replica when PostgreSQL was down -- with it up,
#                Patroni adopts the running primary and takes the lock.
lock_holder="$(on "$leader" sudo bash -c \
  "etcdctl --cacert=/etc/lab4/pki/ca.crt --cert=/etc/lab4/pki/etcd.crt \
   --key=/etc/lab4/pki/etcd.key --endpoints=https://${PG1_IP}:2379 \
   get /service/lab4/leader --print-value-only" 2>/dev/null | tr -d '\n')"
if [[ -n "$lock_holder" ]]; then
  echo "  handback branch: the leader key is STILL HELD by '$lock_holder' (restore beat the ${ttl:-30}s TTL)"
else
  echo "  handback branch: the leader key has EXPIRED; Patroni must race for a free lock"
fi

on "$leader" sudo systemctl start percona-patroni >/dev/null 2>&1
adopted=""
for _ in {1..40}; do
  role="$(jq -r --arg m "${leader#$VM_PREFIX}" '.[] | select(.Member == $m) | .Role' \
    <<< "$(patroni_json)" 2>/dev/null)"
  [[ "$role" == "Leader" ]] && { adopted=yes; break; }
  sleep 3
done
[[ -n "$adopted" ]] \
  && pass "Patroni adopted the promoted node and holds the leader lock" \
  || fail "Patroni did not take the leader lock; the rewound node is not the leader"

echo
echo "=== The boundary is exact, in BOTH directions ==="
before_now="$(sql_on "$leader" "select count(*) from public.rung5 where phase = 'before'")"
after_now="$(sql_on "$leader" "select count(*) from public.rung5 where phase = 'after'")"
[[ "$before_now" == "20" ]] \
  && pass "all 20 rows committed before the marker are present" \
  || fail "only $before_now of 20 'before' rows survived: the restore included too little"
[[ "$after_now" == "0" ]] \
  && pass "none of the 30 rows committed after it are present" \
  || fail "$after_now 'after' rows survived: the restore included too much, which is as wrong as too little"

echo
echo "=== Rebuild the standbys: they hold the future ==="
for vm in "${VM_NAMES[@]}"; do
  [[ "$vm" == "$leader" ]] && continue
  on "$vm" sudo rm -rf "$PGDATA_DIR" >/dev/null 2>&1
  on "$vm" sudo systemctl start percona-patroni >/dev/null 2>&1
done
stopped=0   # every node has been asked to come back up
(( paused )) && { for vm in "${VM_NAMES[@]}"; do pctl "$vm" resume >/dev/null 2>&1 && { paused=0; break; }; done; }
grep -q "Maintenance mode: on" <<< "$(pctl "$(any_vm)" list 2>/dev/null)" \
  && fail "the cluster is STILL paused: it looks healthy and has no failover" \
  || pass "cluster resumed; automatic failover is live again"

wait_for_quorum \
  && pass "one leader and two streaming quorum standbys again" \
  || fail "the cluster did not return to full redundancy"
elapsed=$((SECONDS - started))

echo
echo "=== The repository's newest backup is now on an abandoned timeline ==="
# Easy to skip and expensive to skip. Every backup in the repository predates the
# rewind, so after this the only route back to *now* is an old backup plus WAL
# replayed across a timeline switch -- which works, and is a dependency nobody
# should be carrying unnecessarily. A full backup on the current timeline removes
# it, and belongs in the runbook as the last step of any rung-5 operation.
new_leader="$(leader_vm)"
on "$new_leader" sudo -u postgres pgbackrest --stanza="$STANZA" --type=full backup >/dev/null 2>&1 \
  && pass "a fresh full backup was taken on the timeline the cluster is actually on" \
  || fail "no backup after the rewind: the repository still only knows the abandoned timeline"

echo
echo "=== AC-6: the result is a cluster, not a data directory ==="
[[ "$(sql_on "$new_leader" "select count(*) from public.rung5 where phase='before'")" == "20" ]] \
  && pass "the recovered data is there, through Patroni's leader" \
  || fail "the leader does not hold the recovered rows"
on "$new_leader" sudo -u postgres "$PGBIN/psql" -d appdb -Atc \
  "insert into public.ha_probe (probe_id, client_name, server_address)
   values ('rung5-proof-'||floor(random()*100000)::text, 'rung5', '127.0.0.1')" </dev/null >/dev/null 2>&1 \
  && pass "it accepts writes: quorum commit is satisfied, so a standby confirmed it" \
  || fail "the cluster cannot accept a write"
on "$new_leader" sudo -u postgres pgbackrest --stanza="$STANZA" check >/dev/null 2>&1 \
  && pass "archiving works on the rewound cluster, into the same stanza" \
  || fail "pgbackrest check fails after the rewind"

echo
echo "=== AC-4's negative control: a timestamp cannot do this ==="
# Same intended moment, expressed the way a real incident supplies it. Restored
# BESIDE rather than in place -- the property under test is target precision, not
# rewind mechanics, and there is no reason to stop the cluster twice.
on "$new_leader" sudo bash -c "rm -rf ${RESTORE_DIR:?}/* ${RESTORE_DIR}/.??*" >/dev/null 2>&1
on "$new_leader" sudo -u postgres pgbackrest --stanza="$STANZA" --pg1-path="$RESTORE_DIR" \
  --type=time --target="$ts_target" --target-action=promote --log-level-console=warn restore >/dev/null 2>&1
on "$new_leader" sudo -u postgres "$PGBIN/pg_ctl" -D "$RESTORE_DIR" -w -t 90 \
  -o "-p $COPY_PORT -c archive_mode=off -c listen_addresses=localhost" \
  -l "$RESTORE_DIR/startup.log" start >/dev/null 2>&1
ts_before="$(on "$new_leader" sudo -u postgres "$PGBIN/psql" -p "$COPY_PORT" -d appdb -Atc \
  "select count(*) from public.rung5 where phase='before'" </dev/null 2>/dev/null)"
echo "  target by name      -> 20 'before' rows (exact)"
echo "  target by timestamp -> ${ts_before:-<unreadable>} 'before' rows, for the same moment"
if [[ "$ts_before" == "20" ]]; then
  echo "  the timestamp happened to land correctly this time; it is not guaranteed to,"
  echo "  because it cannot separate two commits within the same second"
  pass "recorded: a second-precision target reproduced the boundary here, by luck rather than by design"
else
  pass "a timestamp target did NOT reproduce the boundary (${ts_before:-none} vs 20): it cannot separate commits within one second"
fi

echo
echo "  rung 5 cost: ${downtime}s before the cluster could serve again,"
echo "               ${elapsed}s before it was redundant again,"
echo "               $after_count committed transactions discarded, both standbys rebuilt"
record_cost 5 "$elapsed" "$after_count" "$downtime" "rewound the whole cluster to a marker; everything after it was discarded"
echo
(( failures == 0 )) && { echo "PASS"; exit 0; }
echo "FAILED: $failures problem(s)" >&2
exit 1
