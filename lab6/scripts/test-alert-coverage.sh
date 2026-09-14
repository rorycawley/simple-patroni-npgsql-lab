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
readonly VM_NAMES=(lab6-pg1 lab6-pg2 lab6-pg3)
readonly VM_PREFIX="lab6-"
readonly PATRONI_CONFIG=/etc/patroni/patroni.yml
readonly PGBIN=/usr/pgsql-18/bin

[[ -f "$LAB_DIR/.env" ]] || { echo "Run make create_vms first" >&2; exit 1; }
# shellcheck disable=SC1091
source "$LAB_DIR/.env"
readonly GW="${LAB6_GATEWAY_IP:-${PG1_IP%.*}.1}"
readonly MIMIR="http://$GW:${LAB6_MIMIR_PORT:-9019}"

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
  if t="$(await_firing ClusterPaused 32)"; then
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
  if t="$(await_firing EtcdQuorumLost 32)"; then
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
# ---------------------------------------------------------------------------
echo
echo "=== Fault: a node is isolated from etcd (runbook 4, single member) ==="
# Distinct from quorum loss: the cluster survives, and the isolated node demotes
# itself rather than diverging. Correct behaviour, still worth knowing about.
victim=""
for vm in "${VM_NAMES[@]}"; do [[ "$vm" != "$(leader_vm)" ]] && { victim="$vm"; break; }; done
if [[ -n "$victim" ]]; then
  on "$victim" sudo bash -c 'firewall-cmd --direct --add-rule ipv4 filter OUTPUT 0 -p tcp --dport 2379 -j DROP' >/dev/null 2>&1
  if t="$(await_firing PatroniLostDcs 40)"; then
    pass "PatroniLostDcs fired after ${t}s on ${victim#$VM_PREFIX}"
  else
    fail "a node was cut off from etcd and PatroniLostDcs never fired"
  fi
  [[ "$(rule_state EtcdQuorumLost)" != "firing" ]] \
    && pass "and EtcdQuorumLost stayed quiet: one member is not a quorum problem" \
    || fail "EtcdQuorumLost fired for a single isolated member"
  on "$victim" sudo bash -c 'firewall-cmd --direct --remove-rule ipv4 filter OUTPUT 0 -p tcp --dport 2379 -j DROP' >/dev/null 2>&1
fi
settle >/dev/null 2>&1; await_all_clear >/dev/null 2>&1

# ---------------------------------------------------------------------------
echo
echo "=== Fault: a node will not rejoin (runbook 5) ==="
# Damaging the control file kills PATRONI, not just PostgreSQL: it reads
# pg_control at startup and exits on an identity mismatch. Alloy keeps running and
# keeps shipping node metrics, so the node looks alive to everything except a
# check that notices Patroni itself has stopped answering.
victim=""
for vm in "${VM_NAMES[@]}"; do [[ "$vm" != "$(leader_vm)" ]] && { victim="$vm"; break; }; done
if [[ -n "$victim" ]]; then
  on "$victim" sudo systemctl stop percona-patroni >/dev/null 2>&1
  on "$victim" sudo -u postgres "$PGBIN/pg_ctl" -D /var/lib/pgsql/data -w -t 40 stop -m fast >/dev/null 2>&1
  on "$victim" sudo bash -c 'head -c 8192 /dev/urandom > /var/lib/pgsql/data/global/pg_control' >/dev/null 2>&1
  on "$victim" sudo systemctl start percona-patroni >/dev/null 2>&1
  if t="$(await_firing PatroniNotScrapable 32)"; then
    pass "PatroniNotScrapable fired after ${t}s on ${victim#$VM_PREFIX}"
  else
    fail "Patroni died on a node and PatroniNotScrapable never fired"
  fi
  [[ "$(rule_state AlloyNotReporting)" != "firing" ]] \
    && pass "and AlloyNotReporting stayed quiet: the agent is fine, which is what makes this fault sneaky" \
    || fail "AlloyNotReporting fired; the agent is healthy and should look it"
  # Repair by the documented route: reinit is unavailable while Patroni is down.
  on "$victim" sudo systemctl stop percona-patroni >/dev/null 2>&1
  on "$victim" sudo rm -rf /var/lib/pgsql/data >/dev/null 2>&1
  on "$victim" sudo install -d -o postgres -g postgres -m 0700 /var/lib/pgsql/data >/dev/null 2>&1
  on "$victim" sudo systemctl start percona-patroni >/dev/null 2>&1
