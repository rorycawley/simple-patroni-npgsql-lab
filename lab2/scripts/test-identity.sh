#!/usr/bin/env bash
set -uo pipefail

# AC-3: the client verifies who it is talking to, rather than merely encrypting.
#
# This is the criterion most easily mistaken for AC-2. An encrypted connection
# to an impostor is still an encrypted connection: SSL Mode=Require would pass
# every check in test-in-transit.sh while accepting any certificate at all.
# What is tested here is that verification FAILS CLOSED -- a wrong trust root,
# or a name that does not match, must be refused rather than downgraded.

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly APP_VM=lab2-app1
readonly CLIENT=/opt/lab2-client/Lab2.Client
readonly CLIENT_DIR=/etc/lab2/client

[[ -f "$LAB_DIR/.env" ]] || { echo "Run make create_vms first" >&2; exit 1; }
source "$LAB_DIR/.env"

failures=0
restore_needed=""
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; failures=$((failures + 1)); }

cleanup() {
  if [[ -n "$restore_needed" ]]; then
    limactl shell --tty=false "$APP_VM" sudo bash -c \
      "test -f $CLIENT_DIR/ca.crt.good && mv $CLIENT_DIR/ca.crt.good $CLIENT_DIR/ca.crt" >/dev/null 2>&1
  fi
  return 0
}
trap cleanup EXIT

run_client() {
  limactl shell --tty=false "$APP_VM" sudo env \
    LAB2_PG_HOSTS="${PG1_IP},${PG2_IP},${PG3_IP}" \
    LAB2_PGPASS="$CLIENT_DIR/pgpass" \
    LAB2_CA="$1" "$CLIENT" 2>&1
}

echo
echo "=== Identity: the baseline connection verifies ==="
out="$(run_client "$CLIENT_DIR/ca.crt" | jq -r '.ok' 2>/dev/null || true)"
[[ "$out" == true ]] && pass "the client connects with the correct CA" \
  || { fail "the baseline connection failed; the rest of this test would be meaningless"; exit 1; }

echo
echo "=== Identity: a wrong trust root must fail closed ==="
# A syntactically valid CA that simply did not sign the cluster's certificates.
limactl shell --tty=false "$APP_VM" sudo bash -c "
  set -e
  cp $CLIENT_DIR/ca.crt $CLIENT_DIR/ca.crt.good
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -keyout /tmp/impostor.key -out $CLIENT_DIR/ca.crt -subj '/CN=Impostor CA' >/dev/null 2>&1
  chmod 644 $CLIENT_DIR/ca.crt" >/dev/null 2>&1
restore_needed=yes

out="$(run_client "$CLIENT_DIR/ca.crt")"
if grep -qiE 'ok.*true' <<< "$out"; then
  fail "the client connected against a CA that signed nothing in this cluster"
else
  reason="$(grep -oiE 'certificate|trust|authentication failed|RemoteCertificate' <<< "$out" | head -1)"
  pass "connection refused against the wrong CA (${reason:-verification failure})"
fi

echo
echo "=== Identity: it recovers when the correct CA is restored ==="
limactl shell --tty=false "$APP_VM" sudo bash -c \
  "mv $CLIENT_DIR/ca.crt.good $CLIENT_DIR/ca.crt" >/dev/null 2>&1
restore_needed=""
out="$(run_client "$CLIENT_DIR/ca.crt" | jq -r '.ok' 2>/dev/null || true)"
[[ "$out" == true ]] && pass "the client connects again with the correct CA" \
  || fail "the client did not recover after the correct CA was restored"

echo
echo "=== Identity: verification is by name, not merely by chain ==="
# The certificates carry IP SANs for the addresses the client uses. Asking for a
# name the certificate does not assert must fail even though the chain is valid,
# which is the difference between VerifyFull and VerifyCA.
out="$(limactl shell --tty=false "$APP_VM" sudo bash -c "
  timeout 8 openssl s_client -connect ${PG1_IP}:5432 -starttls postgres \
    -CAfile $CLIENT_DIR/ca.crt -verify_return_error -verify_hostname wrong.example </dev/null 2>&1 |
  grep -ciE 'verify error|Verification error|handshake failure' || true")"
[[ "${out:-0}" -ge 1 ]] && pass "a mismatched name is rejected" \
  || fail "a certificate was accepted for a name it does not assert"

out="$(limactl shell --tty=false "$APP_VM" sudo bash -c "
  timeout 8 openssl s_client -connect ${PG1_IP}:5432 -starttls postgres \
    -CAfile $CLIENT_DIR/ca.crt -verify_return_error -verify_ip ${PG1_IP} </dev/null 2>&1 |
  grep -c 'Verification: OK' || true")"
[[ "${out:-0}" -ge 1 ]] && pass "the node's own address verifies (IP SAN present)" \
  || fail "the node's address did not verify; the IP SAN may be missing"

echo
if (( failures == 0 )); then
  echo "PASS (identity)"
else
  echo "FAILED: $failures problem(s)" >&2
  exit 1
fi
