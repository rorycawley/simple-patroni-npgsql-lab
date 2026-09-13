#!/usr/bin/env bash
set -uo pipefail

# AC-2 in full: every inducible fault raises ITS OWN alert, and nothing else.
#
# "And none are invented" is half the criterion and the half usually skipped. An
# alerting system that fires three alerts for one fault trains its operators to
# ignore it, which is a slower way of having no monitoring at all. So each fault
# here asserts two things: the expected alert fires, and a named alert that must
# NOT fire stays quiet.
#
# The three causes of "no leader anywhere" are why specificity matters most here.
# Paused, etcd quorum lost, and a node unable to arm its watchdog are
# indistinguishable from `patronictl list` -- all three show no Leader row -- so an
# alert that merely says "no leader" sends the reader to a page that cannot tell
# them which of three procedures to follow.
#
# Faults already proven firing in earlier phases are asserted as LOADED here
# rather than induced again, with the measured latency recorded beside them:
#
#   WritesBlockedOnSyncReplication   P2, 130s
#   ArchivingFailing                 P2, 192s
#   RepositoryDoesNotVerify          P3, 204s
#   AlloyNotReporting                P5, 253s

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly VM_NAMES=(lab5-pg1 lab5-pg2 lab5-pg3)
readonly VM_PREFIX="lab5-"
readonly PATRONI_CONFIG=/etc/patroni/patroni.yml
readonly PGBIN=/usr/pgsql-18/bin

[[ -f "$LAB_DIR/.env" ]] || { echo "Run make create_vms first" >&2; exit 1; }
# shellcheck disable=SC1091
source "$LAB_DIR/.env"
readonly GW="${LAB5_GATEWAY_IP:-${PG1_IP%.*}.1}"
readonly MIMIR="http://$GW:${LAB5_MIMIR_PORT:-9009}"

failures=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; failures=$((failures + 1)); }
on() { local vm="$1"; shift; limactl shell --tty=false "$vm" "$@" 2>/dev/null; }

rule_state() {
  curl -s --max-time 12 "$MIMIR/prometheus/api/v1/rules" 2>/dev/null \
    | jq -r --arg n "$1" '.data.groups[]?.rules[]? | select(.name==$n) | .state' 2>/dev/null
}
leader_vm() {
  local vm out
  for vm in "${VM_NAMES[@]}"; do
    out="$(on "$vm" sudo -u postgres timeout 12 patronictl -c "$PATRONI_CONFIG" list --format=json </dev/null)" || continue
    [[ -n "$out" ]] && { printf '%s%s\n' "$VM_PREFIX" "$(jq -r '.[]|select(.Role|test("Leader"))|.Member' <<< "$out")"; return; }
  done
}
settle() {
  local i primary states
  for i in $(seq 1 40); do
    primary="$(leader_vm)"
    if [[ -n "$primary" && "$primary" != "$VM_PREFIX" ]]; then
      states="$(on "$primary" sudo -u postgres "$PGBIN/psql" -Atc \
        "select string_agg(sync_state,',' order by application_name) from pg_stat_replication" </dev/null)"
      [[ "$states" == "quorum,quorum" ]] && return 0
    fi
    sleep 6
  done
  return 1
}
# Waits for a rule to fire, bounded, and returns how long it took.
await_firing() {
  local rule="$1" limit="${2:-30}" i
  for i in $(seq 1 "$limit"); do
    sleep 10
    [[ "$(rule_state "$rule")" == "firing" ]] && { printf '%s\n' $((i * 10)); return 0; }
  done
  return 1
}
# Everything quiet again, so the next fault starts from a clean slate rather than
# inheriting the last one's alert.
await_all_clear() {
  local i n
  for i in $(seq 1 40); do
    n="$(curl -s --max-time 12 "$MIMIR/prometheus/api/v1/rules" 2>/dev/null \
      | jq -r '[.data.groups[]?.rules[]? | select(.state != "inactive")] | length' 2>/dev/null)"
    [[ "${n:-1}" == "0" ]] && return 0
    sleep 10
  done
  return 1
}

