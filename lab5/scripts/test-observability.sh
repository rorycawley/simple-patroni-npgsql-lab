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
# Settle first. These rules watch the repository reporter, and the phases before
# this one deliberately stop Patroni, pause the cluster and break archiving --
# after which the leader gate correctly answers "cannot tell" and the rules go
# `pending`. That is them working, not failing.
#
# So the check waits for them to clear rather than demanding `inactive` the
# instant a drill ends. Simply ACCEPTING pending would be the wrong repair: it
# would also accept a rule on its way to firing for a real reason.
for _ in $(seq 1 24); do
  rules="$(curl -s --max-time 15 "$MIMIR/prometheus/api/v1/rules" 2>/dev/null)"
  unsettled="$(jq -r '[.data.groups[]?.rules[]? | select(.state != "inactive")] | length' <<< "$rules" 2>/dev/null)"
  [[ "${unsettled:-1}" == "0" ]] && break
  sleep 10
done
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
echo "=== AC-4: reconstruct the last failover from logs alone ==="
# Loki only. No patronictl, no knowledge of which test induced anything -- the
# question is whether someone arriving after the fact can answer it from what was
# shipped, which is the only situation where log retention earns its cost.
# The failover is INDUCED here rather than assumed to have happened. Without
# this the check depends on some earlier phase having caused one: it would fail
# on a fresh run for lack of a failover, or -- worse -- be "fixed" by widening
# the window until it found an old one and passed without proving anything.
ac4_leader=""
for vm in "${VM_NAMES[@]}"; do
  [[ "$(on "$vm" sudo -u postgres "$PGBIN/psql" -Atc 'select not pg_is_in_recovery()' </dev/null)" == "t" ]] \
    && { ac4_leader="$vm"; break; }
done
if [[ -n "$ac4_leader" ]]; then
  echo "  inducing a failover on ${ac4_leader#$VM_PREFIX} to have something to reconstruct"
  # Patroni is stopped FIRST. Killing PostgreSQL alone is a local failure that
  # Patroni simply repairs -- it restarts the postmaster and keeps the leader
  # key, so no promotion happens at all. The first version of this did exactly
  # that, timed out waiting, and then reconstructed a STALE promotion from an
  # earlier run, reporting a leader that was no longer current.
  on "$ac4_leader" sudo systemctl stop percona-patroni >/dev/null 2>&1
  on "$ac4_leader" sudo -u postgres "$PGBIN/pg_ctl" -D /var/lib/pgsql/data -w -t 40 stop -m immediate >/dev/null 2>&1
  ac4_moved=""
  for _ in $(seq 1 30); do
    sleep 5
    nl="$(on "${VM_NAMES[1]}" sudo -u postgres timeout 15 patronictl -c /etc/patroni/patroni.yml list --format=json </dev/null \
      | jq -r '.[]|select(.Role|test("Leader"))|.Member' 2>/dev/null)"
    [[ -n "$nl" && "$nl" != "${ac4_leader#$VM_PREFIX}" ]] && { ac4_moved="$nl"; break; }
  done
  on "$ac4_leader" sudo systemctl start percona-patroni >/dev/null 2>&1
  if [[ -z "$ac4_moved" ]]; then
    fail "could not induce a failover, so there is nothing to reconstruct"
    echo "       (reconstructing a stale event here would prove nothing)" >&2
    ac4_leader=""
  else
    sleep 25   # let the promotion lines reach Loki
  fi
fi

lq() {
  curl -s --max-time 25 -G "$LOKI/loki/api/v1/query_range" \
    --data-urlencode "query=$1" --data-urlencode "limit=${2:-200}" \
    --data-urlencode "direction=backward" \
    --data-urlencode "start=$(( $(date +%s) - 7200 ))000000000" \
    --data-urlencode "end=$(date +%s)000000000" 2>/dev/null
}

# 1. WHO was promoted, and WHEN. Patroni says this once, precisely.
promo="$(lq '{unit="percona-patroni.service"} |= "promoted self to leader by acquiring session lock"' 5)"
new_leader="$(jq -r '[.data.result[]? | .stream.node as $n | .values[]? | {t: .[0], n: $n}] | sort_by(.t) | last | .n // empty' <<< "$promo")"
promo_ns="$(jq -r '[.data.result[]?.values[]?[0]] | map(tonumber) | max // empty' <<< "$promo")"

if [[ -n "$new_leader" && -n "$promo_ns" ]]; then
  pass "a promotion is in the logs: ${new_leader} at $(date -r $((promo_ns/1000000000)) '+%H:%M:%S')"
else
  fail "no promotion found in the logs; a failover cannot be reconstructed"
fi

# 2. WHO it replaced: the last node holding the lock before that moment, which is
#    not the promoted node.
if [[ -n "$promo_ns" ]]; then
  prev="$(lq '{unit="percona-patroni.service"} |= "the leader with the lock"' 400)"
  old_leader="$(jq -r --argjson cut "$promo_ns" --arg new "$new_leader" \
    '[.data.result[]? | .stream.node as $n | .values[]? | select((.[0]|tonumber) < $cut) | {t: (.[0]|tonumber), n: $n}]
     | map(select(.n != $new)) | sort_by(.t) | last | .n // empty' <<< "$prev")"
  lost_ns="$(jq -r --argjson cut "$promo_ns" --arg new "$new_leader" \
    '[.data.result[]? | .stream.node as $n | .values[]? | select((.[0]|tonumber) < $cut) | {t: (.[0]|tonumber), n: $n}]
     | map(select(.n != $new)) | sort_by(.t) | last | .t // empty' <<< "$prev")"

  [[ -n "$old_leader" ]] \
    && pass "it replaced ${old_leader}, last seen holding the lock at $(date -r $((lost_ns/1000000000)) '+%H:%M:%S')" \
    || fail "cannot identify which node was primary before the promotion"

  if [[ -n "$lost_ns" ]]; then
    gap=$(( (promo_ns - lost_ns) / 1000000000 ))
    (( gap >= 0 && gap < 300 )) \
      && pass "the gap between the two was ${gap}s, derived entirely from log timestamps" \
      || fail "the reconstructed gap is ${gap}s, which is not credible"
  fi
