#!/usr/bin/env bash
set -uo pipefail

# AC-4: a dump proves the data is READABLE, not merely present.
# AC-5, second half: the dumps are encrypted too.
#
# The second half is the one that is easy to miss. repo1-cipher-pass protects
# only what pgBackRest writes, and these objects are deliberately written outside
# repo1-path so pgBackRest's retention can never reap them. A criterion that
# checked the pgBackRest objects and stopped would leave the dumps sitting in
# plaintext beside them and still pass, having tested the easier half of the data.
#
# Reloading into a scratch database is not a restore rehearsal -- that is Lab 4.
# It is the cheapest available proof that the dump can still be PARSED, which is
# the property `pgbackrest verify` cannot give: verifying checksums confirms the
# bytes are intact and says nothing about whether PostgreSQL can read them.

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly VM_NAMES=(lab4-pg1 lab4-pg2 lab4-pg3)
readonly VM_PREFIX="lab4-"
readonly STANZA=lab4
readonly PATRONI_CONFIG=/etc/patroni/patroni.yml
readonly BIN=/usr/local/lib/lab4
readonly PASSFILE=/etc/lab4/dump.pass
readonly PGBIN=/usr/pgsql-18/bin
readonly SCRATCH=dump_reload_probe

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }
[[ -f "$LAB_DIR/.env" ]] || { echo "Run make create_vms first" >&2; exit 1; }

failures=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; failures=$((failures + 1)); }
on() { local vm="$1"; shift; limactl shell --tty=false "$vm" "$@" 2>/dev/null; }

leader_vm() {
  local out
  for vm in "${VM_NAMES[@]}"; do
    if out="$(on "$vm" sudo -u postgres patronictl -c "$PATRONI_CONFIG" list --format=json)"; then
      printf '%s%s\n' "$VM_PREFIX" \
        "$(jq -r '.[] | select(.Role | test("Leader")) | .Member' <<< "$out")"
      return 0
    fi
  done
  return 1
}

leader="$(leader_vm)" || { echo "cannot find the leader" >&2; exit 1; }
cleanup() {
  on "$leader" sudo -u postgres "$PGBIN/psql" -Atc "DROP DATABASE IF EXISTS $SCRATCH" >/dev/null 2>&1
  on "$leader" sudo rm -f /tmp/lab4-dump-probe.enc /tmp/lab4-dump-probe >/dev/null 2>&1
}
trap cleanup EXIT

echo
echo "=== A dump is taken, and only by the leader ==="
echo "  leader is ${leader#$VM_PREFIX}"
before="$(on "$leader" sudo "$BIN/lab4-s3" list dumps/ | wc -l | tr -d ' ')"

for vm in "${VM_NAMES[@]}"; do
  out="$(on "$vm" sudo systemctl start lab4-dump.service 2>&1)"; rc=$?
  (( rc == 0 )) || fail "${vm#$VM_PREFIX}: the dump unit failed: $out"
done

for vm in "${VM_NAMES[@]}"; do
  [[ "$vm" == "$leader" ]] && continue
  on "$vm" journalctl -u lab4-dump.service -n 10 --no-pager | grep -q "Leader confirmed" \
    && fail "${vm#$VM_PREFIX}: a standby took a dump" \
    || pass "${vm#$VM_PREFIX}: declined, as a non-leader must"
done

keys="$(on "$leader" sudo "$BIN/lab4-s3" list dumps/ | sort)"
newest="$(printf '%s\n' "$keys" | tail -1)"
[[ -n "$newest" ]] && pass "a dump is in the bucket: $newest" \
                   || { fail "no dump object was produced"; exit 1; }

echo
echo "=== pgBackRest cannot see the dumps, and never expires them ==="
# The prefix sits outside repo1-path on purpose. If pgBackRest could see these,
# its retention would eventually reap the very thing kept for surgical recovery.
if on "$leader" sudo -u postgres pgbackrest --stanza="$STANZA" repo-ls 2>/dev/null | grep -q '^dumps$'; then
  fail "the dumps prefix is inside the pgBackRest repository; expire could reap it"
else
  pass "the dumps prefix is outside repo1-path, beyond expire's reach"
fi

echo
echo "=== The dump is unreadable straight from the bucket ==="
# Straight from the bucket, with no decryption step: whatever an object-store
# administrator would see. Fetched to a file rather than piped, so nothing
# depends on xxd (absent from a minimal image) or on surviving SIGPIPE.
on "$leader" sudo bash -c "$BIN/lab4-s3 cat '$newest' > /tmp/lab4-dump-probe.enc"
raw_head="$(on "$leader" sudo bash -c \
  "head -c 8 /tmp/lab4-dump-probe.enc | od -An -v -tx1 | tr -d ' \n'")"
