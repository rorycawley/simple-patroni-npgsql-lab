#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly LAB_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
readonly ENV_FILE="$LAB_DIR/.env"
readonly VM_NAMES=(lab1-pg1 lab1-pg2 lab1-pg3)
readonly NODE_NAMES=(pg1 pg2 pg3)
readonly NODE_FQDNS=(pg1.lab.example pg2.lab.example pg3.lab.example)

usage() {
  echo "Usage: lima.sh --list" >&2
}

require_vms() {
  command -v limactl >/dev/null 2>&1 || {
    echo "limactl is required to build the Lab 1 inventory" >&2
    exit 1
  }
  [[ -f "$ENV_FILE" ]] || {
    echo "Missing $ENV_FILE. Run 'make -C $LAB_DIR create_vms' first." >&2
    exit 1
  }
}

inventory() {
  local index vm_name ssh_config_file node_ip node_ip_variable

  source "$ENV_FILE"
  printf '%s' '{"_meta":{"hostvars":{'
  for index in "${!VM_NAMES[@]}"; do
    vm_name="${VM_NAMES[index]}"
    ssh_config_file="$(limactl list --format '{{.SSHConfigFile}}' "$vm_name")"
    node_ip_variable="PG$((index + 1))_IP"
    node_ip="${!node_ip_variable}"
    [[ -n "$ssh_config_file" && -n "$node_ip" ]] || {
      echo "Missing Lima SSH configuration or VM IP for $vm_name" >&2
      exit 1
    }
    [[ "$index" -gt 0 ]] && printf ','
    printf '"%s":{"ansible_host":"lima-%s","ansible_ssh_common_args":"-F %s","lab1_node_ip":"%s","lab1_node_name":"%s","lab1_node_fqdn":"%s"}' \
      "$vm_name" "$vm_name" "$ssh_config_file" "$node_ip" \
      "${NODE_NAMES[index]}" "${NODE_FQDNS[index]}"
  done
  printf '%s' '}},"patroni_nodes":{"hosts":['
  for index in "${!VM_NAMES[@]}"; do
    [[ "$index" -gt 0 ]] && printf ','
    printf '"%s"' "${VM_NAMES[index]}"
  done
  printf '%s\n' ']}}'
}

case "${1:-}" in
  --list) require_vms; inventory ;;
  *) usage; exit 2 ;;
esac
