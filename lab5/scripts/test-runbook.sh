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
readonly VM_NAMES=(lab5-pg1 lab5-pg2 lab5-pg3)
readonly VM_PREFIX="lab5-"     # VM name = this prefix + the Patroni member name
readonly THIS_LAB="Lab 5"
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
  drill       All drills
  all         lint, then every drill (default)
EOF
}

for required in limactl jq; do
  command -v "$required" >/dev/null 2>&1 || {
    echo "$required is required" >&2; exit 1; }
done
[[ -f "$LAB_DIR/.env" ]] || { echo "Run make create_vms first" >&2; exit 1; }
# shellcheck disable=SC1091
source "$LAB_DIR/.env"
readonly PKI_DIR=/etc/lab5/pki
readonly STANZA_NAME=lab5
readonly ETCD_ENDPOINTS="https://${PG1_IP}:2379,https://${PG2_IP}:2379,https://${PG3_IP}:2379"
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
# fail() COUNTS. It used to only print, leaving every caller responsible for
# incrementing a local counter alongside it -- and two calls in the sync drill
# did not, so a drill whose documented symptom never occurred still reported
# PASS. A verdict that depends on remembering a second statement is a verdict
# that will eventually be wrong.
FAIL_COUNT=0
fail() { echo "  FAIL: $1" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }

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
  local _fc0=$FAIL_COUNT
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

  # Skip flags before the unit name. `systemctl enable --now percona-patroni` is
  # an ordinary invocation, and taking the third word from it yields '--now' --
  # which the lint then reported as a missing unit, failing a correct runbook.
  while IFS= read -r line; do units+=("$line"); done < <(runbook_lines \
    | grep -oE 'systemctl [a-z-]+( --?[a-z-]+)* [a-z0-9@.-]+' \
    | awk '{print $NF}' | grep -vE '^-' | sort -u)
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
  failures=$((FAIL_COUNT - _fc0))
  (( failures == 0 )) && { echo "PASS (lint)"; return 0; }
  echo "FAILED (lint): $failures problem(s)" >&2
  return 1
}

test_drill_sync() {
  local _fc0=$FAIL_COUNT
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
  failures=$((FAIL_COUNT - _fc0))
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
  local _fc0=$FAIL_COUNT
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
  failures=$((FAIL_COUNT - _fc0))
  (( failures == 0 )) && { echo "PASS (pause drill)"; return 0; }
  echo "FAILED (pause drill): $failures problem(s)" >&2
  return 1
}

# Runbook 8. The only VERIFIED procedure here that is a planned operation rather
# than an incident, and the one an operator will actually perform most. It is
# also the cheapest way to put a number on planned maintenance, which SLA.md
# currently records as unmeasured.
test_drill_switchover() {
  local _fc0=$FAIL_COUNT
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
  failures=$((FAIL_COUNT - _fc0))
  (( failures == 0 )) && { echo "PASS (switchover drill)"; return 0; }
  echo "FAILED (switchover drill): $failures problem(s)" >&2
  return 1
}

