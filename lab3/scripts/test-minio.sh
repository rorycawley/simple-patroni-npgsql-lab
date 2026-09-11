#!/usr/bin/env bash
set -uo pipefail

# P1: the object store exists, every node reaches it over VERIFIED TLS, and
# plaintext is refused.
#
# What this does NOT prove is that pgBackRest can use it as a repository. That
# is P2, and it is proven with pgBackRest itself rather than by installing a
# second S3 client on the guests purely to satisfy a check -- the client that
# matters is the one that will actually take the backups.
#
# Each positive assertion has a negative control. "curl succeeded with our CA"
# means nothing unless the same call FAILS without it: it would also succeed if
# verification were switched off, which is the failure this lab exists to rule
# out for the database and has no reason to tolerate here.

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly PKI_DIR="$LAB_DIR/.secrets/pki"
readonly CLUSTER_SECRETS="$LAB_DIR/.secrets/cluster.yml"
readonly MC_DIR="$LAB_DIR/.minio/mc"
readonly GUEST_CA=/etc/lab3/pki/ca.crt
# The database nodes only. pgBackRest runs where PostgreSQL runs, so the
# application host has no reason to reach the backup store -- it holds the CA
# at a different path for exactly that reason, and reaching the repository is
# not among the things it is supposed to be able to do.
readonly VM_NAMES=(lab3-pg1 lab3-pg2 lab3-pg3)
readonly BUCKET=lab3-backups

command -v mc >/dev/null 2>&1 || { echo "mc is required" >&2; exit 1; }
[[ -f "$CLUSTER_SECRETS" ]] || { echo "Run make configure_cluster first" >&2; exit 1; }

secret() { sed -n "s/^$1: \"\\(.*\\)\"$/\\1/p" "$CLUSTER_SECRETS"; }
ENDPOINT="$("$SCRIPT_DIR/minio.sh" url)"
readonly ENDPOINT

failures=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; failures=$((failures + 1)); }

# curl itself prints 000 and exits non-zero when the transfer never happens, so
# the exit status is swallowed rather than turned into a second code -- doing
# both produced "000000" and made every negative control look like a failure.
guest_curl() {  # vm, extra args... -> prints the HTTP code, or 000
  local vm="$1" code; shift
  code="$(limactl shell --tty=false "$vm" curl -s -o /dev/null -w '%{http_code}' \
    --max-time 10 "$@" 2>/dev/null || true)"
  printf '%s\n' "${code:-000}"
}

echo
echo "=== P1: the object store, reached from every node ==="
echo "  endpoint: $ENDPOINT"

for vm in "${VM_NAMES[@]}"; do
  # 1. Verified TLS, using the CA the node already holds for the cluster.
  code="$(guest_curl "$vm" --cacert "$GUEST_CA" "$ENDPOINT/minio/health/live")"
  [[ "$code" == "200" ]] \
    && pass "$vm: healthy over TLS, verified against the lab CA" \
    || fail "$vm: health check returned '$code' (expected 200)"

  # 2. Negative control. Without the lab CA the certificate is untrusted, so
  #    this must fail -- otherwise assertion 1 proves only that a port is open.
  code="$(guest_curl "$vm" "$ENDPOINT/minio/health/live")"
  [[ "$code" == "000" ]] \
    && pass "$vm: refused without the lab CA, so verification is real" \
    || fail "$vm: connected WITHOUT the lab CA (got '$code'); it is not verifying"

  # 3. Plaintext must not be served on the TLS port.
  code="$(guest_curl "$vm" "${ENDPOINT/https:/http:}/minio/health/live")"
  [[ "$code" == "000" || "$code" == "400" ]] \
    && pass "$vm: plaintext refused" \
    || fail "$vm: plaintext returned '$code'"

  # 4. The S3 API is really there, and the bucket is not world-readable.
  code="$(guest_curl "$vm" --cacert "$GUEST_CA" "$ENDPOINT/$BUCKET/")"
  [[ "$code" == "403" ]] \
    && pass "$vm: bucket reachable and closed to anonymous access" \
    || fail "$vm: anonymous bucket request returned '$code' (expected 403)"
done

echo
echo "=== The certificate it serves is the one the PKI issued ==="
# Not redundant with the TLS checks above: those would still pass if the whole
# lab were rebuilt against a NEW CA while MinIO kept serving a certificate from
# the old one -- the nodes would simply all fail, which looks like a broken
# repository rather than a stale certificate. Assert identity, not just validity.
serving="$(openssl s_client -connect "${ENDPOINT#https://}" </dev/null 2>/dev/null \
  | openssl x509 -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//')"
issued="$(openssl x509 -noout -fingerprint -sha256 -in "$PKI_DIR/minio.crt" 2>/dev/null | sed 's/.*=//')"
if [[ -n "$serving" && "$serving" == "$issued" ]]; then
  pass "the served certificate matches the current PKI"
else
  fail "MinIO is serving a superseded certificate (${serving:0:17}… vs ${issued:0:17}…)"
fi

echo
echo "=== The node credential works, and is scoped to one bucket ==="
export MC_CONFIG_DIR="$MC_DIR"
access_key="$(secret minio_backup_access_key)"
secret_key="$(secret minio_backup_secret_key)"

if mc --quiet --no-color alias set lab3backup "$ENDPOINT" \
     "$access_key" "$secret_key" >/dev/null 2>&1; then
  pass "backup credential '$access_key' authenticates"
else
  fail "backup credential '$access_key' could not authenticate"
fi

mc --quiet --no-color ls "lab3backup/$BUCKET" >/dev/null 2>&1 \
  && pass "it can list $BUCKET" \
  || fail "it cannot list $BUCKET"

# Least privilege is a claim until something is denied. If the node credential
# could create buckets it could also create somewhere its own backups are not
# subject to the repository's retention.
if mc --quiet --no-color mb "lab3backup/should-not-exist" >/dev/null 2>&1; then
  fail "the backup credential created a second bucket; the policy is not scoped"
  mc --quiet --no-color rb --force "lab3backup/should-not-exist" >/dev/null 2>&1 || true
else
  pass "it cannot create other buckets, so the policy is scoped"
fi

echo
(( failures == 0 )) && { echo "PASS"; exit 0; }
echo "FAILED: $failures problem(s)" >&2
exit 1
