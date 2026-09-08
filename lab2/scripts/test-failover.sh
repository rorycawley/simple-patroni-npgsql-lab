#!/usr/bin/env bash
set -euo pipefail

# Fault-injection tests for the Lab 2 cluster.
#
# The first two prove acceptance criterion 2 -- after failover promotes a new
# node to primary, the Npgsql client reaches that new node for read-write work.
# They start the client *inside* the failover window, while no host is an
# eligible primary, so it has to ride out the election through its own retry
# loop instead of connecting to an already-settled cluster.
#
#   vm        The whole primary VM disappears. Patroni and PostgreSQL die
#             together, nothing releases the leader key, and a replica can only
#             promote after the key's ttl (30s) expires.
#   postgres  Only the PostgreSQL postmaster is killed. Patroni stays alive,
#             notices the crash, and because primary_start_timeout is 0 it hands
#             the leader key to a healthy replica rather than restarting
#             PostgreSQL locally. It then rejoins the node without a VM restart.
#
# The second two prove how the node stops serving when it can no longer prove it
# still holds the leader key. These are the split-brain cases, and they take
# visibly different paths:
#
#   patroni   SIGSTOP Patroni. It cannot renew the leader key and cannot pet the
#             watchdog, but PostgreSQL keeps running and keeps answering as a
#             primary. Nothing in userspace can fix this, so softdog resets the
#             node at ttl - safety_margin = 25s. Proven by the boot id changing.
#   etcd      Block the etcd ports so Patroni loses the DCS while staying alive
#             itself. Here Patroni *can* still act, so it demotes itself to a
#             standby within about ten seconds and the watchdog never fires.
#             Proven by pg_is_in_recovery() flipping true with no reboot.

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly VM_NAMES=(lab2-pg1 lab2-pg2 lab2-pg3)
readonly PATRONI_CONFIG=/etc/patroni/patroni.yml
readonly POSTGRES_DATA_DIR=/var/lib/pgsql/data
readonly POSTGRES_BIN_DIR=/usr/pgsql-18/bin
readonly FENCE_TABLE=lab2_fence

usage() {
  cat <<'EOF'
Usage: ./scripts/test-failover.sh [vm|postgres|patroni|etcd|failover|fencing|all]

Acceptance criterion 2 (the client follows the promotion):
  vm        Force-stop the primary VM, killing Patroni and PostgreSQL together.
  postgres  SIGKILL only the PostgreSQL postmaster, leaving Patroni running.
  failover  Both of the above.

Split-brain prevention (how a doomed primary stops serving):
  patroni   SIGSTOP Patroni; softdog resets the node at 25s.
  etcd      Cut Patroni off from etcd; Patroni demotes itself instead.
  fencing   Both of the above.

all         Every scenario (default).
EOF
}

for required in limactl jq; do
  command -v "$required" >/dev/null 2>&1 || {
    echo "$required is required to run the failover test" >&2
    exit 1
  }
done
[[ -f "$LAB_DIR/.env" ]] || { echo "Run make create_vms first" >&2; exit 1; }

source "$LAB_DIR/.env"

stopped_vm=""
frozen_vm=""
frozen_pid=""
partitioned_vm=""
client_pid=""
client_stdout=""
client_stderr=""

cleanup() {
  if [[ -n "$client_pid" ]]; then
    kill "$client_pid" 2>/dev/null || true
  fi
  if [[ -n "$frozen_vm" ]]; then
    echo "Un-freezing Patroni on $frozen_vm after an interrupted run" >&2
    limactl shell --tty=false "$frozen_vm" sudo kill -CONT "$frozen_pid" 2>/dev/null || true
  fi
  if [[ -n "$partitioned_vm" ]]; then
    echo "Healing the etcd partition on $partitioned_vm after an interrupted run" >&2
    limactl shell --tty=false "$partitioned_vm" sudo nft delete table inet "$FENCE_TABLE" 2>/dev/null || true
  fi
  if [[ -n "$stopped_vm" ]]; then
    echo "Restarting $stopped_vm after an interrupted run" >&2
    limactl start --tty=false "$stopped_vm" >/dev/null || true
  fi
  if [[ -n "$client_stdout" ]]; then
    rm -f "$client_stdout" "$client_stderr"
  fi
}
trap cleanup EXIT

