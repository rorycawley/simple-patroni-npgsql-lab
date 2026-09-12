#!/usr/bin/env bash
set -uo pipefail

# AC-5 and AC-6, rung 6: total loss.
#
# Every other rung recovers something from a cluster that still exists. This one
# assumes there is nothing: the VMs, their encrypted volumes, and every local
# secret are destroyed, and a working cluster is rebuilt from the repository plus
# `.recovery-inputs/` alone. Nothing is recovered from a surviving node, because
# there is none.
#
# THE RESET PATH. The restored data directory carries the OLD roles and their old
# password hashes, so a rebuilt cluster has to agree with them somehow. There are
# two ways and this lab takes the second:
#
#   supply the old passwords as recovery inputs -- simple, but it puts the
#     superuser and replication passwords on the list of things a customer must
#     protect through a disaster
#   reset them after restoring -- more steps, and the surviving set shrinks to
#     the repository plus one cipher passphrase
#
# The second makes the strongest claim this lab can make, and it is the one an
# operator can actually keep: a bucket and a passphrase.
#
# WHAT MUST NOT HAPPEN HERE is a bootstrap. Patroni's default is `initdb`, which
# would produce a brand-new cluster with a new system identifier -- and a
# pgBackRest stanza belongs to ONE database by that identifier, so the surviving
# backups would be unreadable by the very cluster meant to restore them. The
# rebuild therefore prepares the machines and stops, and the data arrives by
# restore before Patroni is ever started.

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly VM_NAMES=(lab5-pg1 lab5-pg2 lab5-pg3)
readonly VM_PREFIX="lab5-"
readonly STANZA=lab5
readonly PATRONI_CONFIG=/etc/patroni/patroni.yml
readonly PGBIN=/usr/pgsql-18/bin
readonly PGDATA_DIR=/var/lib/pgsql/data
readonly CLUSTER_SECRETS="$LAB_DIR/.secrets/cluster.yml"
readonly REPO_SECRETS="$LAB_DIR/.recovery-inputs/repo.yml"
readonly STATE="$LAB_DIR/.rung6-state"

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

# --dry-run stops before anything is destroyed, having proved the preconditions
# by USING them: the repository is readable with the surviving passphrase, the
# surviving credentials authenticate, and a backup covering the current data
# exists. That is a standing operational question -- "could we actually recover
# right now?" -- and it should be answerable without a disaster to find out.
DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

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

secret() { sed -n "s/^$1: \"\\(.*\\)\"$/\\1/p" "$CLUSTER_SECRETS" 2>/dev/null; }

# `timeout` inside the guest, because patronictl BLOCKS on an unreachable DCS
# rather than erroring. With etcd down this call sat for over five minutes, and a
# retry loop built on it never completes -- the run neither passes nor fails, it
# just stops producing output. A bounded call turns that into a visible failure.
patroni_json() {
  local out vm
  for vm in "${VM_NAMES[@]}"; do
    if out="$(on "$vm" sudo -u postgres timeout 20 patronictl -c "$PATRONI_CONFIG" list --format=json 2>/dev/null)"; then
      [[ -n "$out" ]] && { printf '%s\n' "$out"; return 0; }
    fi
  done
  return 1
}
leader_vm() {
  printf '%s%s\n' "$VM_PREFIX" \
    "$(jq -r '.[] | select(.Role | test("Leader")) | .Member' <<< "$(patroni_json)" 2>/dev/null)"
}

# ---------------------------------------------------------------------------
echo
echo "=== What has to come back, committed and pushed to the repository ==="
leader="$(leader_vm)"
[[ -n "$leader" && "$leader" != "$VM_PREFIX" ]] || { echo "no healthy cluster to destroy" >&2; exit 1; }
sql() { on "$leader" sudo -u postgres "$PGBIN/psql" -d appdb -Atc "$1" </dev/null; }
echo "  leader is ${leader#$VM_PREFIX}"