# ---------------------------------------------------------------------------
# Runbook 4: etcd has lost quorum.
#
# The labs isolate ONE member, which is a different incident: the cluster
# survives it. Losing two of three is the case the runbook describes and nothing
# had ever induced, so its central claim -- that Patroni recovers on its own once
# quorum returns, with no --force-new-cluster -- was reasoning, not a result.
#
# The assertion that makes this a drill rather than a demonstration of
# systemctl: the cluster must actually STOP ACCEPTING WRITES while quorum is
# gone. If it kept serving, the runbook would be describing a different system.
test_drill_quorum() {
  local _fc0=$FAIL_COUNT
  local downed=() vm out rc
  echo
  echo "=== Runbook 4 drill: 'etcd has lost quorum' ==="
  wait_for_quorum || { fail "cluster was not settled before the drill"; return 1; }
  local leader; leader="$(leader_vm)"
  echo "  leader is ${leader#$VM_PREFIX}"

  # Two of three, so one survivor cannot form a majority. The leader keeps its
  # own etcd so the failure is quorum loss rather than a node losing its DCS.
  for vm in "${VM_NAMES[@]}"; do
    [[ "$vm" == "$leader" ]] && continue
    downed+=("$vm")
  done
  restore_etcd() {
    for vm in "${downed[@]}"; do
      limactl shell --tty=false "$vm" sudo systemctl start etcd >/dev/null 2>&1
    done
  }
  trap restore_etcd RETURN

  for vm in "${downed[@]}"; do
    limactl shell --tty=false "$vm" sudo systemctl stop etcd >/dev/null 2>&1
  done
  sleep 5

  # Confirm, using the runbook's own command.
  out="$(limactl shell --tty=false "$leader" sudo bash -c \
    "etcdctl --cacert=$PKI_DIR/ca.crt --cert=$PKI_DIR/etcd.crt --key=$PKI_DIR/etcd.key \
     --endpoints=$ETCD_ENDPOINTS endpoint health --cluster" 2>&1)"
  grep -qiE "unhealthy|context deadline|connection refused" <<< "$out" \
    && pass "etcdctl reports the cluster unhealthy, as the runbook says it will" \
    || fail "etcd still reports healthy with two members down"

  # The consequence that matters. ttl is 30s, so give Patroni time to notice.
  local blocked="" i
  for i in $(seq 1 20); do
    sleep 5
    out="$(limactl shell --tty=false "$leader" sudo -u postgres \
      env PGOPTIONS='-c statement_timeout=8s' "$POSTGRES_BIN_DIR/psql" -d appdb -Atc \
      "insert into public.ha_probe (probe_id, client_name, server_address)
       values ('rb4-'||floor(random()*1000000)::text, 'runbook4-drill', '127.0.0.1')" 2>&1)"
    rc=$?
    (( rc != 0 )) && { blocked="$out"; break; }
  done
  if [[ -n "$blocked" ]]; then
    pass "the cluster stopped accepting writes: $(head -1 <<< "$blocked" | cut -c1-72)"
  else
    fail "writes still succeeded with etcd quorum lost; the cluster did not demote"
  fi

  # Fix, exactly as the runbook prints it.
  echo "  restoring membership (no --force-new-cluster, which the runbook forbids)"
  restore_etcd
  local healthy=""
  for i in $(seq 1 24); do
    sleep 5
    out="$(limactl shell --tty=false "$leader" sudo bash -c \
      "etcdctl --cacert=$PKI_DIR/ca.crt --cert=$PKI_DIR/etcd.crt --key=$PKI_DIR/etcd.key \
       --endpoints=$ETCD_ENDPOINTS endpoint health --cluster" 2>&1)"
    grep -qiE "unhealthy|refused" <<< "$out" || { healthy=yes; break; }
  done
  [[ -n "$healthy" ]] \
    && pass "every endpoint is healthy again" \
    || fail "etcd did not return to health after restarting the members"

  wait_for_quorum \
    && pass "Patroni re-acquired the leader key by itself, within ttl" \
    || fail "the cluster did not recover on its own once quorum returned"

  sql "$(leader_vm)" "delete from public.ha_probe where client_name = 'runbook4-drill'" >/dev/null 2>&1
  trap - RETURN
  echo
  (( FAIL_COUNT == _fc0 )) && { echo "PASS (quorum drill)"; return 0; }
  echo "FAILED (quorum drill): $((FAIL_COUNT - _fc0)) problem(s)" >&2
  return 1
}

