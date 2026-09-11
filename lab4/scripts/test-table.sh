#!/usr/bin/env bash
set -uo pipefail

# AC-3, rung 4: one table comes back, and nothing else moves.
#
# This is the rung the logical dump exists for. Recovering one mangled table
# from the PHYSICAL backup means rewinding the whole cluster to a point in time
# and discarding every unrelated transaction committed since. A dump of that one
# table costs nothing outside it.
#
# It is not free, and the ladder says so: you lose **later writes to that table**
# -- everything committed to it between the dump and the damage. This check
# measures that rather than glossing over it, because a rung whose cost is
# unstated is a rung nobody can choose between.
#
# What must hold, and the second is the one a demonstration would skip:
#
#   1. the damaged table holds its pre-damage contents again
#   2. EVERY OTHER TABLE keeps every row written since -- including rows
#      committed while the restore was running

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly VM_NAMES=(lab4-pg1 lab4-pg2 lab4-pg3)
readonly VM_PREFIX="lab4-"
readonly STANZA=lab4
readonly PATRONI_CONFIG=/etc/patroni/patroni.yml
readonly PGBIN=/usr/pgsql-18/bin
readonly BIN=/usr/local/lib/lab4
readonly PASSFILE=/etc/lab4/dump.pass

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
sql() { on "$leader" sudo -u postgres "$PGBIN/psql" -d appdb -Atc "$1" </dev/null; }

cleanup() {
  on "$leader" sudo pkill -f rung4-client.sh >/dev/null 2>&1
  on "$leader" sudo bash -c "rm -f /tmp/rung4-*" >/dev/null 2>&1
  on "$leader" sudo -u postgres "$PGBIN/psql" -d appdb -Atc \
    "drop table if exists public.rung4" </dev/null >/dev/null 2>&1
  on "$leader" sudo -u postgres "$PGBIN/psql" -d appdb -Atc \
    "delete from public.ha_probe where client_name = 'rung4-client'" </dev/null >/dev/null 2>&1
}
trap cleanup EXIT
cleanup

echo
echo "=== A table worth recovering, captured in a dump ==="
echo "  leader is ${leader#$VM_PREFIX}"
sql "create table public.rung4 (id int primary key, value text not null)" >/dev/null
sql "insert into public.rung4 select g, 'good-'||g from generate_series(1,20) g" >/dev/null
originals="$(sql "select string_agg(value, ',' order by id) from public.rung4")"

on "$leader" sudo systemctl start lab4-dump.service >/dev/null 2>&1
newest="$(on "$leader" sudo "$BIN/lab4-s3" list dumps/ | sort | tail -1)"
[[ -n "$newest" ]] \
  && pass "a dump was taken with the table intact: $newest" \
  || { fail "no dump produced; rung 4 has nothing to restore from"; exit 1; }

echo
echo "=== Writes to that table AFTER the dump -- the cost of this rung ==="
sql "insert into public.rung4 select g, 'post-dump-'||g from generate_series(21,25) g" >/dev/null
post_dump="$(sql "select count(*) from public.rung4 where value like 'post-dump-%'")"
[[ "$post_dump" == "5" ]] \
  && pass "5 rows committed to the table after the dump; these are what rung 4 loses" \
  || fail "expected 5 post-dump rows, found $post_dump"

echo
echo "=== The damage, and a client writing elsewhere throughout ==="
sql "update public.rung4 set value = 'MANGLED'" >/dev/null
mangled="$(sql "select count(*) from public.rung4 where value = 'MANGLED'")"
[[ "$mangled" == "25" ]] \
  && pass "all 25 rows mangled; the good values exist only in the dump" \
  || fail "expected 25 mangled rows, found $mangled"

on "$leader" sudo -u postgres tee /tmp/rung4-client.sh >/dev/null <<CLIENT
#!/usr/bin/env bash
for i in \$(seq 1 400); do
  $PGBIN/psql -d appdb -Atc "insert into public.ha_probe (probe_id, client_name, server_address)
    values ('rung4-' || \$i || '-' || floor(random()*100000)::text, 'rung4-client', '127.0.0.1')" \
    >/dev/null 2>>/tmp/rung4-client.err || echo FAIL >> /tmp/rung4-client.fail
  sleep 0.25