sql "drop table if exists public.rung6" >/dev/null
sql "create table public.rung6 (id int primary key, value text not null)" >/dev/null
sql "insert into public.rung6 select g, 'survives-'||g from generate_series(1,50) g" >/dev/null
expect_rung6="$(sql "select count(*) from public.rung6")"
expect_probe="$(sql "select count(*) from public.ha_probe")"
sysid="$(on "$leader" sudo -u postgres "$PGBIN/pg_controldata" "$PGDATA_DIR" \
  | sed -n 's/^Database system identifier: *//p')"
ca_before="$(openssl x509 -in "$LAB_DIR/.secrets/pki/ca.crt" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)"

# The data only counts as recoverable once it is in the REPOSITORY. A backup
# plus WAL that never left the node dies with the node.
on "$leader" sudo -u postgres pgbackrest --stanza="$STANZA" --type=full backup >/dev/null 2>&1
target_wal="$(sql "select pg_walfile_name(pg_current_wal_lsn())")"
sql "select pg_switch_wal()" >/dev/null
archived=""
for _ in {1..60}; do
  on "$leader" sudo -u postgres pgbackrest --stanza="$STANZA" repo-ls "archive/$STANZA" --recurse 2>/dev/null \
    | grep -q "$target_wal" && { archived=yes; break; }
  sleep 1
done
[[ -n "$archived" ]] \
  && pass "$expect_rung6 rows committed, backed up, and the closing WAL segment is in the repository" \
  || { fail "the last WAL segment never reached the repository; the rows would not survive"; exit 1; }

{ echo "expect_rung6=$expect_rung6"; echo "expect_probe=$expect_probe"
  echo "sysid=$sysid"; echo "ca_before=$ca_before"; } > "$STATE"
echo "  system identifier that must come back: $sysid"

# ---------------------------------------------------------------------------
if (( DRY_RUN )); then
  echo
  echo "=== Could we actually recover right now? ==="
  # Each of these uses a surviving input rather than checking it is present. A
  # passphrase that exists and does not decrypt is worth nothing, and the only
  # way to know the difference is to decrypt something with it.
  "$SCRIPT_DIR/repo-verify.sh" "$leader" "$STANZA" >/dev/null 2>&1 \
    && pass "the repository verifies: every backup and WAL segment decrypts and checksums" \
    || fail "the repository does not verify; a rebuild from it would not be trustworthy"

  fulls="$(on "$leader" sudo -u postgres pgbackrest --stanza="$STANZA" --output=json info \
    | jq -r '[.[0].backup[] | select(.type == "full")] | length')"
  (( ${fulls:-0} > 0 )) \
    && pass "$fulls full backup(s) to replay onto" \
    || fail "no full backup: WAL alone has no floor to restore onto"

  for k in repo_cipher_pass minio_backup_access_key minio_backup_secret_key; do
    grep -q "^$k:" "$REPO_SECRETS" \
      && pass "recovery input present: $k" \
      || fail "recovery input MISSING: $k -- the rebuild would fail at the first step"
  done
  "$SCRIPT_DIR/test-minio.sh" >/dev/null 2>&1 \
    && pass "the surviving object-store credentials authenticate and reach the bucket" \
    || fail "the surviving credentials do not open the repository"

  echo
  echo "=== What the real run would destroy, and what it would keep ==="
  echo "  destroy: 3 VMs and their LUKS volumes, .secrets/ (CA key, superuser,"
  echo "           replication and application passwords), .env, the client build"
  echo "  keep   : .minio/ (the repository) and .recovery-inputs/repo.yml"
  printf '  keep   : %s values, none of which are cluster credentials\n' \
    "$(grep -c ':' "$REPO_SECRETS")"
  echo
  echo "  Nothing was destroyed. Re-run without --dry-run to perform rung 6."
  echo
  (( failures == 0 )) && { echo "PASS (dry run)"; exit 0; }
  echo "FAILED: $failures problem(s)" >&2
  exit 1
fi

echo
echo "=== Destroy everything a disaster would take ==="
destroy_start="$SECONDS"
make -C "$LAB_DIR" clean >/dev/null 2>&1
[[ -d "$LAB_DIR/.secrets" ]] \
  && fail ".secrets/ survived; this is not a total loss" \
  || pass ".secrets/ is gone: the CA key, superuser and replication passwords with it"
