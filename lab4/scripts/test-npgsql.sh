#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

[[ -f "$LAB_DIR/.env" ]] || { echo "Run make create_vms first" >&2; exit 1; }
[[ -f "$LAB_DIR/.secrets/pgpass" ]] || { echo "Run make configure_cluster first" >&2; exit 1; }

source "$LAB_DIR/.env"
# The client runs on the application VM, not the host: it crosses the same
# network, firewall and pg_hba rules as any real client, and PostgreSQL can pin
# a TLS 1.3 floor that .NET on macOS cannot negotiate.
limactl shell --tty=false lab4-app1 sudo env \
  LAB4_PG_HOSTS="${PG1_IP},${PG2_IP},${PG3_IP}" \
  LAB4_PGPASS=/etc/lab4/client/pgpass \
  LAB4_CA=/etc/lab4/client/ca.crt \
  /opt/lab4-client/Lab4.Client
