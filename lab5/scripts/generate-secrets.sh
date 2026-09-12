#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly SECRETS_DIR="$LAB_DIR/.secrets"
readonly CLUSTER_SECRETS="$SECRETS_DIR/cluster.yml"
readonly PGPASS_FILE="$SECRETS_DIR/pgpass"

command -v openssl >/dev/null 2>&1 || {
  echo "openssl is required to generate Lab 5 passwords" >&2
  exit 1
}

readonly RECOVERY_DIR="$LAB_DIR/.recovery-inputs"
readonly REPO_SECRETS="$RECOVERY_DIR/repo.yml"

umask 077
mkdir -p "$SECRETS_DIR" "$RECOVERY_DIR"

touch "$CLUSTER_SECRETS" "$REPO_SECRETS"

# Add a secret only if it is absent, never rewrite one that exists. A later lab
# adding a credential must not silently rotate the passwords a running cluster
# is already using -- Patroni holds the superuser and replication passwords in
# its own configuration and in the DCS, so changing them here breaks
# replication at a moment of its choosing.
ensure_secret() {
  local file="$1" key="$2" value="$3"
  grep -q "^$key:" "$file" && return 0
  printf '%s: "%s"\n' "$key" "$value" >> "$file"
  echo "  added $key to ${file##*/}"
}

# These three die with the cluster, and are meant to. Rung 6 rebuilds onto fresh
# machines with NEW values for all of them and resets the restored roles to
# match -- so nothing here has to survive a disaster.
ensure_secret "$CLUSTER_SECRETS" postgres_superuser_password   "$(openssl rand -hex 24)"
ensure_secret "$CLUSTER_SECRETS" postgres_replication_password "$(openssl rand -hex 24)"
ensure_secret "$CLUSTER_SECRETS" app_runtime_password          "$(openssl rand -hex 24)"

# MinIO gets two identities, for the same reason the database does not run as a
# superuser. The root credential administers the object store; the nodes get a
# separate key scoped to the one bucket.
#
# Both are RECOVERY INPUTS, not cluster secrets. They describe how to reach the
# surviving repository, so they have to outlive the cluster that used them --
# the object store keeps its IAM configuration inside .minio/, and regenerating
# these would leave a repository full of intact backups that nothing holds the
# keys to. In production this is the difference between losing your database and
# losing your database *and* the credentials for the bucket holding its backups.
migrate_to_recovery_inputs() {
  local key="$1" value
  grep -q "^$key:" "$REPO_SECRETS" && return 0
  value="$(sed -n "s/^$key: \"\\(.*\\)\"$/\\1/p" "$CLUSTER_SECRETS")"
  [[ -n "$value" ]] || return 1
  printf '%s: "%s"\n' "$key" "$value" >> "$REPO_SECRETS"
  # Carried across with its VALUE intact, never regenerated: the surviving
  # object store already knows this key, and a new one would leave a repository
  # full of intact backups that nothing can authenticate to.
  #
  # Then dropped from cluster.yml, so there is one source of truth. Two copies
  # means someone edits the dead one and wonders why nothing changed.
  grep -v "^$key:" "$CLUSTER_SECRETS" > "$CLUSTER_SECRETS.tmp" \
    && mv "$CLUSTER_SECRETS.tmp" "$CLUSTER_SECRETS"
  echo "  moved $key into ${REPO_SECRETS##*/} (it must survive 'make clean')"
}
for key in minio_root_user minio_root_password \
           minio_backup_access_key minio_backup_secret_key; do
  migrate_to_recovery_inputs "$key" || true
done
ensure_secret "$REPO_SECRETS" minio_root_user         "lab5-admin"
ensure_secret "$REPO_SECRETS" minio_root_password     "$(openssl rand -hex 24)"
ensure_secret "$REPO_SECRETS" minio_backup_access_key "lab5-pgbackrest"
ensure_secret "$REPO_SECRETS" minio_backup_secret_key "$(openssl rand -hex 24)"

# The repository cipher passphrase is deliberately NOT one of the above.
#
# `make clean` deletes .secrets/, and Lab 5's premise is that the VMs, the
# volumes and the local secrets are all destroyed while the backups survive. A
# passphrase that dies with the cluster makes every backup it encrypted
# permanently unreadable -- it is the one secret whose loss cannot be recovered
# from, because the backups needed to recover it are the ones it encrypts.
#
# So it lives outside everything `clean` removes, and is treated as an *input*
# to the build rather than a product of it. In production that input comes from
# a secrets manager or a sealed offline copy; here, from this file or from
# LAB5_REPO_CIPHER_PASS.
if ! grep -q '^repo_cipher_pass:' "$REPO_SECRETS"; then
  printf 'repo_cipher_pass: "%s"\n' \
    "${LAB5_REPO_CIPHER_PASS:-$(openssl rand -hex 32)}" >> "$REPO_SECRETS"
  echo "  added repo_cipher_pass to $REPO_SECRETS"
  echo "  (kept outside .secrets/ on purpose: it must survive 'make clean')"
fi

# A SECOND passphrase, not a reuse of the first. The dumps live outside the
# pgBackRest repository, so repo1-cipher-pass does not cover them -- and a single
# key for both would mean losing one loses everything.
if ! grep -q '^dump_cipher_pass:' "$REPO_SECRETS"; then
  printf 'dump_cipher_pass: "%s"\n' \
    "${LAB5_DUMP_CIPHER_PASS:-$(openssl rand -hex 32)}" >> "$REPO_SECRETS"
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