patroni_json() {
  limactl shell --tty=false "$1" sudo -u postgres \
    patronictl -c "$PATRONI_CONFIG" list --format=json
}

leader_of() {
  jq -r '.[] | select(.Role == "Leader") | .Member' <<< "$1"
}

# Exact per-boot UUID. uptime -s is derived from the uptime counter and drifts by
# a second between reads, which would make a naive comparison report a phantom
# reboot; boot_id does not move until the kernel actually restarts.
boot_id() {
  limactl shell --tty=false "$1" cat /proc/sys/kernel/random/boot_id
}

pg_in_recovery() {
  limactl shell --tty=false "$1" sudo -u postgres \
    "$POSTGRES_BIN_DIR/psql" -Atc 'select pg_is_in_recovery()'
}

# First VM that is not the one about to be broken; used to read cluster state.
other_vm() {
  local vm
  for vm in "${VM_NAMES[@]}"; do
    if [[ "$vm" != "${1:-}" ]]; then
      printf '%s\n' "$vm"
      return 0
    fi
  done
  return 1
}

wait_for_new_leader() {
  local survivor="$1" previous_leader="$2" json leader
  for _ in {1..45}; do
    if json="$(patroni_json "$survivor" 2>/dev/null)"; then
      leader="$(leader_of "$json")"
      if [[ -n "$leader" && "$leader" != "$previous_leader" ]]; then
        printf '%s\n' "$leader"
        return 0
      fi
    fi
    sleep 2
  done
  return 1
}

# Called when a node fails to rejoin. Without this the only signal is "did not
# rejoin", which says nothing about whether Patroni is crash-looping, its config
# is unreadable, or replication simply has not caught up yet.
diagnose_node() {
  local vm="$1"
  echo "--- diagnostics for $vm ---" >&2
  if ! limactl shell --tty=false "$vm" true 2>/dev/null; then
    echo "  $vm is not reachable over SSH" >&2
    return
  fi
  printf '  patroni.yml: ' >&2
  limactl shell --tty=false "$vm" sudo stat -c '%s bytes, modified %y' \
    /etc/patroni/patroni.yml 2>&1 >&2 || true
  printf '  services: patroni=%s etcd=%s\n' \
    "$(limactl shell --tty=false "$vm" systemctl is-active percona-patroni 2>&1)" \
    "$(limactl shell --tty=false "$vm" systemctl is-active etcd 2>&1)" >&2
  echo "  last Patroni log lines:" >&2
  limactl shell --tty=false "$vm" sudo journalctl -u percona-patroni --no-pager -n 8 2>/dev/null \
    | sed 's/^/    /' >&2 || true
}

wait_for_healthy_cluster() {
  local survivor="$1" json
  for _ in {1..90}; do
    if json="$(patroni_json "$survivor" 2>/dev/null)" && \
      jq -e 'length == 3
             and ([.[] | select(.Role == "Leader")] | length == 1)
             and ([.[] | select(.State == "streaming")] | length == 2)' \
        <<< "$json" >/dev/null; then
      return 0
    fi
    sleep 2
  done
  return 1
}

