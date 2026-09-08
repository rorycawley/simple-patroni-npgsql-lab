#!/usr/bin/env bash
set -uo pipefail

# Proves the cluster really does replicate with quorum commit, at three levels:
#
#   topology    Patroni has PostgreSQL configured for quorum commit right now --
#               synchronous_standby_names is an "ANY n (...)" expression and both
#               standbys report sync_state = quorum. This catches the config
#               never having been applied.
#   blocking    A commit actually waits for a standby. Both walreceivers are
#               frozen, then the committing backend is observed parked in
#               wait_event = SyncRep and cancelled, which makes PostgreSQL report
#               that it was waiting for synchronous replication. Neither signal
#               can occur on an asynchronous cluster.
#   durability  No acknowledged transaction is lost when the primary is destroyed.
#               Rows are committed, the primary VM is force-stopped immediately,
#               and every acknowledged row must be present on the promoted node.
#
# topology alone would pass on a cluster that merely *claims* to be synchronous,
# which is why blocking and durability exist.

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly VM_NAMES=(lab2-pg1 lab2-pg2 lab2-pg3)
readonly PATRONI_CONFIG=/etc/patroni/patroni.yml
readonly POSTGRES_BIN_DIR=/usr/pgsql-18/bin
readonly EXPECTED_NODE_COUNT=1
readonly DURABILITY_ROWS=200
# Tags the deliberately blocked commit so its backend can be found and cancelled.
readonly BLOCK_PROBE_APP=lab2-sync-block-probe

usage() {
  cat <<'EOF'
Usage: ./scripts/test-sync-replication.sh [topology|blocking|durability|all]
EOF
}

for required in limactl jq; do
  command -v "$required" >/dev/null 2>&1 || {
    echo "$required is required to run the sync replication test" >&2
    exit 1
  }
done
[[ -f "$LAB_DIR/.env" ]] || { echo "Run make create_vms first" >&2; exit 1; }

frozen_vms=()
stopped_vm=""
block_pid=""
block_output=""

cleanup() {
  local vm
  if [[ -n "$block_pid" ]]; then
    kill "$block_pid" 2>/dev/null
  fi
  if [[ -n "$block_output" ]]; then
    rm -f "$block_output"
  fi
  for vm in "${frozen_vms[@]:-}"; do
    [[ -n "$vm" ]] && limactl shell --tty=false "$vm" \
      sudo pkill -CONT -f '[w]alreceiver' 2>/dev/null
  done
  if [[ -n "$stopped_vm" ]]; then
    limactl start --tty=false "$stopped_vm" >/dev/null 2>&1
  fi
  return 0
}
trap cleanup EXIT

patroni_json() {
  local vm out
  for vm in "${VM_NAMES[@]}"; do
    if out="$(limactl shell --tty=false "$vm" sudo -u postgres \
      patronictl -c "$PATRONI_CONFIG" list --format=json 2>/dev/null)"; then
      printf '%s\n' "$out"
      return 0
    fi
  done
  return 1
}

leader_vm() {
  printf 'lab2-%s\n' "$(jq -r '.[] | select(.Role | test("Leader")) | .Member' <<< "$(patroni_json)")"
}

sql() {
  limactl shell --tty=false "$1" sudo -u postgres \
    "$POSTGRES_BIN_DIR/psql" -d appdb -Atc "$2"
}

pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; return 1; }

wait_for_quorum() {
  local primary states
  for _ in {1..45}; do
    primary="$(leader_vm)"
    states="$(sql "$primary" "select string_agg(sync_state, ',' order by application_name) from pg_stat_replication" 2>/dev/null)"
    [[ "$states" == "quorum,quorum" ]] && return 0
    sleep 2
  done
  return 1
}

