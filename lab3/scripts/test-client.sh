#!/usr/bin/env bash
set -euo pipefail

# Proves the client-side guarantees the top-level README claims, beyond "it
# survives a failover":
#
#   pool              Maximum Pool Size is enforced, and Timeout bounds how long
#                     the client waits for a connection.
#   command-timeout   Command Timeout bounds a running statement.
#   uncertain-write   A commit whose acknowledgement is lost leaves the client
#                     unable to tell whether it committed -- and the client
#                     reports failure instead of reissuing the write.
#
# The expected values below are asserted here rather than inside the client, so
# that changing a setting in Program.cs fails this test instead of quietly
# testing the new value.

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly VM_NAMES=(lab3-pg1 lab3-pg2 lab3-pg3)
readonly PATRONI_CONFIG=/etc/patroni/patroni.yml
readonly POSTGRES_BIN_DIR=/usr/pgsql-18/bin

readonly EXPECTED_MAX_POOL_SIZE=20
readonly EXPECTED_TIMEOUT=5
readonly EXPECTED_COMMAND_TIMEOUT=10
readonly EXPECTED_SSL_MODE=VerifyFull

usage() {
  cat <<'EOF'
Usage: ./scripts/test-client.sh [pool|command-timeout|uncertain-write|all]
EOF
}

for required in limactl jq; do
  command -v "$required" >/dev/null 2>&1 || {
    echo "$required is required to run the client tests" >&2
    exit 1
  }
done
[[ -f "$LAB_DIR/.env" ]] || { echo "Run make create_vms first" >&2; exit 1; }
[[ -f "$LAB_DIR/.secrets/pgpass" ]] || { echo "Run make configure_cluster first" >&2; exit 1; }

source "$LAB_DIR/.env"

client_stdout=""
client_stderr=""
client_pid=""

cleanup() {
  if [[ -n "$client_pid" ]]; then
    kill "$client_pid" 2>/dev/null || true
  fi
  if [[ -n "$client_stdout" ]]; then
    rm -f "$client_stdout" "$client_stderr"
  fi
}
trap cleanup EXIT

# Runs on the application VM. Extra environment for a probe is passed through
# as NAME=VALUE arguments before the mode.
run_client() {
  # Seeded rather than started empty: bash 3.2, which macOS ships, treats
  # "${arr[@]}" on an empty array as an unbound variable under set -u.
  local -a env_pairs=(
    "LAB3_PG_HOSTS=${PG1_IP},${PG2_IP},${PG3_IP}"
    "LAB3_PGPASS=/etc/lab3/client/pgpass"
    "LAB3_CA=/etc/lab3/client/ca.crt"
  )
  while [[ "${1:-}" == *=* ]]; do env_pairs+=("$1"); shift; done
  limactl shell --tty=false lab3-app1 sudo env "${env_pairs[@]}" \
    /opt/lab3-client/Lab3.Client "$@"
}

patroni_json() {
  local vm out
  for vm in "${VM_NAMES[@]}"; do
    if out="$(limactl shell --tty=false "$vm" sudo -u postgres \
      patronictl -c "$PATRONI_CONFIG" list --format=json 2>/dev/null)"; then
      printf '%s\n' "$out"
      return 0
    fi
  done
  echo "Could not reach any Patroni member" >&2
  return 1
}

primary_vm() {
  printf 'lab3-%s\n' "$(jq -r '.[] | select(.Role == "Leader") | .Member' <<< "$(patroni_json)")"
}

sql_on_primary() {
  limactl shell --tty=false "$PRIMARY_VM" sudo -u postgres \
    "$POSTGRES_BIN_DIR/psql" -d appdb -Atc "$1"
}

assert_equal() {
  local label="$1" actual="$2" expected="$3"
  [[ "$actual" == "$expected" ]] || {
    echo "  FAIL: $label is '$actual', expected '$expected'" >&2
    return 1
  }
  echo "  ok: $label = $actual"
}

assert_between() {
  local label="$1" actual="$2" low="$3" high="$4"
  awk -v a="$actual" -v l="$low" -v h="$high" 'BEGIN { exit !(a >= l && a <= h) }' || {
    echo "  FAIL: $label is ${actual}s, expected between ${low}s and ${high}s" >&2
    return 1
  }
  echo "  ok: $label = ${actual}s (within ${low}-${high}s)"
}

