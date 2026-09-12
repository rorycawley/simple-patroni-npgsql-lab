#!/usr/bin/env bash
set -uo pipefail

# Does the repository actually verify?
#
# `pgbackrest verify` EXITS 0 ON A CORRUPTED REPOSITORY. Measured: with one
# archived WAL segment overwritten in place, it found the damage, said so, and
# still returned success --
#
#   INFO: invalid result 18-1/...0000006A-....gz: unexpected eof in compressed data
#   INFO: stanza: lab5
#         status: error
#           archiveId: 18-1, total WAL checked: 6, total valid WAL: 5
#   INFO: verify command end: completed successfully (15256ms)
#   exit code: 0
#
# So every check written as `pgbackrest verify && pass || fail` is vacuous: it
# cannot fail on the thing it exists to detect. There were thirteen of them
# across Labs 3 and 4. This is the same shape as `pgbackrest info`, which exits 0
# on a repository it cannot even read.
#
# The verdict is in the OUTPUT, not the status. A clean verify prints nothing but
# begin and end -- no counts, no "status: ok", at any log level -- so the
# available signal is the absence of error markers, which is exactly the kind of
# assertion this lab distrusts.
#
# What makes it trustworthy here is that something proves it FIRES: AC-8's third
# control corrupts a real object and requires this script to reject it. An
# absence-check validated by a known-positive case is worth having; one that has
# never been shown to fail is not.
#
# Usage: repo-verify.sh <vm> [stanza]
# Exit 0 only if the repository is genuinely intact.

readonly VM="${1:?usage: repo-verify.sh <vm> [stanza]}"
readonly STANZA="${2:-lab5}"

out="$(limactl shell --tty=false "$VM" sudo -u postgres \
  pgbackrest --stanza="$STANZA" verify 2>&1)"

# Kept for the day pgBackRest starts reporting failure properly: if it ever does
# exit non-zero, that is still a failure and must not be second-guessed here.
rc=$?
if (( rc != 0 )); then
  echo "verify exited $rc" >&2
  grep -iE "error|invalid" <<< "$out" | tail -3 >&2
  exit 1
fi

# `status: error`, `invalid result` and `invalid file` are what it prints when it
# finds something. WARN lines are not included: a backup running concurrently
# produces "found in the repository but not in backup.info", which is transient
# and not damage.
if grep -qiE "status: *error|invalid result|invalid file|invalid backup" <<< "$out"; then
  echo "the repository does NOT verify, though pgbackrest exited 0:" >&2
  grep -iE "status: *error|invalid result|invalid file|invalid backup|total valid" <<< "$out" \
    | sed 's/^.*INFO: *//' | tail -4 >&2
  exit 1
fi

# A run that did not reach the end tells us nothing either way.
grep -q "verify command end: completed successfully" <<< "$out" || {
  echo "verify did not complete; no verdict available" >&2
  tail -3 <<< "$out" >&2
  exit 1
}
exit 0
