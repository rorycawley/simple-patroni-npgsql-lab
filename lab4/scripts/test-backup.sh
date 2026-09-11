#!/usr/bin/env bash
set -uo pipefail

# AC-1: a backup history exists, and only the leader creates it.
#
# This is the criterion Lab 4 exists for. `pgbackrest check` passing is not
# evidence that a backup exists -- it validates configuration and passes happily
# against a repository containing none, which is exactly the state Labs 1 and 2
# are in. So this asserts the ARTEFACT.
#
# It also never trusts an exit status. Measured while planning this lab:
# `pgbackrest info` printed "status: error (other)" with a CryptoError against a
# repository it could not decrypt, and still exited 0. Everything here is read
# out of parsed JSON.

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly VM_NAMES=(lab4-pg1 lab4-pg2 lab4-pg3)
readonly VM_PREFIX="lab4-"
readonly STANZA=lab4
readonly PATRONI_CONFIG=/etc/patroni/patroni.yml
readonly GATE=/usr/local/lib/lab4/lab4-leader-gate
readonly PATRONI_REST_PORT=8008

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }
[[ -f "$LAB_DIR/.env" ]] || { echo "Run make create_vms first" >&2; exit 1; }

failures=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; failures=$((failures + 1)); }

on() { local vm="$1"; shift; limactl shell --tty=false "$vm" "$@" 2>/dev/null; }

leader_vm() {
  local out
  for vm in "${VM_NAMES[@]}"; do
    if out="$(on "$vm" sudo -u postgres patronictl -c "$PATRONI_CONFIG" list --format=json)"; then
      printf '%s%s\n' "$VM_PREFIX" \
        "$(jq -r '.[] | select(.Role | test("Leader")) | .Member' <<< "$out")"
      return 0
    fi
  done
  return 1
}

# pgbackrest info as JSON, from any node: the repository is shared, so every
# node sees the same history.
repo_json() { on "${VM_NAMES[0]}" sudo -u postgres pgbackrest --stanza="$STANZA" --output=json info; }

backup_count() { jq -r '[.[0].backup[]] | length' <<< "$1"; }
backup_types() { jq -r '[.[0].backup[].type] | join(",")' <<< "$1"; }
# Identity, not population. A full backup can trigger retention, which expires
# an older full and every incremental depending on it in the same breath -- so
# the total can go DOWN while a backup was correctly taken. Counting caught this
# lab out; comparing the set of labels is what actually answers "was exactly one
# new backup produced".
backup_labels() { jq -r '.[0].backup[].label' <<< "$1" | sort; }

echo
echo "=== The leader gate answers correctly, and only for the leader ==="
leader="$(leader_vm)" || { echo "cannot find the leader" >&2; exit 1; }
echo "  leader is ${leader#$VM_PREFIX}"

for vm in "${VM_NAMES[@]}"; do
  on "$vm" sudo "$GATE"; rc=$?
  if [[ "$vm" == "$leader" ]]; then
    (( rc == 0 )) && pass "${vm#$VM_PREFIX}: gate says leader (0)" \
                  || fail "${vm#$VM_PREFIX}: gate returned $rc on the leader, expected 0"
  else
    (( rc == 1 )) && pass "${vm#$VM_PREFIX}: gate says not leader (1)" \
                  || fail "${vm#$VM_PREFIX}: gate returned $rc on a standby, expected 1"
  fi
done

