#!/usr/bin/env bash
set -uo pipefail

# Drills ../RUNBOOKS.md against this lab, in two parts.
#
#   lint   Everything the runbook names must exist HERE: every absolute path,
#          every systemd unit, every `sudo -u` user. This is the part that
#          catches a runbook drifting from the system it describes -- a bare
#          `psql` that is not on PATH, a service renamed, a config path moved.
#          Lines marked for the other lab are skipped, which forces a
#          lab-specific instruction to say so rather than read as general.
#
#   drill  Every procedure marked VERIFIED is executed end to end: break the
#          cluster the way the runbook describes, run the documented diagnosis,
#          assert it reports what the runbook says it will, run the documented
#          fix, and assert recovery. Each has a negative control on a healthy
#          cluster, where the same diagnosis must NOT match -- otherwise the
#          runbook is telling you to look for something that is always there.
#
#          Three procedures carry that marker, and they are deliberately of
#          different kinds: one incident you must recognise (blocked writes),
#          one silent degradation that looks exactly like health (paused), and
#          one planned operation you perform on purpose (switchover).
#
# A runbook is an assertion until something runs it. Reviewing it by eye is how
# four wrong commands survived into the first version of this file's subject.

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly RUNBOOK="$LAB_DIR/../RUNBOOKS.md"
readonly VM_NAMES=(lab4-pg1 lab4-pg2 lab4-pg3)
readonly VM_PREFIX="lab4-"     # VM name = this prefix + the Patroni member name
readonly THIS_LAB="Lab 4"
readonly OTHER_LAB="Lab 1"
readonly PATRONI_CONFIG=/etc/patroni/patroni.yml
readonly POSTGRES_BIN_DIR=/usr/pgsql-18/bin

usage() {
  cat <<'EOF'
Usage: ./scripts/test-runbook.sh [lint|drill|sync|pause|switchover|all]

  lint        Every path, unit and account the runbook names exists here
  sync        Drill runbook 1: writes blocked on synchronous replication
  pause       Drill runbook 3: Patroni paused and nobody remembers
  switchover  Drill runbook 8: planned switchover
  drill       All three drills
  all         lint, then every drill (default)
EOF
}

for required in limactl jq; do
  command -v "$required" >/dev/null 2>&1 || {
    echo "$required is required" >&2; exit 1; }
done
[[ -f "$LAB_DIR/.env" ]] || { echo "Run make create_vms first" >&2; exit 1; }
[[ -f "$RUNBOOK" ]] || { echo "Cannot find $RUNBOOK" >&2; exit 1; }

stopped_standbys=()
paused_by_drill=0

# Both drills leave the cluster in a state that must not outlive a failed run.
# A standby left stopped blocks writes; a cluster left paused has no automatic
# failover at all -- which is precisely the silent degradation runbook 3 exists
# to catch, and it would be inexcusable for the drill to cause it.
cleanup() {
  local vm
  for vm in "${stopped_standbys[@]:-}"; do
    [[ -n "$vm" ]] && limactl shell --tty=false "$vm" \
      sudo systemctl start percona-patroni >/dev/null 2>&1
  done
  if (( paused_by_drill )); then
    patronictl_on "$(leader_vm)" resume >/dev/null 2>&1
  fi
  return 0
}
trap cleanup EXIT

pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; }

patroni_json() {
  local vm out
  for vm in "${VM_NAMES[@]}"; do
    if out="$(limactl shell --tty=false "$vm" sudo -u postgres \
      patronictl -c "$PATRONI_CONFIG" list --format=json 2>/dev/null)"; then
      printf '%s\n' "$out"; return 0
    fi
  done
  return 1
}

leader_vm() {
  printf '%s%s\n' "$VM_PREFIX" \
    "$(jq -r '.[] | select(.Role | test("Leader")) | .Member' <<< "$(patroni_json)")"
}

# Exactly the invocation the runbook prints, so a drill cannot pass using a
# command an operator following the page would not have.
patronictl_on() {
  local vm="$1"; shift
  limactl shell --tty=false "$vm" sudo -u postgres \
    patronictl -c "$PATRONI_CONFIG" "$@"
}

sql() {
  limactl shell --tty=false "$1" sudo -u postgres \
    "$POSTGRES_BIN_DIR/psql" -d appdb -Atc "$2"
}

wait_for_quorum() {
  local primary states
  for _ in {1..45}; do
    primary="$(leader_vm)"
    states="$(sql "$primary" "select string_agg(sync_state, ',' order by application_name) from pg_stat_replication" 2>/dev/null)"
    [[ "$states" == "quorum,quorum" ]] && return 0
    sleep 2
  done
  return 1
}

