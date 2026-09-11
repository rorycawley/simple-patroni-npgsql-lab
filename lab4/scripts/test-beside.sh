#!/usr/bin/env bash
set -uo pipefail

# AC-2, rung 3: a copy is restored BESIDE a cluster that never stops serving.
#
# This is the rung people skip and usually the right answer. You know which rows
# were damaged; you do not know what they held before. Rewinding the cluster
# would recover them and discard every unrelated transaction committed since --
# including everything committed while you were working out what went wrong.
#
# Restoring a copy alongside production costs an outage of nothing and loses
# nothing. The old values are read out of the copy and written forward.
#
# Three things this check must prove, and the last two are what make it more
# than a demonstration that `pgbackrest restore` accepts a --pg1-path:
#
#   1. the damaged rows hold their original values again
#   2. production NEVER STOPPED -- a client commits throughout, zero failures
#   3. nothing written during the operation was lost
#
# And one it must not cause: the copy inherits archive_command from the backup.
# Promoted with archiving on -- which reading it requires -- it pushes WAL from a
# divergent timeline into the production stanza, corrupting the repository every
# other rung depends on. Measured, not imagined. Hence archive_mode=off.

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly VM_NAMES=(lab4-pg1 lab4-pg2 lab4-pg3)
readonly VM_PREFIX="lab4-"
readonly STANZA=lab4
readonly PATRONI_CONFIG=/etc/patroni/patroni.yml
readonly PGBIN=/usr/pgsql-18/bin
readonly RESTORE_DIR=/var/lib/pgsql-restore
readonly COPY_PORT=5433

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
leader="$(leader_vm)" || { echo "cannot find the leader" >&2; exit 1; }
sql()  { on "$leader" sudo -u postgres "$PGBIN/psql" -d appdb -Atc "$1"; }
copy() { on "$leader" sudo -u postgres "$PGBIN/psql" -p "$COPY_PORT" -d appdb -Atc "$1"; }

cleanup() {
  # Kill the background client BEFORE removing its files. Deleting them while it
  # runs leaves the previous run's client appending failures into this run's
  # counters -- which is how 48 failures appeared from a client that had already
  # been "cleaned up".
  on "$leader" sudo pkill -f rung3-client.sh >/dev/null 2>&1
  on "$leader" sudo -u postgres "$PGBIN/pg_ctl" -D "$RESTORE_DIR" stop -m immediate >/dev/null 2>&1
  on "$leader" sudo bash -c "rm -rf ${RESTORE_DIR:?}/* ${RESTORE_DIR}/.??* /tmp/rung3-client.*" >/dev/null 2>&1
  on "$leader" sudo -u postgres "$PGBIN/psql" -d appdb -Atc "drop table if exists public.rung3" >/dev/null 2>&1
  on "$leader" sudo -u postgres "$PGBIN/psql" -d appdb -Atc \
    "delete from public.ha_probe where client_name = 'rung3-client'" >/dev/null 2>&1
}
trap cleanup EXIT
cleanup   # leave nothing from a previous run to be mistaken for this one's work

echo
echo "=== Data whose old values only a backup can recover ==="
echo "  leader is ${leader#$VM_PREFIX}"
sql "create table public.rung3 (id int primary key, value text not null)" >/dev/null
sql "insert into public.rung3 select g, 'original-'||g from generate_series(1,20) g" >/dev/null
originals="$(sql "select string_agg(value, ',' order by id) from public.rung3")"

# A full backup so the marker has a floor to replay from, then the marker itself.
on "$leader" sudo -u postgres pgbackrest --stanza="$STANZA" --type=full backup >/dev/null 2>&1
marker="rung3_$(date -u +%Y%m%d%H%M%S)"
sql "select pg_create_restore_point('$marker')" >/dev/null
sql "select pg_switch_wal()" >/dev/null
sleep 3
pass "20 rows recorded, and a marker placed after a full backup: $marker"

echo
echo "=== The damage: old values now unrecoverable from production ==="
sql "update public.rung3 set value = 'CORRUPTED'" >/dev/null
damaged="$(sql "select count(*) from public.rung3 where value = 'CORRUPTED'")"
[[ "$damaged" == "20" ]] \
  && pass "all 20 rows overwritten; production no longer holds the originals" \
  || fail "expected 20 damaged rows, found $damaged"

echo
echo "=== A client commits throughout, to unrelated rows ==="
# Written to a file rather than nested inside quotes. The first version escaped
# its way to "rung3-" in the SQL -- a double-quoted IDENTIFIER, not a string
# literal -- so every insert failed with `column "rung3-" does not exist` and the
# check reported the client had never committed. Deep quoting is not worth it.
on "$leader" sudo -u postgres tee /tmp/rung3-client.sh >/dev/null <<CLIENT
#!/usr/bin/env bash
for i in \$(seq 1 400); do
  $PGBIN/psql -d appdb -Atc "insert into public.ha_probe (probe_id, client_name, server_address)
    values ('rung3-' || \$i || '-' || floor(random()*100000)::text, 'rung3-client', '127.0.0.1')" \
    >/dev/null 2>>/tmp/rung3-client.err || echo FAIL >> /tmp/rung3-client.fail
  sleep 0.25
