#!/usr/bin/env bash
set -uo pipefail

# AC-8: recovery fails closed.
#
# Every other check in this lab asks whether recovery works. This one asks what
# happens when it cannot, which is the more dangerous question. R1, the defining
# risk of Lab 4, is a restore that produces a cluster which starts, accepts
# connections and looks entirely healthy while holding the wrong data. Nobody
# reads the logs of a recovery that appeared to succeed.
#
# So each control below is deliberately broken in a way an operator could
# plausibly cause, and the requirement is the same every time: fail LOUDLY, and
# leave nothing behind that could be mistaken for a recovered database.
#
#   1. the wrong cipher passphrase -- the repository is unreadable, and must say
#      so rather than restoring some subset of what it could decrypt
#   2. a target earlier than the oldest base backup -- there is no floor to
#      replay from, and "the oldest one I have" is the wrong answer
#   3. a tampered repository object -- the bytes changed under us, and a checksum
#      is the only thing that would ever notice
#
# Control 3 writes to the real repository, which is the only place the property
# can be tested. The original bytes are read back first and restored by a trap,
# and the run asserts the repository verifies again afterwards -- an unrepaired
# repository would be a far worse outcome than a failed test.

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly VM_NAMES=(lab4-pg1 lab4-pg2 lab4-pg3)
readonly VM_PREFIX="lab4-"
readonly STANZA=lab4
readonly PATRONI_CONFIG=/etc/patroni/patroni.yml
readonly PGBIN=/usr/pgsql-18/bin
readonly BIN=/usr/local/lib/lab4
readonly RESTORE_DIR=/var/lib/pgsql-restore
# Object keys are prefixed by repo1-path with its leading slash stripped.
# Omitting it does not error: the GET 404s, `cat` writes an empty file, and a
# later `put` creates a STRAY object beside the repository instead of
# overwriting anything in it. Read from the node rather than assumed.
repo_prefix=""

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }
[[ -f "$LAB_DIR/.env" ]] || { echo "Run make create_vms first" >&2; exit 1; }

failures=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; failures=$((failures + 1)); }
on() { local vm="$1"; shift; limactl shell --tty=false "$vm" "$@" 2>/dev/null; }
# on() discards stderr, which is exactly where pgBackRest puts the reason it
# refused. Asserting on a message requires a variant that keeps it -- the first
# version of this check used on() and concluded the restore "failed without
# naming decryption as the cause" from an empty string.
on_err() { local vm="$1"; shift; limactl shell --tty=false "$vm" "$@" 2>&1; }

patroni_json() {
  local out vm
  for vm in "${VM_NAMES[@]}"; do
    if out="$(on "$vm" sudo -u postgres timeout 20 patronictl -c "$PATRONI_CONFIG" list --format=json 2>/dev/null)"; then
      [[ -n "$out" ]] && { printf '%s\n' "$out"; return 0; }
    fi
  done
  return 1
}
leader_vm() {
  printf '%s%s\n' "$VM_PREFIX" \
    "$(jq -r '.[] | select(.Role | test("Leader")) | .Member' <<< "$(patroni_json)" 2>/dev/null)"
}
leader="$(leader_vm)"
[[ -n "$leader" && "$leader" != "$VM_PREFIX" ]] || { echo "no healthy cluster" >&2; exit 1; }

repo_prefix="$(on "$leader" sudo bash -c \
  "grep -o 'repo1-path=.*' /etc/pgbackrest/pgbackrest.conf | cut -d= -f2" | sed 's|^/||' | tr -d ' \r')"
[[ -n "$repo_prefix" ]] || { echo "cannot determine repo1-path; refusing to guess object keys" >&2; exit 1; }

tampered_key=""
restore_tampered() {
  if [[ -n "$tampered_key" ]] \
     && on "$leader" sudo bash -c "test -s /tmp/fc-original.bin" >/dev/null 2>&1; then
    if on "$leader" sudo bash -c "$BIN/lab4-s3 put /tmp/fc-original.bin '$tampered_key'" >/dev/null 2>&1; then
      echo "  (repository object restored: $tampered_key)"
    else
      echo "  !! COULD NOT RESTORE $tampered_key -- the repository is still damaged" >&2
      echo "  !! the original bytes are on ${leader#$VM_PREFIX} at /tmp/fc-original.bin" >&2
    fi
  fi
  on "$leader" sudo -u postgres "$PGBIN/pg_ctl" -D "$RESTORE_DIR" stop -m immediate >/dev/null 2>&1
  on "$leader" sudo bash -c "rm -rf ${RESTORE_DIR:?}/* ${RESTORE_DIR}/.??*" >/dev/null 2>&1
}
trap restore_tampered EXIT
on "$leader" sudo bash -c "rm -rf ${RESTORE_DIR:?}/* ${RESTORE_DIR}/.??*" >/dev/null 2>&1