# Content belonging to the other lab is not this lab's problem. Scoping is by
# SECTION, not by line: a procedure whose status says "<other lab> only" is
# skipped entirely, because its commands sit on the lines BELOW that marker
# rather than on it. A line-based filter skipped the marker and linted the
# commands anyway -- caught by this check on its first run against real content.
#
# An instruction that is lab-specific and does NOT say so still fails here. That
# is the point: being silently lab-specific is the error.
runbook_lines() {
  awk -v other="$OTHER_LAB" '
    /^# [0-9]+\./                     { skip = 0 }
    $0 ~ ("Status:.*" other " only")  { skip = 1 }
    skip == 0                         { print }
  ' "$RUNBOOK" | grep -v "\*\*${OTHER_LAB} only\*\*" | grep -v "(${OTHER_LAB})"
}

test_lint() {
  echo
  echo "=== Runbook lint: everything it names exists on ${THIS_LAB} ==="
  local failures=0 node="${VM_NAMES[0]}" path unit user
  local -a paths=() units=() users=()

  # Absolute paths, from fenced commands and inline code alike. Restricted to
  # the directories a runbook would legitimately name, so prose like
  # "/dev/mapper" examples in another lab's row do not leak in.
  # No mapfile: the host runs bash 3.2, where it does not exist.
  while IFS= read -r line; do paths+=("$line"); done < <(runbook_lines \
    | grep -oE '/(usr|etc|var)/[A-Za-z0-9_./-]+' \
    | grep -vE '\.md$|<|>' | sort -u)

  for path in "${paths[@]:-}"; do
    [[ -z "$path" ]] && continue
    # Placeholders and per-incident paths are not expected to pre-exist.
    [[ "$path" == *restore* ]] && continue
    if limactl shell --tty=false "$node" sudo test -e "$path" 2>/dev/null; then
      pass "exists: $path"
    else
      fail "the runbook names '$path', which does not exist on $node"
      failures=$((failures + 1))
    fi
  done

  while IFS= read -r line; do units+=("$line"); done < <(runbook_lines \
    | grep -oE 'systemctl [a-z-]+ [a-z0-9@.-]+' | awk '{print $3}' | sort -u)
  for unit in "${units[@]:-}"; do
    [[ -z "$unit" ]] && continue
    if limactl shell --tty=false "$node" systemctl cat "$unit" >/dev/null 2>&1; then
      pass "unit exists: $unit"
    else
      fail "the runbook names systemd unit '$unit', which does not exist"
      failures=$((failures + 1))
    fi
  done

  while IFS= read -r line; do users+=("$line"); done < <(runbook_lines | grep -oE 'sudo -u [a-z_]+' | awk '{print $3}' | sort -u)
  for user in "${users[@]:-}"; do
    [[ -z "$user" ]] && continue
    if limactl shell --tty=false "$node" id "$user" >/dev/null 2>&1; then
      pass "user exists: $user"
    else
      fail "the runbook runs commands as '$user', which does not exist"
      failures=$((failures + 1))
    fi
  done

  # A bare `psql` would be command-not-found on these nodes, which is exactly
  # the kind of error a review by eye lets through.
  if runbook_lines | grep -qE '(^|[^/[:alnum:]])psql '; then
    fail "the runbook invokes 'psql' without a full path; it is not on PATH here"
    failures=$((failures + 1))
  else
    pass "psql is always invoked by full path"
  fi

  echo
  (( failures == 0 )) && { echo "PASS (lint)"; return 0; }
  echo "FAILED (lint): $failures problem(s)" >&2
  return 1
}

