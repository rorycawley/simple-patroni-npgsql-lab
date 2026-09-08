#!/usr/bin/env bash
set -uo pipefail

# AC-1: the database and its cluster state are encrypted at rest.
#
#   layout  Both data directories are distinct LUKS2 devices, neither on the
#           root filesystem, each listed in crypttab so it unlocks at boot.
#   guard   Patroni never runs without its data volume. Without this the
#           encryption is decorative: PostgreSQL would initialise an empty data
#           directory over the mountpoint and report a healthy node holding none
#           of the data, and every other check in the suite would still pass.

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly VM_NAMES=(lab2-pg1 lab2-pg2 lab2-pg3)
readonly PATRONI_CONFIG=/etc/patroni/patroni.yml

usage() { echo "Usage: ./scripts/test-at-rest.sh [layout|guard|all]" >&2; }

for required in limactl jq; do
  command -v "$required" >/dev/null 2>&1 || { echo "$required is required" >&2; exit 1; }
done
[[ -f "$LAB_DIR/.env" ]] || { echo "Run make create_vms first" >&2; exit 1; }

broken_vm=""

cleanup() {
  if [[ -n "$broken_vm" ]]; then
    echo "  restoring $broken_vm after an interrupted run" >&2
    limactl shell --tty=false "$broken_vm" sudo bash -c '
      systemctl stop percona-patroni 2>/dev/null
      device=$(blkid -t TYPE=crypto_LUKS -o device | head -1)
      cryptsetup status lab2-pgdata >/dev/null 2>&1 || \
        cryptsetup luksOpen --key-file /etc/lab2/luks/pgdata.key "$device" lab2-pgdata
      [ -f /etc/fstab.lab2bak ] && mv /etc/fstab.lab2bak /etc/fstab
      systemctl daemon-reload
      mountpoint -q /var/lib/pgsql || mount /var/lib/pgsql
      systemctl reset-failed percona-patroni 2>/dev/null
      systemctl start percona-patroni' >/dev/null 2>&1
  fi
  return 0
}
trap cleanup EXIT

pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; return 1; }

patroni_json() {
  local vm out
  for vm in "${VM_NAMES[@]}"; do
    if out="$(limactl shell --tty=false "$vm" sudo -u postgres \
      patronictl -c "$PATRONI_CONFIG" list --format=json 2>/dev/null)"; then
      printf '%s\n' "$out"
      return 0
    fi
  done
  return 1
}

leader_member() { jq -r '.[] | select(.Role | test("Leader")) | .Member' <<< "$(patroni_json)"; }

wait_for_healthy() {
  local _
  for _ in {1..60}; do
    if jq -e 'length == 3 and ([.[] | select(.State == "streaming")] | length == 2)' \
      <<< "$(patroni_json 2>/dev/null)" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

test_layout() {
  echo
  echo "=== Encryption at rest: both data volumes are LUKS2 ==="
  local vm report
  for vm in "${VM_NAMES[@]}"; do
    report="$(limactl shell --tty=false "$vm" sudo bash -s <<'REMOTE' 2>&1
set -uo pipefail
fail=0
root=$(findmnt -no SOURCE /)
for spec in "/var/lib/pgsql:lab2-pgdata" "/var/lib/etcd:lab2-etcd"; do
  path="${spec%%:*}"; mapper="${spec##*:}"
  src=$(findmnt -no SOURCE "$path" 2>/dev/null || echo "")
  [ "$src" = "/dev/mapper/$mapper" ] || { echo "FAIL $path mounted from '${src:-nothing}', expected /dev/mapper/$mapper"; fail=1; continue; }
  [ "$src" != "$root" ] || { echo "FAIL $path is on the root filesystem"; fail=1; continue; }
  backing=$(cryptsetup status "$mapper" | awk '/device:/ {print $2}')
  [ -n "$backing" ] || { echo "FAIL $mapper is not an open LUKS device"; fail=1; continue; }
  fstype=$(lsblk -dno FSTYPE "$backing")
  [ "$fstype" = "crypto_LUKS" ] || { echo "FAIL $backing is '$fstype', expected crypto_LUKS"; fail=1; continue; }
  version=$(cryptsetup luksDump "$backing" | awk '/^Version:/ {print $2}')
  [ "$version" = "2" ] || { echo "FAIL $backing is LUKS version $version, expected 2"; fail=1; continue; }
  grep -q "^$mapper " /etc/crypttab || { echo "FAIL $mapper has no crypttab entry and will not unlock at boot"; fail=1; continue; }
  echo "ok $path -> /dev/mapper/$mapper on $backing (LUKS2, in crypttab)"
done
pg=$(findmnt -no SOURCE /var/lib/pgsql 2>/dev/null); et=$(findmnt -no SOURCE /var/lib/etcd 2>/dev/null)
[ "$pg" != "$et" ] || { echo "FAIL PostgreSQL and etcd share a device"; fail=1; }
exit $fail
REMOTE
)"
    echo "$vm:"
    echo "$report" | sed 's/^/    /'
    if grep -q 'FAIL' <<< "$report"; then
      fail "$vm failed the layout check"
      return 1
    fi
  done
  pass "all three nodes: distinct LUKS2 volumes, off the root filesystem, in crypttab"
  echo "PASS (layout)"
}