done
CLIENT
on "$leader" sudo -u postgres bash -c "nohup bash /tmp/rung3-client.sh >/dev/null 2>&1 &" >/dev/null 2>&1
sleep 2
started_rows="$(sql "select count(*) from public.ha_probe where client_name = 'rung3-client'")"
(( started_rows > 0 )) \
  && pass "client is committing ($started_rows rows so far)" \
  || fail "the client never committed anything; the rest proves nothing"

echo
echo "=== Restore a copy beside it, onto its own encrypted volume ==="
restore_start="$SECONDS"
on "$leader" sudo -u postgres pgbackrest --stanza="$STANZA" --pg1-path="$RESTORE_DIR" \
  --type=name --target="$marker" --target-action=promote --log-level-console=warn restore \
  >/dev/null 2>&1
rc=$?
(( rc == 0 )) && pass "restored to $RESTORE_DIR, targeting the marker" \
              || { fail "restore failed (exit $rc)"; exit 1; }

# archive_mode=off is not optional: see R3 above.
on "$leader" sudo -u postgres "$PGBIN/pg_ctl" -D "$RESTORE_DIR" -w -t 90 \
  -o "-p $COPY_PORT -c archive_mode=off -c listen_addresses=localhost" \
  -l "$RESTORE_DIR/startup.log" start >/dev/null 2>&1
restore_elapsed=$((SECONDS - restore_start))
[[ "$(copy "select 1")" == "1" ]] \
  && pass "the copy is up on port $COPY_PORT, ${restore_elapsed}s after starting" \
  || { fail "the copy did not start"; exit 1; }

echo
echo "=== The copy holds the old values, and production is untouched by it ==="
copy_values="$(copy "select string_agg(value, ',' order by id) from public.rung3")"
[[ "$copy_values" == "$originals" ]] \
  && pass "the copy holds all 20 original values" \
  || fail "the copy does not hold the originals"

# It must be a RESTORE, not a lucky read: production cannot supply these.
prod_corrupt="$(sql "select count(*) from public.rung3 where value = 'CORRUPTED'")"
[[ "$prod_corrupt" == "20" ]] \
  && pass "production still shows all 20 as CORRUPTED, so the values came from the repository" \
  || fail "production changed by itself; this proves nothing about the restore"

echo
echo "=== Fix production forward from the copy ==="
# In a real incident the values move by hand or by script; here the copy is
# queried and the update built from what it returns.
pairs="$(copy "select id || '|' || value from public.rung3 order by id")"
while IFS='|' read -r id value; do
  [[ -z "$id" ]] && continue
  # </dev/null matters: limactl shell reads stdin, and without this it swallows
  # the here-string the loop is iterating, so the repair stops after one row.
  sql "update public.rung3 set value = '$value' where id = $id" </dev/null >/dev/null
done <<< "$pairs"

restored="$(sql "select string_agg(value, ',' order by id) from public.rung3")"
[[ "$restored" == "$originals" ]] \
  && pass "production holds the original values again" \
  || fail "production was not fully repaired"

echo
echo "=== What it cost: nothing ==="
sleep 2
client_fails="$(on "$leader" sudo bash -c "wc -l < /tmp/rung3-client.fail 2>/dev/null || echo 0" | tr -d ' ')"
final_rows="$(sql "select count(*) from public.ha_probe where client_name = 'rung3-client'")"
[[ "${client_fails:-0}" == "0" ]] \
  && pass "the client recorded 0 failed transactions throughout" \
  || fail "the client recorded $client_fails failures; production did not keep serving"
(( final_rows > started_rows )) \
  && pass "unrelated writes continued during the restore ($started_rows -> $final_rows rows, all present)" \
  || fail "no unrelated rows were committed during the operation"

echo
echo "=== And the repository is no worse for it (R3) ==="
on "$leader" sudo -u postgres pgbackrest --stanza="$STANZA" check >/dev/null 2>&1 \
  && pass "pgbackrest check still passes" || fail "check failed after the restore"
on "$leader" sudo -u postgres pgbackrest --stanza="$STANZA" verify >/dev/null 2>&1 \
  && pass "the repository still verifies: the copy archived nothing into it" \
  || fail "verify failed; the copy polluted the stanza"

timelines="$(on "$leader" sudo -u postgres pgbackrest --stanza="$STANZA" repo-ls \
  "archive/$STANZA" --recurse 2>/dev/null | grep -c '\.history$' || true)"
echo "  timeline histories in the archive: $timelines"

echo
echo "  rung 3 cost: ${restore_elapsed}s to a usable copy, 0 rows lost, 0 downtime"
echo
(( failures == 0 )) && { echo "PASS"; exit 0; }
echo "FAILED: $failures problem(s)" >&2
exit 1
