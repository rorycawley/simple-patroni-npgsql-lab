#!/usr/bin/env bash
set -uo pipefail

# AC-1, rung 1 of the ladder: a node is replaced from the REPOSITORY, not from
# the primary.
#
# This is the cheapest rung and the one most clusters get wrong by default.
# Patroni's out-of-the-box method is `basebackup`, which streams the whole data
# directory off the primary -- so rebuilding a standby loads the primary under
# exactly the conditions that lost the node in the first place. On a large
# database that is the difference between a rebuild costing the cluster nothing
# and costing it its remaining headroom.
#
# The repository already holds everything needed and is not on the write path,
# so `pgbackrest` goes first and `basebackup` stays as the fallback. Asserting
# WHICH method ran is the entire point: a rebuilt standby that streams again
# looks identical either way, and the difference is only visible in the log and
# in what the primary was asked to do.

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly VM_NAMES=(lab4-pg1 lab4-pg2 lab4-pg3)
readonly VM_PREFIX="lab4-"
readonly STANZA=lab4
readonly PATRONI_CONFIG=/etc/patroni/patroni.yml
readonly PGBIN=/usr/pgsql-18/bin

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
      printf '%s\n' "$out"; return 0
    fi
  done
  return 1
}
leader_vm() {
  printf '%s%s\n' "$VM_PREFIX" \
    "$(jq -r '.[] | select(.Role | test("Leader")) | .Member' <<< "$(patroni_json)")"
}
wait_for_quorum() {
  local primary states
  for _ in {1..60}; do
    primary="$(leader_vm)"
    states="$(on "$primary" sudo -u postgres "$PGBIN/psql" -Atc \
      "select string_agg(sync_state, ',' order by application_name) from pg_stat_replication")"
    [[ "$states" == "quorum,quorum" ]] && return 0
    sleep 2
  done
  return 1
}

echo
echo "=== A settled cluster, and a standby to sacrifice ==="
wait_for_quorum || { echo "cluster was not settled before the test" >&2; exit 1; }
leader="$(leader_vm)"
target=""
for vm in "${VM_NAMES[@]}"; do [[ "$vm" != "$leader" ]] && { target="$vm"; break; }; done
member="${target#$VM_PREFIX}"
echo "  leader is ${leader#$VM_PREFIX}; rebuilding ${member}"

# Rows committed before the rebuild. Rung 1 must lose none of them -- the claim
# is not just "the node came back" but "nothing was lost doing it".
rows_before="$(on "$leader" sudo -u postgres "$PGBIN/psql" -d appdb -Atc \
  "select count(*) from public.ha_probe")"

echo
echo "=== The configured method puts the repository ahead of the primary ==="
for vm in "${VM_NAMES[@]}"; do
  first="$(on "$vm" sudo bash -c "grep -A1 'create_replica_methods' $PATRONI_CONFIG | tail -1 | tr -d ' -'")"
  [[ "$first" == "pgbackrest" ]] \
    && pass "${vm#$VM_PREFIX}: first method is pgbackrest" \
    || fail "${vm#$VM_PREFIX}: first method is '${first:-unset}', so a rebuild would load the primary"
done
# basebackup must survive as the fallback. Removing it would trade one failure
# mode for a worse one: a repository problem would leave no way to build a node.
if on "$target" sudo grep -A2 'create_replica_methods' "$PATRONI_CONFIG" | grep -q basebackup; then
  pass "basebackup is retained as the fallback"
else
  fail "basebackup is gone; a repository outage would leave no way to rebuild a node"
fi

echo
echo "=== Destroy the standby and let Patroni rebuild it ==="
started="$SECONDS"
# Read only what happens from here on. Rotating and vacuuming the journal does
# NOT reliably clear it -- the active journal survives -- and an earlier version
# of this check matched the previous run's messages and "passed" in 1s having
# watched nothing. A cursor is exact.
cursor="$(on "$target" sudo journalctl -u percona-patroni --no-pager -n 0 --show-cursor 2>/dev/null \
  | sed -n 's/^-- cursor: //p')"
[[ -n "$cursor" ]] || { echo "could not take a journal cursor" >&2; exit 1; }
since_reinit() { on "$target" sudo journalctl -u percona-patroni --no-pager --after-cursor "$cursor" 2>/dev/null; }

