#!/usr/bin/env bash
# Runs the Lab 4 phases in order and prints one summary at the end.
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
readonly VM_NAMES=(lab4-pg1 lab4-pg2 lab4-pg3)
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
  printf ' Lab 4 results\n'
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
      run_phase "Create the four Lima VMs" create_vms required
      run_phase "Start the backup object store" minio_start required
      run_phase "Install and configure the Patroni cluster" configure_cluster required
      ;;
    check) ;;
    *) usage; exit 2 ;;
  esac

  run_phase "Cluster services, quorum, replication, pgBackRest" verify_cluster optional
  run_phase "Object store: reachable from every node over verified TLS" test_minio optional
  run_phase "Backups: a history exists, and only the leader creates it" test_backup optional
  run_phase "A history worth restoring from: a base backup and a marker" test_history optional
  run_phase "Repository: off-host, reachable from every node, complete" test_repository optional
  run_phase "Rung 1: a node is rebuilt from the repository, not the primary" test_replica optional
  run_phase "Rung 3: a copy restored beside a cluster that keeps serving" test_beside optional
  run_phase "Backup chain: it verifies, and retention expires dependents" test_chain optional
  run_phase "Logical dumps: encrypted, readable, and they reload" test_dump optional
  run_phase "Encryption: every object needs its passphrase, both prefixes" test_encryption optional
  run_phase "Archiving survives a promotion, and the window is measured" test_archive optional
  run_phase "Encryption at rest: LUKS2 volumes, and a missing one stops the service" test_at_rest optional
  run_phase "PKI: certificates assert the right identities" test_pki optional
  run_phase "Encryption in transit: every channel, plaintext refused" test_in_transit optional
  run_phase "Identity: verification fails closed on a wrong CA" test_identity optional
  run_phase "Criterion 1: client connects to the primary and queries it" test_connection optional
  run_phase "Client guarantees: pool limit, timeouts, no blind retry" test_client optional
  run_phase "Quorum commit: configured, blocking, strict, and lossless" test_sync optional
  run_phase "Runbook: matches this lab, and its verified procedures work" test_runbook optional
  run_phase "Criterion 2: failover after the primary VM is lost" test_failover_vm optional
  run_phase "Criterion 2: failover after PostgreSQL is killed" test_failover_postgres optional
  run_phase "Split brain: softdog fences a frozen Patroni" test_fencing_patroni optional
  run_phase "Split brain: Patroni demotes itself without etcd" test_fencing_etcd optional

  show_topology
  summary
  (( $(failures) == 0 ))
}

main "$@"
