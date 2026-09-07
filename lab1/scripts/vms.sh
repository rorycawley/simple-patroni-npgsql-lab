#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly VM_NAMES=(lab1-pg1 lab1-pg2 lab1-pg3)
readonly VM_CPUS="${VM_CPUS:-2}"
readonly VM_MEMORY_GIB="${VM_MEMORY_GIB:-4}"
readonly VM_DISK_GIB="${VM_DISK_GIB:-20}"
readonly LIMA_TEMPLATE="${LIMA_TEMPLATE:-$SCRIPT_DIR/../rocky-9.8.yaml}"

usage() {
  cat <<'EOF'
Usage: ./scripts/vms.sh create|destroy|status

create   Create (if needed) and start lab1-pg1, lab1-pg2, and lab1-pg3.
destroy  Permanently delete those three VMs and their disks.
status   Display the Lima status of the Lab 1 VMs.

Optional environment overrides:
  VM_CPUS=2 VM_MEMORY_GIB=4 VM_DISK_GIB=20 LIMA_TEMPLATE=rocky-9.8.yaml
EOF
}

require_lima() {
  command -v limactl >/dev/null 2>&1 || {
    echo "limactl is required. Install Lima first: brew install lima" >&2
    exit 1
  }
}

instance_exists() {
  limactl list --quiet | grep -Fxq "$1"
}

create() {
  for vm_name in "${VM_NAMES[@]}"; do
    if instance_exists "$vm_name"; then
      echo "Starting existing VM: $vm_name"
    else
      echo "Creating VM: $vm_name"
      limactl create --tty=false --name="$vm_name" \
        --cpus="$VM_CPUS" --memory="$VM_MEMORY_GIB" --disk="$VM_DISK_GIB" \
        --mount-none "$LIMA_TEMPLATE"
    fi
    limactl start --tty=false "$vm_name"
  done
}

destroy() {
  for vm_name in "${VM_NAMES[@]}"; do
    if instance_exists "$vm_name"; then
      echo "Deleting VM and disk: $vm_name"
      limactl delete --tty=false --force "$vm_name"
    else
      echo "VM does not exist, skipping: $vm_name"
    fi
  done
}

status() {
  for vm_name in "${VM_NAMES[@]}"; do
    if instance_exists "$vm_name"; then
      limactl list --format table "$vm_name"
    else
      echo "Not created: $vm_name"
    fi
  done
}

main() {
  require_lima
  case "${1:-}" in
    create) create ;;
    destroy) destroy ;;
    status) status ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
