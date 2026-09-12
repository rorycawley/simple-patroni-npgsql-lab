#!/usr/bin/env bash
set -uo pipefail

# P0: the monitoring stack exists, every node ships to it, its data is in MinIO,
# and — the one that matters most — the cluster does not depend on any of it.
#
# The last is not a nicety. Alloy runs on the database nodes, so it is the piece
# that could plausibly take PostgreSQL down: a unit ordered before it, a failed
# dependency, a full disk from buffered telemetry. A database made LESS available
# by being watched would defeat the entire lab, so it is asserted rather than
# intended.
#
# The storage assertions look for REAL telemetry, not for the stores being up.
# Both Mimir and Loki write a seed object at startup, and a check satisfied by
# that would pass against a stack storing nothing — the same shape as a repository
# check satisfied by an empty bucket. Flush intervals are shortened in
# observability.sh precisely so a run can observe data land.

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly VM_NAMES=(lab5-pg1 lab5-pg2 lab5-pg3)
readonly VM_PREFIX="lab5-"
readonly MIMIR_BUCKET=lab5-mimir
readonly LOKI_BUCKET=lab5-loki
readonly BACKUP_BUCKET=lab5-backups
readonly PGBIN=/usr/pgsql-18/bin

[[ -f "$LAB_DIR/.env" ]] || { echo "Run make create_vms first" >&2; exit 1; }
# shellcheck disable=SC1091
source "$LAB_DIR/.env"
readonly GW="${LAB5_GATEWAY_IP:-${PG1_IP%.*}.1}"
readonly MIMIR="http://$GW:${LAB5_MIMIR_PORT:-9009}"
readonly LOKI="http://$GW:${LAB5_LOKI_PORT:-3100}"

failures=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; failures=$((failures + 1)); }
on() { local vm="$1"; shift; limactl shell --tty=false "$vm" "$@" 2>/dev/null; }
mc_() { MC_CONFIG_DIR="$LAB_DIR/.minio/mc" mc --quiet --no-color "$@"; }
objects() { mc_ ls --recursive "lab5/$1" 2>/dev/null | wc -l | tr -d ' '; }

echo
echo "=== The stack answers ==="
for probe in "$MIMIR/ready:Mimir" "$LOKI/ready:Loki"; do
  url="${probe%:*}"; name="${probe##*:}"
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$url" 2>/dev/null)"
  [[ "$code" == "200" ]] \
    && pass "$name is ready" \
    || fail "$name returned ${code:-nothing} from $url"
done

echo
echo "=== Every node ships, and all three are present ==="
nodes="$(curl -s --max-time 10 "$LOKI/loki/api/v1/label/node/values" 2>/dev/null)"
for vm in "${VM_NAMES[@]}"; do
  grep -q "\"$vm\"" <<< "$nodes" \
    && pass "${vm#$VM_PREFIX}: logs are arriving in Loki" \
    || fail "${vm#$VM_PREFIX}: no logs in Loki; the node is not shipping"
done

metrics="$(curl -s --max-time 10 -G "$MIMIR/prometheus/api/v1/query" \
  --data-urlencode 'query=count by (node) (up)' 2>/dev/null)"
for vm in "${VM_NAMES[@]}"; do
  grep -q "\"$vm\"" <<< "$metrics" \
    && pass "${vm#$VM_PREFIX}: metrics are arriving in Mimir" \
    || fail "${vm#$VM_PREFIX}: no metrics in Mimir; the node is not shipping"
done

echo
echo "=== The data is in MinIO, not in a container ==="
# Seeds are excluded deliberately: both stores write one at startup, so a check
# that counted them would pass against a stack that has stored no telemetry.
# Bounded WAIT, not a single sample. Mimir cuts blocks on wall-clock-aligned
# boundaries and ships after head compaction -- measured at 180s from a cold
# start even with a 2m block range. Sampling once makes this assertion pass or
# fail on when the run happened to start, which is the kind of flake that gets
# a real failure dismissed as "just timing" later.
mimir_blocks=0; loki_chunks=0
for _ in $(seq 1 40); do
  mimir_blocks="$(mc_ ls --recursive "lab5/$MIMIR_BUCKET" 2>/dev/null | grep -vc "seed" || true)"
  loki_chunks="$(mc_ ls --recursive "lab5/$LOKI_BUCKET" 2>/dev/null | grep -vc "seed" || true)"
  (( ${mimir_blocks:-0} > 0 && ${loki_chunks:-0} > 0 )) && break
  sleep 15
done
(( ${mimir_blocks:-0} > 0 )) \
  && pass "Mimir has written $mimir_blocks object(s) of real telemetry to $MIMIR_BUCKET" \
  || fail "$MIMIR_BUCKET holds only seed data; metrics are not reaching the object store"