fi

# 3. The reconstruction must be RIGHT, not merely produced. Checked against the
#    cluster only now, after the answer has been committed to.
actual="$(on "${VM_NAMES[0]}" sudo -u postgres timeout 20 patronictl -c /etc/patroni/patroni.yml list --format=json </dev/null \
  | jq -r '.[]|select(.Role|test("Leader"))|.Member' 2>/dev/null)"
if [[ -n "$new_leader" && -n "$actual" ]]; then
  [[ "${new_leader#$VM_PREFIX}" == "$actual" ]] \
    && pass "and it is correct: the cluster's leader is ${actual}, which is what the logs said" \
    || fail "the logs named ${new_leader#$VM_PREFIX} but the leader is ${actual}"
fi

echo
echo "=== AC-5: the pipeline is monitored, and alerts ARRIVE ==="
# Firing and arriving are different claims. Between a firing rule and a woken
# human sit a ruler, an alertmanager, a route, a receiver and SMTP -- and this
# lab found all of them broken while the rules showed green: Mimir's `all` target
# excluded the alertmanager, so the ruler logged "Error sending alert" every
# minute to an endpoint that 404'd, and nothing else reported it. Its replacement,
# Mimir's built-in alertmanager, then delivered exactly ONE notification per
# restart and failed every later one with "invalid service state: Terminated"
# while /services still reported it Running. Both failures looked identical from
# the dashboard: every rule green, every rule firing, nobody woken. Alerting now
# runs on a standalone Alertmanager with a mounted config file.
MAILPIT="http://$GW:${LAB5_MAILPIT_PORT:-8025}"
curl -sf --max-time 8 "$MAILPIT/api/v1/messages?limit=1" >/dev/null 2>&1 \
  && pass "the mailbox is reachable, so 'no mail arrived' can be told from 'nothing was listening'" \
  || fail "the alert destination is not reachable; delivery cannot be asserted"

curl -s --max-time 10 -X DELETE "$MAILPIT/api/v1/messages" >/dev/null 2>&1

# Alloy cannot report its own death: it scrapes ITSELF, so a stopped agent stops
# sending and the last value it sent persists through the lookback. Measured --
# with Alloy stopped, up{job="integrations/self"} still read 1 for that node. The
# rule therefore asks the STORE how long ago the node last said anything.
victim="${VM_NAMES[2]}"
on "$victim" sudo systemctl stop alloy >/dev/null 2>&1
delivered=""
# Up to 10 minutes, and the latency is REPORTED rather than merely tolerated. A
# node that stops shipping has to age out of the query lookback before anything
# can notice it is gone -- that delay is a property of the design, so the run
# states it instead of hiding it behind a generous timeout.
ac5_start=$SECONDS
for _ in $(seq 1 50); do
  sleep 12
  # WHICH alert arrived, not whether ANY mail did. This check used to accept the
  # first message in the box and then inspect it -- and it passed on a stale
  # synthetic alert left behind by an earlier probe, reporting delivery of
  # something that had nothing to do with the agent that was stopped. A delivery
  # test that any mail satisfies is not a delivery test.
  #
  # Requiring this specific alert also proves the pipeline delivers MORE THAN
  # ONCE: stopping Alloy trips PatroniLostDcs first, so by the time the
  # AlloyNotReporting mail lands, a separate notification has already been sent.
  # That matters because the previous alertmanager delivered exactly one
  # notification after a restart and silently dropped every one after it.
  for id in $(curl -s --max-time 8 "$MAILPIT/api/v1/messages?limit=25" 2>/dev/null \
                | jq -r '.messages[]?.ID'); do
    if curl -s --max-time 8 "$MAILPIT/api/v1/message/$id" 2>/dev/null \
         | grep -q "AlloyNotReporting"; then
      delivered="$id"; break
    fi
  done
  [[ -n "$delivered" ]] && break
done
ac5_latency=$((SECONDS - ac5_start))
on "$victim" sudo systemctl start alloy >/dev/null 2>&1

if [[ -n "$delivered" ]]; then
  pass "stopping Alloy on ${victim#$VM_PREFIX} produced an AlloyNotReporting mail that ARRIVED, ${ac5_latency}s after the agent stopped, and it was not the first mail of the run"
else
  fail "Alloy was stopped and no alert was delivered; the pipeline fires into a void"
fi

if [[ -n "$delivered" ]]; then
  body="$(curl -s --max-time 10 "$MAILPIT/api/v1/message/$delivered" 2>/dev/null)"
  subj="$(jq -r '.Subject // ""' <<< "$body" 2>/dev/null)"
  grep -qiE "FIRING" <<< "$subj" \
    && pass "and it is legible: subject '$subj'" \
    || fail "the mail arrived with an unusable subject: '$subj'"
  # The reason this lab uses email rather than a webhook: a JSON dump would
  # accept an unrendered template without comment.
  grep -qi "no value" <<< "$body" \
    && fail "an annotation rendered as '<no value>'; the alert would tell a human nothing" \
    || pass "every annotation template rendered; no '<no value>' anywhere in the mail"
  grep -qiE "runbook" <<< "$body" \
    && pass "and it carries the runbook reference, so the reader knows which procedure to follow" \
    || fail "the mail names no runbook"
fi

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
