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

# Repeated, because the outcome is NOT deterministic and one trial cannot say so.
# Measured across runs: the same command cost an election twice (timelines 14->15
# and 15->16) and cost nothing at all a third time, when the restart completed
# inside Patroni's 10s loop_wait and the cluster never noticed the postmaster had
# gone. Asserting "it costs an election" would therefore be asserting a coin
# flip, and would have failed a correct test.
#
# What IS deterministic is that PostgreSQL really restarted, so that is what is
# asserted; whether Patroni noticed is what gets COUNTED. The frequency is the
# finding, and it is worse for an operator than a certainty would be: a mistake
# that usually appears harmless is one people keep making.
attempts=3
elections=0
restarts=0
alerts_before=""
for attempt in $(seq 1 $attempts); do
  before="$(patroni_json)"
  leader2="$(leader_of "$before")"
  tl_before="$(jq -r --arg l "$leader2" '.[] | select(.Member == $l) | .TL' <<< "$before")"
  start_before="$(sql "$VM_PREFIX$leader2" "SELECT pg_postmaster_start_time()")"
  [[ $attempt == 1 ]] && alerts_before="$(curl -s --max-time 12 "$MIMIR/prometheus/api/v1/alerts" 2>/dev/null \
    | jq -r '[.data.alerts[]? | select(.state == "firing") | .labels.alertname] | sort | join(",")')"

  elect_start=$SECONDS
  # BOUNDED. `pg_ctl restart` waits for the postmaster to come back, and Patroni
  # is managing that same postmaster concurrently -- the two raced and wedged for
  # 27 minutes on one run, with no output and no timeout. `timeout` runs inside
  # the guest, which is Linux and has it; the macOS host does not.
  #
  # A timed-out restart is not a failed measurement: postgres was still stopped,
  # which is the wrong move being simulated, and Patroni brings it back. What
  # follows measures what actually happened either way.
  # STOP, not restart, and Patroni does the starting.
  #
  # `pg_ctl restart` waits for the postmaster to come back while Patroni is
  # racing to start it, and the two deadlock. Bounding the guest side with
  # `timeout` was not enough: `limactl shell` does not return when its remote
  # command is killed, so the HOST side hung for 88 minutes with the guest
  # process already gone. `stop` returns as soon as the postmaster is down.
  #
  # It is also the more faithful simulation. The operator's mistake is taking
  # PostgreSQL away from Patroni; what happens next is Patroni's decision, which
  # is exactly the thing being measured.
  on "$VM_PREFIX$leader2" sudo -u postgres timeout 45 "$PGBIN/pg_ctl" -D "$PGDATA" -m fast stop >/dev/null 2>&1

  writable=""
  for _ in {1..90}; do
    now="$(patroni_json)" || { sleep 2; continue; }
    nl="$(leader_of "$now")"
    # statement_timeout, because this INSERT is exactly the write that BLOCKS
    # when synchronous replication cannot be satisfied. Without it the probe for
    # "is the cluster writable yet" hangs on the answer being "no".
    if [[ -n "$nl" ]] && sql "$VM_PREFIX$nl" \
        "SET statement_timeout='5s'; INSERT INTO public.p2_probe DEFAULT VALUES" >/dev/null 2>&1; then
      writable=yes; break
    fi
    sleep 2
  done
  elapsed=$((SECONDS - elect_start))

  after="$(patroni_json)"
  new_leader="$(leader_of "$after")"
  tl_after="$(jq -r --arg l "$new_leader" '.[] | select(.Member == $l) | .TL' <<< "$after")"
  start_after="$(sql "$VM_PREFIX$new_leader" "SELECT pg_postmaster_start_time()")"

  # The deterministic half: the postmaster really did go away and come back.
  if [[ -n "$start_before" && "$start_after" != "$start_before" ]]; then
    restarts=$((restarts + 1))
  else
    fail "attempt $attempt: the postmaster start time did not move, so nothing was actually restarted"
  fi
  [[ -n "$writable" ]] || fail "attempt $attempt: the cluster never became writable again"

  if [[ "$tl_after" != "$tl_before" ]]; then
    elections=$((elections + 1))
    echo "    attempt $attempt: ELECTION -- timeline $tl_before -> $tl_after, writable again in ${elapsed}s"
  else
    echo "    attempt $attempt: no election -- the restart finished inside loop_wait, writable in ${elapsed}s"
  fi
  sleep 20
done

(( restarts == attempts )) \
  && pass "all $attempts restarts genuinely took the postmaster down and back" \
  || fail "only $restarts of $attempts restarts actually happened"

echo "  COST of wrong move 2: an election in $elections of $attempts restarts"
if (( elections > 0 && elections < attempts )); then
  pass "the cost is a GAMBLE, not a certainty: $elections of $attempts cost an election"
  echo "         A mistake that usually looks harmless is one people keep making, so the"
  echo "         runbook has to say it risks an election rather than that it causes one."
elif (( elections == attempts )); then
  pass "every restart cost an election, as AC-2's premise expects"
else
  pass "no restart cost an election in $attempts attempts: at this loop_wait the cluster never noticed"
  echo "         AC-2's premise as written -- 'restarting the primary directly costs an"
  echo "         election' -- does not hold deterministically. Recorded, not rewritten."
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