test_guard() {
  echo
  echo "=== Encryption at rest: Patroni never runs without its data volume ==="
  local leader target vm report
  leader="$(leader_member)"
  target=""
  for vm in "${VM_NAMES[@]}"; do
    if [[ "$vm" != "lab2-$leader" ]]; then target="$vm"; break; fi
  done
  [[ -n "$target" ]] || { fail "could not pick a replica to test"; return 1; }
  echo "  using replica $target (leader is $leader, untouched)"
  broken_vm="$target"

  # A plain umount proves nothing: RequiresMountsFor= pulls the mount unit in,
  # so systemd simply remounts the volume and starts normally. Both cases below
  # are ones systemd cannot repair.
  report="$(limactl shell --tty=false "$target" sudo bash -s <<'REMOTE' 2>&1
set -uo pipefail
fail=0
device=$(cryptsetup status lab2-pgdata | awk '/device:/ {print $2}')

restore() {
  systemctl stop percona-patroni 2>/dev/null
  cryptsetup status lab2-pgdata >/dev/null 2>&1 || \
    cryptsetup luksOpen --key-file /etc/lab2/luks/pgdata.key "$device" lab2-pgdata
  [ -f /etc/fstab.lab2bak ] && mv /etc/fstab.lab2bak /etc/fstab
  systemctl daemon-reload
  mountpoint -q /var/lib/pgsql || mount /var/lib/pgsql
  systemctl reset-failed percona-patroni 2>/dev/null
  systemctl start percona-patroni
}
trap restore EXIT

# Never a blocking `systemctl start`: with the mapper device absent the mount
# job waits for it indefinitely, so start would hang rather than fail. All that
# matters is that the service never reaches "active".
try_start() {
  systemctl reset-failed percona-patroni 2>/dev/null
  systemctl start --no-block percona-patroni 2>/dev/null
  sleep 12
  systemctl is-active percona-patroni 2>/dev/null || true
}

check_case() {
  label="$1"
  state=$(try_start)
  if [ "$state" = "active" ]; then
    echo "FAIL $label: Patroni reached active without its data volume"; fail=1
  else
    echo "ok $label: Patroni never became active (state: $state)"
  fi
  if [ "$(ls -A /var/lib/pgsql | wc -l)" -eq 0 ]; then
    echo "ok $label: nothing written to the root filesystem under the mountpoint"
  else
    echo "FAIL $label: data was written under the mountpoint"; fail=1
  fi
  systemctl stop percona-patroni 2>/dev/null
}

# Case 1 -- the volume fails to unlock, so the mount unit cannot activate and
# RequiresMountsFor= must stop Patroni.
systemctl stop percona-patroni
umount /var/lib/pgsql
cryptsetup luksClose lab2-pgdata
check_case "case 1 (volume locked)"
cryptsetup luksOpen --key-file /etc/lab2/luks/pgdata.key "$device" lab2-pgdata

# Case 2 -- the mount is never configured. With no mount unit to require,
# RequiresMountsFor= is a no-op and only ExecStartPre stands between Patroni and
# an initdb onto the root filesystem.
cp /etc/fstab /etc/fstab.lab2bak
sed -i '/lab2-pgdata/d' /etc/fstab
systemctl daemon-reload
umount /var/lib/pgsql 2>/dev/null
check_case "case 2 (no mount configured)"

exit $fail
REMOTE
)"
  echo "$report" | sed 's/^/    /'
  if grep -q 'FAIL' <<< "$report"; then
    fail "a guard did not hold"
    return 1
  fi

  broken_vm=""
  wait_for_healthy || { fail "$target did not rejoin as a healthy replica"; return 1; }
  pass "$target restored and rejoined the cluster"
  echo "PASS (guard)"
}

main() {
  case "${1:-all}" in
    layout) test_layout ;;
    guard) test_guard ;;
    all) test_layout || exit 1; test_guard || exit 1 ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