test_drill_sync() {
  echo
  echo "=== Runbook 1 drill: 'writes are blocked on synchronous replication' ==="
  local failures=0 primary vm names blocked probe_out probe_rc

  wait_for_quorum || { fail "cluster was not settled before the drill"; return 1; }
  primary="$(leader_vm)"
  echo "  primary is $primary"

  # Negative control first. The runbook says ANY 1 (*) cannot occur on a healthy
  # cluster; if it can, the diagnosis it gives is worthless.
  names="$(sql "$primary" "show synchronous_standby_names")"
  if [[ "$names" == *'(*)'* ]]; then
    fail "the runbook's signature 'ANY 1 (*)' is present on a HEALTHY cluster"
    failures=$((failures + 1))
  else
    pass "healthy cluster does not match the runbook's signature (saw '$names')"
  fi

  echo "  inducing the state the runbook describes"
  for vm in "${VM_NAMES[@]}"; do
    if [[ "$vm" != "$primary" ]]; then
      limactl shell --tty=false "$vm" sudo systemctl stop percona-patroni >/dev/null 2>&1
      stopped_standbys+=("$vm")
    fi
  done
  sleep 25

  # Exactly the command the runbook tells an operator to run.
  names="$(limactl shell --tty=false "$primary" sudo -u postgres \
    "$POSTGRES_BIN_DIR/psql" -Atc "show synchronous_standby_names" 2>/dev/null)"
  echo "  documented diagnosis reports: '$names'"
  [[ "$names" == *'(*)'* ]] \
    && pass "the documented diagnosis identifies the state" \
    || { fail "the documented diagnosis did not report 'ANY 1 (*)'"; failures=$((failures + 1)); }

  # And that a commit really is blocked, which is the symptom it describes.
  #
  # server_address is supplied explicitly: its default is inet_server_addr(),
  # which is NULL over a Unix socket, and psql as postgres connects that way.
  # The .NET client connects over TCP and so never hits it.
  #
  # The output is captured rather than discarded. Sending it to /dev/null makes
  # "committed successfully" and "failed instantly" indistinguishable -- both
  # simply exit -- and the first version of this check reported the second as
  # the first.
  probe_out="$(mktemp "${TMPDIR:-/tmp}/lab-runbook-probe.XXXXXX")"
  limactl shell --tty=false "$primary" sudo -u postgres \
    "$POSTGRES_BIN_DIR/psql" -d appdb -Atc \
    "insert into public.ha_probe (probe_id, client_name, server_address) values ('runbook-drill-$$', 'runbook-drill', '127.0.0.1')" \
    > "$probe_out" 2>&1 &
  blocked=$!
  sleep 10
  if kill -0 "$blocked" 2>/dev/null; then
    pass "a commit is blocked, as the symptom section describes"
    kill "$blocked" 2>/dev/null; wait "$blocked" 2>/dev/null
  else
    wait "$blocked" 2>/dev/null; probe_rc=$?
    if (( probe_rc == 0 )); then
      fail "the commit COMPLETED; the documented symptom did not occur"
    else
      fail "the probe errored instead of blocking (exit $probe_rc): $(tr '\n' ' ' < "$probe_out" | cut -c1-160)"
    fi
    failures=$((failures + 1))
  fi
  rm -f "$probe_out"

  # The documented fix: bring ONE standby back, which the runbook says suffices.
  echo "  applying the documented fix: start one standby only"
  limactl shell --tty=false "${stopped_standbys[0]}" \
    sudo systemctl start percona-patroni >/dev/null 2>&1

  names=""
  for _ in {1..30}; do
    names="$(sql "$primary" "show synchronous_standby_names" 2>/dev/null)"
    [[ -n "$names" && "$names" != *'(*)'* ]] && break
    sleep 2
  done
  [[ -n "$names" && "$names" != *'(*)'* ]] \
    && pass "one standby was enough, as documented (now '$names')" \
    || { fail "one standby did not clear the block; the runbook overstates the fix"; failures=$((failures + 1)); }

  for vm in "${stopped_standbys[@]}"; do
    limactl shell --tty=false "$vm" sudo systemctl start percona-patroni >/dev/null 2>&1
  done
  stopped_standbys=()
  wait_for_quorum || { fail "quorum did not recover after the drill"; return 1; }
  pass "cluster restored to one leader and two quorum standbys"

  echo
  (( failures == 0 )) && { echo "PASS (sync drill)"; return 0; }
  echo "FAILED (sync drill): $failures problem(s)" >&2
  return 1
}