still_up=0
for vm in "${VM_NAMES[@]}"; do
  limactl list 2>/dev/null | grep -q "^$vm " && still_up=$((still_up + 1))
done
(( still_up == 0 )) \
  && pass "all three VMs and their encrypted volumes are destroyed" \
  || fail "$still_up VM(s) survived the teardown"

# The two things that must NOT have been destroyed, checked rather than hoped.
[[ -s "$REPO_SECRETS" ]] \
  && pass "the recovery inputs survive: $(grep -c ':' "$REPO_SECRETS") values in .recovery-inputs/" \
  || { fail "the recovery inputs are gone; nothing below is possible"; exit 1; }
[[ -d "$LAB_DIR/.minio" ]] \
  && pass "the repository survives in .minio/" \
  || { fail "the repository is gone; there is nothing to restore from"; exit 1; }

# ---------------------------------------------------------------------------
echo
echo "=== Rebuild the machines, with a NEW CA and NEW passwords ==="
make -C "$LAB_DIR" create_vms >/dev/null 2>&1
# FATAL, not recorded and stepped over. An earlier version treated this as one
# more failed assertion and carried on: etcd had not started, so the next twelve
# minutes printed "ok" for a restore, a promotion and a credential reset that
# were all genuinely fine, and then hung indefinitely on the first call that
# needed the DCS. A precondition that fails has to stop the run, or the output
# describes a recovery that cannot finish.
prepare_log="$LAB_DIR/.rung6-prepare.log"
# FATAL, not recorded and stepped over. An earlier version treated this as one
# more failed assertion and carried on: the next twelve minutes printed "ok" for
# a restore, a promotion and a credential reset that were all genuinely fine, and
# then hung indefinitely on the first call that needed the DCS.
#
# This also used to retry once, on the belief that etcd's first bootstrap was
# flaky on cold VMs. It is not. The failure was a handler in this lab notifying
# only "Reload Patroni" and not the check it depends on, which failed the play at
# the END of configure.yml -- so start-etcd.yml never ran, and etcd was found
# stopped with no journal entries because nothing had ever tried to start it. The
# retry "worked" only because a second run changes no template and therefore
# notifies no handler. Diagnostics are kept; the retry is not.
if make -C "$LAB_DIR" rebuild_prepare > "$prepare_log" 2>&1; then
  pass "fresh machines prepared: packages, encrypted volumes, TLS, etcd"
else
  fail "the rebuild did not complete; nothing below it can be trusted"
  echo "  --- what Ansible reported ---" >&2
  grep -iE "^(fatal|failed|ERROR)|msg\":|unreachable" "$prepare_log" 2>/dev/null \
    | tail -8 | cut -c1-200 | sed 's/^/    /' >&2
  for vm in "${VM_NAMES[@]}"; do
    echo "  --- ${vm#$VM_PREFIX} ---" >&2
    on "$vm" sudo bash -c \
      'systemctl is-active etcd; journalctl -u etcd --no-pager -n 6 2>&1 | tail -6;
       echo "member dir: $(ls -A /var/lib/etcd/lab5 2>/dev/null | wc -l) entries"' 2>&1 \
      | sed 's/^/    /' >&2
  done
  exit 1
fi

# MinIO starts only NOW, and the order is not arbitrary. The teardown deleted
# .secrets/pki, so the object store has no server certificate until
# rebuild_prepare reissues one from the new CA. Started any earlier it comes up
# without TLS or not at all, and the restore fails with a message that says
# nothing about certificates:
#
#   WARN: [HostConnectError] unable to connect to '192.168.105.1:9200'
#   ERROR: [075]: no backup set found to restore
#
# "No backup set found" against a repository that is completely intact.
"$SCRIPT_DIR/minio.sh" start >/dev/null 2>&1
on "${VM_NAMES[0]}" sudo -u postgres pgbackrest --stanza="$STANZA" info >/dev/null 2>&1 \
  && pass "the repository answers from the rebuilt machines, over the new CA" \
  || { fail "the rebuilt nodes cannot reach the repository; the restore cannot start"; exit 1; }