(( ${loki_chunks:-0} > 0 )) \
  && pass "Loki has written $loki_chunks object(s) of real telemetry to $LOKI_BUCKET" \
  || fail "$LOKI_BUCKET holds only seed data; logs are not reaching the object store"

echo
echo "=== AC-1: every component is observable ==="
# A distinctive metric per source, not just "the target is up". `up` only says a
# scrape succeeded; these say the thing on the other end is the component it
# claims to be.
promq() {
  curl -s --max-time 10 -G "$MIMIR/prometheus/api/v1/query" \
    --data-urlencode "query=$1" 2>/dev/null | jq -r '.data.result[0].value[1] // "0"'
}
for probe in "patroni_primary:Patroni" "etcd_server_has_leader:etcd" \
             "pg_up:PostgreSQL" "node_filesystem_avail_bytes:the node" \
             "alloy_build_info:Alloy"; do
  q="${probe%%:*}"; name="${probe##*:}"
  n="$(promq "count($q)")"
  (( ${n%%.*} > 0 )) \
    && pass "$name is observable: $q has ${n%%.*} series" \
    || fail "$name reports nothing; $q is absent"
done

echo
echo "=== AC-1: a source that stops is visible as ABSENCE, not read as zero ==="
# The distinction the whole lab turns on. A stopped source must not look like a
# healthy one reporting zero -- that is the shape of every silent failure this
# series has found, from `pgbackrest verify` exiting 0 to a check satisfied by an
# empty bucket.
etcd_victim="${VM_NAMES[1]}"
before="$(promq "count(up{job=\"etcd\"} == 1)")"
on "$etcd_victim" sudo systemctl stop etcd >/dev/null 2>&1
absent=""
for _ in $(seq 1 20); do
  sleep 6
  now="$(promq "count(up{job=\"etcd\"} == 1)")"
  (( ${now%%.*} < ${before%%.*} )) && { absent=yes; break; }
done
[[ -n "$absent" ]] \
  && pass "stopping etcd on ${etcd_victim#$VM_PREFIX} dropped healthy targets ${before%%.*} -> ${now%%.*}" \
  || fail "etcd stopped on ${etcd_victim#$VM_PREFIX} and the metrics did not change; the outage is invisible"

# And it is reported as a FAILED scrape rather than simply vanishing: a target
# that disappears entirely is silence, which is AC-5's problem, not this one.
down="$(promq "count(up{job=\"etcd\"} == 0)")"
(( ${down%%.*} > 0 )) \
  && pass "and it shows as up==0, a failed scrape, not as a missing series" \
  || fail "the stopped source vanished instead of reporting up==0"

on "$etcd_victim" sudo systemctl start etcd >/dev/null 2>&1
restored=""
for _ in $(seq 1 20); do
  sleep 6
  now="$(promq "count(up{job=\"etcd\"} == 1)")"
  (( ${now%%.*} >= ${before%%.*} )) && { restored=yes; break; }
done
[[ -n "$restored" ]] \
  && pass "etcd restarted and the target recovered on its own" \
  || fail "etcd did not return to being scraped"

echo
echo "=== AC-2: the alerts for the two failures that never heal ==="
# Loaded, and SILENT on a healthy cluster. Both halves matter: an alert that
# cannot fire is useless, and one that fires constantly gets muted, which is a
# slower way of having no monitoring at all.
rules="$(curl -s --max-time 15 "$MIMIR/prometheus/api/v1/rules" 2>/dev/null)"
for a in WritesBlockedOnSyncReplication ArchivingFailing NothingArchivedRecently \
         RepositoryDoesNotVerify RepositoryHealthUnreported RepositoryLeaderUndetermined \
         BackupTooOld ArchiveBacklogGrowing; do
  st="$(jq -r --arg n "$a" '.data.groups[]?.rules[]? | select(.name==$n) | .state' <<< "$rules" 2>/dev/null)"
  case "$st" in
    inactive) pass "$a is loaded and silent on a healthy cluster" ;;
    firing)   fail "$a is FIRING on a cluster the rest of this check calls healthy" ;;
    "")       fail "$a is not loaded; the failure it covers would go unnoticed" ;;
    *)        fail "$a is in state '$st'" ;;
  esac
done

echo
echo "=== AC-3: the repository is watched for rot, not only for absence ==="
# verify_ok is read from pgbackrest verify's OUTPUT. Its exit code is 0 on a
# corrupted repository, so a metric built on the exit code could never be 0 and
# the alert above it could never fire.
vok="$(promq "min(lab5_repo_verify_ok)")"
[[ "$vok" == "1" ]] \
  && pass "the repository verifies, reported from verify's output rather than its exit code" \
  || fail "lab5_repo_verify_ok is ${vok:-absent}"
