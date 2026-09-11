#!/usr/bin/env bash
set -uo pipefail

# P1: there is a history worth restoring from, and a marker can be placed in it.
#
# Nothing on the recovery ladder works without this, and it is the phase a fork
# creates the need for: Lab 4 has its own bucket, so it starts with an empty one.
#
# The part that is not obvious is the marker. Recovery to a point needs a way to
# NAME that point, and the three candidates are not equivalent:
#
#   restore point   a named record written into WAL. Precise, but it is a write,
#                   so it must be placed before the damage -- nobody creates one
#                   retrospectively.
#   LSN             equally precise and read-only, so it can be captured without
#                   writing to the primary.
#   timestamp       what you actually have in a real incident, and the weakest:
#                   measured in Lab 4's planning, a target truncated to the
#                   second excluded rows committed within that same second.
#
# This check places all three at one moment and proves the repository can see
# them. AC-4 later restores to each and compares what comes back.

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
sql() { on "$leader" sudo -u postgres "$PGBIN/psql" -d appdb -Atc "$1"; }
repo_json() { on "$leader" sudo -u postgres pgbackrest --stanza="$STANZA" --output=json info; }

echo
echo "=== A base backup exists to replay from ==="
echo "  leader is ${leader#$VM_PREFIX}"
info="$(repo_json)"
fulls="$(jq -r '[.[0].backup[] | select(.type == "full")] | length' <<< "$info")"
if (( fulls == 0 )); then
  echo "  no full backup yet; taking one"
  on "$leader" sudo -u postgres pgbackrest --stanza="$STANZA" --type=full backup >/dev/null 2>&1
  info="$(repo_json)"
  fulls="$(jq -r '[.[0].backup[] | select(.type == "full")] | length' <<< "$info")"
fi
(( fulls > 0 )) \
  && pass "$fulls full backup(s) in the repository" \
  || fail "no full backup: WAL alone restores nothing, because there is no floor to replay onto"

echo
echo "=== Writes on both sides of a marker, and the marker in three forms ==="
# Clear this check's own rows first. Without it the run is not repeatable: the
# assertion counts exactly ten each side, so a second run would see twenty and
# fail for a reason that has nothing to do with the property being tested.
sql "delete from public.ha_probe where client_name = 'history'" >/dev/null
sql "insert into public.ha_probe (probe_id, client_name, server_address)
     select 'before-'||g, 'history', '127.0.0.1' from generate_series(1,10) g" >/dev/null
before_rows="$(sql "select count(*) from public.ha_probe where probe_id like 'before-%'")"

marker="lab4_history_$(date -u +%Y%m%d%H%M%S)"
sql "select pg_create_restore_point('$marker')" >/dev/null
marker_lsn="$(sql "select pg_current_wal_lsn()")"
marker_time="$(sql "select now()")"
echo "  restore point : $marker"
echo "  LSN           : $marker_lsn"
echo "  timestamp     : $marker_time"

sql "insert into public.ha_probe (probe_id, client_name, server_address)
     select 'after-'||g, 'history', '127.0.0.1' from generate_series(1,10) g" >/dev/null
after_rows="$(sql "select count(*) from public.ha_probe where probe_id like 'after-%'")"
[[ "$before_rows" == "10" && "$after_rows" == "10" ]] \
  && pass "10 rows committed either side of the marker" \
  || fail "expected 10 rows each side, got $before_rows and $after_rows"

echo
echo "=== The marker reaches the repository, not just the primary's memory ==="
# A restore point lives inside the CURRENT WAL segment. Until that segment is
# archived it exists only on the primary -- and a marker you cannot reach from
# the repository is no use to a restore that starts from the repository.
target_wal="$(sql "select pg_walfile_name(pg_current_wal_lsn())")"
sql "select pg_switch_wal()" >/dev/null

arrived=""
for _ in {1..60}; do
  if on "$leader" sudo -u postgres pgbackrest --stanza="$STANZA" \
       repo-ls "archive/$STANZA" --recurse 2>/dev/null | grep -q "$target_wal"; then
    arrived=yes; break
  fi
  sleep 1
done
[[ -n "$arrived" ]] \
  && pass "the segment holding the marker is in the archive: $target_wal" \
  || fail "the marker's segment never reached the repository; nothing can restore to it"

echo
echo "=== The archive spans the window with no gap ==="
final="$(repo_json)"
min="$(jq -r '.[0].archive[-1].min' <<< "$final")"
max="$(jq -r '.[0].archive[-1].max' <<< "$final")"
echo "  archive runs $min -> $max"
on "$leader" sudo -u postgres pgbackrest --stanza="$STANZA" verify >/dev/null 2>&1 \
  && pass "pgbackrest verify passes: the history is intact and continuous" \
  || fail "verify failed; the history has a hole in it"

status="$(jq -r '.[0].status.message' <<< "$final")"
[[ "$status" == "ok" ]] && pass "stanza status is ok" || fail "stanza status is '$status'"

echo
echo "=== What later phases restore to ==="
printf '  %-14s %s\n' "restore point" "$marker"
printf '  %-14s %s\n' "LSN" "$marker_lsn"
printf '  %-14s %s\n' "timestamp" "$marker_time"
echo "  Rows before it: $before_rows   after it: $after_rows"

echo
(( failures == 0 )) && { echo "PASS"; exit 0; }
echo "FAILED: $failures problem(s)" >&2
exit 1