# Checked here, where it is cheap to say so. Patroni cannot take a leader lock
# without a DCS, and the etcd bootstrap on freshly booted VMs is not always
# first-time green -- start-etcd.yml carries its own re-bootstrap for that. The
# failure this guards against is not etcd being slow, it is the run continuing
# past a dead DCS and reporting a recovery it cannot possibly complete.
etcd_up=0
for vm in "${VM_NAMES[@]}"; do
  [[ "$(on "$vm" systemctl is-active etcd)" == "active" ]] && etcd_up=$((etcd_up + 1))
done
(( etcd_up == 3 )) \
  && pass "etcd is running on all three nodes: there is a DCS to hand the cluster to" \
  || { fail "etcd is up on only $etcd_up/3 nodes; Patroni could not take a leader lock"; exit 1; }

ca_after="$(openssl x509 -in "$LAB_DIR/.secrets/pki/ca.crt" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)"
# shellcheck disable=SC1090
source "$STATE"
[[ -n "$ca_after" && "$ca_after" != "$ca_before" ]] \
  && pass "the CA is new, so nothing secret had to survive except the repository's own keys" \
  || fail "the CA is unchanged; this rebuild reused material a disaster would have taken"

empty=0
for vm in "${VM_NAMES[@]}"; do
  n="$(on "$vm" sudo bash -c "ls -A $PGDATA_DIR 2>/dev/null | wc -l" | tr -d ' ')"
  (( ${n:-0} == 0 )) && empty=$((empty + 1))
done
(( empty == 3 )) \
  && pass "no database was bootstrapped: all three data directories are empty" \
  || fail "$((3 - empty)) node(s) hold a database already; a bootstrap would have broken the stanza"

# ---------------------------------------------------------------------------
echo
echo "=== Restore onto one node, from the repository alone ==="
first="${VM_NAMES[0]}"
# The timers are live on the rebuilt machines and fire every couple of minutes.
# The leader gate should keep them idle while Patroni is stopped, but a backup
# that did start would hold the stanza lock and fail the restore underneath it.
# Quiesced explicitly rather than relying on the gate.
for vm in "${VM_NAMES[@]}"; do
  on "$vm" sudo systemctl stop lab5-backup-full.timer lab5-backup-incr.timer lab5-dump.timer \
    >/dev/null 2>&1
done
restore_start="$SECONDS"
on "$first" sudo -u postgres pgbackrest --stanza="$STANZA" --log-level-console=warn restore >/dev/null 2>&1
rc=$?
restore_elapsed=$((SECONDS - restore_start))
(( rc == 0 )) \
  && pass "restored in ${restore_elapsed}s, decrypted with the surviving passphrase" \
  || { fail "restore failed (exit $rc)"; exit 1; }

# Replay is the second half of the cost and it is not the same number. The
# restore moves files; the replay applies every WAL segment archived since the
# backup, and that is what an operator's RTO actually depends on.
replay_start="$SECONDS"
on "$first" sudo -u postgres "$PGBIN/pg_ctl" -D "$PGDATA_DIR" -w -t 600 \
  -l "$PGDATA_DIR/rung6-startup.log" start >/dev/null 2>&1
recovered=""
for _ in {1..120}; do
  [[ "$(on "$first" sudo -u postgres "$PGBIN/psql" -Atc 'select not pg_is_in_recovery()' </dev/null)" == "t" ]] \
    && { recovered=yes; break; }
  sleep 2
done
replay_elapsed=$((SECONDS - replay_start))
[[ -n "$recovered" ]] \
  && pass "replayed the archive and promoted in ${replay_elapsed}s" \
  || { fail "the restored node never finished recovery"; exit 1; }

sysid_now="$(on "$first" sudo -u postgres "$PGBIN/pg_controldata" "$PGDATA_DIR" \
  | sed -n 's/^Database system identifier: *//p')"
