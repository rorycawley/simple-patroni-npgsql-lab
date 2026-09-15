#!/usr/bin/env bash
set -uo pipefail

# AC-8, positive half: a correct patch cycle wakes nobody.
#
# The negative half was recorded in P2, while those faults were already induced:
# blocked writes raise WritesBlockedOnSyncReplication and nothing misdirecting,
# and an unnecessary election raises NOTHING AT ALL. This phase asserts the other
# direction, which is the one that decides whether any of the ordering rules get
# followed: an alerting system that fires through every maintenance window
# teaches people to ignore it, and they stop reading at exactly the wrong moment.
#
# The MAILBOX is the instrument, not the ruler's current state. An alert that
# fires and resolves inside the window would be invisible to a final-state check
# and would still have woken someone -- Alertmanager sends on the transition, not
# on the endpoint. Reading real mail is the only check that cannot miss that.
#
# The cycle is run fresh rather than reusing P3's result, and the LEVELLING is
# deliberately done before the mailbox is emptied. Putting every node back on the
# build version is setup, not a patch cycle, and AC-8's claim is about the cycle.

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly VM_NAMES=(lab6-pg1 lab6-pg2 lab6-pg3)
readonly VM_PREFIX="lab6-"
readonly STANZA=lab6
readonly PATRONI_CONFIG=/etc/patroni/patroni.yml
readonly PGBIN=/usr/pgsql-18/bin
readonly BUILD_VERSION="${LAB6_PG_VERSION:-18.4}"

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }
[[ -f "$LAB_DIR/.env" ]] || { echo "Run make create_vms first" >&2; exit 1; }
# shellcheck disable=SC1091
source "$LAB_DIR/.env"
readonly GW="${LAB6_GATEWAY_IP:-${PG1_IP%.*}.1}"
readonly MIMIR="http://$GW:${LAB6_MIMIR_PORT:-9019}"
readonly MAILPIT="http://$GW:${LAB6_MAILPIT_PORT:-8035}"

failures=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; failures=$((failures + 1)); }
on() { local vm="$1"; shift; limactl shell --tty=false "$vm" "$@" 2>/dev/null; }

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
installed_on() { on "$VM_PREFIX$1" rpm -q --qf '%{VERSION}' percona-postgresql18-server 2>/dev/null; }
mail_count() { curl -s --max-time 10 "$MAILPIT/api/v1/messages?limit=1" 2>/dev/null | jq -r '.messages_count // "unreachable"'; }
firing_now() {
  curl -s --max-time 12 "$MIMIR/prometheus/api/v1/alerts" 2>/dev/null \
    | jq -r '[.data.alerts[]? | select(.state == "firing") | .labels.alertname] | sort | join(",")'
}

dnf_do() {
  local vm="$1" op="$2"; shift 2
  local i out
  for i in 1 2 3; do
    # shellcheck disable=SC2086
    out="$(on "$vm" sudo dnf -y $( ((i > 1)) && echo --refresh ) "$op" "$@" 2>&1)" && return 0
    sleep 5
  done
  echo "      dnf $op failed on $vm:" >&2
  grep -iE "^error" <<< "$out" | head -2 | sed 's/^/        /' >&2
  return 1
}
pg_packages() { printf '%s' "percona-postgresql18-server-$1* percona-postgresql18-$1* percona-postgresql18-contrib-$1* percona-postgresql18-libs-$1*"; }

echo
echo "=== Setup, before the mailbox is emptied: level every node to $BUILD_VERSION ==="
# Deliberately outside the measured window. This is a rolling downgrade, not a
# patch cycle, and AC-8 is a claim about the cycle.
cluster="$(patroni_json)" || { echo "  FAIL: no Patroni cluster answered" >&2; exit 1; }
for m in $(jq -r '.[].Member' <<< "$cluster"); do
  v="$(installed_on "$m")"
  if [[ "$v" == "$BUILD_VERSION" ]]; then
    echo "  $m already on $BUILD_VERSION"
  else
    echo "  $m on $v, stepping back"
    # shellcheck disable=SC2046
    dnf_do "$VM_PREFIX$m" downgrade $(pg_packages "$BUILD_VERSION") || fail "could not level $m"
    on "$VM_PREFIX$(leader_of "$(patroni_json)")" sudo -u postgres patronictl -c "$PATRONI_CONFIG" \
      restart "$STANZA" "$m" --force >/dev/null 2>&1
    for _ in {1..60}; do
      [[ "$(jq -r --arg m "$m" '.[] | select(.Member == $m) | .State' <<< "$(patroni_json)")" == "streaming" ]] && break
      sleep 3
    done
  fi
done
levelled=""
for _ in {1..40}; do
  [[ "$(jq -r '[.[] | select(.State == "streaming")] | length' <<< "$(patroni_json)")" == "2" ]] && { levelled=yes; break; }
  sleep 5