if [[ "$raw_head" == 53616c7465645f5f ]]; then
  pass "it begins 'Salted__': encrypted, not a pg_dump archive"
else
  # A custom-format pg_dump archive begins with the magic "PGDMP".
  if [[ "$raw_head" == 5047444d50* ]]; then
    fail "the object in the bucket begins 'PGDMP': the dump was uploaded in PLAINTEXT"
  else
    fail "unexpected first bytes in the bucket: $raw_head"
  fi
fi

echo
echo "=== With its passphrase it decrypts, parses, and reloads ==="
on "$leader" sudo bash -c "
  openssl enc -d -aes-256-cbc -pbkdf2 -in /tmp/lab4-dump-probe.enc \
    -out /tmp/lab4-dump-probe -pass file:$PASSFILE" >/dev/null 2>&1 \
  && pass "decrypts with the dump passphrase" \
  || { fail "could not decrypt the dump"; exit 1; }

on "$leader" sudo -u postgres "$PGBIN/pg_restore" --list /tmp/lab4-dump-probe >/dev/null 2>&1 \
  && pass "pg_restore can parse the archive" \
  || fail "pg_restore cannot parse the decrypted archive"

# The real assertion. Reading every row through PostgreSQL's own executor is
# what a physical backup cannot do, and it is why this dump exists.
source_rows="$(on "$leader" sudo -u postgres "$PGBIN/psql" -d appdb -Atc \
  "select count(*) from public.ha_probe")"
on "$leader" sudo -u postgres "$PGBIN/psql" -Atc "DROP DATABASE IF EXISTS $SCRATCH" >/dev/null 2>&1
on "$leader" sudo -u postgres "$PGBIN/psql" -Atc "CREATE DATABASE $SCRATCH" >/dev/null 2>&1
on "$leader" sudo -u postgres "$PGBIN/pg_restore" -d "$SCRATCH" /tmp/lab4-dump-probe >/dev/null 2>&1
restored_rows="$(on "$leader" sudo -u postgres "$PGBIN/psql" -d "$SCRATCH" -Atc \
  "select count(*) from public.ha_probe")"

if [[ -n "$restored_rows" && "$restored_rows" == "$source_rows" ]]; then
  pass "reloaded into a scratch database: $restored_rows rows, matching the source"
else
  fail "reload produced '${restored_rows:-nothing}' rows, source has $source_rows"
fi

echo
echo "=== The dump's scope is what the documentation claims ==="
# Both of these are stated in WHY_PGBACKREST_AND_PGDUMP.md. Neither was checked,
# and the reload above cannot catch either: it restores into a cluster where the
# roles already exist, so a dump missing them looks perfect.
sql_text="$(on "$leader" sudo -u postgres "$PGBIN/pg_restore" -f - /tmp/lab4-dump-probe 2>/dev/null)"

roles="$(grep -c '^CREATE ROLE' <<< "$sql_text" || true)"
(( roles == 0 )) \
  && pass "no roles in the dump: they are cluster-wide, and a restore needs pg_dumpall --globals-only" \
  || fail "the dump contains $roles CREATE ROLE statements, which contradicts what the docs claim"

# It should carry appdb's own objects and nothing from another database.
if grep -q 'public.ha_probe' <<< "$sql_text"; then
  pass "the dump carries appdb's tables"
else
  fail "the dump does not contain appdb's tables"
fi

echo
echo "=== The assumption the dumper role rests on still holds ==="
# pg_read_all_data covers tables, views and sequences -- and NOT large objects.
# Measured: pg_dump as dumper fails with "permission denied for large object"
# the moment one exists. appdb has none, so the job works; but that is an
# assumption about the schema, and an assumption nothing checks is a landmine.
# This turns it into a check that fires the day someone stores a blob.
lo_count="$(on "$leader" sudo -u postgres "$PGBIN/psql" -d appdb -Atc \
  "select count(*) from pg_largeobject_metadata")"
if [[ "$lo_count" == "0" ]]; then
  pass "appdb holds no large objects, which is what lets dumper read all of it"
else
  fail "appdb holds $lo_count large object(s): dumper cannot read them, and this dump is incomplete or failing. The job must run as the owner or a superuser"
fi

echo
echo "=== Old dumps are expired by the job that wrote them ==="
count="$(printf '%s\n' "$keys" | grep -c . || true)"
keep="$(on "$leader" sudo sed -n 's/^readonly KEEP=//p' "$BIN/lab4-dump")"
(( count <= keep )) \
  && pass "$count dump(s) retained, within the limit of $keep" \
  || fail "$count dumps retained but the limit is $keep; nothing is expiring them"

echo
(( failures == 0 )) && { echo "PASS"; exit 0; }
echo "FAILED: $failures problem(s)" >&2
exit 1
