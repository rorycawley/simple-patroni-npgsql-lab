#!/usr/bin/env bash
set -uo pipefail

# AC-5: EVERY object is encrypted at rest, and every transfer is encrypted.
#
# The obvious version of this criterion checks the pgBackRest objects and stops
# there -- which would leave the dumps sitting in plaintext beside them and still
# pass, having tested the easier half of the data. repo1-cipher-pass protects
# only what pgBackRest writes, and the dumps are written outside repo1-path on
# purpose so its retention can never reap them. Their encryption is therefore
# nobody's job but the dump script's, and nothing else would notice if it stopped.
#
# Every assertion here reads bytes straight out of the bucket -- what an
# object-store administrator would see -- rather than checking that a setting is
# present in a configuration file.

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly VM_NAMES=(lab6-pg1 lab6-pg2 lab6-pg3)
readonly STANZA=lab6
readonly BIN=/usr/local/lib/lab6
readonly RECOVERY_INPUTS="$LAB_DIR/.recovery-inputs/repo.yml"
readonly PASSFILE=/etc/lab6/dump.pass

failures=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; failures=$((failures + 1)); }
on() { local vm="$1"; shift; limactl shell --tty=false "$vm" "$@" 2>/dev/null; }

node="${VM_NAMES[0]}"
for vm in "${VM_NAMES[@]}"; do
  on "$vm" sudo -u postgres pgbackrest --stanza="$STANZA" info >/dev/null 2>&1 && { node="$vm"; break; }
done

echo
echo "=== The pgBackRest objects are encrypted at rest ==="
head_hex="$(on "$node" sudo bash -c \
  "$BIN/lab6-s3 cat pgbackrest/backup/$STANZA/backup.info 2>/dev/null | head -c 8 | od -An -v -tx1 | tr -d ' \n'")"
if [[ "$head_hex" == 53616c7465645f5f ]]; then
  pass "backup.info begins 'Salted__' in the bucket"
elif [[ -z "$head_hex" ]]; then
  fail "could not read backup.info from the bucket"
else
  # A plaintext pgBackRest info file starts with its own format banner.
  fail "backup.info is NOT encrypted in the bucket (first bytes: $head_hex)"
fi

# The negative control. Without it, "we set a cipher option" is a claim about a
# config file rather than about the bytes.
if on "$node" sudo -u postgres pgbackrest --stanza="$STANZA" --repo1-cipher-type=none info 2>&1 \
     | grep -qiE "crypto|cipher|unable to load"; then
  pass "reading the repository without the passphrase fails"
else
  fail "the repository was readable without its passphrase"
fi

echo
echo "=== The dumps are encrypted too, and by a different key ==="
newest_dump="$(on "$node" sudo "$BIN/lab6-s3" list dumps/ | sort | tail -1)"
if [[ -z "$newest_dump" ]]; then
  fail "no dump found to check"
else
  head_hex="$(on "$node" sudo bash -c \
    "$BIN/lab6-s3 cat '$newest_dump' 2>/dev/null | head -c 8 | od -An -v -tx1 | tr -d ' \n'")"
  if [[ "$head_hex" == 53616c7465645f5f ]]; then
    pass "$newest_dump begins 'Salted__' in the bucket"
  elif [[ "$head_hex" == 5047444d50* ]]; then
    fail "the dump is in the bucket as a plaintext PGDMP archive"
  else
    fail "unexpected first bytes for the dump: ${head_hex:-<none>}"
  fi

  # The repository passphrase must not open the dump: if it did, the two stores
  # would share a secret and losing one would lose both.
  #
  # The property is about the PLAINTEXT, not about openssl's exit status, and the
  # difference is not academic. With -pbkdf2 a wrong passphrase still produces
  # output; openssl only errors if the final block's PKCS#7 padding fails to
  # validate, which by chance it survives roughly 1 time in 256. This check used
  # to test the exit code and duly failed a correctly encrypted dump -- garbage
  # bytes '333 240 e 250' that openssl was happy to emit.
  #
  # So decrypt and look: a dump begins with the magic PGDMP. Anything else is not
  # the dump, whatever openssl thought of it.
  repo_pass="$(sed -n 's/^repo_cipher_pass: "\(.*\)"$/\1/p' "$RECOVERY_INPUTS")"
  wrong_head="$(on "$node" sudo bash -c \
    "$BIN/lab6-s3 cat '$newest_dump' > /tmp/lab6-enc-probe 2>/dev/null
     openssl enc -d -aes-256-cbc -pbkdf2 -in /tmp/lab6-enc-probe \
       -out /tmp/lab6-enc-probe.out -pass pass:'$repo_pass' 2>/dev/null
     head -c 5 /tmp/lab6-enc-probe.out 2>/dev/null")"
  [[ "$wrong_head" == "PGDMP" ]] \
    && fail "the dump decrypted with the REPOSITORY passphrase; the two keys are the same" \
    || pass "the repository passphrase does not yield the dump: separate keys"

  # The positive half, which the old check never made: the dump passphrase must
  # actually open it. "Nothing else decrypts it" is only half a claim if the
  # right key does not either.
  right_head="$(on "$node" sudo bash -c \
    "openssl enc -d -aes-256-cbc -pbkdf2 -in /tmp/lab6-enc-probe \
       -out /tmp/lab6-enc-probe.out -pass file:$PASSFILE 2>/dev/null
     head -c 5 /tmp/lab6-enc-probe.out 2>/dev/null")"
  [[ "$right_head" == "PGDMP" ]] \
    && pass "and the dump passphrase does open it, to a real PGDMP archive" \
    || fail "the dump passphrase does not open the dump: it is unreadable"
  on "$node" sudo rm -f /tmp/lab6-enc-probe /tmp/lab6-enc-probe.out >/dev/null 2>&1
fi

dump_pass="$(sed -n 's/^dump_cipher_pass: "\(.*\)"$/\1/p' "$RECOVERY_INPUTS")"
repo_pass="$(sed -n 's/^repo_cipher_pass: "\(.*\)"$/\1/p' "$RECOVERY_INPUTS")"
[[ -n "$dump_pass" && -n "$repo_pass" && "$dump_pass" != "$repo_pass" ]] \
  && pass "the two passphrases are distinct secrets" \
  || fail "the dump and repository passphrases are missing or identical"

echo
echo "=== And nothing is transferred in plaintext ==="
endpoint="$("$SCRIPT_DIR/minio.sh" url)"
code="$(on "$node" curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
  "${endpoint/https:/http:}/minio/health/live" || true)"
[[ "${code:-000}" == "000" || "${code:-000}" == "400" ]] \
  && pass "a plaintext request to the object store is refused" \
  || fail "plaintext to the object store returned '$code'"

echo
(( failures == 0 )) && { echo "PASS"; exit 0; }
echo "FAILED: $failures problem(s)" >&2
exit 1