test_pool() {
  echo
  echo "=== Client guarantee: Maximum Pool Size and Timeout ==="
  local json
  json="$(run_client pool)"

  assert_equal "configured Maximum Pool Size" "$(jq -r '.maxPoolSize' <<< "$json")" "$EXPECTED_MAX_POOL_SIZE"
  assert_equal "configured Timeout" "$(jq -r '.timeout' <<< "$json")" "$EXPECTED_TIMEOUT"
  assert_equal "configured SSL Mode" "$(jq -r '.sslMode' <<< "$json")" "$EXPECTED_SSL_MODE"
  assert_equal "connections opened before the limit" "$(jq -r '.opened' <<< "$json")" "$EXPECTED_MAX_POOL_SIZE"
  # The overflow request must be refused, and refused after roughly Timeout --
  # not instantly (which would mean it never waited) and not much later (which
  # would mean Timeout is not bounding the wait).
  assert_between "wait before the pool refused connection $((EXPECTED_MAX_POOL_SIZE + 1))" \
    "$(jq -r '.exhaustedAfterSeconds' <<< "$json")" \
    "$(( EXPECTED_TIMEOUT - 1 ))" "$(( EXPECTED_TIMEOUT + 4 ))"
  assert_between "reconnect after releasing one connection" \
    "$(jq -r '.recoveredAfterSeconds' <<< "$json")" 0 2
  echo "PASS (pool)"
}

test_command_timeout() {
  echo
  echo "=== Client guarantee: Command Timeout ==="
  local json
  json="$(run_client command-timeout)"

  assert_equal "configured Command Timeout" "$(jq -r '.commandTimeout' <<< "$json")" "$EXPECTED_COMMAND_TIMEOUT"
  assert_between "time before a $(jq -r '.sleepSeconds' <<< "$json")s query was cut off" \
    "$(jq -r '.elapsedSeconds' <<< "$json")" \
    "$(( EXPECTED_COMMAND_TIMEOUT - 1 ))" "$(( EXPECTED_COMMAND_TIMEOUT + 5 ))"
  echo "PASS (command-timeout)"
}

test_uncertain_write() {
  echo
  echo "=== Client guarantee: an uncertain commit is not retried ==="
  local probe_id app_name client_status rows_before rows_after committed

  PRIMARY_VM="$(primary_vm)"
  echo "  primary is $PRIMARY_VM"

  probe_id="$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')"
  app_name="lab3-uncertain-${probe_id:0:8}"

  rows_before="$(sql_on_primary "select count(*) from public.ha_probe where probe_id = '$probe_id'")"
  assert_equal "rows for this probe id before the run" "$rows_before" "0"

  client_stdout="$(mktemp "${TMPDIR:-/tmp}/lab3-uncertain-out.XXXXXX")"
  client_stderr="$(mktemp "${TMPDIR:-/tmp}/lab3-uncertain-err.XXXXXX")"

  run_client "LAB3_PROBE_ID=$probe_id" "LAB3_APP_NAME=$app_name" uncertain-write > "$client_stdout" 2> "$client_stderr" &
  client_pid=$!

  # Wait until a third-party session can see the row. That proves the COMMIT is
  # durable, and that the client is now blocked in the pg_sleep that follows it.
  committed=""
  for _ in {1..80}; do
    if [[ "$(sql_on_primary "select count(*) from public.ha_probe where probe_id = '$probe_id'")" == "1" ]]; then
      committed=yes
      break
    fi
    sleep 0.5
  done
  [[ -n "$committed" ]] || {
    echo "  FAIL: the write never became visible, so no uncertainty was created" >&2
    cat "$client_stderr" >&2
    return 1
  }
  echo "  ok: the COMMIT is durable and visible to another session"

  # Now destroy the connection before the client can be told any of that.
  sql_on_primary "select pg_terminate_backend(pid) from pg_stat_activity
                  where application_name = '$app_name'" >/dev/null
  echo "  ok: terminated the client's backend mid-batch"

  client_status=0
  wait "$client_pid" || client_status=$?
  client_pid=""

  (( client_status != 0 )) || {
    echo "  FAIL: the client reported success even though it never saw the commit acknowledged" >&2
    return 1
  }
  echo "  ok: client exited $client_status (reported failure, as it must)"

  grep -q 'NOT retrying' "$client_stderr" || {
    echo "  FAIL: the client did not report an unknown commit outcome" >&2
    cat "$client_stderr" >&2
    return 1
  }
  echo "  ok: client reported an UNKNOWN commit outcome rather than guessing"

  # The whole point: the write is committed even though the client saw a failure,
  # and there is exactly one of it. Counting by the per-run client_name rather
  # than the primary key is deliberate -- a client that reissued the operation
  # with a fresh probe id would land a second row here, which a probe_id count
  # would miss entirely.
  rows_after="$(sql_on_primary "select count(*) from public.ha_probe where client_name = 'uncertain-$probe_id'")"
  assert_equal "rows written by this run" "$rows_after" "1"
  echo "  => the write succeeded, the client could not know it, and it was not duplicated"

  rm -f "$client_stdout" "$client_stderr"
  client_stdout=""
  client_stderr=""
  echo "PASS (uncertain-write)"
}

main() {
  case "${1:-all}" in
    pool) test_pool ;;
    command-timeout) test_command_timeout ;;
    uncertain-write) test_uncertain_write ;;
    all)
      test_pool
      test_command_timeout
      test_uncertain_write
      ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