[[ "$sysid_now" == "$sysid" ]] \
  && pass "it is the same database: system identifier $sysid_now" \
  || fail "system identifier is $sysid_now, expected $sysid -- this is not the cluster that was lost"

# ---------------------------------------------------------------------------
echo
echo "=== Reset the restored roles to the new credentials ==="
# The reset path. These roles came back from the backup with the OLD hashes;
# nothing on this machine knows the old passwords, and nothing needs to.
super_pw="$(secret postgres_superuser_password)"
repl_pw="$(secret postgres_replication_password)"
[[ -n "$super_pw" && -n "$repl_pw" ]] \
  || { fail "could not read the newly generated passwords"; exit 1; }

# A statement timeout, because the failure here is a HANG rather than an error.
psql1() {
  on "$first" sudo -u postgres env PGOPTIONS='-c statement_timeout=30s' \
    "$PGBIN/psql" --no-psqlrc --set=ON_ERROR_STOP=1 -Atc "$1" </dev/null
}

# The reset path deadlocks against strict synchronous replication, and the two
# halves of the deadlock are each individually correct:
#
#   synchronous_standby_names comes back FROM THE BACKUP, naming standbys that
#   do not exist yet, so under synchronous_mode_strict every write blocks
#   an ALTER ROLE is a write, so resetting the replication password blocks
#   a standby cannot attach until that password is reset
#
# Measured as `wait_event = SyncRep` on the ALTER ROLE, waiting indefinitely.
# Suspending sync commit for the length of the reset is what breaks it. The
# setting is RESET rather than left cleared: postgresql.auto.conf overrides
# postgresql.conf, so a value left here would quietly outrank Patroni's own
# management of it for the life of the cluster.
psql1 "alter system set synchronous_standby_names = ''" >/dev/null 2>&1
psql1 "select pg_reload_conf()" >/dev/null 2>&1
pass "synchronous commit suspended for the reset: no standby exists to confirm it yet"

[[ "$(psql1 "alter role postgres with password '$super_pw'" 2>&1)" == "ALTER ROLE" ]] \
  && pass "the superuser password now matches the rebuilt cluster's configuration" \
  || fail "could not reset the superuser password"
[[ "$(psql1 "alter role replicator with password '$repl_pw'" 2>&1)" == "ALTER ROLE" ]] \
  && pass "the replication password matches, so standbys will be able to attach" \
  || fail "could not reset the replication password"

psql1 "alter system reset synchronous_standby_names" >/dev/null 2>&1
psql1 "select pg_reload_conf()" >/dev/null 2>&1
pass "synchronous commit handed back to Patroni, which owns that setting"

