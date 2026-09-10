#!/usr/bin/env bash
set -uo pipefail

# AC-2: no cluster data crosses the network unencrypted.
#
# Every channel in README.md's in-transit table is checked twice: TLS must
# succeed, and the plaintext or uncertificated equivalent must be REFUSED.
# Only the second half is a security property. A cluster that merely works over
# TLS while still accepting plaintext is not encrypted in transit, and every
# other check in this suite would pass on it.

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly VM_NAMES=(lab3-pg1 lab3-pg2 lab3-pg3)
readonly APP_VM=lab3-app1
readonly PKI=/etc/lab3/pki

[[ -f "$LAB_DIR/.env" ]] || { echo "Run make create_vms first" >&2; exit 1; }
source "$LAB_DIR/.env"

failures=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; failures=$((failures + 1)); }

# Runs a check inside a node, where the certificates live.
on_node() { limactl shell --tty=false "$1" sudo bash -c "$2" 2>&1; }

echo
echo "=== In transit: etcd client API (2379) ==="
for index in "${!VM_NAMES[@]}"; do
  vm="${VM_NAMES[index]}"
  ip_var="PG$((index + 1))_IP"; ip="${!ip_var}"

  out="$(on_node "$vm" "curl -s --max-time 5 http://$ip:2379/version >/dev/null 2>&1 && echo ACCEPTED || echo refused")"
  [[ "$out" == refused ]] && pass "$vm plaintext refused" || fail "$vm accepted plaintext on 2379"

  out="$(on_node "$vm" "curl -s --max-time 5 --cacert $PKI/ca.crt https://$ip:2379/version >/dev/null 2>&1 && echo ACCEPTED || echo refused")"
  [[ "$out" == refused ]] && pass "$vm refused a client with no certificate" || fail "$vm accepted TLS without a client certificate on 2379"

  out="$(on_node "$vm" "curl -s --max-time 5 --cacert $PKI/ca.crt --cert $PKI/etcd.crt --key $PKI/etcd.key https://$ip:2379/version | grep -c etcdserver || true")"
  [[ "$out" == 1 ]] && pass "$vm served a client presenting a valid certificate" || fail "$vm rejected a valid client certificate on 2379"

  out="$(on_node "$vm" "timeout 8 openssl s_client -brief -tls1_3 -connect $ip:2379 -CAfile $PKI/ca.crt -cert $PKI/etcd.crt -key $PKI/etcd.key </dev/null 2>&1 | grep -c 'TLSv1.3' || true")"
  [[ "$out" -ge 1 ]] && pass "$vm negotiated TLS 1.3" || fail "$vm did not negotiate TLS 1.3 on 2379"

  out="$(on_node "$vm" "timeout 8 openssl s_client -brief -tls1_2 -connect $ip:2379 -CAfile $PKI/ca.crt -cert $PKI/etcd.crt -key $PKI/etcd.key </dev/null 2>&1 | grep -ciE 'protocol version|alert|error' || true")"
  [[ "$out" -ge 1 ]] && pass "$vm rejected TLS 1.2" || fail "$vm accepted TLS 1.2 on 2379"
done

echo
echo "=== In transit: etcd peer API (2380) ==="
for index in "${!VM_NAMES[@]}"; do
  vm="${VM_NAMES[index]}"
  ip_var="PG$((index + 1))_IP"; ip="${!ip_var}"
  out="$(on_node "$vm" "timeout 8 openssl s_client -brief -connect $ip:2380 -CAfile $PKI/ca.crt -cert $PKI/etcd.crt -key $PKI/etcd.key </dev/null 2>&1 | grep -c 'Verification: OK' || true")"
  [[ "$out" -ge 1 ]] && pass "$vm peer port serves a verified TLS connection" || fail "$vm peer port did not verify on 2380"
done