# R1's negative control, and the reason this lab has one at all. "Cannot
# determine" must NOT be reported as "not the leader": if it is, one broken
# endpoint makes all three nodes decline and the repository silently stops
# filling while every timer reports success.
#
# Two shapes, because they fail differently and only one of them is obvious:
#
#   wrong path    Patroni answers 503 -- the SAME code it uses for "not the
#                 leader". This is the one that fooled the first version of the
#                 gate, which read /leader and trusted the status code.
#   nothing there curl never completes and reports 000.
#
echo
echo "=== A gate that cannot get an answer fails loudly, not quietly ==="
broken_gate() {  # $1=sed expression, $2=description
  local rc
  on "$leader" sudo sed "$1" "$GATE" > /tmp/lab4-gate-broken.sh
  on "$leader" sudo tee "$GATE-broken" >/dev/null < /tmp/lab4-gate-broken.sh
  on "$leader" sudo chmod 0755 "$GATE-broken"
  on "$leader" sudo "$GATE-broken"; rc=$?
  (( rc == 2 )) \
    && pass "$2 returns 2 (cannot tell), not 1 (not leader)" \
    || fail "$2 returned $rc; 'cannot tell' is being reported as 'no'"
  on "$leader" sudo rm -f "$GATE-broken"
  rm -f /tmp/lab4-gate-broken.sh
}
broken_gate 's|/patroni"|/nonexistent-endpoint"|' "a renamed endpoint (Patroni answers 503)"
broken_gate "s|:$PATRONI_REST_PORT/|:$((PATRONI_REST_PORT + 1))/|" "an endpoint with nothing listening"

echo
echo "=== A backup cycle produces exactly one backup, from the leader ==="
before="$(repo_json)"
labels_before="$(backup_labels "$before")"
echo "  backups in the repository before this cycle: $(backup_count "$before")"

# Run the job on ALL THREE nodes, which is what the timers do. Two must decline.
for vm in "${VM_NAMES[@]}"; do
  out="$(on "$vm" sudo systemctl start "lab4-backup@full.service" 2>&1)"; rc=$?
  (( rc == 0 )) || fail "${vm#$VM_PREFIX}: the backup unit failed: $out"
done

after="$(repo_json)"
labels_after="$(backup_labels "$after")"
added="$(comm -13 <(printf '%s\n' "$labels_before") <(printf '%s\n' "$labels_after") | grep -c .)"
(( added == 1 )) \
  && pass "three nodes ran the job and exactly one new backup appeared" \
  || fail "three nodes running the job added $added backups, expected 1"

# Retention runs as part of a full backup, so the total can fall even though a
# backup was taken. Reported rather than asserted here -- the cascade is AC-3's
# to prove, and this is where it was first observed.
removed="$(comm -23 <(printf '%s\n' "$labels_before") <(printf '%s\n' "$labels_after") | grep -c .)"
(( removed > 0 )) && echo "  (retention expired $removed older backup(s) in the same cycle)"

# And it was the leader that did it, not merely someone.
non_leader_ran=0
for vm in "${VM_NAMES[@]}"; do
  [[ "$vm" == "$leader" ]] && continue
  if on "$vm" journalctl -u "lab4-backup@full.service" -n 20 --no-pager \
       | grep -q "Leader confirmed"; then
    non_leader_ran=1
    fail "${vm#$VM_PREFIX}: a non-leader believed it was the leader"
  fi
done
(( non_leader_ran == 0 )) && pass "both standbys declined without touching the repository"

echo
echo "=== The history is a chain, not a single backup ==="
on "$leader" sudo systemctl start "lab4-backup@incr.service" >/dev/null 2>&1
on "$leader" sudo systemctl start "lab4-backup@incr.service" >/dev/null 2>&1
final="$(repo_json)"
types="$(backup_types "$final")"
echo "  backup types in the repository: $types"
[[ "$types" == *full* && "$types" == *incr* ]] \
  && pass "the repository holds a full and at least one incremental" \
  || fail "expected a full and incrementals, got '$types'"

# The status pgbackrest itself reports. Parsed, never inferred from exit code.
status="$(jq -r '.[0].status.message' <<< "$final")"
[[ "$status" == "ok" ]] \
  && pass "pgbackrest reports the stanza status as ok" \
  || fail "pgbackrest reports stanza status '$status'"

echo
echo "=== The timers are enabled on every node, not just configured ==="
for vm in "${VM_NAMES[@]}"; do
  for timer in lab4-backup-full.timer lab4-backup-incr.timer; do
    state="$(on "$vm" systemctl is-enabled "$timer")"
    [[ "$state" == "enabled" ]] \
      && pass "${vm#$VM_PREFIX}: $timer enabled" \
      || fail "${vm#$VM_PREFIX}: $timer is '$state'"
  done
done

echo
(( failures == 0 )) && { echo "PASS"; exit 0; }
echo "FAILED: $failures problem(s)" >&2
exit 1
