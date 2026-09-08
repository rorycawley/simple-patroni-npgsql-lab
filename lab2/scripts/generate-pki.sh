#!/usr/bin/env bash
set -euo pipefail

# Issues the lab CA and four certificates per node.
#
# One certificate per purpose, not one per node: distinct extended key usages
# mean a stolen Patroni REST key cannot open an etcd client session.
#
#   <node>-postgres     serverAuth              PostgreSQL, incl. replication
#   <node>-etcd         serverAuth, clientAuth  etcd client and peer APIs
#   <node>-patroni      serverAuth, clientAuth  Patroni REST API
#   <node>-dcs-client   clientAuth              Patroni's own client to etcd
#
# Everything stays under .secrets/, which is ignored wholesale. That matters:
# .gitignore covers *.key but not *.crt, so a directory outside .secrets/ would
# make certificates committable to a public repository.
#
# The CA key never leaves this machine. Each node receives ca.crt plus its own
# four identities and nothing else.

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly PKI_DIR="$LAB_DIR/.secrets/pki"
readonly NODE_NAMES=(pg1 pg2 pg3)
readonly DOMAIN=lab2.example
readonly CA_DAYS=3650
readonly LEAF_DAYS=825

command -v openssl >/dev/null 2>&1 || { echo "openssl is required" >&2; exit 1; }
[[ -f "$LAB_DIR/.env" ]] || { echo "Run make create_vms first" >&2; exit 1; }
source "$LAB_DIR/.env"

umask 077
mkdir -p "$PKI_DIR"

if { [[ -f "$PKI_DIR/ca.crt" ]] && [[ ! -f "$PKI_DIR/ca.key" ]]; } ||
   { [[ ! -f "$PKI_DIR/ca.crt" ]] && [[ -f "$PKI_DIR/ca.key" ]]; }; then
  echo "Incomplete lab CA: ca.crt and ca.key must both exist or both be absent" >&2
  exit 1
fi

if [[ ! -f "$PKI_DIR/ca.crt" ]]; then
  echo "Creating lab CA"
  openssl genrsa -out "$PKI_DIR/ca.key" 3072 >/dev/null 2>&1
  chmod 600 "$PKI_DIR/ca.key"
  openssl req -x509 -new -sha256 -days "$CA_DAYS" -key "$PKI_DIR/ca.key" \
    -out "$PKI_DIR/ca.crt" -subj "/CN=Lab 2 Root CA/O=Local Lab"
fi

# Reissue whenever the requested identity changes. Lima can hand out different
# addresses after a rebuild, and a stale IP SAN fails VerifyFull in a way that
# reads like a cluster fault rather than a certificate one.
sign_cert() {
  local name="$1" cn="$2" san="$3" eku="$4"
  local spec="cn=$cn|san=$san|eku=$eku"
  local spec_file="$PKI_DIR/$name.spec"

  if [[ -f "$PKI_DIR/$name.crt" && -f "$PKI_DIR/$name.key" && -f "$spec_file" ]] &&
     [[ "$(cat "$spec_file")" == "$spec" ]] &&
     openssl x509 -checkend 86400 -noout -in "$PKI_DIR/$name.crt" >/dev/null 2>&1 &&
     openssl verify -CAfile "$PKI_DIR/ca.crt" "$PKI_DIR/$name.crt" >/dev/null 2>&1; then
    return 0
  fi

  echo "Issuing certificate: $name"
  openssl genrsa -out "$PKI_DIR/$name.key" 2048 >/dev/null 2>&1
  chmod 600 "$PKI_DIR/$name.key"
  openssl req -new -sha256 -key "$PKI_DIR/$name.key" -out "$PKI_DIR/$name.csr" \
    -subj "/CN=$cn/O=Local Lab"
  cat > "$PKI_DIR/$name.ext" <<EXT
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=$eku
subjectAltName=$san
EXT
  openssl x509 -req -sha256 -days "$LEAF_DAYS" -in "$PKI_DIR/$name.csr" \
    -CA "$PKI_DIR/ca.crt" -CAkey "$PKI_DIR/ca.key" -CAcreateserial \
    -out "$PKI_DIR/$name.crt" -extfile "$PKI_DIR/$name.ext" >/dev/null 2>&1
  printf '%s\n' "$spec" > "$spec_file"
  rm -f "$PKI_DIR/$name.csr" "$PKI_DIR/$name.ext"
}

for index in "${!NODE_NAMES[@]}"; do
  node="${NODE_NAMES[index]}"
  ip_var="PG$((index + 1))_IP"
  ip="${!ip_var}"
  [[ -n "$ip" ]] || { echo "No address for $node in .env" >&2; exit 1; }

  # localhost is on the server certificates because Patroni's own control
  # connection to PostgreSQL uses it, and that connection verifies too.
  san="DNS:${node}.${DOMAIN},DNS:${node},DNS:localhost,IP:${ip},IP:127.0.0.1"

  sign_cert "${node}-postgres"   "${node}.${DOMAIN}" "$san" "serverAuth"
  sign_cert "${node}-etcd"       "${node}.${DOMAIN}" "$san" "serverAuth,clientAuth"
  sign_cert "${node}-patroni"    "${node}.${DOMAIN}" "$san" "serverAuth,clientAuth"
  sign_cert "${node}-dcs-client" "${node}-dcs-client" "DNS:${node}.${DOMAIN}" "clientAuth"
done

chmod 600 "$PKI_DIR"/*.key
echo "TLS material is in $PKI_DIR (the CA key stays here and is never shipped)"
