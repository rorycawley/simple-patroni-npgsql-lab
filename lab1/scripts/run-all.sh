#!/usr/bin/env bash
# Runs the Lab 1 phases in order and prints one summary at the end.
#
#   all     Create the VMs, configure the cluster, then run every check.
#   check   Run every check against a cluster that is already configured.
#
# Setup phases abort the run if they fail, because there is nothing to test. The
# checks all run even when an earlier one fails, so a single invocation reports
# everything that is broken rather than only the first thing.
set -uo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly VM_NAMES=(lab1-pg1 lab1-pg2 lab1-pg3)
readonly PATRONI_CONFIG=/etc/patroni/patroni.yml

names=()
results=()
seconds=()

usage() {
  cat <<'EOF'
Usage: ./scripts/run-all.sh [all|check]

all     Create the VMs, configure the cluster, then run every check (default).
check   Run every check against an already-configured cluster.
EOF
}

banner() {
  printf '\n'
  printf '%s\n' '------------------------------------------------------------------------------'
  printf '>>> %s\n' "$1"
  printf '%s\n' '------------------------------------------------------------------------------'
}

record() {
  names+=("$1")
  results+=("$2")
  seconds+=("$3")
}

failures() {
  local index count=0
  for index in "${!results[@]}"; do
    [[ "${results[index]}" == FAIL ]] && count=$((count + 1))
  done
  printf '%d\n' "$count"
}

format_duration() {
  local total="$1"
  if (( total >= 60 )); then
    printf '%dm%02ds' "$((total / 60))" "$((total % 60))"
  else
    printf '%ds' "$total"
  fi
}

summary() {
  local index passed failed
  failed="$(failures)"
  passed=$(( ${#names[@]} - failed ))

  printf '\n'
  printf '%s\n' '=============================================================================='
  printf ' Lab 1 results\n'
  printf '%s\n' '=============================================================================='
  for index in "${!names[@]}"; do
    # The width must clear the longest phase label, or the duration column wraps.
    printf ' %-4s  %-62s %8s\n' \
      "${results[index]}" "${names[index]}" "$(format_duration "${seconds[index]}")"
  done
  printf '%s\n' '------------------------------------------------------------------------------'
  printf ' %d passed, %d failed, total %s\n' \
    "$passed" "$failed" "$(format_duration "$SECONDS")"
  printf '%s\n' '=============================================================================='
}

show_topology() {
  local vm
  banner "Final Patroni topology"
  for vm in "${VM_NAMES[@]}"; do
    if limactl shell --tty=false "$vm" sudo -u postgres \
      patronictl -c "$PATRONI_CONFIG" list 2>/dev/null; then
      return 0
    fi
  done
  echo "Could not reach any Patroni member to report the final topology." >&2
}

run_phase() {
  local label="$1" target="$2" required="$3" start rc

  banner "$label"
  start=$SECONDS
  make -C "$LAB_DIR" "$target"
  rc=$?
  if (( rc == 0 )); then
    record "$label" PASS "$((SECONDS - start))"
  else
    record "$label" FAIL "$((SECONDS - start))"
    if [[ "$required" == required ]]; then
      summary
      printf '\nSetup phase "%s" failed, so the checks were not run.\n' "$label" >&2
      exit 1
    fi
  fi
}

main() {
  local mode="${1:-all}"

  case "$mode" in
    all)
      run_phase "Create the three Lima VMs" create_vms required
      run_phase "Install and configure the Patroni cluster" configure_cluster required
      ;;
    check) ;;
    *) usage; exit 2 ;;
  esac

  run_phase "Cluster services, quorum, replication, pgBackRest" verify_cluster optional
  run_phase "Criterion 1: client connects to the primary and queries it" test_connection optional
  run_phase "Client guarantees: pool limit, timeouts, no blind retry" test_client optional
  run_phase "Quorum commit: configured, blocking, and lossless" test_sync optional
  run_phase "Criterion 2: failover after the primary VM is lost" test_failover_vm optional
  run_phase "Criterion 2: failover after PostgreSQL is killed" test_failover_postgres optional
  run_phase "Split brain: softdog fences a frozen Patroni" test_fencing_patroni optional
  run_phase "Split brain: Patroni demotes itself without etcd" test_fencing_etcd optional

  show_topology
  summary
  (( $(failures) == 0 ))
}

main "$@"