break_the_primary() {
  local scenario="$1" target_vm="$2" recovery

  case "$scenario" in
    vm)
      echo "Force-stopping the primary VM $target_vm (Patroni and PostgreSQL both die)"
      limactl stop --force "$target_vm"
      stopped_vm="$target_vm"
      ;;
    postgres)
      echo "SIGKILLing the PostgreSQL postmaster on $target_vm (Patroni stays up)"
      limactl shell --tty=false "$target_vm" sudo sh -ceu \
        "kill -9 \"\$(head -1 $POSTGRES_DATA_DIR/postmaster.pid)\""
      ;;
    patroni)
      frozen_pid="$(limactl shell --tty=false "$target_vm" \
        sudo systemctl show -p MainPID --value percona-patroni)"
      echo "Freezing Patroni (pid $frozen_pid) on $target_vm with SIGSTOP"
      limactl shell --tty=false "$target_vm" sudo kill -STOP "$frozen_pid"
      frozen_vm="$target_vm"
      # The split-brain window: Patroni can no longer prove it holds the leader
      # key, yet PostgreSQL is still up and still answering as a primary.
      recovery="$(pg_in_recovery "$target_vm")"
      [[ "$recovery" == "f" ]] || {
        echo "Expected PostgreSQL to still be primary right after freezing Patroni (got '$recovery')" >&2
        return 1
      }
      echo "  PostgreSQL is still primary (pg_is_in_recovery = false) with Patroni frozen."
      echo "  This is exactly the window softdog exists to close."
      ;;
    etcd)
      echo "Blocking etcd ports 2379/2380 on $target_vm (Patroni loses the DCS but stays alive)"
      limactl shell --tty=false "$target_vm" sudo nft -f - <<NFT
table inet $FENCE_TABLE {
  chain out {
    type filter hook output priority 0; policy accept;
    tcp dport { 2379, 2380 } reject
  }
  chain in {
    type filter hook input priority 0; policy accept;
    tcp dport { 2379, 2380 } reject
  }
}
NFT
      partitioned_vm="$target_vm"
      ;;
  esac
}

# Wait until the fault has visibly taken hold, and assert *how* it took hold.
# For vm and postgres there is nothing to wait for: the client starts straight
# away and rides out the election.
confirm_fault() {
  local scenario="$1" target_vm="$2" boot_before="$3" current

  case "$scenario" in
    vm | postgres)
      return 0
      ;;
    patroni)
      echo "Waiting for softdog to reset $target_vm (watchdog timeout = ttl - safety_margin = 25s)"
      for _ in {1..45}; do
        current="$(boot_id "$target_vm" 2>/dev/null || true)"
        if [[ -n "$current" && "$current" != "$boot_before" ]]; then
          echo "  FENCED: boot id changed $boot_before -> $current"
          echo "  The node reset itself; nothing asked it to."
          frozen_vm=""
          frozen_pid=""
          return 0
        fi
        sleep 2
      done
      echo "softdog did not reset $target_vm within 90s" >&2
      return 1
      ;;
    etcd)
      echo "Waiting for Patroni to notice the DCS is gone"
      for _ in {1..30}; do
        if [[ "$(pg_in_recovery "$target_vm" 2>/dev/null || true)" == "t" ]]; then
          current="$(boot_id "$target_vm")"
          echo "  DEMOTED: pg_is_in_recovery is now true on $target_vm"
          [[ "$current" == "$boot_before" ]] || {
            echo "  Expected a graceful demotion, but the node rebooted ($boot_before -> $current)" >&2
            return 1
          }
          echo "  boot id unchanged ($current): Patroni stepped down by itself,"
          echo "  so the watchdog never needed to fire."
          return 0
        fi
        sleep 2
      done
      echo "Patroni did not demote itself on $target_vm within 60s" >&2
      return 1
      ;;
  esac
}

recover_the_old_primary() {
  local scenario="$1" target_vm="$2"

  case "$scenario" in
    vm)
      echo "Restarting $target_vm so it can rejoin as a replica"
      limactl start --tty=false "$target_vm" >/dev/null
      stopped_vm=""
      ;;
    postgres)
      echo "Waiting for Patroni to restart PostgreSQL on $target_vm as a replica"
      ;;
    patroni)
      echo "Waiting for $target_vm to finish rebooting and rejoin as a replica"
      ;;
    etcd)
      echo "Healing the etcd partition on $target_vm"
      limactl shell --tty=false "$target_vm" sudo nft delete table inet "$FENCE_TABLE"
      partitioned_vm=""
      ;;
  esac
}