echo
echo "=== A quiet baseline: a healthy cluster raises nothing ==="
settle || { echo "cluster was not settled before the run" >&2; exit 1; }
await_all_clear \
  && pass "all rules are inactive before any fault is induced" \
  || fail "something is already firing; every result below would be ambiguous"

# ---------------------------------------------------------------------------
echo
echo "=== Fault: the cluster is paused (runbook 3) ==="
# The one that looks perfectly healthy. Nothing else in this lab notices it.
paused=0
for vm in "${VM_NAMES[@]}"; do
  on "$vm" sudo -u postgres timeout 15 patronictl -c "$PATRONI_CONFIG" pause </dev/null >/dev/null 2>&1 \
    && { paused=1; break; }
done
if (( paused )); then
  if t="$(await_firing ClusterPaused 24)"; then
    pass "ClusterPaused fired after ${t}s"
  else
    fail "the cluster is paused and ClusterPaused never fired"
  fi
  # Specificity: a paused cluster is not an etcd problem, and must not look like one.
  [[ "$(rule_state EtcdQuorumLost)" != "firing" ]] \
    && pass "and EtcdQuorumLost stayed quiet: the two causes are distinguishable" \
    || fail "EtcdQuorumLost also fired; a paused cluster is being reported as an etcd fault"
  for vm in "${VM_NAMES[@]}"; do
    on "$vm" sudo -u postgres timeout 15 patronictl -c "$PATRONI_CONFIG" resume </dev/null >/dev/null 2>&1 && break
  done
else
  fail "could not pause the cluster"
fi
await_all_clear >/dev/null 2>&1

# ---------------------------------------------------------------------------
echo
echo "=== Fault: etcd loses quorum (runbook 4) ==="
# Two of three must run. Stopping two leaves one survivor, which cannot form a
# majority and goes read-only by design.
leader="$(leader_vm)"
downed=()
for vm in "${VM_NAMES[@]}"; do
  [[ "$vm" == "$leader" ]] && continue
  on "$vm" sudo systemctl stop etcd >/dev/null 2>&1 && downed+=("$vm")
done
if (( ${#downed[@]} == 2 )); then
  if t="$(await_firing EtcdQuorumLost 24)"; then
    pass "EtcdQuorumLost fired after ${t}s"
  else
    fail "etcd quorum was lost and EtcdQuorumLost never fired"
  fi
  # Specificity: quorum loss is not a pause, however similar the symptom.
  [[ "$(rule_state ClusterPaused)" != "firing" ]] \
    && pass "and ClusterPaused stayed quiet: automatic failover is still enabled, just impossible" \
    || fail "ClusterPaused also fired; quorum loss is being reported as a pause"
  for vm in "${downed[@]}"; do on "$vm" sudo systemctl start etcd >/dev/null 2>&1; done
else
  fail "could not stop etcd on two nodes"
fi
settle >/dev/null 2>&1
await_all_clear >/dev/null 2>&1

# ---------------------------------------------------------------------------
echo
echo "=== Already proven firing in earlier phases ==="
# Not re-induced: each was watched firing with a measured latency, and repeating
# a twenty-minute induction to re-learn the same fact is not worth the run time.
# Asserted LOADED here so a rule deleted by accident cannot pass unnoticed.
for entry in "WritesBlockedOnSyncReplication:P2, 130s" "ArchivingFailing:P2, 192s" \
             "RepositoryDoesNotVerify:P3, 204s" "AlloyNotReporting:P5, 253s"; do
  r="${entry%%:*}"; when="${entry##*:}"
  st="$(rule_state "$r")"
  [[ -n "$st" ]] \
    && pass "$r is loaded (watched firing in $when)" \
    || fail "$r is no longer loaded; the fault it covers would go unnoticed"
done

echo
echo "=== And the cluster is healthy again ==="
settle \
  && pass "one leader and two streaming quorum standbys" \
  || fail "the cluster did not return to health"
await_all_clear \
  && pass "and every rule is inactive again" \
  || fail "something is still firing after the faults were repaired"

echo
(( failures == 0 )) && { echo "PASS"; exit 0; }
echo "FAILED: $failures problem(s)" >&2
exit 1
