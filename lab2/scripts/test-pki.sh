#!/usr/bin/env bash
set -uo pipefail

# Prerequisite for AC-2 and AC-3: the certificates exist, assert the identities
# they are supposed to, and the CA private key is nowhere near a guest.
#
# A certificate that verifies but carries the wrong SAN or extended key usage
# will fail later as a confusing TLS handshake error, so it is cheaper to check
# the contents here than to debug them in P4 or P5.

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly PKI_DIR="$LAB_DIR/.secrets/pki"
readonly VM_NAMES=(lab2-pg1 lab2-pg2 lab2-pg3)
readonly NODE_NAMES=(pg1 pg2 pg3)
readonly DOMAIN=lab2.example
readonly REMOTE_PKI=/etc/lab2/pki

failures=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; failures=$((failures + 1)); }

[[ -d "$PKI_DIR" ]] || { echo "No PKI at $PKI_DIR. Run make configure_cluster first." >&2; exit 1; }
[[ -f "$LAB_DIR/.env" ]] || { echo "Run make create_vms first" >&2; exit 1; }
source "$LAB_DIR/.env"

echo
echo "=== PKI: every certificate asserts the identity it should ==="

for index in "${!NODE_NAMES[@]}"; do
  node="${NODE_NAMES[index]}"
  ip_var="PG$((index + 1))_IP"
  ip="${!ip_var}"

  while IFS='|' read -r name expected_eku want_ip; do
    crt="$PKI_DIR/${node}-${name}.crt"
    [[ -f "$crt" ]] || { fail "$node-$name is missing"; continue; }

    openssl verify -CAfile "$PKI_DIR/ca.crt" "$crt" >/dev/null 2>&1 \
      || { fail "$node-$name does not verify against the lab CA"; continue; }

    eku="$(openssl x509 -in "$crt" -noout -ext extendedKeyUsage 2>/dev/null | tail -1 | tr -d ' ')"
    [[ "$eku" == "$expected_eku" ]] \
      || { fail "$node-$name has EKU '$eku', expected '$expected_eku'"; continue; }

    san="$(openssl x509 -in "$crt" -noout -ext subjectAltName 2>/dev/null | tail -1 | tr -d ' ')"
    [[ "$san" == *"DNS:${node}.${DOMAIN}"* ]] \
      || { fail "$node-$name is missing its DNS name in the SAN"; continue; }

    # Only the server certificates need an address: the client connects by IP,
    # and with VerifyFull nothing but an IP SAN can satisfy verification.
    if [[ "$want_ip" == yes ]]; then
      [[ "$san" == *"IPAddress:${ip}"* ]] \
        || { fail "$node-$name is missing IP:$ip in the SAN (VerifyFull by address would fail)"; continue; }
    fi

    openssl x509 -in "$crt" -noout -checkend 604800 >/dev/null 2>&1 \
      || { fail "$node-$name expires within a week"; continue; }

    pass "$node-$name verifies, EKU $eku, SAN carries ${node}.${DOMAIN}$([[ "$want_ip" == yes ]] && echo " and $ip")"
  done <<EOF
postgres|TLSWebServerAuthentication|yes
etcd|TLSWebServerAuthentication,TLSWebClientAuthentication|yes
patroni|TLSWebServerAuthentication,TLSWebClientAuthentication|yes
dcs-client|TLSWebClientAuthentication|no
EOF
done

echo
echo "=== PKI: the CA private key never reaches a guest ==="
[[ -f "$PKI_DIR/ca.key" ]] && pass "CA key is on the control machine" \
  || fail "CA key is missing from $PKI_DIR"

for vm in "${VM_NAMES[@]}"; do
  found="$(limactl shell --tty=false "$vm" sudo sh -c \
    "find / -xdev -name 'ca.key' -o -xdev -name '*ca*.key' 2>/dev/null | head -5" 2>/dev/null || true)"
  if [[ -n "$found" ]]; then
    fail "$vm holds what looks like a CA key: $(tr '\n' ' ' <<< "$found")"
  else
    pass "$vm holds no CA private key"
  fi

  # Quoted so the glob is expanded on the node. Unquoted it expands locally,
  # where the path does not exist, and the check silently sees nothing.
  perms="$(limactl shell --tty=false "$vm" sudo sh -c \
    "stat -c '%n %U %a' $REMOTE_PKI/*.key" 2>/dev/null || true)"
  if [[ -z "$perms" ]]; then
    fail "$vm has no private keys under $REMOTE_PKI"
  elif grep -qv ' 600$' <<< "$perms"; then
    fail "$vm has a private key that is not mode 600: $(grep -v ' 600$' <<< "$perms" | tr '\n' ' ')"
  else
    pass "$vm: all private keys are mode 600 ($(wc -l <<< "$perms" | tr -d ' ') keys)"
  fi
done

echo
if (( failures == 0 )); then
  echo "PASS (pki)"
else
  echo "FAILED: $failures problem(s)" >&2
  exit 1
fi
