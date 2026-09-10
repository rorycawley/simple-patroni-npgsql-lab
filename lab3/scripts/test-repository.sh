#!/usr/bin/env bash
set -uo pipefail

# AC-2: the repository outlives any node.
#
# Labs 1 and 2 kept a pgBackRest repository on each database host, which is
# exactly the arrangement that cannot survive the failure it exists to protect
# against: lose the node and you lose both the data and the means to get it back.
#
# The live half of this criterion -- that backups written by one node are still
# readable after that node stops being the leader -- is asserted in
# test-archive.sh, which already has a promotion to hand. What is asserted here
# is structural, and cheap enough to run on every build: the repository is
# configured to be remote, everything in it is actually in the bucket, and no
# node is quietly still writing backups to its own disk.

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly VM_NAMES=(lab3-pg1 lab3-pg2 lab3-pg3)
readonly VM_PREFIX="lab3-"
readonly STANZA=lab3
readonly BIN=/usr/local/lib/lab3
readonly LOCAL_REPO=/var/lib/pgbackrest

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

failures=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; failures=$((failures + 1)); }
on() { local vm="$1"; shift; limactl shell --tty=false "$vm" "$@" 2>/dev/null; }

echo
echo "=== Every node is configured to back up off-host ==="
for vm in "${VM_NAMES[@]}"; do
  kind="$(on "$vm" sudo sed -n 's/^repo1-type=//p' /etc/pgbackrest/pgbackrest.conf)"
  [[ "$kind" == "s3" ]] \
    && pass "${vm#$VM_PREFIX}: repo1-type=s3" \
    || fail "${vm#$VM_PREFIX}: repo1-type is '${kind:-unset}', not s3"
done

# archive_command follows the primary, so every node needs to be able to reach
# the repository -- not just whichever one happens to be leader today.
for vm in "${VM_NAMES[@]}"; do
  on "$vm" sudo -u postgres pgbackrest --stanza="$STANZA" repo-ls >/dev/null 2>&1 \
    && pass "${vm#$VM_PREFIX}: can reach the repository" \
    || fail "${vm#$VM_PREFIX}: cannot reach the repository"
done

echo
echo "=== Everything the repository lists is in the bucket ==="
node="${VM_NAMES[0]}"
info="$(on "$node" sudo -u postgres pgbackrest --stanza="$STANZA" --output=json info)"
labels="$(jq -r '.[0].backup[].label' <<< "$info")"

# Probed per label rather than by listing the whole prefix and grepping. One
# full backup of this cluster is over a thousand objects, so a single listing is
# truncated -- and a truncated listing does not error, it just quietly omits the
# newest backups and makes them look missing.
missing=0
while IFS= read -r label; do
  [[ -z "$label" ]] && continue
  found="$(on "$node" sudo "$BIN/lab3-s3" list "pgbackrest/backup/$STANZA/$label/" | grep -c . || true)"
  (( found > 0 )) || { fail "$label is listed by info but has no objects in the bucket"; missing=1; }
done <<< "$labels"
(( missing == 0 )) && pass "all $(grep -c . <<< "$labels") backup(s) have objects in the bucket"

echo
echo "=== No node is still writing backups to its own disk ==="
# The local directory survives from before the repository moved, so the question
# is not whether it is empty -- it is whether anything NEW lands there. A node
# quietly writing locally would look healthy right up until it was lost.
for vm in "${VM_NAMES[@]}"; do
  recent="$(on "$vm" sudo find "$LOCAL_REPO" -type f -newer /etc/pgbackrest/pgbackrest.conf 2>/dev/null | wc -l | tr -d ' ')"
  [[ "${recent:-0}" == "0" ]] \
    && pass "${vm#$VM_PREFIX}: nothing written locally since the repository moved" \
    || fail "${vm#$VM_PREFIX}: $recent file(s) written to $LOCAL_REPO after the move"
done

# And no backup set is hiding there, whatever its age.
for vm in "${VM_NAMES[@]}"; do
  local_backups="$(on "$vm" sudo ls "$LOCAL_REPO/backup/$STANZA" 2>/dev/null | grep -c 'F$' || true)"
  [[ "${local_backups:-0}" == "0" ]] \
    && pass "${vm#$VM_PREFIX}: holds no backup set of its own" \
    || fail "${vm#$VM_PREFIX}: $local_backups backup set(s) on local disk"
done

echo
(( failures == 0 )) && { echo "PASS"; exit 0; }
echo "FAILED: $failures problem(s)" >&2
exit 1
