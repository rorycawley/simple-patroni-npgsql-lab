#!/usr/bin/env bash
set -uo pipefail

# The monitoring stack: Grafana, Mimir and Loki on the control machine.
#
# It runs HERE, not in more VMs, for the reason the whole lab exists: the
# failures worth detecting are a cluster that has quietly stopped doing
# something, and something outside it has to notice. Monitoring that dies with
# the cluster it watches is not monitoring.
#
# STORAGE IS MINIO. Mimir keeps its blocks in `lab5-mimir` and Loki its chunks in
# `lab5-loki`, which is how both are run anywhere that matters, and which this lab
# can afford because the object store, its TLS and its scoped-credential pattern
# already exist. Prometheus is not used: it writes a local TSDB and has no S3
# backend, so S3-backed metrics means Mimir. Tempo is not built, because traces
# are deferred and storage nothing writes to is not worth configuring.
#
# The cost, stated rather than hidden: backups and telemetry now share one object
# store. A MinIO outage stops the backups *and* blinds the monitoring that should
# report it, and the alert cannot be written either. What can still be limited is
# limited -- telemetry authenticates as its OWN identity, scoped to its own two
# buckets, so a monitoring stack that misbehaves cannot reach the repository.

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly PKI_DIR="$LAB_DIR/.secrets/pki"
readonly REPO_SECRETS="$LAB_DIR/.recovery-inputs/repo.yml"
readonly OBS_DIR="$LAB_DIR/.observability"
readonly CONF_DIR="$OBS_DIR/config"
readonly LOG_FILE="$OBS_DIR/observability.log"

readonly MIMIR_BUCKET=lab5-mimir
readonly LOKI_BUCKET=lab5-loki
readonly TELEMETRY_POLICY=lab5-telemetry-rw

# Ports published on the control machine. The guests reach these at the Lima
# shared-network gateway, the same address they already use for the object store.
readonly GRAFANA_PORT="${LAB5_GRAFANA_PORT:-3000}"
readonly MIMIR_PORT="${LAB5_MIMIR_PORT:-9009}"
readonly LOKI_PORT="${LAB5_LOKI_PORT:-3100}"
readonly MAILPIT_HTTP_PORT="${LAB5_MAILPIT_PORT:-8025}"

readonly MIMIR_IMAGE="grafana/mimir:2.14.2"
readonly LOKI_IMAGE="grafana/loki:3.3.2"
readonly GRAFANA_IMAGE="grafana/grafana:11.4.0"
readonly NET=lab5-observability

usage() {
  cat >&2 <<'USAGE'
Usage: ./scripts/observability.sh [start|stop|status|destroy|url]

  start     Create the buckets and telemetry credential, then run the stack
  stop      Stop the containers; the data stays in MinIO
  status    Is it running, and what does it hold?
  destroy   Stop it and DELETE the telemetry buckets. Backups are untouched
  url       Print Grafana's address
USAGE
}

secret() {
  local v
  v="$(sed -n "s/^$1: \"\\(.*\\)\"$/\\1/p" "$REPO_SECRETS" 2>/dev/null)"
  printf '%s\n' "$v"
}

gateway_ip() {
  [[ -f "$LAB_DIR/.env" ]] || { echo "Run make create_vms first" >&2; exit 1; }
  # shellcheck disable=SC1091
  source "$LAB_DIR/.env"
  printf '%s\n' "${LAB5_GATEWAY_IP:-${PG1_IP%.*}.1}"
}

docker_() { docker "$@"; }
running() { [[ -n "$(docker_ ps -q -f "name=^lab5-(grafana|mimir|loki|mailpit)$" 2>/dev/null)" ]]; }

# `host.lima.internal`, NOT `host.docker.internal`. Measured from a container on
# this machine:
#
#     192.168.105.1        -> 200
#     host.lima.internal   -> 200
#     host.docker.internal -> 000   (connection refused)
#
# The Docker alias resolves to the bridge gateway INSIDE the container runtime's
# own VM, which is not where MinIO listens. The Lima name works, and it has the
# second property that matters: it is in the certificate's SANs, so TLS verifies
# against the lab CA rather than needing to be disabled. An IP would also work
# and would hardcode a Lima-assigned address into the config.
readonly S3_FROM_CONTAINER="host.lima.internal:${LAB5_MINIO_PORT:-9300}"