echo
echo "=== A known-good repository to break ==="
echo "  leader is ${leader#$VM_PREFIX}"
on "$leader" sudo -u postgres pgbackrest --stanza="$STANZA" --type=full backup >/dev/null 2>&1
"$SCRIPT_DIR/repo-verify.sh" "$leader" "$STANZA" >/dev/null 2>&1 \
  && pass "a full backup exists and the repository verifies before we break anything" \
  || { fail "the repository does not verify to begin with; nothing below would mean anything"; exit 1; }

# ---------------------------------------------------------------------------
echo
echo "=== Control 1: the wrong cipher passphrase ==="
# The failure that must not happen quietly: restoring whatever could be decrypted
# and leaving a partial data directory that starts.
# Supplied through the environment, not the command line. pgBackRest REFUSES
# --repo1-cipher-pass as an argument -- "[031]: option 'repo1-cipher-pass' is not
# allowed on the command-line" -- and the first version of this control accepted
# that as proof, because the word "cipher" appears in the refusal. It exited
# non-zero for a reason that had nothing to do with decryption, and the check was
# green. The passphrase has to actually reach pgBackRest for this to test
# anything.
# log-level-console=info, not error: the evidence that DECRYPTION failed is a
# WARN, and at error level the only thing printed is a message about there being
# no backups. Asserting at the wrong log level would have hidden the real
# behaviour behind the misleading one.
out1="$(on_err "$leader" sudo -u postgres \
  env PGBACKREST_REPO1_CIPHER_PASS=definitely-not-the-passphrase \
  pgbackrest --stanza="$STANZA" --pg1-path="$RESTORE_DIR" \
  --log-level-console=info restore)"
rc1=$?
(( rc1 != 0 )) \
  && pass "the restore refused, exit $rc1" \
  || fail "the restore SUCCEEDED with a wrong passphrase"
if grep -qiE "not allowed on the command-line" <<< "$out1"; then
  fail "it rejected how the passphrase was supplied, so decryption was never attempted"
elif grep -qiE "unable to load info file|FormatError" <<< "$out1"; then
  pass "the evidence is there: it could not read backup.info, because it could not decrypt it"
else
  fail "nothing in the output points at decryption: ${out1:0:140}"
fi

# The trap, recorded as an assertion so it cannot quietly change. A wrong
# passphrase does not present as a key problem: it presents as an EMPTY
# repository, and pgBackRest suggests the one action that must not be taken.
if grep -qiE "no backup set found" <<< "$out1"; then
  echo "  note: the headline error is 'no backup set found to restore' -- a wrong key"
  echo "        looks exactly like a repository with nothing in it"
fi
grep -qiE "has a stanza-create been performed" <<< "$out1" \
  && pass "and it suggests 'has a stanza-create been performed?' -- following that hint on a repository whose passphrase is merely wrong is how backups get destroyed" \
  || echo "  note: the misleading stanza-create hint is no longer emitted"

# Nothing startable must be left behind.
left1="$(on "$leader" sudo bash -c "ls -A $RESTORE_DIR 2>/dev/null | wc -l" | tr -d ' ')"
(( ${left1:-0} == 0 )) \
  && pass "it left the target directory empty: nothing to mistake for a database" \
  || fail "$left1 entries were written before it gave up; a partial restore can look startable"

# ---------------------------------------------------------------------------
echo
echo "=== Control 2: a recovery target older than every backup ==="
# "As close as I can get" is the wrong answer. Silently restoring the oldest
# backup would hand back a cluster that is months wrong and looks perfect.
oldest="$(on "$leader" sudo -u postgres pgbackrest --stanza="$STANZA" --output=json info \
  | jq -r '[.[0].backup[].timestamp.start] | min | todate')"
echo "  oldest backup starts $oldest; asking for 2021-01-01"
out2="$(on_err "$leader" sudo -u postgres pgbackrest --stanza="$STANZA" \
  --pg1-path="$RESTORE_DIR" --type=time --target='2021-01-01 00:00:00+00' \
  --log-level-console=error restore 2>&1)"
rc2=$?
(( rc2 != 0 )) \
  && pass "the restore refused, exit $rc2" \
  || fail "it restored SOMETHING for a target before the repository existed"
grep -qiE "unable to find backup set|no backup set" <<< "$out2" \
  && pass "and it said why: no backup set covers that time" \
  || fail "it failed for an unexplained reason: ${out2:0:120}"
left2="$(on "$leader" sudo bash -c "ls -A $RESTORE_DIR 2>/dev/null | wc -l" | tr -d ' ')"
(( ${left2:-0} == 0 )) \
  && pass "and left nothing behind" \
  || fail "$left2 entries were written for an impossible target"

