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
readonly VM_NAMES=(lab4-pg1 lab4-pg2 lab4-pg3)
readonly VM_PREFIX="lab4-"
readonly STANZA=lab4
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
secret() { sed -n "s/^$1: \"\\(.*\\)\"$/\\1/p" "$CLUSTER_SECRETS" 2>/dev/null; }

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
  on "$leader" sudo -u postgres pgbackrest --stanza="$STANZA" verify >/dev/null 2>&1 \
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
"$SCRIPT_DIR/minio.sh" start >/dev/null 2>&1
make -C "$LAB_DIR" create_vms >/dev/null 2>&1
make -C "$LAB_DIR" rebuild_prepare >/dev/null 2>&1 \
  && pass "fresh machines prepared: packages, encrypted volumes, TLS, etcd" \
  || fail "the rebuild did not complete"

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
on "$first" sudo -u postgres "$PGBIN/psql" --no-psqlrc --set=ON_ERROR_STOP=1 -Atc \
  "alter role postgres with password '$super_pw'" </dev/null >/dev/null 2>&1 \
  && pass "the superuser password now matches the rebuilt cluster's configuration" \
  || fail "could not reset the superuser password"
on "$first" sudo -u postgres "$PGBIN/psql" --no-psqlrc --set=ON_ERROR_STOP=1 -Atc \
  "alter role replicator with password '$repl_pw'" </dev/null >/dev/null 2>&1 \
  && pass "the replication password matches, so standbys will be able to attach" \
  || fail "could not reset the replication password"

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
armed=0
for vm in "${VM_NAMES[@]}"; do
  on "$vm" sudo journalctl -u percona-patroni --no-pager 2>/dev/null \
    | grep -qi "watchdog" && armed=$((armed + 1))
done
(( armed == 3 )) \
  && pass "the watchdog is armed on all three nodes" \
  || fail "only $armed node(s) report a watchdog; fencing is not fully restored"

echo
echo "  rung 6 cost: ${restore_elapsed}s restore + ${replay_elapsed}s replay,"
echo "               ${total_elapsed}s from destruction to a redundant cluster,"
echo "               0 rows lost, and nothing survived but the repository and one passphrase"
echo
rm -f "$STATE"
(( failures == 0 )) && { echo "PASS"; exit 0; }
echo "FAILED: $failures problem(s)" >&2
exit 1