ensure_buckets() {
  local root_user root_pass tel_key tel_secret
  root_user="$(secret minio_root_user)"
  root_pass="$(secret minio_root_password)"
  tel_key="$(secret telemetry_access_key)"
  tel_secret="$(secret telemetry_secret_key)"
  [[ -n "$root_user" && -n "$tel_key" ]] || {
    echo "telemetry credentials missing; run ./scripts/generate-secrets.sh" >&2
    return 1
  }

  local mc_dir="$LAB_DIR/.minio/mc"
  mc_() { MC_CONFIG_DIR="$mc_dir" mc --quiet --no-color "$@"; }
  mc_ alias set lab5 "https://$(gateway_ip):${LAB5_MINIO_PORT:-9300}" \
    "$root_user" "$root_pass" >/dev/null 2>&1

  local b
  for b in "$MIMIR_BUCKET" "$LOKI_BUCKET"; do
    mc_ mb --ignore-existing "lab5/$b" >/dev/null 2>&1
  done

  # A policy scoped to exactly these two buckets. The backup repository is not in
  # it, which is the whole point of a separate identity.
  cat > "$OBS_DIR/telemetry-policy.json" <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow",
      "Action": ["s3:*"],
      "Resource": ["arn:aws:s3:::$MIMIR_BUCKET", "arn:aws:s3:::$MIMIR_BUCKET/*",
                   "arn:aws:s3:::$LOKI_BUCKET",  "arn:aws:s3:::$LOKI_BUCKET/*"] }
  ]
}
POLICY
  mc_ admin policy create lab5 "$TELEMETRY_POLICY" "$OBS_DIR/telemetry-policy.json" >/dev/null 2>&1
  mc_ admin user add lab5 "$tel_key" "$tel_secret" >/dev/null 2>&1
  mc_ admin policy attach lab5 "$TELEMETRY_POLICY" --user "$tel_key" >/dev/null 2>&1
  return 0
}

