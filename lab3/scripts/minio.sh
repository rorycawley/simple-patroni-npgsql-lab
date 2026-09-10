#!/usr/bin/env bash
set -euo pipefail

# The backup object store for Lab 3, on the control machine.
#
# It runs on the host rather than in a fifth VM, for the reason recorded in
# lab2/PLAN.md before this lab began: four VMs already use most of the memory on
# one laptop, and that resource pressure is what ruled out a Tang server in
# Lab 2. The guests reach it at the Lima shared-network gateway.
#
# TLS is not optional here. MinIO is issued a `minio` certificate from the SAME
# CA as the cluster, so a node verifying the object store uses the trust root it
# already has. Nothing is shipped to the guests but ca.crt, which they hold
# already -- the MinIO key stays on this machine, exactly as the CA key does.
#
# Two identities, deliberately:
#
#   root            administers the store. Never leaves this machine
#   lab3-pgbackrest reads and writes ONE bucket, and nothing else
#
# That split is the same reasoning that gives the application app_runtime rather
# than a superuser. A leaked node credential must not be able to delete the
# backups it is meant to be writing.

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly PKI_DIR="$LAB_DIR/.secrets/pki"
readonly CLUSTER_SECRETS="$LAB_DIR/.secrets/cluster.yml"

# Deliberately NOT under .secrets/: `make clean` wipes that, and the whole
# premise of Lab 4 is that the cluster can be destroyed while the backups
# survive. Removing the repository is its own explicit command.
readonly MINIO_DIR="$LAB_DIR/.minio"
readonly DATA_DIR="$MINIO_DIR/data"
readonly CERTS_DIR="$MINIO_DIR/certs"
readonly MC_DIR="$MINIO_DIR/mc"
readonly PID_FILE="$MINIO_DIR/minio.pid"
readonly LOG_FILE="$MINIO_DIR/minio.log"

readonly BUCKET=lab3-backups
# Not 9000. The sibling lab ../percona-patroni-npgsql-lab runs its own MinIO
# there, and a lab that cannot be built while another one is running is not
# standalone -- the same property that keeps Labs 1 and 2 independent copies.
readonly PORT="${LAB3_MINIO_PORT:-9100}"
readonly POLICY=lab3-backup-rw

usage() {
  cat <<'EOF'
Usage: ./scripts/minio.sh [start|stop|status|url|destroy]

  start    Issue the certificate if needed, start MinIO, create the bucket
           and the scoped backup user. Idempotent.
  stop     Stop MinIO. The repository contents are kept.
  status   Report whether it is running, and what it holds.
  url      Print the endpoint the guests use.
  destroy  Stop it and DELETE THE REPOSITORY. Not part of `make clean`.
EOF
}

for required in minio mc openssl; do
  command -v "$required" >/dev/null 2>&1 || {
    echo "$required is required (brew install $required)" >&2; exit 1; }
done

secret() { sed -n "s/^$1: \"\\(.*\\)\"$/\\1/p" "$CLUSTER_SECRETS"; }

gateway_ip() {
  [[ -f "$LAB_DIR/.env" ]] || { echo "Run make create_vms first" >&2; exit 1; }
  # shellcheck disable=SC1091
  source "$LAB_DIR/.env"
  printf '%s\n' "${LAB3_GATEWAY_IP:-${PG1_IP%.*}.1}"
}

endpoint() { printf 'https://%s:%s\n' "$(gateway_ip)" "$PORT"; }