fi
settle >/dev/null 2>&1; await_all_clear >/dev/null 2>&1

# ---------------------------------------------------------------------------
echo
echo "=== Fault: failover blocked by a missing watchdog (runbook 2) ==="
# The real fault is a missing module, CLUSTER-WIDE -- softdog not loaded, so no
# node can arm a watchdog and Patroni's `mode: required` means none will hold the
# leader key. Removing it from only the two standbys does not reproduce that: the
# fenced leader reboots, modules-load.d reloads softdog, and it RECLAIMS the key
# within about a minute, so the no-leader window closes before any sane alert
# threshold. That is what the first attempt measured.
#
# The leader's Patroni is stopped cleanly rather than frozen, so nothing has to be
# fenced: the key simply expires and nobody is eligible to take it.
leader="$(leader_vm)"
stripped=()
for vm in "${VM_NAMES[@]}"; do
  on "$vm" sudo rmmod softdog >/dev/null 2>&1 && stripped+=("$vm")
done
if (( ${#stripped[@]} >= 2 )); then
  on "$leader" sudo systemctl stop percona-patroni >/dev/null 2>&1
  if t="$(await_firing NoLeaderAnywhere 40)"; then
    pass "NoLeaderAnywhere fired after ${t}s with no watchdog available on any node"
  else
    fail "no node could be promoted and NoLeaderAnywhere never fired"
  fi
  for other in ClusterPaused EtcdQuorumLost; do
    [[ "$(rule_state "$other")" != "firing" ]] \
      && pass "and $other stayed quiet: this is the watchdog cause, not that one" \
      || fail "$other also fired; the three causes of 'no leader' are not distinguishable"
  done
  for vm in "${stripped[@]}"; do on "$vm" sudo modprobe softdog >/dev/null 2>&1; done
  on "$leader" sudo systemctl start percona-patroni >/dev/null 2>&1
else
  fail "could not remove softdog"
fi
settle >/dev/null 2>&1; await_all_clear >/dev/null 2>&1

# ---------------------------------------------------------------------------
echo
echo "=== Faults that repair themselves faster than any sane alert ==="
# PostgreSQL killed while Patroni lives, and a VM lost with two survivors, are
# repaired automatically in seconds to about a minute. Paging for them would be
# wrong: the design says so, and SLA.md measures the recovery. An alert with a
# threshold short enough to catch them would flap on every routine promotion.
#
# What must hold instead is that the event is not INVISIBLE. P4 proves a failover
# is reconstructable from logs alone, and this records that the choice is
# deliberate rather than a gap nobody noticed.
pass "PostgreSQL killed and primary VM lost are deliberately NOT alerted: Patroni repairs both, and P4 proves the event stays reconstructable from logs"

echo
echo "=== Already proven firing in earlier phases ==="
# Not re-induced: each was watched firing with a measured latency, and repeating
# a twenty-minute induction to re-learn the same fact is not worth the run time.
# Asserted LOADED here so a rule deleted by accident cannot pass unnoticed.
for entry in "WritesBlockedOnSyncReplication:P2, 130s" "ArchivingFailing:P2, 192s" \
             "RepositoryDoesNotVerify:P3, 204s" "AlloyNotReporting:P5, 253s" \
             "NodeNotReporting:P5, alongside AlloyNotReporting"; do
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