write_configs() {
  local tel_key tel_secret
  tel_key="$(secret telemetry_access_key)"
  tel_secret="$(secret telemetry_secret_key)"
  mkdir -p "$CONF_DIR"
  cp "$PKI_DIR/ca.crt" "$CONF_DIR/ca.crt"

  # Mimir, monolithic. One bucket with prefixes rather than three buckets: the
  # stores are logically separate and operationally one thing to lose.
  cat > "$CONF_DIR/mimir.yaml" <<MIMIR
# `all,alertmanager` -- NOT just `all`. Mimir's `all` target deliberately excludes
# the alertmanager, so with `all` the ruler evaluates rules, marks them firing,
# tries to deliver them, and logs `Error sending alert` every minute to an
# endpoint that 404s. Rules looked healthy and nothing was ever delivered, which
# is precisely the failure AC-5 exists to catch -- found here by reading Mimir's
# own log, because nothing else reported it.
target: all,alertmanager
multitenancy_enabled: false
server:
  http_listen_port: ${MIMIR_PORT}
  log_level: warn
common:
  storage:
    backend: s3
    s3:
      endpoint: ${S3_FROM_CONTAINER}
      bucket_name: ${MIMIR_BUCKET}
      access_key_id: ${tel_key}
      secret_access_key: ${tel_secret}
      insecure: false
      http:
        tls_ca_path: /etc/mimir/ca.crt
blocks_storage:
  s3:
    bucket_name: ${MIMIR_BUCKET}
  storage_prefix: blocks
  tsdb:
    dir: /data/tsdb
    # Minutes, not the default two hours. The same reasoning that sets
    # archive_timeout to 60s in the earlier labs: a claim you cannot observe
    # inside a test run is a claim the run cannot make. Without this, "telemetry
    # is stored in MinIO" would rest on a seed file and a promise to ship later.
    block_ranges_period: ["2m"]
    ship_interval: 1m
    retention_period: 6h
  bucket_store:
    sync_dir: /data/tsdb-sync
ruler:
  # Without this the ruler evaluates rules, marks them firing, and sends them
  # NOWHERE. Measured before P5: three alerts had been watched firing and none of
  # them were delivered anywhere, which is a rule that works and monitoring that
  # does not.
  alertmanager_url: http://127.0.0.1:${MIMIR_PORT}/alertmanager
ruler_storage:
  s3:
    bucket_name: ${MIMIR_BUCKET}
  storage_prefix: ruler
alertmanager:
  data_dir: /data/alertmanager
  external_url: http://127.0.0.1:${MIMIR_PORT}/alertmanager
  sharding_ring:
    replication_factor: 1
alertmanager_storage:
  s3:
    bucket_name: ${MIMIR_BUCKET}
  storage_prefix: alertmanager
ingester:
  ring:
    replication_factor: 1
store_gateway:
  sharding_ring:
    replication_factor: 1
MIMIR

  cat > "$CONF_DIR/loki.yaml" <<LOKI
auth_enabled: false
server:
  http_listen_port: ${LOKI_PORT}
  log_level: warn
common:
  instance_addr: 127.0.0.1
  path_prefix: /loki
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory
  storage:
    s3:
      endpoint: ${S3_FROM_CONTAINER}
      bucketnames: ${LOKI_BUCKET}
      access_key_id: ${tel_key}
      secret_access_key: ${tel_secret}
      s3forcepathstyle: true
      insecure: false
      http_config:
        ca_file: /etc/loki/ca.crt
schema_config:
  configs:
    - from: 2024-01-01
      store: tsdb
      object_store: s3
      schema: v13
      index:
        prefix: index_
        period: 24h
limits_config:
  allow_structured_metadata: true
ingester:
  # As above: flush in minutes so a run can SEE chunks land in the bucket.
  chunk_idle_period: 1m
  max_chunk_age: 2m
LOKI

  mkdir -p "$CONF_DIR/provisioning/datasources"
  cat > "$CONF_DIR/provisioning/datasources/lab5.yaml" <<DS
apiVersion: 1
datasources:
  - name: Mimir
    type: prometheus
    access: proxy
    url: http://lab5-mimir:${MIMIR_PORT}/prometheus
    isDefault: true
  - name: Loki
    type: loki
    access: proxy
    url: http://lab5-loki:${LOKI_PORT}
DS
}