echo
echo "=== In transit: Patroni REST API (8008) ==="
for index in "${!VM_NAMES[@]}"; do
  vm="${VM_NAMES[index]}"
  ip_var="PG$((index + 1))_IP"; ip="${!ip_var}"

  out="$(on_node "$vm" "curl -s --max-time 5 http://$ip:8008/health >/dev/null 2>&1 && echo ACCEPTED || echo refused")"
  [[ "$out" == refused ]] && pass "$vm plaintext refused" || fail "$vm accepted plaintext on 8008"

  out="$(on_node "$vm" "curl -s --max-time 5 --cacert $PKI/ca.crt https://$ip:8008/health >/dev/null 2>&1 && echo ACCEPTED || echo refused")"
  [[ "$out" == refused ]] && pass "$vm refused a client with no certificate" || fail "$vm accepted TLS without a client certificate on 8008"

  out="$(on_node "$vm" "curl -s --max-time 5 --cacert $PKI/ca.crt --cert $PKI/patroni.crt --key $PKI/patroni.key https://$ip:8008/health >/dev/null 2>&1 && echo ok || echo REFUSED")"
  [[ "$out" == ok ]] && pass "$vm served a client presenting a valid certificate" || fail "$vm rejected a valid client certificate on 8008"
done

echo
echo "=== In transit: PostgreSQL (5432) ==="
primary_json="$(limactl shell --tty=false lab3-pg1 sudo -u postgres \
  patronictl -c /etc/patroni/patroni.yml list --format=json 2>/dev/null)"
primary="lab3-$(jq -r '.[] | select(.Role | test("Leader")) | .Member' <<< "$primary_json")"
primary_ip="$(jq -r '.[] | select(.Role | test("Leader")) | .Host' <<< "$primary_json")"
echo "  primary is $primary ($primary_ip)"

# The application's own session, from the VM the client actually runs on.
out="$(limactl shell --tty=false "$APP_VM" sudo env \
  LAB3_PG_HOSTS="${PG1_IP},${PG2_IP},${PG3_IP}" \
  LAB3_PGPASS=/etc/lab3/client/pgpass LAB3_CA=/etc/lab3/client/ca.crt \
  /opt/lab3-client/Lab3.Client 2>/dev/null | jq -r '.ok' 2>/dev/null || true)"
[[ "$out" == true ]] && pass "the application connects over TLS from $APP_VM" || fail "the application could not connect from $APP_VM"

out="$(on_node "$primary" "sudo -u postgres /usr/pgsql-18/bin/psql -Atc \"select count(*) from pg_stat_ssl s join pg_stat_activity a using (pid) where a.application_name like 'npgsql%' or a.backend_type = 'walsender'\" 2>/dev/null || echo 0")"
out_enc="$(on_node "$primary" "sudo -u postgres /usr/pgsql-18/bin/psql -Atc \"select count(*) from pg_stat_ssl s join pg_stat_activity a using (pid) where a.backend_type = 'walsender' and s.ssl\" 2>/dev/null || echo 0")"
[[ "${out_enc:-0}" -ge 1 ]] && pass "streaming replication is encrypted ($out_enc walsender sessions with ssl on)" \
  || fail "no encrypted walsender session found; replication may not be using TLS"

out="$(on_node "$primary" "sudo -u postgres /usr/pgsql-18/bin/psql -Atc \"show ssl_min_protocol_version\"")"
[[ "$out" == "TLSv1.3" ]] && pass "PostgreSQL floor is TLSv1.3" || fail "PostgreSQL floor is '$out', expected TLSv1.3"

# hostssl only: a plaintext connection must be refused by pg_hba, not merely
# unused. sslmode=disable asks libpq not to negotiate TLS at all.
out="$(limactl shell --tty=false "$APP_VM" sudo bash -c \
  "PGPASSFILE=/etc/lab3/client/pgpass psql 'host=$primary_ip port=5432 dbname=appdb user=app_runtime sslmode=disable connect_timeout=5' -Atc 'select 1' >/dev/null 2>&1 && echo ACCEPTED || echo refused" 2>/dev/null || echo refused)"
[[ "$out" == refused ]] && pass "a plaintext connection is refused by pg_hba" || fail "PostgreSQL accepted a plaintext connection"

echo
if (( failures == 0 )); then
  echo "PASS (in-transit)"
else
  echo "FAILED: $failures problem(s)" >&2
  exit 1
fi
