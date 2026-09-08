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
limactl shell --tty=false lab2-app1 sudo env \
  LAB2_PG_HOSTS="${PG1_IP},${PG2_IP},${PG3_IP}" \
  LAB2_PGPASS=/etc/lab2/client/pgpass \
  LAB2_CA=/etc/lab2/client/ca.crt \
  /opt/lab2-client/Lab2.Client