run_scenario() {
  local scenario="$1"
  local initial_json initial_leader initial_server target_vm survivor boot_before
  local client_status new_leader new_server retries

  echo
  echo "=== Scenario: $scenario ==="

  # Begin from a settled cluster. Fault-injection scenarios run back to back,
  # and one that starts while a node from the previous scenario is still
  # catching up can see promotion delayed past its window: Patroni will not
  # promote a lagging candidate, so the wait below expires against a cluster
  # that was never unhealthy, only busy.
  wait_for_healthy_cluster "$(other_vm)" || {
    echo "The cluster was not healthy before injecting the fault" >&2
    return 1
  }

  initial_json="$(patroni_json "$(other_vm)")"
  initial_leader="$(leader_of "$initial_json")"
  [[ -n "$initial_leader" ]] || {
    echo "Could not identify the current Patroni leader" >&2
    return 1
  }
  target_vm="lab2-$initial_leader"
  survivor="$(other_vm "$target_vm")"

  # Baseline, and acceptance criterion 1: the client reaches the current primary
  # and completes a write. Also warms the dotnet build, so the timed run below
  # measures the failover window rather than a cold compile.
  initial_server="$("$SCRIPT_DIR/test-npgsql.sh" | jq -r '.server')"
  echo "Baseline: client wrote through primary $initial_leader ($initial_server)"

  boot_before="$(boot_id "$target_vm")"
  client_stdout="$(mktemp "${TMPDIR:-/tmp}/lab2-failover-out.XXXXXX")"
  client_stderr="$(mktemp "${TMPDIR:-/tmp}/lab2-failover-err.XXXXXX")"

  break_the_primary "$scenario" "$target_vm"
  confirm_fault "$scenario" "$target_vm" "$boot_before"

  # For vm and postgres this lands while no host is an eligible primary. For the
  # two split-brain scenarios it deliberately waits until the old primary has
  # been fenced or has demoted itself: until then it is still answering as a
  # primary, and a client reaching it would be writing to a doomed node.
  "$SCRIPT_DIR/test-npgsql.sh" > "$client_stdout" 2> "$client_stderr" &
  client_pid=$!
  echo "Started the Npgsql client (pid $client_pid)"

  new_leader="$(wait_for_new_leader "$survivor" "$initial_leader")" || {
    echo "A new Patroni leader was not elected" >&2
    return 1
  }
  echo "Patroni promoted $new_leader"

  client_status=0
  wait "$client_pid" || client_status=$?
  client_pid=""
  (( client_status == 0 )) || {
    echo "The Npgsql client did not reach the new primary (exit $client_status):" >&2
    cat "$client_stderr" >&2
    return 1
  }

  new_server="$(jq -r '.server' < "$client_stdout")"
  [[ "$new_server" != "$initial_server" ]] || {
    echo "Npgsql did not move off the failed primary" >&2
    return 1
  }
  retries="$(grep -c 'No primary available' "$client_stderr" || true)"
  echo "Client wrote through the new primary $new_leader ($new_server) after $retries retries"

  recover_the_old_primary "$scenario" "$target_vm"

  # A quiet lab may not emit another WAL record after pg_rewind establishes the
  # rejoining node's minimum recovery point. Generate one through the same path.
  "$SCRIPT_DIR/test-npgsql.sh" >/dev/null

  wait_for_healthy_cluster "$survivor" || {
    echo "$target_vm did not rejoin the cluster as a healthy replica" >&2
    diagnose_node "$target_vm"
    return 1
  }

  rm -f "$client_stdout" "$client_stderr"
  client_stdout=""
  client_stderr=""
  echo "PASS ($scenario): all three members are healthy again"
}

main() {
  case "${1:-all}" in
    vm | postgres | patroni | etcd) run_scenario "$1" ;;
    failover)
      run_scenario vm
      run_scenario postgres
      ;;
    fencing)
      run_scenario patroni
      run_scenario etcd
      ;;
    all)
      run_scenario vm
      run_scenario postgres
      run_scenario patroni
      run_scenario etcd
      ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