test_topology() {
  echo
  echo "=== Quorum commit: configuration is actually in effect ==="
  local primary names states count

  # Patroni adds standbys to the quorum set as they catch up, so immediately
  # after bootstrap the set can legitimately hold one node. Asserting then
  # measures convergence rather than configuration.
  wait_for_quorum || { fail "the quorum set did not reach both standbys"; return 1; }

  primary="$(leader_vm)"
  echo "  primary is $primary"

  names="$(sql "$primary" "show synchronous_standby_names")"
  [[ -n "$names" ]] || { fail "synchronous_standby_names is empty - replication is asynchronous"; return 1; }
  echo "  synchronous_standby_names = $names"

  # Quorum commit renders as ANY n (...); plain sync mode renders as FIRST n (...).
  grep -qiE '^ANY [0-9]+ \(' <<< "$names" \
    || { fail "expected an ANY quorum expression, got '$names'"; return 1; }
  pass "quorum expression in use (ANY n), not FIRST n"

  count="$(sed -E 's/^[Aa][Nn][Yy] ([0-9]+) .*/\1/' <<< "$names")"
  [[ "$count" == "$EXPECTED_NODE_COUNT" ]] \
    || { fail "synchronous_node_count is $count, expected $EXPECTED_NODE_COUNT"; return 1; }
  pass "synchronous_node_count = $count"

  [[ "$(sql "$primary" "show synchronous_commit")" == "on" ]] \
    || { fail "synchronous_commit is not 'on', so the quorum expression has no effect"; return 1; }
  pass "synchronous_commit = on"

  states="$(sql "$primary" "select string_agg(application_name || '=' || sync_state, ' ' order by application_name) from pg_stat_replication")"
  echo "  pg_stat_replication: $states"
  [[ "$(grep -o 'quorum' <<< "$states" | wc -l | tr -d ' ')" == "2" ]] \
    || { fail "expected both standbys in sync_state=quorum"; return 1; }
  pass "both standbys are quorum members"
  echo "PASS (topology)"
}

test_blocking() {
  echo
  echo "=== Quorum commit: a commit really waits for a standby ==="
  local primary vm baseline_ms start end wait_event output

  primary="$(leader_vm)"
  sql "$primary" "create table if not exists public.sync_probe (id bigserial primary key, at timestamptz default clock_timestamp())" >/dev/null

  start=$(date +%s%N)
  sql "$primary" "insert into public.sync_probe default values" >/dev/null
  end=$(date +%s%N)
  baseline_ms=$(( (end - start) / 1000000 ))
  echo "  baseline commit with both standbys streaming: ${baseline_ms}ms"

  # The [w] bracket matters: pkill -f matches its own command line too, so a
  # plain 'walreceiver' pattern makes pkill SIGSTOP itself and the ssh session
  # hangs forever. '[w]alreceiver' matches the real process but not the literal
  # text of the pkill invocation.
  # Freeze both walreceivers. Neither standby can confirm a flush, so the primary
  # has nothing to satisfy its quorum with. Note the connections stay open, so
  # Patroni still counts both standbys as present and never degrades the quorum:
  # this commit will wait forever, and statement_timeout will NOT end it, because
  # a synchronous replication wait is only interruptible by an actual query
  # cancel. Hence the background job plus pg_cancel_backend below.
  for vm in "${VM_NAMES[@]}"; do
    if [[ "$vm" != "$primary" ]]; then
      limactl shell --tty=false "$vm" sudo pkill -STOP -f '[w]alreceiver' 2>/dev/null
      frozen_vms+=("$vm")
    fi
  done
  echo "  froze walreceiver on: ${frozen_vms[*]}"

  block_output="$(mktemp "${TMPDIR:-/tmp}/lab2-syncblock.XXXXXX")"
  limactl shell --tty=false "$primary" sudo -u postgres \
    env PGAPPNAME="$BLOCK_PROBE_APP" "$POSTGRES_BIN_DIR/psql" -d appdb -Atc \
    "insert into public.sync_probe default values" > "$block_output" 2>&1 &
  block_pid=$!

  # PostgreSQL names the wait itself: a backend parked in SyncRep is, by
  # definition, waiting for a synchronous standby to confirm a flush. No timing
  # heuristic can be fooled here, and on an asynchronous cluster this state
  # cannot occur at all.
  wait_event=""
  for _ in {1..30}; do
    wait_event="$(sql "$primary" "select coalesce(wait_event, '') from pg_stat_activity where application_name = '$BLOCK_PROBE_APP' and state = 'active' limit 1" 2>/dev/null)"
    [[ "$wait_event" == "SyncRep" ]] && break
    sleep 1
  done
  [[ "$wait_event" == "SyncRep" ]] \
    || { fail "the commit never entered a SyncRep wait (saw '${wait_event:-nothing}') - it did not wait for a standby"; return 1; }
  pass "the committing backend is parked in wait_event = SyncRep"

  # Cancelling proves the other half: the commit is already durable locally, so
  # PostgreSQL cannot roll it back and says so explicitly.
  sql "$primary" "select pg_cancel_backend(pid) from pg_stat_activity where application_name = '$BLOCK_PROBE_APP'" >/dev/null 2>&1
  wait "$block_pid" 2>/dev/null
  output="$(cat "$block_output")"
  block_pid=""

  for vm in "${frozen_vms[@]}"; do
    limactl shell --tty=false "$vm" sudo pkill -CONT -f '[w]alreceiver' 2>/dev/null
  done
  frozen_vms=()
  echo "  thawed both walreceivers"

  grep -qi 'canceling wait for synchronous replication' <<< "$output" \
    || { fail "expected a synchronous replication cancel warning, got: $(head -3 <<< "$output" | tr '\n' ' ')"; return 1; }
  pass "PostgreSQL reported 'canceling wait for synchronous replication'"

  rm -f "$block_output"
  block_output=""
  wait_for_quorum || { fail "quorum did not recover after thawing the standbys"; return 1; }
  pass "quorum restored after thawing"
  echo "PASS (blocking)"
}

