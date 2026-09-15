#!/usr/bin/env bash
set -uo pipefail

# AC-2, and AC-8's negative half: the two wrong moves, performed on a live
# cluster and COSTED.
#
# Every other phase in this lab can pass on a careful run by a careful operator
# and prove nothing about the procedure. This one establishes that the ordering
# rules are load-bearing rather than superstition, and it produces the only
# output that makes "one node at a time" an instruction someone follows at 02:00
# rather than an unexplained rule: a number for each wrong move.
#
# The expected ALERTING is written down before each control runs, because "the
# right alert fired" decided after seeing what fired is not a test. The two
# controls expect different things, and the second is the uncomfortable one --
# see its section.
#
# Specificity here cannot mean silence. Taking both standbys out makes alerts
# about those standbys fire, and they are TRUE: the nodes really are down. What
# must stay quiet is any alert that would send the operator to the wrong
# procedure, which is what the named quiet-assertions below check.

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly VM_NAMES=(lab6-pg1 lab6-pg2 lab6-pg3)
readonly VM_PREFIX="lab6-"
readonly STANZA=lab6
readonly PATRONI_CONFIG=/etc/patroni/patroni.yml
readonly PGBIN=/usr/pgsql-18/bin
readonly PGDATA=/var/lib/pgsql/data
readonly BLOCK_PROBE_APP="lab6_p2_blocked"

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }
[[ -f "$LAB_DIR/.env" ]] || { echo "Run make create_vms first" >&2; exit 1; }
# shellcheck disable=SC1091
source "$LAB_DIR/.env"
readonly GW="${LAB6_GATEWAY_IP:-${PG1_IP%.*}.1}"
readonly MIMIR="http://$GW:${LAB6_MIMIR_PORT:-9019}"

failures=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; failures=$((failures + 1)); }
on() { local vm="$1"; shift; limactl shell --tty=false "$vm" "$@" 2>/dev/null; }
sql() { on "$1" sudo -u postgres "$PGBIN/psql" -d appdb -Atc "$2"; }

patroni_json() {
  local out vm
  for vm in "${VM_NAMES[@]}"; do
    if out="$(on "$vm" sudo -u postgres patronictl -c "$PATRONI_CONFIG" list --format=json)"; then
      [[ -n "$out" ]] && { printf '%s' "$out"; return 0; }
    fi
  done
  return 1
}
leader_of() { jq -r '.[] | select(.Role | test("Leader")) | .Member' <<< "$1"; }
rule_state() {
  curl -s --max-time 12 "$MIMIR/prometheus/api/v1/rules" 2>/dev/null \
    | jq -r --arg n "$1" '[.data.groups[]?.rules[]? | select(.name == $n)][0].state // "absent"'
}
# Wait for a named alert to reach firing, reporting how long it took.
await_firing() {
  local rule="$1" budget="${2:-30}" i
  for ((i = 1; i <= budget; i++)); do
    [[ "$(rule_state "$rule")" == "firing" ]] && { printf '%s' $((i * 10)); return 0; }
    sleep 10
  done
  return 1
}

cluster="$(patroni_json)" || { echo "  FAIL: no Patroni cluster answered" >&2; exit 1; }
leader="$(leader_of "$cluster")"
# Not `mapfile`: this runs on macOS, where bash is 3.2 and mapfile does not
# exist. The failure is loud rather than silent, but only because `set -u`
# caught the unset array on the next line.
standbys=()
while IFS= read -r _m; do [[ -n "$_m" ]] && standbys+=("$_m"); done < <(
  jq -r '.[] | select(.Role | test("Leader") | not) | .Member' <<< "$cluster")
echo
echo "=== A settled cluster before anything is broken ==="
echo "  leader $leader, standbys ${standbys[*]}"
[[ "$(jq -r '[.[] | select(.State == "streaming")] | length' <<< "$cluster")" == "2" ]] \
  && pass "two streaming standbys, so both wrong moves start from health" \
  || fail "the cluster is not healthy; refusing to measure a wrong move from a wrong state"

sql "$VM_PREFIX$leader" "CREATE TABLE IF NOT EXISTS public.p2_probe (id serial, at timestamptz default now())" >/dev/null

# ----------------------------------------------------------------------------
echo
echo "=== Wrong move 1: both standbys at once ==="
echo "  EXPECTED, named in advance:"
echo "    writes block, WritesBlockedOnSyncReplication fires"
echo "    NoLeaderAnywhere, ClusterPaused and EtcdQuorumLost all stay quiet"
echo

# What a parallel patch actually produces: both standbys out of service at the
# same moment. Patroni is stopped first and PostgreSQL after it, because stopping
# Patroni alone leaves PostgreSQL running -- a trap this series has hit before,
# and one that would leave the standbys still confirming flushes, so nothing
# would block and the control would prove nothing.
for m in "${standbys[@]}"; do
  on "$VM_PREFIX$m" sudo systemctl stop percona-patroni >/dev/null 2>&1
  on "$VM_PREFIX$m" sudo -u postgres "$PGBIN/pg_ctl" -D "$PGDATA" -m fast stop >/dev/null 2>&1