running() {
  [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null
}

mc_() { MC_CONFIG_DIR="$MC_DIR" mc --quiet --no-color "$@"; }

do_start() {
  if running; then echo "MinIO is already running at $(endpoint)"; return 0; fi

  [[ -f "$CLUSTER_SECRETS" ]] || "$SCRIPT_DIR/generate-secrets.sh" >/dev/null
  [[ -f "$PKI_DIR/minio.crt" ]] || "$SCRIPT_DIR/generate-pki.sh" >/dev/null

  local root_user root_pass access_key secret_key
  root_user="$(secret minio_root_user)"
  root_pass="$(secret minio_root_password)"
  access_key="$(secret minio_backup_access_key)"
  secret_key="$(secret minio_backup_secret_key)"
  [[ -n "$root_pass" && -n "$secret_key" ]] || {
    echo "MinIO credentials missing from $CLUSTER_SECRETS" >&2; exit 1; }

  umask 077
  mkdir -p "$DATA_DIR" "$CERTS_DIR" "$MC_DIR/certs/CAs"

  # MinIO insists on these two filenames.
  cp "$PKI_DIR/minio.crt" "$CERTS_DIR/public.crt"
  cp "$PKI_DIR/minio.key" "$CERTS_DIR/private.key"
  chmod 600 "$CERTS_DIR/private.key"
  # mc must verify too, or the check that the guests verify proves nothing about
  # the certificate actually being trusted by anything.
  cp "$PKI_DIR/ca.crt" "$MC_DIR/certs/CAs/lab3-ca.crt"

  echo "Starting MinIO on $(endpoint)"
  MINIO_ROOT_USER="$root_user" MINIO_ROOT_PASSWORD="$root_pass" \
  MINIO_BROWSER=off \
    nohup minio server --quiet --address ":$PORT" --certs-dir "$CERTS_DIR" \
      "$DATA_DIR" >"$LOG_FILE" 2>&1 &
  echo $! > "$PID_FILE"

  local ready=""
  for _ in {1..30}; do
    if curl -sf --cacert "$PKI_DIR/ca.crt" "$(endpoint)/minio/health/live" >/dev/null 2>&1; then
      ready=yes; break
    fi
    sleep 1
  done
  [[ -n "$ready" ]] || {
    echo "MinIO did not become healthy. Last lines of $LOG_FILE:" >&2
    tail -20 "$LOG_FILE" >&2; exit 1; }

  mc_ alias set lab3 "$(endpoint)" "$root_user" "$root_pass" >/dev/null
  mc_ mb --ignore-existing "lab3/$BUCKET" >/dev/null

  # Scope the node credential to this one bucket. pgBackRest needs the multipart
  # verbs as well as the obvious ones: a large backup is uploaded in parts.
  cat > "$MINIO_DIR/policy.json" <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation"],
      "Resource": ["arn:aws:s3:::$BUCKET"] },
    { "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject", "s3:DeleteObject",
                 "s3:ListMultipartUploadParts", "s3:AbortMultipartUpload"],
      "Resource": ["arn:aws:s3:::$BUCKET/*"] }
  ]
}
POLICY
  mc_ admin policy create lab3 "$POLICY" "$MINIO_DIR/policy.json" >/dev/null 2>&1 || true
  mc_ admin user add lab3 "$access_key" "$secret_key" >/dev/null 2>&1 || true
  mc_ admin policy attach lab3 "$POLICY" --user "$access_key" >/dev/null 2>&1 || true

  echo "Bucket $BUCKET ready; backup user '$access_key' scoped to it"
}

do_stop() {
  if running; then
    kill "$(cat "$PID_FILE")" 2>/dev/null || true
    for _ in {1..20}; do running || break; sleep 0.5; done
    echo "MinIO stopped (repository kept in $DATA_DIR)"
  else
    echo "MinIO is not running"
  fi
  rm -f "$PID_FILE"
}

do_status() {
  if running; then
    echo "MinIO: running at $(endpoint), pid $(cat "$PID_FILE")"
    mc_ ls "lab3/$BUCKET" 2>/dev/null | sed 's/^/  /' || true
    printf '  repository size: %s\n' "$(du -sh "$DATA_DIR" 2>/dev/null | cut -f1)"
  else
    echo "MinIO: not running"
    [[ -d "$DATA_DIR" ]] && printf '  repository on disk: %s\n' \
      "$(du -sh "$DATA_DIR" 2>/dev/null | cut -f1)"
  fi
}

do_destroy() {
  do_stop
  rm -rf "$MINIO_DIR"
  echo "Deleted the repository and every backup in it"
}

case "${1:-}" in
  start)   do_start ;;
  stop)    do_stop ;;
  status)  do_status ;;
  url)     endpoint ;;
  destroy) do_destroy ;;
  *)       usage; exit 2 ;;
esac