# Runbook 3. The reason this procedure exists is that a paused cluster is
# indistinguishable from a healthy one in the member table -- so the drill has
# to prove BOTH halves: that the documented signal appears when paused, and that
# the ordinary health signals do not change. A check that only asserted the
# footer would not establish the thing the runbook warns about.
test_drill_pause() {
  echo
  echo "=== Runbook 3 drill: 'Patroni is paused and nobody remembers' ==="
  local failures=0 primary listing

  wait_for_quorum || { fail "cluster was not settled before the drill"; return 1; }
  primary="$(leader_vm)"
  echo "  primary is $primary"

  # Negative control: the documented signal must be absent on a healthy cluster.
  listing="$(patronictl_on "$primary" list 2>/dev/null)"
  if grep -q 'Maintenance mode: on' <<< "$listing"; then
    fail "'Maintenance mode: on' is present on a HEALTHY cluster"
    failures=$((failures + 1))
  else
    pass "healthy cluster does not show the runbook's signal"
  fi

  echo "  inducing the state: patronictl pause"
  patronictl_on "$primary" pause >/dev/null 2>&1
  paused_by_drill=1

  listing="$(patronictl_on "$primary" list 2>/dev/null)"
  if grep -q 'Maintenance mode: on' <<< "$listing"; then
    pass "the documented diagnosis identifies the state"
  else
    fail "the documented diagnosis did not report 'Maintenance mode: on'"
    failures=$((failures + 1))
  fi

  # The claim that makes this runbook necessary: everything else still looks
  # healthy. If the member table DID change, the procedure would be overstating
  # the danger and an operator could find this by ordinary inspection.
  if grep -q 'Leader' <<< "$listing" \
     && [[ "$(grep -c 'streaming' <<< "$listing")" == "2" ]]; then
    pass "the member table still reads healthy, exactly as the runbook warns"
  else
    fail "the member table changed while paused; the runbook overstates the risk"
    failures=$((failures + 1))
  fi

  echo "  applying the documented fix: patronictl resume"
  patronictl_on "$primary" resume >/dev/null 2>&1
  paused_by_drill=0

  listing="$(patronictl_on "$primary" list 2>/dev/null)"
  if grep -q 'Maintenance mode: on' <<< "$listing"; then
    fail "the cluster is still paused after the documented fix"
    failures=$((failures + 1))
  else
    pass "automatic failover is live again"
  fi

  echo
  (( failures == 0 )) && { echo "PASS (pause drill)"; return 0; }
  echo "FAILED (pause drill): $failures problem(s)" >&2
  return 1
}

# Runbook 8. The only VERIFIED procedure here that is a planned operation rather
# than an incident, and the one an operator will actually perform most. It is
# also the cheapest way to put a number on planned maintenance, which SLA.md
# currently records as unmeasured.
test_drill_switchover() {
  echo
  echo "=== Runbook 8 drill: 'planned switchover' ==="
  local failures=0 before after target started elapsed vm

  # The runbook's precondition is one leader and two streaming standbys, so the
  # drill refuses to start without it for the same reason the page does.
  wait_for_quorum || { fail "the runbook's precondition was not met"; return 1; }
  before="$(leader_vm)"
  target=""
  for vm in "${VM_NAMES[@]}"; do
    [[ "$vm" != "$before" ]] && { target="$vm"; break; }
  done
  echo "  switching over from ${before#"$VM_PREFIX"} to ${target#"$VM_PREFIX"}"

  started="$SECONDS"
  patronictl_on "$before" switchover \
    --leader "${before#"$VM_PREFIX"}" --candidate "${target#"$VM_PREFIX"}" \
    --force >/dev/null 2>&1

  after=""
  for _ in {1..45}; do
    after="$(leader_vm 2>/dev/null)"
    [[ "$after" == "$target" ]] && break
    sleep 2
  done
  elapsed=$((SECONDS - started))

  if [[ "$after" == "$target" ]]; then
    pass "the leader moved to the intended candidate in ${elapsed}s"
  else
    fail "the leader is '$after', not the requested candidate '$target'"
    failures=$((failures + 1))
  fi

  # A switchover that promotes but leaves the cluster degraded is not a
  # successful planned operation -- the old primary must come back as a standby.
  if wait_for_quorum; then
    pass "cluster settled to one leader and two quorum standbys"
  else
    fail "the cluster did not return to full redundancy after the switchover"
    failures=$((failures + 1))
  fi

  echo
  (( failures == 0 )) && { echo "PASS (switchover drill)"; return 0; }
  echo "FAILED (switchover drill): $failures problem(s)" >&2
  return 1
}

# Every drill runs even after one fails, so a single invocation reports
# everything that is broken rather than only the first thing -- the same
# convention run-all.sh uses for the checks.
test_drill() {
  local failures=0
  test_drill_sync       || failures=$((failures + 1))
  test_drill_pause      || failures=$((failures + 1))
  test_drill_switchover || failures=$((failures + 1))
  echo
  (( failures == 0 )) && { echo "PASS (all drills)"; return 0; }
  echo "FAILED: $failures drill(s)" >&2
  return 1
}

main() {
  case "${1:-all}" in
    lint) test_lint ;;
    sync) test_drill_sync ;;
    pause) test_drill_pause ;;
    switchover) test_drill_switchover ;;
    drill) test_drill ;;
    all) test_lint || exit 1; test_drill || exit 1 ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