on "$leader" sudo -u postgres patronictl -c "$PATRONI_CONFIG" \
  reinit "$STANZA" "$member" --force >/dev/null 2>&1

# Wait for the rebuild to BEGIN before waiting for it to finish. reinit is
# asynchronous -- Patroni acts on its next heartbeat -- so checking for
# "streaming" immediately finds the node still streaming from before it was
# touched. The first version of this check "passed" in 1s having observed
# nothing at all.
#
# The journal is the ground truth here, not the member state: Patroni may not
# publish an intermediate state between polls, and the member can drop out of
# the list entirely while it is being rebuilt.
# Either method announces itself here. "Removing data directory" is the
# basebackup path; "Leaving data directory uncleaned" is keep_data, which is
# what pgbackrest --delta needs and is therefore the message we expect.
started_rebuild=""
for _ in {1..60}; do
  if since_reinit | grep -qiE "Leaving data directory uncleaned|Removing data directory|restore command begin"; then
    started_rebuild=yes; break
  fi
  sleep 1
done
[[ -n "$started_rebuild" ]] \
  && pass "the rebuild started" \
  || fail "no sign the rebuild ever began; reinit did not take effect"

rebuilt=""
for _ in {1..90}; do
  state="$(jq -r --arg m "$member" '.[] | select(.Member == $m) | .State' <<< "$(patroni_json)")"
  [[ "$state" == "streaming" ]] && { rebuilt=yes; break; }
  sleep 2
done
elapsed=$((SECONDS - started))
[[ -n "$rebuilt" ]] \
  && pass "$member is streaming again, ${elapsed}s after being destroyed" \
  || fail "$member did not return to streaming"

echo
echo "=== It was rebuilt from the repository, which is the whole claim ==="
log="$(since_reinit)"
if grep -qi "replica has been created using pgbackrest" <<< "$log"; then
  pass "Patroni reports: replica created using pgbackrest"
elif grep -qi "replica has been created using basebackup" <<< "$log"; then
  fail "it fell back to basebackup: the primary served the rebuild after all"
else
  fail "cannot tell which method was used; neither message is in the journal"
fi

# keep_data is not cosmetic: pgbackrest --delta reuses what is already on disk,
# and Patroni wiping PGDATA first would turn every rebuild into a full transfer.
grep -qi "Leaving data directory uncleaned" <<< "$log" \
  && pass "keep_data honoured: --delta reused the existing directory" \
  || fail "Patroni cleaned PGDATA first, so --delta had nothing to reuse"

# What the restore actually moved, straight from pgBackRest's own report.
restore_line="$(grep -o "restore size = [^,]*, file total = [0-9]*" <<< "$log" | tail -1)"
[[ -n "$restore_line" ]] \
  && pass "the repository served it: $restore_line" \
  || fail "no pgBackRest restore report in the journal"

# The negative half. A rebuild via basebackup appears on the primary as a
# walsender in backup state; via the repository the primary is never asked.
if grep -qiE "pg_basebackup|BASE_BACKUP" <<< "$log"; then
  fail "the journal mentions a base backup; the primary was involved"
else
  pass "no base backup appears anywhere in the rebuild"
fi

echo
echo "=== Nothing was lost, and the cluster is whole ==="
wait_for_quorum \
  && pass "one leader and two quorum standbys again" \
  || fail "the cluster did not return to full redundancy"
rows_after="$(on "$(leader_vm)" sudo -u postgres "$PGBIN/psql" -d appdb -Atc \
  "select count(*) from public.ha_probe")"
[[ "$rows_after" == "$rows_before" ]] \
  && pass "rung 1 cost 0 rows ($rows_after before and after)" \
  || fail "row count changed across the rebuild: $rows_before -> $rows_after"

# The repository must be no worse for having been read.
on "$(leader_vm)" sudo -u postgres pgbackrest --stanza="$STANZA" verify >/dev/null 2>&1 \
  && pass "the repository still verifies after being used as a source" \
  || fail "verify failed after the rebuild"

echo
echo "  rung 1 cost: ${elapsed}s, 0 rows, no load on the primary"
echo
(( failures == 0 )) && { echo "PASS"; exit 0; }
echo "FAILED: $failures problem(s)" >&2
exit 1