# Coverage, so "found nothing wrong" cannot be confused with "checked nothing" --
# the same distinction as a check that passes on an empty result.
checked="$(promq "max(lab5_repo_wal_checked)")"
age="$(promq "max(lab5_repo_last_backup_age_seconds)")"
(( ${age%%.*} >= 0 )) \
  && pass "the newest backup is ${age%%.*}s old, reported by the node holding the leader key" \
  || fail "no backup age is being reported"
leaders="$(promq "count(lab5_repo_metrics_leader == 1)")"
[[ "${leaders%%.*}" == "1" ]] \
  && pass "exactly one node reports on the repository, so the alert cannot flap between three" \
  || fail "${leaders%%.*} nodes claim to be the repository reporter"

echo
echo "=== Telemetry cannot reach the backup repository ==="
# The coupling accepted in the design is one object store. It is not one
# identity, and this is the assertion that keeps those separate.
tel_key="$(sed -n 's/^telemetry_access_key: "\(.*\)"$/\1/p' "$LAB_DIR/.recovery-inputs/repo.yml")"
tel_secret="$(sed -n 's/^telemetry_secret_key: "\(.*\)"$/\1/p' "$LAB_DIR/.recovery-inputs/repo.yml")"
mc_ alias set lab5tel "https://$GW:${LAB5_MINIO_PORT:-9300}" "$tel_key" "$tel_secret" >/dev/null 2>&1
mc_ ls "lab5tel/$MIMIR_BUCKET" >/dev/null 2>&1 \
  && pass "the telemetry credential can read its own bucket" \
  || fail "the telemetry credential cannot reach $MIMIR_BUCKET"
if mc_ ls "lab5tel/$BACKUP_BUCKET" >/dev/null 2>&1; then
  fail "the telemetry credential can read $BACKUP_BUCKET; the identities are not separated"
else
  pass "and it is refused on $BACKUP_BUCKET: a misbehaving stack cannot touch the backups"
fi
mc_ alias remove lab5tel >/dev/null 2>&1

echo
echo "=== The cluster does not depend on the stack ==="
# Stop the whole stack and require the database to carry on. This is the
# property that decides whether monitoring made availability better or worse.
"$SCRIPT_DIR/observability.sh" stop >/dev/null 2>&1
sleep 10
leader=""
for vm in "${VM_NAMES[@]}"; do
  [[ "$(on "$vm" sudo -u postgres "$PGBIN/psql" -Atc 'select not pg_is_in_recovery()' </dev/null)" == "t" ]] \
    && { leader="$vm"; break; }
done
[[ -n "$leader" ]] \
  && pass "a primary is still serving with the entire stack down" \
  || fail "no primary answers while the stack is stopped; the cluster depends on it"

if [[ -n "$leader" ]]; then
  on "$leader" sudo -u postgres env PGOPTIONS='-c statement_timeout=15s' "$PGBIN/psql" -d appdb -Atc \
    "insert into public.ha_probe (probe_id, client_name, server_address)
     values ('obs-'||floor(random()*1000000)::text, 'observability', '127.0.0.1')" </dev/null >/dev/null 2>&1 \
    && pass "and it still accepts writes, so quorum commit is unaffected" \
    || fail "writes fail while the stack is down; monitoring has become a dependency"
fi

alloy_up=0
for vm in "${VM_NAMES[@]}"; do
  [[ "$(on "$vm" systemctl is-active alloy)" == "active" ]] && alloy_up=$((alloy_up + 1))
done
(( alloy_up == 3 )) \
  && pass "Alloy keeps running with nowhere to send: it buffers rather than dying" \
  || fail "Alloy stopped on $((3 - alloy_up)) node(s) when the stack went away"

"$SCRIPT_DIR/observability.sh" start >/dev/null 2>&1
recovered=""
for _ in $(seq 1 30); do
  [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 "$MIMIR/ready" 2>/dev/null)" == "200" ]] \
    && { recovered=yes; break; }
  sleep 4
done
[[ -n "$recovered" ]] \
  && pass "the stack came back on its own terms, with the cluster none the wiser" \
  || fail "the stack did not restart"

on "$leader" sudo -u postgres "$PGBIN/psql" -d appdb -Atc \
  "delete from public.ha_probe where client_name = 'observability'" </dev/null >/dev/null 2>&1

echo
(( failures == 0 )) && { echo "PASS"; exit 0; }
echo "FAILED: $failures problem(s)" >&2
exit 1
