#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly SECRETS_DIR="$LAB_DIR/.secrets"
readonly CLUSTER_SECRETS="$SECRETS_DIR/cluster.yml"
readonly PGPASS_FILE="$SECRETS_DIR/pgpass"

command -v openssl >/dev/null 2>&1 || {
  echo "openssl is required to generate Lab 4 passwords" >&2
  exit 1
}

umask 077
mkdir -p "$SECRETS_DIR"

touch "$CLUSTER_SECRETS"

# Add a secret only if it is absent, never rewrite one that exists. A later lab
# adding a credential must not silently rotate the passwords a running cluster
# is already using -- Patroni holds the superuser and replication passwords in
# its own configuration and in the DCS, so changing them here breaks
# replication at a moment of its choosing.
ensure_secret() {
  local key="$1" value="$2"
  grep -q "^$key:" "$CLUSTER_SECRETS" && return 0
  printf '%s: "%s"\n' "$key" "$value" >> "$CLUSTER_SECRETS"
  echo "  added $key"
}

ensure_secret postgres_superuser_password   "$(openssl rand -hex 24)"
ensure_secret postgres_replication_password "$(openssl rand -hex 24)"
ensure_secret app_runtime_password          "$(openssl rand -hex 24)"

# MinIO gets two identities, for the same reason the database does not run as a
# superuser. The root credential administers the object store and never leaves
# this machine; the nodes get a separate key scoped to the one bucket.
ensure_secret minio_root_user        "lab4-admin"
ensure_secret minio_root_password    "$(openssl rand -hex 24)"
ensure_secret minio_backup_access_key "lab4-pgbackrest"
ensure_secret minio_backup_secret_key "$(openssl rand -hex 24)"

# The repository cipher passphrase is deliberately NOT one of the above.
#
# `make clean` deletes .secrets/, and Lab 4's premise is that the VMs, the
# volumes and the local secrets are all destroyed while the backups survive. A
# passphrase that dies with the cluster makes every backup it encrypted
# permanently unreadable -- it is the one secret whose loss cannot be recovered
# from, because the backups needed to recover it are the ones it encrypts.
#
# So it lives outside everything `clean` removes, and is treated as an *input*
# to the build rather than a product of it. In production that input comes from
# a secrets manager or a sealed offline copy; here, from this file or from
# LAB4_REPO_CIPHER_PASS.
readonly RECOVERY_DIR="$LAB_DIR/.recovery-inputs"
readonly REPO_SECRETS="$RECOVERY_DIR/repo.yml"
mkdir -p "$RECOVERY_DIR"
touch "$REPO_SECRETS"
if ! grep -q '^repo_cipher_pass:' "$REPO_SECRETS"; then
  printf 'repo_cipher_pass: "%s"\n' \
    "${LAB4_REPO_CIPHER_PASS:-$(openssl rand -hex 32)}" >> "$REPO_SECRETS"
  echo "  added repo_cipher_pass to $REPO_SECRETS"
  echo "  (kept outside .secrets/ on purpose: it must survive 'make clean')"
fi

# A SECOND passphrase, not a reuse of the first. The dumps live outside the
# pgBackRest repository, so repo1-cipher-pass does not cover them -- and a single
# key for both would mean losing one loses everything.
if ! grep -q '^dump_cipher_pass:' "$REPO_SECRETS"; then
  printf 'dump_cipher_pass: "%s"\n' \
    "${LAB4_DUMP_CIPHER_PASS:-$(openssl rand -hex 32)}" >> "$REPO_SECRETS"
  echo "  added dump_cipher_pass to $REPO_SECRETS"
fi
chmod 600 "$REPO_SECRETS"

app_password="$(sed -n 's/^app_runtime_password: "\([0-9a-f]*\)"$/\1/p' "$CLUSTER_SECRETS")"
[[ -n "$app_password" ]] || {
  echo "Cannot read app_runtime_password from $CLUSTER_SECRETS" >&2
  exit 1
}
printf '*:*:appdb:app_runtime:%s\n' "$app_password" > "$PGPASS_FILE"
chmod 600 "$CLUSTER_SECRETS" "$PGPASS_FILE"
echo "Updated $PGPASS_FILE"