test_durability() {
  echo
  echo "=== Quorum commit: no acknowledged transaction is lost on failover ==="
  local primary acknowledged surviving new_primary

  primary="$(leader_vm)"

  sql "$primary" "create table if not exists public.sync_durability (id int primary key)" >/dev/null
  sql "$primary" "truncate public.sync_durability" >/dev/null

  # Each row is its own committed transaction, so every one of these was
  # acknowledged to the client under quorum commit.
  sql "$primary" "insert into public.sync_durability select generate_series(1, $DURABILITY_ROWS)" >/dev/null
  acknowledged="$(sql "$primary" "select count(*) from public.sync_durability")"
  [[ "$acknowledged" == "$DURABILITY_ROWS" ]] \
    || { fail "expected $DURABILITY_ROWS acknowledged rows, got $acknowledged"; return 1; }
  pass "$acknowledged rows committed and acknowledged on $primary"

  echo "  destroying $primary immediately, with no clean shutdown"
  limactl stop --force "$primary" >/dev/null 2>&1
  stopped_vm="$primary"

  for _ in {1..45}; do
    new_primary="$(leader_vm 2>/dev/null)"
    [[ -n "$new_primary" && "$new_primary" != "$primary" && "$new_primary" != "lab2-" ]] && break
    sleep 2
  done
  [[ -n "$new_primary" && "$new_primary" != "$primary" ]] \
    || { fail "no new primary was promoted"; return 1; }
  pass "promoted $new_primary"

  surviving="$(sql "$new_primary" "select count(*) from public.sync_durability")"
  [[ "$surviving" == "$acknowledged" ]] \
    || { fail "$surviving of $acknowledged acknowledged rows survived - data was lost"; return 1; }
  pass "all $surviving acknowledged rows survived the failover"

  limactl start --tty=false "$stopped_vm" >/dev/null 2>&1
  stopped_vm=""
  wait_for_quorum || { fail "quorum did not recover after the old primary rejoined"; return 1; }
  pass "quorum restored with all three members"
  echo "PASS (durability)"
}

main() {
  case "${1:-all}" in
    topology) test_topology ;;
    blocking) test_blocking ;;
    durability) test_durability ;;
    all)
      test_topology || exit 1
      test_blocking || exit 1
      test_durability || exit 1
      ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