# ---------------------------------------------------------------------------
echo
echo "=== Control 3: a repository object altered behind pgBackRest's back ==="
# A WAL segment rather than backup.info: if the trap failed to put the original
# back, a damaged manifest would be far harder to live with than one archived
# segment, and `verify` checksums both.
tampered_key="$(on "$leader" sudo -u postgres pgbackrest --stanza="$STANZA" \
  repo-ls "archive/$STANZA" --recurse --output=json 2>/dev/null \
  | jq -r 'to_entries[] | select(.value.type == "file") | .key' \
  | grep -E '[0-9A-F]{24}' | head -1)"
tampered_key="$repo_prefix/archive/$STANZA/$tampered_key"
[[ -n "$tampered_key" ]] || { fail "could not find a WAL object to tamper with"; exit 1; }
echo "  target: $tampered_key"

on "$leader" sudo bash -c "$BIN/lab4-s3 cat '$tampered_key' > /tmp/fc-original.bin" >/dev/null 2>&1
size="$(on "$leader" sudo bash -c "stat -c %s /tmp/fc-original.bin 2>/dev/null" | tr -d ' ')"
(( ${size:-0} > 0 )) \
  && pass "original bytes saved ($size bytes), so this is reversible" \
  || { fail "could not read the object; refusing to tamper with something unrecoverable"; exit 1; }

# Flip bytes in the middle. Keeping the length identical is deliberate: a size
# change is trivially detectable, and the property under test is whether CONTENT
# is checksummed.
on "$leader" sudo bash -c "
  cp /tmp/fc-original.bin /tmp/fc-tampered.bin
  # Offset 100, not size/2. Measured in Lab 5: corrupting the middle of a
  # compressed WAL segment was NOT detected by verify on two attempts, while
  # corrupting near the start was detected immediately. A positive control that
  # fires only sometimes is worse than none -- it makes a working detector look
  # broken, and teaches you to rerun until it agrees with you.
  printf 'CORRUPTCORRUPT' | dd of=/tmp/fc-tampered.bin bs=1 seek=100 conv=notrunc status=none
  $BIN/lab4-s3 put /tmp/fc-tampered.bin '$tampered_key'" >/dev/null 2>&1 \
  && pass "8 bytes rewritten in place, same length as before" \
  || { fail "could not upload the tampered object"; exit 1; }

# This is the positive control that earns repo-verify.sh its keep. A check for
# the ABSENCE of error markers is only trustworthy if something proves it fires,
# and this is the only place in either lab where the repository is knowingly
# broken.
if "$SCRIPT_DIR/repo-verify.sh" "$leader" "$STANZA" >/dev/null 2>&1; then
  fail "repo-verify.sh PASSED over a corrupted object; every repository check in this lab is blind"
else
  pass "repo-verify.sh rejected the damaged repository, which is what makes it a check"
fi
out3="$(on_err "$leader" sudo -u postgres pgbackrest --stanza="$STANZA" verify)"
grep -qiE "invalid result|status: *error" <<< "$out3" \
  && pass "pgBackRest named the damage: $(grep -oiE 'total WAL checked: [0-9]+, total valid WAL: [0-9]+' <<< "$out3" | head -1)" \
  || fail "pgBackRest reported nothing wrong with a corrupted object"

# The two commands that do NOT fail closed, recorded because the whole ladder
# rests on knowing which of these is a check and which is a listing.
on "$leader" sudo -u postgres pgbackrest --stanza="$STANZA" verify >/dev/null 2>&1 \
  && echo "  note: 'verify' itself still EXITS 0 on this damaged repository -- the verdict is in its output, not its status" \
  || echo "  note: 'verify' exited non-zero (pgBackRest behaviour has changed; repo-verify.sh can be simplified)"
on "$leader" sudo -u postgres pgbackrest --stanza="$STANZA" info >/dev/null 2>&1 \
  && echo "  note: 'info' also exits 0 -- it lists what is there, it does not check it" \
  || echo "  note: 'info' also failed"

# ---------------------------------------------------------------------------
echo
echo "=== And the repository is whole again ==="
on "$leader" sudo bash -c "$BIN/lab4-s3 put /tmp/fc-original.bin '$tampered_key'" >/dev/null 2>&1
tampered_key=""   # restored; the trap has nothing left to do
"$SCRIPT_DIR/repo-verify.sh" "$leader" "$STANZA" >/dev/null 2>&1 \
  && pass "the original bytes are back and the repository verifies" \
  || fail "the repository still does not verify; it needs manual repair"
on "$leader" sudo bash -c "rm -f /tmp/fc-original.bin /tmp/fc-tampered.bin" >/dev/null 2>&1

echo
(( failures == 0 )) && { echo "PASS"; exit 0; }
echo "FAILED: $failures problem(s)" >&2
exit 1