done
blocked_start=$SECONDS
down=0
for m in "${standbys[@]}"; do
  on "$VM_PREFIX$m" pgrep -x postgres >/dev/null 2>&1 || down=$((down + 1))
done
(( down == 2 )) \
  && pass "both standbys are down, which is what patching them together produces" \
  || fail "only $down of 2 standbys stopped; the control is not in the state it claims"

# The write that should not complete. Backgrounded, and its exit is the measure
# of how long the cluster refused writes.
block_out="$(mktemp "${TMPDIR:-/tmp}/lab6-p2.XXXXXX")"
on "$VM_PREFIX$leader" sudo -u postgres env PGAPPNAME="$BLOCK_PROBE_APP" \
  "$PGBIN/psql" -d appdb -Atc "INSERT INTO public.p2_probe DEFAULT VALUES" > "$block_out" 2>&1 &
block_pid=$!

# PostgreSQL names the wait itself. A backend parked in SyncRep is by definition
# waiting for a synchronous standby to confirm a flush, so no timing heuristic
# can be fooled here.
waited=""
for _ in {1..30}; do
  we="$(sql "$VM_PREFIX$leader" "SELECT wait_event FROM pg_stat_activity WHERE application_name = '$BLOCK_PROBE_APP' AND state = 'active' LIMIT 1")"
  [[ "$we" == "SyncRep" ]] && { waited=yes; break; }
  sleep 2
done
[[ -n "$waited" ]] \
  && pass "the write is parked in SyncRep: PostgreSQL itself says it is waiting on a standby" \
  || fail "no backend reached SyncRep; writes are not blocked and this is not runbook 1's state"

ssn="$(sql "$VM_PREFIX$leader" "SHOW synchronous_standby_names")"
grep -q '(\*)' <<< "$ssn" \
  && pass "synchronous_standby_names is '$ssn' -- Patroni's unsatisfiable placeholder, runbook 1's signature" \
  || fail "synchronous_standby_names is '$ssn', not the placeholder runbook 1 documents"

echo "  holding the fault so the alert has time to fire (its window is 130s)..."
# Measured from blocked_start, the same baseline as the cost below. Reporting it
# from when this wait happened to begin produced "fired at 140s" beside "blocked
# for 133s", which reads as the alert arriving after the fault had ended.
if await_firing WritesBlockedOnSyncReplication 30 >/dev/null; then
  lat=$((SECONDS - blocked_start))
  pass "WritesBlockedOnSyncReplication fired ${lat}s after writes began blocking"
else
  fail "WritesBlockedOnSyncReplication never fired while writes were demonstrably blocked"
fi

# Specificity: the alerts that would send the reader to the wrong page.
for pair in "NoLeaderAnywhere:there IS a leader; this is not runbook 2" \
            "ClusterPaused:automatic failover is still enabled, just impossible to satisfy" \
            "EtcdQuorumLost:etcd is untouched; the DCS is healthy"; do
  r="${pair%%:*}"; why="${pair#*:}"
  [[ "$(rule_state "$r")" != "firing" ]] \
    && pass "and $r stayed quiet: $why" \
    || fail "$r is firing, which would send the operator to the wrong procedure"
done

echo "  restoring both standbys..."
for m in "${standbys[@]}"; do
  on "$VM_PREFIX$m" sudo systemctl start percona-patroni >/dev/null 2>&1
done
wait "$block_pid" 2>/dev/null
blocked_for=$((SECONDS - blocked_start))
if grep -qi "INSERT 0 1" "$block_out"; then
  pass "the blocked write finally committed once a standby returned: writes were refused, never lost"
else
  fail "the blocked write did not commit: $(head -1 "$block_out")"
fi
rm -f "$block_out"

recovered=""
for _ in {1..60}; do
  [[ "$(jq -r '[.[] | select(.State == "streaming")] | length' <<< "$(patroni_json)")" == "2" ]] \
    && { recovered=yes; break; }
  sleep 5
done
[[ -n "$recovered" ]] \
  && pass "both standbys are streaming again" \
  || fail "the cluster did not recover two streaming standbys"

echo "  COST of wrong move 1: writes refused for ${blocked_for}s"

# ----------------------------------------------------------------------------
echo
echo "=== Wrong move 2: restarting PostgreSQL behind Patroni's back ==="
echo "  EXPECTED, named in advance:"
echo "    the leader key moves and the timeline advances -- an election"
echo "    NO alert fires at all: the cluster self-repairs faster than every"
echo "    threshold in the ruleset, so monitoring will not report this mistake"
echo

before="$(patroni_json)"
leader2="$(leader_of "$before")"
tl_before="$(jq -r --arg l "$leader2" '.[] | select(.Member == $l) | .TL' <<< "$before")"
echo "  leader $leader2 on timeline $tl_before"