do_start() {
  mkdir -p "$OBS_DIR" "$CONF_DIR"
  if running; then
    echo "The monitoring stack is already running at $(url_)"
    return 0
  fi
  ensure_buckets || return 1
  write_configs

  docker_ network create "$NET" >/dev/null 2>&1

  docker_ run -d --name lab5-mimir --network "$NET" \
    -p "${MIMIR_PORT}:${MIMIR_PORT}" \
    -v "$CONF_DIR/mimir.yaml:/etc/mimir/mimir.yaml:ro" \
    -v "$CONF_DIR/ca.crt:/etc/mimir/ca.crt:ro" \
    "$MIMIR_IMAGE" -config.file=/etc/mimir/mimir.yaml >>"$LOG_FILE" 2>&1

  docker_ run -d --name lab5-loki --network "$NET" \
    -p "${LOKI_PORT}:${LOKI_PORT}" \
    -v "$CONF_DIR/loki.yaml:/etc/loki/loki.yaml:ro" \
    -v "$CONF_DIR/ca.crt:/etc/loki/ca.crt:ro" \
    "$LOKI_IMAGE" -config.file=/etc/loki/loki.yaml >>"$LOG_FILE" 2>&1

  # Mailpit, not a hand-rolled webhook sink. Email is the channel these alerts
  # would actually use, and it exercises the part a webhook cannot: Alertmanager's
  # email_configs, and the TEMPLATING inside every annotation. A JSON dump would
  # accept `<no value>` as a subject line without comment; a rendered mail does
  # not. SMTP on 1025, HTTP API on 8025 for the checks to read.
  docker_ run -d --name lab5-mailpit --network "$NET" \
    -p "${MAILPIT_HTTP_PORT}:8025" \
    axllent/mailpit:v1.21 >>"$LOG_FILE" 2>&1

  docker_ run -d --name lab5-grafana --network "$NET" \
    -p "${GRAFANA_PORT}:3000" \
    -e GF_AUTH_ANONYMOUS_ENABLED=true \
    -e GF_AUTH_ANONYMOUS_ORG_ROLE=Admin \
    -e GF_FEATURE_TOGGLES_ENABLE=alertingSimplifiedRouting \
    -v "$CONF_DIR/provisioning:/etc/grafana/provisioning:ro" \
    "$GRAFANA_IMAGE" >>"$LOG_FILE" 2>&1

  # Rules are part of the stack, not a manual step. An alert that exists only
  # because someone remembered to curl it in is not monitoring.
  local i ready=""
  for i in $(seq 1 60); do
    if curl -sf "http://127.0.0.1:${MIMIR_PORT}/ready" >/dev/null 2>&1 \
       && curl -sf "http://127.0.0.1:${LOKI_PORT}/ready" >/dev/null 2>&1; then
      ready=yes; break
    fi
    sleep 2
  done
  if [[ -n "$ready" ]]; then
    # The alertmanager config is per-tenant and must be uploaded; without it a
    # firing alert reaches an alertmanager with no route and stops there.
    cat > "$CONF_DIR/alertmanager.yaml" <<'AMCFG'
alertmanager_config: |
  route:
    receiver: lab5-oncall
    group_wait: 5s
    group_interval: 10s
    repeat_interval: 1h
  receivers:
    - name: lab5-oncall
      email_configs:
        - to: oncall@lab5.example
          from: alertmanager@lab5.example
          smarthost: lab5-mailpit:1025
          require_tls: false
          send_resolved: true
AMCFG
    curl -s --max-time 20 -X POST --data-binary @"$CONF_DIR/alertmanager.yaml" \
      "http://127.0.0.1:${MIMIR_PORT}/api/v1/alerts" >/dev/null 2>&1 \
      && echo "Alertmanager route loaded"

    if [[ -f "$LAB_DIR/observability/rules/lab5.yaml" ]]; then
      curl -s --max-time 20 -X POST -H "Content-Type: application/yaml" \
        --data-binary @"$LAB_DIR/observability/rules/lab5.yaml" \
        "http://127.0.0.1:${MIMIR_PORT}/prometheus/config/v1/rules/lab5" >/dev/null 2>&1 \
        && echo "Alert rules loaded"
    fi
    echo "Monitoring stack up: Grafana $(url_), Mimir :${MIMIR_PORT}, Loki :${LOKI_PORT}"
    echo "Telemetry is stored in MinIO: $MIMIR_BUCKET and $LOKI_BUCKET"
  else
    echo "The stack did not become ready; see 'docker logs lab5-mimir' / 'lab5-loki'" >&2
    return 1
  fi
}

do_stop() {
  docker_ rm -f lab5-grafana lab5-loki lab5-mimir lab5-mailpit >/dev/null 2>&1
  echo "Monitoring stack stopped (telemetry kept in MinIO)"
}

url_() { printf 'http://%s:%s\n' "$(gateway_ip)" "$GRAFANA_PORT"; }

do_status() {
  if running; then
    echo "Running: $(url_)"
    docker_ ps --filter "name=lab5-" --format '  {{.Names}}  {{.Status}}'
  else
    echo "Not running"
  fi
}

do_destroy() {
  do_stop
  local root_user root_pass mc_dir="$LAB_DIR/.minio/mc"
  root_user="$(secret minio_root_user)"; root_pass="$(secret minio_root_password)"
  MC_CONFIG_DIR="$mc_dir" mc --quiet --no-color alias set lab5 \
    "https://$(gateway_ip):${LAB5_MINIO_PORT:-9300}" "$root_user" "$root_pass" >/dev/null 2>&1
  local b
  for b in "$MIMIR_BUCKET" "$LOKI_BUCKET"; do
    MC_CONFIG_DIR="$mc_dir" mc --quiet --no-color rb --force "lab5/$b" >/dev/null 2>&1
  done
  docker_ network rm "$NET" >/dev/null 2>&1
  rm -rf "$OBS_DIR"
  echo "Deleted the telemetry buckets. The backup repository is untouched."
}

case "${1:-}" in
  start)   do_start ;;
  stop)    do_stop ;;
  status)  do_status ;;
  destroy) do_destroy ;;
  url)     url_ ;;
  *)       usage; exit 2 ;;
esac
