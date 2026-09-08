#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

[[ -f "$LAB_DIR/.env" ]] || { echo "Run make create_vms first" >&2; exit 1; }
[[ -f "$LAB_DIR/.secrets/pgpass" ]] || { echo "Run make configure_cluster first" >&2; exit 1; }

source "$LAB_DIR/.env"
export LAB2_PG_HOSTS="${PG1_IP},${PG2_IP},${PG3_IP}"
export LAB2_PGPASS="$LAB_DIR/.secrets/pgpass"

dotnet run --project "$LAB_DIR/client/Lab2.Client.csproj" --configuration Release