# Wrong move 1 left true alerts firing about standbys that really were down.
# Wait for them to clear, so this control starts from silence and anything heard
# afterwards belongs to THIS control.
echo "  waiting for the alerting to fall silent after the first control..."
quiet=""
for _ in {1..40}; do
  [[ "$(curl -s --max-time 12 "$MIMIR/prometheus/api/v1/alerts" 2>/dev/null \
      | jq -r '[.data.alerts[]? | select(.state == "firing")] | length')" == "0" ]] \
    && { quiet=yes; break; }
  sleep 15
done
[[ -n "$quiet" ]] \
  && pass "the alerting is silent again, so this control starts from a clean baseline" \
  || fail "alerts are still firing from the previous control; cannot attribute what follows"

# Names, not a count. Comparing counts cannot tell "a new alert fired" from "an
# old one resolved" -- the first version of this check failed because the count
# fell from 3 to 0, which is the system behaving correctly.
alerts_before="$(curl -s --max-time 12 "$MIMIR/prometheus/api/v1/alerts" 2>/dev/null \
  | jq -r '[.data.alerts[]? | select(.state == "firing") | .labels.alertname] | sort | join(",")')"

# `pg_ctl restart` is the exact move: it is what an operator who knows PostgreSQL
# and not Patroni types, believing it costs two seconds. With
# primary_start_timeout: 0 Patroni treats the vanished postmaster as a crash.
elect_start=$SECONDS
on "$VM_PREFIX$leader2" sudo -u postgres "$PGBIN/pg_ctl" -D "$PGDATA" -m fast restart >/dev/null 2>&1

writable=""
new_leader=""
for _ in {1..90}; do
  now="$(patroni_json)" || { sleep 2; continue; }
  new_leader="$(leader_of "$now")"
  if [[ -n "$new_leader" ]] && sql "$VM_PREFIX$new_leader" "INSERT INTO public.p2_probe DEFAULT VALUES" >/dev/null 2>&1; then
    writable=yes; break
  fi
  sleep 2
done
elect_elapsed=$((SECONDS - elect_start))
[[ -n "$writable" ]] \
  && pass "the cluster accepted writes again ${elect_elapsed}s after the restart" \
  || fail "the cluster never became writable again"

after="$(patroni_json)"
tl_after="$(jq -r --arg l "$(leader_of "$after")" '.[] | select(.Member == $l) | .TL' <<< "$after")"
if [[ "$tl_after" != "$tl_before" ]]; then
  pass "it cost an ELECTION: timeline $tl_before -> $tl_after, leader $leader2 -> $(leader_of "$after")"
  echo "  COST of wrong move 2: ${elect_elapsed}s and a promotion, against ~2s for a switchover"
else
  fail "no election occurred (timeline still $tl_before) -- AC-2's premise does not hold as written"
  echo "  FINDING: pg_ctl restart completed inside Patroni's loop_wait, so the cluster never noticed."
  echo "           The mistake is real but survivable at this speed; the runbook must say so."
fi

echo "  checking the uncomfortable half: did anything alert?"
sleep 60
alerts_after="$(curl -s --max-time 12 "$MIMIR/prometheus/api/v1/alerts" 2>/dev/null \
  | jq -r '[.data.alerts[]? | select(.state == "firing") | .labels.alertname] | sort | join(",")')"
if [[ "$alerts_after" == "$alerts_before" ]]; then
  pass "no alert fired, as named in advance: an unnecessary election is INVISIBLE to monitoring"
  echo "         The maintenance runbook cannot tell an operator they would have been paged."
else
  fail "alerting changed from [${alerts_before:-none}] to [${alerts_after:-none}]; something fired that was not named"
  curl -s --max-time 12 "$MIMIR/prometheus/api/v1/alerts" 2>/dev/null \
    | jq -r '.data.alerts[]? | select(.state == "firing") | "      firing: \(.labels.alertname)"'
fi

# ----------------------------------------------------------------------------
echo
echo "=== AC-7: the cluster is whole again after both wrong moves ==="
final="$(patroni_json)"
[[ "$(jq -r '[.[] | select(.Role | test("Leader"))] | length' <<< "$final")" == "1" ]] \
  && pass "exactly one leader" || fail "leader count is not 1"
settled=""
for _ in {1..60}; do
  [[ "$(jq -r '[.[] | select(.State == "streaming")] | length' <<< "$(patroni_json)")" == "2" ]] \
    && { settled=yes; break; }
  sleep 5
done
[[ -n "$settled" ]] && pass "two streaming standbys" || fail "the cluster is left degraded"
dcs="$(on "$VM_PREFIX$(leader_of "$final")" sudo -u postgres patronictl -c "$PATRONI_CONFIG" show-config 2>/dev/null)"
grep -q "synchronous_mode_strict: true" <<< "$dcs" \
  && pass "quorum commit is still strict" || fail "strict mode was lost"

sql "$VM_PREFIX$(leader_of "$(patroni_json)")" "DROP TABLE IF EXISTS public.p2_probe" >/dev/null 2>&1

echo
(( failures == 0 )) && { echo "PASS"; exit 0; }
echo "FAILED: $failures problem(s)" >&2
exit 1