done
[[ -n "$levelled" ]] && pass "the cluster is level and healthy on $BUILD_VERSION" || fail "the cluster did not settle after levelling"

echo
echo "=== Wait for the alerting to fall completely silent ==="
# Whatever the levelling stirred up must clear first, or the silence being
# measured would be about the wrong thing.
quiet=""
for _ in {1..60}; do
  [[ -z "$(firing_now)" ]] && { quiet=yes; break; }
  sleep 15
done
[[ -n "$quiet" ]] \
  && pass "no alert is firing, so anything heard from here belongs to the cycle" \
  || { fail "alerts are still firing before the cycle starts: [$(firing_now)]"; }

echo
echo "=== Empty the mailbox, and prove it is both empty AND reachable ==="
# "Zero messages" from a mailbox nobody can reach looks exactly like silence.
before_count="$(mail_count)"
[[ "$before_count" != "unreachable" ]] \
  && pass "the mailbox answers, so 'no mail' can be told from 'nothing listening'" \
  || fail "the mailbox is unreachable; silence cannot be asserted"
curl -s --max-time 10 -X DELETE "$MAILPIT/api/v1/messages" >/dev/null 2>&1
sleep 2
[[ "$(mail_count)" == "0" ]] \
  && pass "the mailbox is empty at the start of the cycle" \
  || fail "the mailbox still holds $(mail_count) message(s) after being emptied"

echo
echo "=== Run the complete cycle, correctly ordered ==="
echo "  (this is test-patch-cycle.sh, run fresh -- the same four steps P3 measures)"
cycle_start=$SECONDS
cycle_log="$(mktemp "${TMPDIR:-/tmp}/lab6-p7cycle.XXXXXX")"
if "$SCRIPT_DIR/test-patch-cycle.sh" > "$cycle_log" 2>&1; then
  pass "the cycle completed: $(grep -oE 'complete cycle .*' "$cycle_log" | head -1)"
  pass "and the client saw: $(grep -oE '[0-9]+ transactions committed, ZERO failed' "$cycle_log" | head -1)"
else
  fail "the patch cycle itself failed; a silence result would say nothing about correct maintenance"
  grep -E "FAIL:" "$cycle_log" | head -3 | sed 's/^/      /' >&2
fi
cycle_elapsed=$((SECONDS - cycle_start))
rm -f "$cycle_log"

echo
echo "=== AC-8: what the on-call received ==="
# Give Alertmanager its group_wait plus a margin, so a notification triggered at
# the very end of the cycle has time to arrive rather than landing after the
# check and being missed.
echo "  waiting 90s for any notification triggered near the end to arrive..."
sleep 90
after_count="$(mail_count)"
if [[ "$after_count" == "0" ]]; then
  pass "the mailbox is STILL EMPTY after the patch cycle: correct maintenance woke nobody"
else
  fail "$after_count message(s) arrived during a correct patch cycle"
  echo "  what was sent -- this is a finding about the thresholds, not a failed procedure:" >&2
  curl -s --max-time 10 "$MAILPIT/api/v1/messages?limit=10" 2>/dev/null \
    | jq -r '.messages[]? | "      \(.Subject)"' >&2
  # Single-quoted: backticks inside a double-quoted string are COMMAND
  # SUBSTITUTION, and this line would have tried to run `for:`. Same bug as the
  # mimir.yaml heredoc, in the one branch a passing run never reaches.
  echo '  RECOMMENDATION: each alert above needs a `for:` window longer than the' >&2
  echo "  step that tripped it, or maintenance will page every time." >&2
fi

still_firing="$(firing_now)"
[[ -z "$still_firing" ]] \
  && pass "and no rule is left firing afterwards" \
  || fail "rules are firing after the cycle: [$still_firing]"

echo
echo "=== AC-7: the cluster is not left degraded ==="
final="$(patroni_json)"
[[ "$(jq -r '[.[] | select(.Role | test("Leader"))] | length' <<< "$final")" == "1" ]] \
  && pass "exactly one leader" || fail "leader count is not 1"
[[ "$(jq -r '[.[] | select(.State == "streaming")] | length' <<< "$final")" == "2" ]] \
  && pass "two streaming standbys" || fail "the cluster is left degraded"

echo
# The wrapper's elapsed time, not the cycle's: it includes this script's own
# setup and the 90s notification wait. The cycle's own figure is the one the
# harness prints above, and conflating them would overstate the window.
echo "  P7: a correct patch cycle produced ${after_count} notification(s) (measured over a ${cycle_elapsed}s window)"
echo
(( failures == 0 )) && { echo "PASS"; exit 0; }
echo "FAILED: $failures problem(s)" >&2
exit 1