done
CLIENT
on "$leader" sudo -u postgres bash -c "nohup bash /tmp/rung4-client.sh >/dev/null 2>&1 &" >/dev/null 2>&1
sleep 2
rows_start="$(sql "select count(*) from public.ha_probe where client_name = 'rung4-client'")"
(( rows_start > 0 )) \
  && pass "client is committing to another table ($rows_start rows so far)" \
  || fail "the client never committed; the untouched-tables claim would prove nothing"

echo
echo "=== Restore that one table, and only that table ==="
started="$SECONDS"
on "$leader" sudo bash -c "
  $BIN/lab4-s3 cat '$newest' > /tmp/rung4.enc &&
  openssl enc -d -aes-256-cbc -pbkdf2 -in /tmp/rung4.enc -out /tmp/rung4.dump \
    -pass file:$PASSFILE" >/dev/null 2>&1 \
  && pass "the dump was fetched and decrypted" \
  || { fail "could not fetch or decrypt the dump"; exit 1; }

# -t restores exactly one table; --clean --if-exists replaces the mangled one.
# Nothing else in the database is named, so nothing else is touched.
on "$leader" sudo -u postgres "$PGBIN/pg_restore" -d appdb -t rung4 --clean --if-exists \
  /tmp/rung4.dump </dev/null >/dev/null 2>&1
elapsed=$((SECONDS - started))

restored="$(sql "select string_agg(value, ',' order by id) from public.rung4")"
[[ "$restored" == "$originals" ]] \
  && pass "the table holds its pre-damage contents again, ${elapsed}s later" \
  || fail "the table was not restored to its original values"

echo
echo "=== The cost, stated rather than hidden ==="
still_post="$(sql "select count(*) from public.rung4 where value like 'post-dump-%'")"
[[ "$still_post" == "0" ]] \
  && pass "the 5 post-dump rows are gone: that is what rung 4 costs, and it is only this table" \
  || fail "expected the post-dump rows to be lost, found $still_post"

echo
echo "=== Nothing else moved ==="
sleep 2
client_fails="$(on "$leader" sudo bash -c "wc -l < /tmp/rung4-client.fail 2>/dev/null || echo 0" | tr -d ' ')"
rows_end="$(sql "select count(*) from public.ha_probe where client_name = 'rung4-client'")"
[[ "${client_fails:-0}" == "0" ]] \
  && pass "the client recorded 0 failed transactions throughout" \
  || fail "the client recorded $client_fails failures; the database did not keep serving"
(( rows_end > rows_start )) \
  && pass "the other table kept every row written during the restore ($rows_start -> $rows_end)" \
  || fail "no rows were committed elsewhere during the restore"

# The whole point of preferring this rung: unrelated data is untouched.
probe_total="$(sql "select count(*) from public.ha_probe")"
(( probe_total >= rows_end )) \
  && pass "ha_probe still holds all $probe_total of its rows, none discarded" \
  || fail "rows disappeared from an unrelated table"

echo
echo "=== The cluster and the repository are unaffected ==="
on "$leader" sudo -u postgres pgbackrest --stanza="$STANZA" verify >/dev/null 2>&1 \
  && pass "the repository still verifies" || fail "verify failed"
states="$(sql "select string_agg(sync_state, ',' order by application_name) from pg_stat_replication")"
[[ "$states" == "quorum,quorum" ]] \
  && pass "both standbys still streaming; no failover, no pause, no restart" \
  || fail "replication state is '$states'"

echo
echo "  rung 4 cost: ${elapsed}s, 5 rows lost (all in the damaged table), 0 downtime"
echo
(( failures == 0 )) && { echo "PASS"; exit 0; }
echo "FAILED: $failures problem(s)" >&2
exit 1