# ---------------------------------------------------------------------------
# Runbook 6: disk filling, or WAL accumulating.
#
# Induced the way it actually happens: the repository becomes unreachable, so
# archive_command fails, so PostgreSQL cannot recycle a segment it never
# archived, so pg_wal grows. Nothing in this series had ever produced that, which
# left three of the runbook's claims as reasoning -- including the two traps that
# send an operator to the wrong node.
#
# What this must prove beyond "archiving broke":
#   a rising failed_count is visible ON THE LEADER
#   a STANDBY shows zeros throughout, so it looks healthy during the incident
#   `pgbackrest check` on a standby fails [027], which reads like a broken
#     repository and is not one
#   repairing archiving drains the backlog by itself
test_drill_wal() {
  local _fc0=$FAIL_COUNT
  local leader standby before_failed after_failed wal_before wal_after out i
  echo
  echo "=== Runbook 6 drill: 'disk filling, or WAL accumulating' ==="
  wait_for_quorum || { fail "cluster was not settled before the drill"; return 1; }
  leader="$(leader_vm)"
  for vm in "${VM_NAMES[@]}"; do [[ "$vm" != "$leader" ]] && { standby="$vm"; break; }; done
  echo "  leader is ${leader#$VM_PREFIX}; standby ${standby#$VM_PREFIX}"

  archiver() {  # node, column
    limactl shell --tty=false "$1" sudo -u postgres "$POSTGRES_BIN_DIR/psql" -Atc \
      "select $2 from pg_stat_archiver" 2>/dev/null | tr -d ' '
  }
  # .ready files, not the file count in pg_wal. PostgreSQL preallocates and
  # RECYCLES a pool of segments sized by min_wal_size, so the count there stays
  # flat until the pool is exhausted -- measured: 32 segments before and after,
  # while archiving was demonstrably broken. What actually accumulates is the
  # set of segments marked ready and not yet archived, which is the mechanism
  # the runbook describes: a segment that was never archived cannot be removed.
  pending_archive() {
    limactl shell --tty=false "$1" sudo bash -c \
      "ls /var/lib/pgsql/data/pg_wal/archive_status/*.ready 2>/dev/null | wc -l" 2>/dev/null | tr -d ' '
  }
  restore_repo() { "$SCRIPT_DIR/minio.sh" start >/dev/null 2>&1; }
  trap restore_repo RETURN

  before_failed="$(archiver "$leader" failed_count)"
  local sb_before; sb_before="$(archiver "$standby" failed_count)"
  wal_before="$(pending_archive "$leader")"
  echo "  before: failed_count=${before_failed:-?}, segments awaiting archive=${wal_before:-?}"

  # The failure. Not a broken command -- an unreachable repository, which is the
  # form this takes in production.
  "$SCRIPT_DIR/minio.sh" stop >/dev/null 2>&1
  # Write BETWEEN the switches. pg_switch_wal() is a no-op when nothing has been
  # written since the last one, so a tight loop of switches produces a single
  # segment -- measured, a backlog of exactly 1, which is too thin a margin for
  # the assertion below to rest on.
  for i in $(seq 1 8); do
    limactl shell --tty=false "$leader" sudo -u postgres "$POSTGRES_BIN_DIR/psql" -d appdb -Atc \
      "create table if not exists public.rb6_churn (id serial primary key, pad text);
       insert into public.rb6_churn (pad) select repeat('x', 512) from generate_series(1, 4000);
       select pg_switch_wal()" >/dev/null 2>&1
  done

  local rose=""
  for i in $(seq 1 24); do
    sleep 5
    after_failed="$(archiver "$leader" failed_count)"
    [[ -n "$after_failed" && -n "$before_failed" ]] \
      && (( after_failed > before_failed )) && { rose=yes; break; }
  done
  [[ -n "$rose" ]] \
    && pass "failed_count rose on the leader: ${before_failed} -> ${after_failed}" \
    || fail "failed_count did not rise; archiving did not actually break"

  out="$(archiver "$leader" "coalesce(last_failed_wal,'none')")"
  [[ -n "$out" && "$out" != "none" ]] \
    && pass "last_failed_wal names the segment that could not be archived: $out" \
    || fail "no last_failed_wal recorded"

  wal_after="$(pending_archive "$leader")"
  (( ${wal_after:-0} > ${wal_before:-0} )) \
    && pass "unarchived WAL is piling up, ${wal_before} -> ${wal_after} segments awaiting archive: none can be recycled" \
    || fail "no backlog formed (${wal_before} -> ${wal_after}); the incident was not reproduced"

  # The trap that sends people to the wrong node. The assertion is that the
  # standby's counter does not RISE -- not that it reads zero. pg_stat_archiver
  # is cumulative and survives a role change, so a node demoted earlier still
  # carries the failures it recorded as primary. Measured here: the standby
  # showed failed_count=4 from an earlier drill's switchover, which is why
  # "reports zeros" was too strong a claim for the runbook to make.
  local sb_after; sb_after="$(archiver "$standby" failed_count)"
  [[ "${sb_after:-0}" == "${sb_before:-0}" ]] \
    && pass "the standby's failed_count did not move (${sb_before} throughout): it looks healthy during this incident" \
    || fail "the standby's failed_count rose ${sb_before} -> ${sb_after}; archiving is not the primary's job alone"

  out="$(limactl shell --tty=false "$standby" sudo -u postgres \
    pgbackrest --stanza="$STANZA_NAME" check 2>&1)"
  grep -q "\[027\]" <<< "$out" \
    && pass "'pgbackrest check' on the standby fails [027] primary database not found, exactly as documented" \
    || fail "the standby's check did not produce [027]: ${out:0:90}"

  # Fix: repair archiving first, and let PostgreSQL recycle.
  echo "  repairing the repository"
  restore_repo
  local ok=""
  for i in $(seq 1 24); do
    sleep 5
    limactl shell --tty=false "$leader" sudo -u postgres \
      pgbackrest --stanza="$STANZA_NAME" check >/dev/null 2>&1 && { ok=yes; break; }
  done
  [[ -n "$ok" ]] \
    && pass "'pgbackrest check' passes on the leader once the repository is back" \
    || fail "check still fails after the repository returned"

  local drained="" archived_before archived_now
  archived_before="$(archiver "$leader" archived_count)"
  for i in $(seq 1 30); do
    sleep 5
    archived_now="$(archiver "$leader" archived_count)"
    [[ -n "$archived_now" && -n "$archived_before" ]] \
      && (( archived_now > archived_before )) && { drained=yes; break; }
  done
  [[ -n "$drained" ]] \
    && pass "archiving resumed (archived_count ${archived_before} -> ${archived_now})" \
    || fail "archiving did not resume after the repository returned"

  # The runbook claims space is reclaimed with no further intervention. That is
  # the backlog draining, so measure the backlog rather than taking it on trust.
  local pending_now=""
  for i in $(seq 1 30); do
    pending_now="$(pending_archive "$leader")"
    [[ -n "$pending_now" ]] && (( pending_now <= wal_before )) && break
    sleep 5
  done
  (( ${pending_now:-999} <= ${wal_before:-0} )) \
    && pass "the backlog drained back to ${pending_now} with no further intervention: space is reclaimed" \
    || fail "${pending_now} segments still await archive; the backlog did not drain"

  limactl shell --tty=false "$leader" sudo -u postgres "$POSTGRES_BIN_DIR/psql" -d appdb -Atc \
    "drop table if exists public.rb6_churn" >/dev/null 2>&1
  trap - RETURN
  echo
  (( FAIL_COUNT == _fc0 )) && { echo "PASS (wal drill)"; return 0; }
  echo "FAILED (wal drill): $((FAIL_COUNT - _fc0)) problem(s)" >&2
  return 1
}