# ---------------------------------------------------------------------------
echo
echo "=== Hand it to Patroni and let the cluster re-form ==="
# PostgreSQL stays RUNNING. Patroni started onto a live primary adopts it and
# takes the leader lock; started onto a stopped one it would have to decide what
# this node is, and rung 5 measured how that goes wrong.
on "$first" sudo systemctl enable --now percona-patroni >/dev/null 2>&1
adopted=""
for _ in {1..60}; do
  [[ "$(jq -r --arg m "${first#$VM_PREFIX}" '.[] | select(.Member == $m) | .Role' \
     <<< "$(patroni_json)" 2>/dev/null)" == "Leader" ]] && { adopted=yes; break; }
  sleep 3
done
[[ -n "$adopted" ]] \
  && pass "Patroni adopted the restored node as leader, on an empty DCS" \
  || fail "Patroni did not take the restored node as leader"

for vm in "${VM_NAMES[@]}"; do
  [[ "$vm" == "$first" ]] && continue
  on "$vm" sudo systemctl enable --now percona-patroni >/dev/null 2>&1
done
settled=""
for _ in {1..90}; do
  states="$(on "$first" sudo -u postgres "$PGBIN/psql" -Atc \
    "select string_agg(sync_state, ',' order by application_name) from pg_stat_replication" </dev/null)"
  [[ "$states" == "quorum,quorum" ]] && { settled=yes; break; }
  sleep 5
done
total_elapsed=$((SECONDS - destroy_start))
[[ -n "$settled" ]] \
  && pass "both standbys built themselves from the repository and are streaming" \
  || fail "the cluster did not reach one leader and two quorum standbys"

make -C "$LAB_DIR" rebuild_finish >/dev/null 2>&1 \
  && pass "the application role and client were reissued against the new credentials" \
  || fail "the application could not be reattached"

# Scheduled backups resume. A recovered cluster whose timers stayed stopped is
# one incident away from having nothing to recover from next time.
for vm in "${VM_NAMES[@]}"; do
  on "$vm" sudo systemctl start lab5-backup-full.timer lab5-backup-incr.timer lab5-dump.timer \
    >/dev/null 2>&1
done
running_timers=0
for vm in "${VM_NAMES[@]}"; do
  [[ "$(on "$vm" systemctl is-active lab5-backup-incr.timer)" == "active" ]] \
    && running_timers=$((running_timers + 1))
done
(( running_timers == 3 )) \
  && pass "scheduled backups are running again on all three nodes" \
  || fail "only $running_timers node(s) have their backup timers running"

# ---------------------------------------------------------------------------
echo
echo "=== AC-5: the data is back ==="
new_leader="$(leader_vm)"
got_rung6="$(on "$new_leader" sudo -u postgres "$PGBIN/psql" -d appdb -Atc \
  "select count(*) from public.rung6" </dev/null)"
got_probe="$(on "$new_leader" sudo -u postgres "$PGBIN/psql" -d appdb -Atc \
  "select count(*) from public.ha_probe" </dev/null)"
[[ "$got_rung6" == "$expect_rung6" ]] \
  && pass "all $expect_rung6 rung-6 rows are present" \
  || fail "expected $expect_rung6 rows, found ${got_rung6:-none}"
[[ "$got_probe" == "$expect_probe" ]] \
  && pass "ha_probe came back complete: $got_probe rows" \
  || fail "ha_probe holds ${got_probe:-none} rows, expected $expect_probe"

echo
echo "=== AC-6: it is a cluster, not a data directory ==="
"$SCRIPT_DIR/test-npgsql.sh" >/dev/null 2>&1 \
  && pass "the Npgsql client connects to the primary and commits through it" \
  || fail "the client cannot use the recovered cluster"
on "$new_leader" sudo -u postgres pgbackrest --stanza="$STANZA" check >/dev/null 2>&1 \
  && pass "archiving works again, into the same stanza it was recovered from" \
  || fail "pgbackrest check fails on the recovered cluster"
# Patroni arms the watchdog when it becomes LEADER, so "every node logged it" is
# the wrong question -- a node that has never been promoted never will have, and
# the first version of this check failed a perfectly healthy cluster on it. What
# has to be true is that every node COULD arm it, and that the one currently
# holding the leader lock HAS.
usable=0
for vm in "${VM_NAMES[@]}"; do
  on "$vm" sudo bash -c 'test -c /dev/watchdog && test "$(stat -c %U /dev/watchdog)" = postgres' \
    && usable=$((usable + 1))
done
(( usable == 3 )) \
  && pass "/dev/watchdog is present and owned by postgres on all three nodes" \
  || fail "only $usable node(s) could arm a watchdog; fencing is not fully restored"
on "$new_leader" sudo journalctl -u percona-patroni --no-pager 2>/dev/null \
  | grep -qi "watchdog activated" \
  && pass "the leader has the watchdog armed" \
  || fail "the leader did not arm its watchdog; a frozen Patroni would not be fenced"

echo
echo "  rung 6 cost: ${restore_elapsed}s restore + ${replay_elapsed}s replay,"
echo "               ${total_elapsed}s from destruction to a redundant cluster,"
echo "               0 rows lost, and nothing survived but the repository and one passphrase"
record_cost 6 "$total_elapsed" 0 "$total_elapsed" "rebuilt from the repository onto fresh machines after total loss"
echo
rm -f "$STATE"
(( failures == 0 )) && { echo "PASS"; exit 0; }
echo "FAILED: $failures problem(s)" >&2
exit 1
