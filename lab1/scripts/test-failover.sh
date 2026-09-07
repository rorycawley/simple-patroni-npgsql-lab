#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly VM_NAMES=(lab1-pg1 lab1-pg2 lab1-pg3)

source "$LAB_DIR/.env"

stopped_vm=""
restarted_vm=""
cleanup() {
  if [[ -n "$stopped_vm" ]]; then
    limactl start --tty=false "$stopped_vm" >/dev/null || true
  fi
}
trap cleanup EXIT

patroni_json() {
  local vm_name="$1"
  limactl shell --tty=false "$vm_name" sudo -u postgres \
    patronictl -c /etc/patroni/patroni.yml list --format=json
}

initial_json="$(patroni_json "${VM_NAMES[0]}")"
initial_leader="$(jq -r '.[] | select(.Role == "Leader") | .Member' <<< "$initial_json")"
[[ -n "$initial_leader" ]] || { echo "Could not identify the initial Patroni leader" >&2; exit 1; }
initial_server="$($SCRIPT_DIR/test-npgsql.sh | jq -r '.server')"
stopped_vm="lab1-$initial_leader"

echo "Stopping primary VM $stopped_vm ($initial_server) without a guest shutdown"
limactl stop --force "$stopped_vm"

survivor=""
for vm_name in "${VM_NAMES[@]}"; do
  [[ "$vm_name" != "$stopped_vm" ]] && { survivor="$vm_name"; break; }
done

new_leader=""
for _ in {1..30}; do
  if current_json="$(patroni_json "$survivor" 2>/dev/null)"; then
    new_leader="$(jq -r '.[] | select(.Role == "Leader") | .Member' <<< "$current_json")"
    [[ -n "$new_leader" && "$new_leader" != "$initial_leader" ]] && break
  fi
  sleep 2
done
[[ -n "$new_leader" && "$new_leader" != "$initial_leader" ]] || {
  echo "A new Patroni leader was not elected" >&2
  exit 1
}

new_server="$($SCRIPT_DIR/test-npgsql.sh | jq -r '.server')"
[[ "$new_server" != "$initial_server" ]] || {
  echo "Npgsql did not move from the failed primary" >&2
  exit 1
}
echo "Npgsql wrote through new primary $new_leader ($new_server)"

echo "Restarting $stopped_vm and waiting for it to rejoin as a replica"
restarted_vm="$stopped_vm"
limactl start --tty=false "$stopped_vm" >/dev/null
stopped_vm=""

# A quiet lab may not emit another WAL record after pg_rewind establishes the
# replica's minimum recovery point. Generate one through the same client path.
"$SCRIPT_DIR/test-npgsql.sh" >/dev/null

for _ in {1..60}; do
  if current_json="$(patroni_json "$survivor" 2>/dev/null)" && \
    jq -e 'length == 3 and ([.[] | select(.Role == "Leader")] | length == 1) and ([.[] | select(.State == "streaming")] | length == 2)' \
      <<< "$current_json" >/dev/null; then
    echo "All three Patroni members are healthy again"
    exit 0
  fi
  sleep 2
done

echo "$restarted_vm did not rejoin the cluster as a healthy replica" >&2
exit 1
