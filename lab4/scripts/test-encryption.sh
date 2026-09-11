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
readonly VM_NAMES=(lab4-pg1 lab4-pg2 lab4-pg3)
readonly VM_PREFIX="lab4-"
readonly STANZA=lab4
readonly BIN=/usr/local/lib/lab4
readonly PATRONI_CONFIG=/etc/patroni/patroni.yml
readonly RECOVERY_INPUTS="$LAB_DIR/.recovery-inputs/repo.yml"

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
  "$BIN/lab4-s3 cat pgbackrest/backup/$STANZA/backup.info 2>/dev/null | head -c 8 | od -An -v -tx1 | tr -d ' \n'")"
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
newest_dump="$(on "$node" sudo "$BIN/lab4-s3" list dumps/ | sort | tail -1)"
if [[ -z "$newest_dump" ]]; then
  fail "no dump found to check"
else
  head_hex="$(on "$node" sudo bash -c \
    "$BIN/lab4-s3 cat '$newest_dump' 2>/dev/null | head -c 8 | od -An -v -tx1 | tr -d ' \n'")"
  if [[ "$head_hex" == 53616c7465645f5f ]]; then
    pass "$newest_dump begins 'Salted__' in the bucket"
  elif [[ "$head_hex" == 5047444d50* ]]; then
    fail "the dump is in the bucket as a plaintext PGDMP archive"
  else
    fail "unexpected first bytes for the dump: ${head_hex:-<none>}"
  fi

  # Decrypting with the WRONG passphrase must fail. The repository passphrase is
  # the most convincing wrong key available: if it worked, the two stores would
  # share a secret and losing one would lose both.
  repo_pass="$(sed -n 's/^repo_cipher_pass: "\(.*\)"$/\1/p' "$RECOVERY_INPUTS")"
  if on "$node" sudo bash -c \
      "$BIN/lab4-s3 cat '$newest_dump' > /tmp/lab4-enc-probe 2>/dev/null &&
       openssl enc -d -aes-256-cbc -pbkdf2 -in /tmp/lab4-enc-probe -out /dev/null \
         -pass pass:'$repo_pass'" >/dev/null 2>&1; then
    fail "the dump decrypted with the REPOSITORY passphrase; the two keys are the same"
  else
    pass "the dump does not open with the repository passphrase: separate keys"
  fi
  on "$node" sudo rm -f /tmp/lab4-enc-probe >/dev/null 2>&1
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
