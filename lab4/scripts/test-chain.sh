#!/usr/bin/env bash
set -uo pipefail

# AC-3: the chain is real, and retention respects it.
#
# An incremental is worthless without every backup back to its full, so
# retention that counts fulls is implicitly retention over everything depending
# on them. Two ways that goes wrong, and only one of them is loud:
#
#   too much expires   a full goes and takes dependents with it. Correct, and
#                      alarming if unexpected -- so it is asserted, not assumed.
#   too little expires a full goes and its dependents are left behind. Now
#                      `pgbackrest info` lists backups that cannot be restored,
#                      which is worse than deleting them, because it will be
#                      believed.
#
# pgBackRest makes the dependency visible in the label itself: an incremental is
# named <full-label>_<timestamp>I. So "did the cascade happen" is exactly "is
# any label still prefixed with the expired full's label", which needs no
# guessing about internal structure.
#
# The timers are stopped for the duration. They fire every couple of minutes in
# this lab, and a backup arriving in the middle of a retention assertion makes
# it flaky for reasons that have nothing to do with the property under test.

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly VM_NAMES=(lab4-pg1 lab4-pg2 lab4-pg3)
readonly VM_PREFIX="lab4-"
readonly STANZA=lab4
readonly PATRONI_CONFIG=/etc/patroni/patroni.yml
readonly TIMERS=(lab4-backup-full.timer lab4-backup-incr.timer)

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }
[[ -f "$LAB_DIR/.env" ]] || { echo "Run make create_vms first" >&2; exit 1; }

failures=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; failures=$((failures + 1)); }

on() { local vm="$1"; shift; limactl shell --tty=false "$vm" "$@" 2>/dev/null; }

restore_timers() {
  local vm timer
  for vm in "${VM_NAMES[@]}"; do
    for timer in "${TIMERS[@]}"; do
      on "$vm" sudo systemctl start "$timer" >/dev/null 2>&1
    done
  done
}
trap restore_timers EXIT

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

leader="$(leader_vm)" || { echo "cannot find the leader" >&2; exit 1; }
repo_json() { on "$leader" sudo -u postgres pgbackrest --stanza="$STANZA" --output=json info; }
labels()    { jq -r '.[0].backup[].label' <<< "$1"; }
fulls()     { jq -r '.[0].backup[] | select(.type == "full") | .label' <<< "$1"; }

take() {  # type -> prints the label of the backup it created
  local before after
  before="$(labels "$(repo_json)")"
  on "$leader" sudo -u postgres pgbackrest --stanza="$STANZA" --type="$1" backup >/dev/null 2>&1
  after="$(labels "$(repo_json)")"
  comm -13 <(printf '%s\n' "$before" | sort) <(printf '%s\n' "$after" | sort) | head -1
}

echo
echo "=== Quiescing the backup timers so retention can be asserted ==="
for vm in "${VM_NAMES[@]}"; do
  for timer in "${TIMERS[@]}"; do on "$vm" sudo systemctl stop "$timer" >/dev/null 2>&1; done
done
echo "  stopped on all three nodes; they are restarted when this exits"
echo "  leader is ${leader#$VM_PREFIX}"

echo
echo "=== The repository verifies before anything is changed ==="
if on "$leader" sudo -u postgres pgbackrest --stanza="$STANZA" verify >/dev/null 2>&1; then
  pass "pgbackrest verify passes across the whole repository"
else
  fail "pgbackrest verify failed on the existing repository"
fi

echo
echo "=== Building a chain whose dependencies are known ==="
full_a="$(take full)"
[[ -n "$full_a" ]] && pass "took a full: $full_a" || { fail "no full backup was created"; exit 1; }
incr_1="$(take incr)"
incr_2="$(take incr)"
echo "  incrementals: $incr_1, $incr_2"

depends=0
for label in "$incr_1" "$incr_2"; do
  [[ "$label" == "$full_a"_* ]] || depends=1
done
(( depends == 0 )) \
  && pass "both incrementals are named for the full they depend on" \
  || fail "an incremental is not linked to $full_a; the chain is not what it appears"

echo
echo "=== Forcing retention to expire that full ==="
echo "  repo1-retention-full is 2, so two more fulls must push it out"
full_b="$(take full)"
full_c="$(take full)"
echo "  took $full_b and $full_c"

final="$(repo_json)"
remaining="$(labels "$final")"

grep -qx "$full_a" <<< "$remaining" \
  && fail "$full_a survived; retention did not expire it" \
  || pass "the oldest full ($full_a) was expired"

orphans="$(grep -c "^${full_a}_" <<< "$remaining" || true)"
(( orphans == 0 )) \
  && pass "its incrementals went with it: the cascade is real" \
  || fail "$orphans backup(s) still depend on the expired $full_a and cannot be restored"

for keep in "$full_b" "$full_c"; do
  grep -qx "$keep" <<< "$remaining" \
    && pass "$keep is retained, as repo1-retention-full=2 requires" \
    || fail "$keep was expired but should have been kept"
done

echo
echo "=== Nothing is referenced that is no longer there ==="
# The direction that matters. A backup listed by `info` whose files are gone is
# a restore that will fail at the worst possible moment.
missing=0
while IFS= read -r label; do
  [[ -z "$label" ]] && continue
  if ! on "$leader" sudo -u postgres pgbackrest --stanza="$STANZA" \
         repo-ls "backup/$STANZA/$label" >/dev/null 2>&1; then
    fail "info lists $label, but it is not in the repository"
    missing=1
  fi
done <<< "$remaining"
(( missing == 0 )) && pass "every backup info lists is present in the repository"

echo
echo "=== And it still verifies after expiry ==="
if on "$leader" sudo -u postgres pgbackrest --stanza="$STANZA" verify >/dev/null 2>&1; then
  pass "pgbackrest verify passes after retention ran"
else
  fail "pgbackrest verify failed after expiry; the repository is inconsistent"
fi

status="$(jq -r '.[0].status.message' <<< "$final")"
[[ "$status" == "ok" ]] \
  && pass "stanza status is ok" \
  || fail "stanza status is '$status'"

echo
(( failures == 0 )) && { echo "PASS"; exit 0; }
echo "FAILED: $failures problem(s)" >&2
exit 1