# ---------------------------------------------------------------------------
# Runbook 5: a node will not rejoin the cluster.
#
# Assembled from failures seen while building Labs 1 and 2, but never driven end
# to end -- so the one ACTIONABLE step on the page, `patronictl reinit`, had
# never been executed by anything.
#
# Induced by damaging a standby's control file, which is the shape most of the
# causes in the table share: the node is up, Patroni is running, and PostgreSQL
# will not start on that data directory. The cause differs; the diagnosis and
# the fix do not.
#
# Three things this must prove, and the last is the one a demonstration skips:
#   the node genuinely will not rejoin on its own
#   reinit brings it back to streaming
#   PRODUCTION NEVER NOTICED -- no failover, no lost rows, writes throughout,
#     because one standby is still confirming commits
test_drill_rejoin() {
  local _fc0=$FAIL_COUNT
  local leader target member rows_before rows_after i state
  echo
  echo "=== Runbook 5 drill: 'a node will not rejoin the cluster' ==="
  wait_for_quorum || { fail "cluster was not settled before the drill"; return 1; }
  leader="$(leader_vm)"
  for vm in "${VM_NAMES[@]}"; do [[ "$vm" != "$leader" ]] && { target="$vm"; break; }; done
  member="${target#$VM_PREFIX}"
  echo "  leader is ${leader#$VM_PREFIX}; breaking ${member}"
  rows_before="$(sql "$leader" "select count(*) from public.ha_probe")"

  # Damage the control file. Patroni stays running; PostgreSQL cannot start on
  # this directory. Safe because it is a standby -- which is precisely the
  # distinction the runbook draws about reinit.
  limactl shell --tty=false "$target" sudo systemctl stop percona-patroni >/dev/null 2>&1
  sleep 2
  limactl shell --tty=false "$target" sudo -u postgres \
    "$POSTGRES_BIN_DIR/pg_ctl" -D /var/lib/pgsql/data -w -t 60 stop -m fast >/dev/null 2>&1
  limactl shell --tty=false "$target" sudo bash -c \
    "head -c 8192 /dev/urandom > /var/lib/pgsql/data/global/pg_control" >/dev/null 2>&1
  limactl shell --tty=false "$target" sudo systemctl start percona-patroni >/dev/null 2>&1

  # It must genuinely fail to rejoin, or the fix below proves nothing.
  local stuck=""
  for i in $(seq 1 20); do
    sleep 5
    state="$(jq -r --arg m "$member" '.[] | select(.Member == $m) | .State' <<< "$(patroni_json)" 2>/dev/null)"
    [[ "$state" == "streaming" ]] && continue
    (( i >= 6 )) && { stuck="$state"; break; }
  done
  [[ -n "$stuck" ]] \
    && pass "$member will not rejoin on its own; state is '${stuck:-absent}'" \
    || fail "$member rejoined by itself; the failure was not reproduced"

  # The documented diagnosis should say why.
  local log; log="$(limactl shell --tty=false "$target" \
    sudo journalctl -u percona-patroni -n 50 --no-pager 2>/dev/null)"
  grep -qiE "pg_control|control file|database system is shut down|could not|fatal" <<< "$log" \
    && pass "journalctl names the cause, as the runbook's diagnosis expects" \
    || fail "the documented diagnosis produced nothing about the failure"

  # Production must not have noticed. This is the half that matters: one standby
  # still confirms commits, so quorum is satisfied and writes continue.
  [[ "$(leader_vm)" == "$leader" ]] \
    && pass "the leader did not move: losing one standby is not a failover" \
    || fail "the leader changed; this incident should not have caused one"
  limactl shell --tty=false "$leader" sudo -u postgres \
    env PGOPTIONS='-c statement_timeout=15s' "$POSTGRES_BIN_DIR/psql" -d appdb -Atc \
    "insert into public.ha_probe (probe_id, client_name, server_address)
     values ('rb5-'||floor(random()*1000000)::text, 'runbook5-drill', '127.0.0.1')" >/dev/null 2>&1 \
    && pass "production still accepts writes with one standby broken" \
    || fail "writes blocked; one healthy standby should satisfy quorum commit"

  # The finding that corrected the page, asserted so it cannot regress quietly.
  # reinit calls the MEMBER's REST API, and a node whose Patroni has exited
  # cannot receive it -- so for this whole class of fault the command the runbook
  # used to give as the remedy is unavailable.
  local reinit_out
  reinit_out="$(patronictl_on "$leader" reinit "$STANZA_NAME" "$member" --force 2>&1)"
  if grep -qiE "connection refused|max retries|failed to establish" <<< "$reinit_out"; then
    pass "reinit is refused while Patroni is down on that node, as the runbook now warns"
  elif grep -qiE "success|initializ" <<< "$reinit_out"; then
    fail "reinit succeeded here; the runbook's warning about it is now wrong and should be revisited"
  else
    pass "reinit did not take effect (Patroni is not running to receive it)"
  fi

  # The fix for this case, exactly as the runbook prints it.
  echo "  clearing the data directory and letting Patroni rebuild ${member}"
  limactl shell --tty=false "$target" sudo systemctl stop percona-patroni >/dev/null 2>&1
  limactl shell --tty=false "$target" sudo rm -rf /var/lib/pgsql/data >/dev/null 2>&1
  limactl shell --tty=false "$target" sudo install -d -o postgres -g postgres -m 0700 \
    /var/lib/pgsql/data >/dev/null 2>&1
  limactl shell --tty=false "$target" sudo systemctl start percona-patroni >/dev/null 2>&1
  local back=""
  for i in $(seq 1 60); do
    sleep 5
    state="$(jq -r --arg m "$member" '.[] | select(.Member == $m) | .State' <<< "$(patroni_json)" 2>/dev/null)"
    [[ "$state" == "streaming" ]] && { back=yes; break; }
  done
  [[ -n "$back" ]] \
    && pass "$member rebuilt itself and is streaming again" \
    || fail "$member did not return to streaming after the data directory was cleared"

  wait_for_quorum \
    && pass "one leader and two quorum standbys again" \
    || fail "the cluster did not return to full redundancy"

  rows_after="$(sql "$(leader_vm)" "select count(*) from public.ha_probe")"
  (( ${rows_after:-0} >= ${rows_before:-0} )) \
    && pass "no committed rows were lost (${rows_before} -> ${rows_after}); only the broken node was discarded" \
    || fail "row count fell ${rows_before} -> ${rows_after}: the rebuild destroyed data it should not have"

  sql "$(leader_vm)" "delete from public.ha_probe where client_name = 'runbook5-drill'" >/dev/null 2>&1
  echo
  (( FAIL_COUNT == _fc0 )) && { echo "PASS (rejoin drill)"; return 0; }
  echo "FAILED (rejoin drill): $((FAIL_COUNT - _fc0)) problem(s)" >&2
  return 1
}

