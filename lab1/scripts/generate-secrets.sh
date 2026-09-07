#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly SECRETS_DIR="$LAB_DIR/.secrets"
readonly CLUSTER_SECRETS="$SECRETS_DIR/cluster.yml"
readonly PGPASS_FILE="$SECRETS_DIR/pgpass"

command -v openssl >/dev/null 2>&1 || {
  echo "openssl is required to generate Lab 1 passwords" >&2
  exit 1
}

umask 077
mkdir -p "$SECRETS_DIR"

if [[ ! -f "$CLUSTER_SECRETS" ]]; then
  postgres_password="$(openssl rand -hex 24)"
  replication_password="$(openssl rand -hex 24)"
  app_password="$(openssl rand -hex 24)"
  printf '%s\n' \
    "postgres_superuser_password: \"$postgres_password\"" \
    "postgres_replication_password: \"$replication_password\"" \
    "app_runtime_password: \"$app_password\"" > "$CLUSTER_SECRETS"
  echo "Generated $CLUSTER_SECRETS"
fi

app_password="$(sed -n 's/^app_runtime_password: "\([0-9a-f]*\)"$/\1/p' "$CLUSTER_SECRETS")"
[[ -n "$app_password" ]] || {
  echo "Cannot read app_runtime_password from $CLUSTER_SECRETS" >&2
  exit 1
}
printf '*:*:appdb:app_runtime:%s\n' "$app_password" > "$PGPASS_FILE"
chmod 600 "$CLUSTER_SECRETS" "$PGPASS_FILE"
echo "Updated $PGPASS_FILE"