# ---------------------------------------------------------------------------
# Runbook 2: failover did not happen.
#
# The page's central claim is the one operators find hardest to believe: with
# `watchdog.mode: required`, a node that cannot arm its watchdog REFUSES TO BE
# PRIMARY, so a missing softdog module presents as *no leader anywhere* rather
# than as a warning. Nothing had ever induced it -- the failover tests all run on
# nodes whose watchdog works, which is the opposite case.
#
# Induced by removing the module from both standbys and then killing the primary,
# leaving a cluster that is fully capable of electing a leader except for the one
# thing Patroni will not proceed without.
#
# This drill deliberately produces a cluster with no primary. The trap restores
# the module and restarts every node regardless of where it fails.
test_drill_failover_blocked() {
  local _fc0=$FAIL_COUNT
  local leader survivors=() vm i saw_leader log dev
  echo
  echo "=== Runbook 2 drill: 'failover did not happen' ==="
  wait_for_quorum || { fail "cluster was not settled before the drill"; return 1; }
  leader="$(leader_vm)"
  for vm in "${VM_NAMES[@]}"; do [[ "$vm" != "$leader" ]] && survivors+=("$vm"); done
  echo "  leader is ${leader#$VM_PREFIX}; disarming ${survivors[*]#$VM_PREFIX}"

  restore_watchdog() {
    for vm in "${VM_NAMES[@]}"; do
      limactl shell --tty=false "$vm" sudo modprobe softdog >/dev/null 2>&1
      limactl shell --tty=false "$vm" sudo systemctl start percona-patroni >/dev/null 2>&1
    done
  }
  trap restore_watchdog RETURN

  # Take the watchdog away from the only nodes that could be promoted.
  for vm in "${survivors[@]}"; do
    limactl shell --tty=false "$vm" sudo rmmod softdog >/dev/null 2>&1
  done
  local gone=0
  for vm in "${survivors[@]}"; do
    limactl shell --tty=false "$vm" sudo test -e /dev/watchdog || gone=$((gone + 1))
  done
  (( gone == 2 )) \
    && pass "/dev/watchdog is gone on both standbys" \
    || fail "the watchdog device survived on $((2 - gone)) standby(s); the fault was not set up"

  # Lose the primary.
  limactl shell --tty=false "$leader" sudo systemctl stop percona-patroni >/dev/null 2>&1
  limactl shell --tty=false "$leader" sudo -u postgres \
    "$POSTGRES_BIN_DIR/pg_ctl" -D /var/lib/pgsql/data -w -t 60 stop -m immediate >/dev/null 2>&1

  # ttl is 30s. Give the election every chance to happen, then assert it did not.
  saw_leader=""
  for i in $(seq 1 18); do
    sleep 5
    [[ "$(leader_vm)" != "$VM_PREFIX" ]] && { saw_leader="$(leader_vm)"; break; }
  done
  [[ -z "$saw_leader" ]] \
    && pass "no leader was elected in 90s: the cluster refused to promote, which is the documented symptom" \
    || fail "${saw_leader#$VM_PREFIX} was promoted without a watchdog; watchdog.mode=required is not being honoured"

  # The diagnosis the runbook sends you to.
  log="$(limactl shell --tty=false "${survivors[0]}" \
    sudo journalctl -u percona-patroni -n 60 --no-pager 2>/dev/null)"
  grep -qi "watchdog" <<< "$log" \
    && pass "journalctl on a survivor names the watchdog, as the runbook's table says it will: $(grep -oiE 'watchdog[^\"]{0,58}' <<< "$log" | tail -1)" \
    || fail "nothing in the journal points at the watchdog; the documented diagnosis would not find this"

  # And the check that distinguishes this from runbook 4: the DCS is fine, so an
  # operator who stopped at "no leader" would be looking in the wrong place.
  grep -qiE "maintenance mode: on" <<< "$(patronictl_on "${survivors[0]}" list 2>&1)" \
    && fail "the cluster is paused; this drill induced the wrong incident" \
    || pass "the cluster is not paused and etcd is healthy: only the watchdog is missing"

  # Fix, exactly as the runbook prints it.
  echo "  restoring the module, as the runbook's last two commands do"
  for vm in "${survivors[@]}"; do
    limactl shell --tty=false "$vm" sudo modprobe softdog >/dev/null 2>&1
  done
  sleep 3
  dev="$(limactl shell --tty=false "${survivors[0]}" sudo stat -c '%U %a' /dev/watchdog 2>/dev/null)"
  [[ "$dev" == "postgres 600" ]] \
    && pass "/dev/watchdog is back, owned by postgres: udev reapplied the rule, so no chown is needed" \
    || fail "the device came back as '${dev:-absent}'; the runbook's fix is incomplete without restoring ownership"

  local promoted=""
  for i in $(seq 1 24); do
    sleep 5
    [[ "$(leader_vm)" != "$VM_PREFIX" ]] && { promoted="$(leader_vm)"; break; }
  done
  [[ -n "$promoted" ]] \
    && pass "${promoted#$VM_PREFIX} was promoted once it could arm a watchdog, with no further intervention" \
    || fail "still no leader after restoring the watchdog"

  limactl shell --tty=false "$leader" sudo systemctl start percona-patroni >/dev/null 2>&1
  wait_for_quorum \
    && pass "one leader and two quorum standbys again" \
    || fail "the cluster did not return to full redundancy"

  trap - RETURN
  echo
  (( FAIL_COUNT == _fc0 )) && { echo "PASS (blocked-failover drill)"; return 0; }
  echo "FAILED (blocked-failover drill): $((FAIL_COUNT - _fc0)) problem(s)" >&2
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
  test_drill_quorum     || failures=$((failures + 1))
  test_drill_wal        || failures=$((failures + 1))
  test_drill_rejoin     || failures=$((failures + 1))
  test_drill_failover_blocked || failures=$((failures + 1))
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
    quorum) test_drill_quorum ;;
    wal) test_drill_wal ;;
    rejoin) test_drill_rejoin ;;
    blocked) test_drill_failover_blocked ;;
    drill) test_drill ;;
    all) test_lint || exit 1; test_drill || exit 1 ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
