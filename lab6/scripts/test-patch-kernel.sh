#!/usr/bin/env bash
set -uo pipefail

# AC-4: a node survives a KERNEL change and a reboot with no operator action.
#
# Lab 2 proved a node survives a reboot. It proved it once, as a property, on the
# kernel it was built with. Patching turns that into a routine and changes the
# kernel underneath it, which is where a marginal dependency surfaces: a crypttab
# entry that works until the keyfile's filesystem mounts a little later, a unit
# ordering that held by accident, a module built for the kernel that was just
# replaced.
#
# `softdog` is the sharpest case and the reason this phase exists. It is a kernel
# module, `watchdog: mode: required` means a node that cannot arm it REFUSES to
# be primary, and that refusal is silent -- the node streams happily and is
# simply never eligible, which nobody discovers until the next failover needs it.
#
# So the watchdog is not asserted by looking for a device file. The rebooted node
# is made LEADER at the end, because promotion is the thing that requires an
# armed watchdog: if the module did not survive the new kernel, the switchover
# cannot complete, and that is a far stronger claim than `test -c /dev/watchdog`.

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly VM_NAMES=(lab6-pg1 lab6-pg2 lab6-pg3)
readonly VM_PREFIX="lab6-"
readonly STANZA=lab6
readonly PATRONI_CONFIG=/etc/patroni/patroni.yml
readonly PGDATA=/var/lib/pgsql/data

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }
[[ -f "$LAB_DIR/.env" ]] || { echo "Run make create_vms first" >&2; exit 1; }

failures=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; failures=$((failures + 1)); }
on() { local vm="$1"; shift; limactl shell --tty=false "$vm" "$@" 2>/dev/null; }
# boot_id moves only when the KERNEL restarts. A service restart, a Patroni
# reload or a reconnect cannot fake it, which is why the reboot is asserted on
# this rather than on uptime or on the node reappearing.
boot_id() { on "$1" cat /proc/sys/kernel/random/boot_id; }

patroni_json() {
  local out vm
  for vm in "${VM_NAMES[@]}"; do
    if out="$(on "$vm" sudo -u postgres patronictl -c "$PATRONI_CONFIG" list --format=json)"; then
      [[ -n "$out" ]] && { printf '%s' "$out"; return 0; }
    fi
  done
  return 1
}
leader_of() { jq -r '.[] | select(.Role | test("Leader")) | .Member' <<< "$1"; }

echo
echo "=== A newer kernel must actually exist, or this phase proves nothing ==="
cluster="$(patroni_json)" || { echo "  FAIL: no Patroni cluster answered" >&2; exit 1; }
leader="$(leader_of "$cluster")"
target="$(jq -r '.[] | select(.Role | test("Leader") | not) | .Member' <<< "$cluster" | head -1)"
echo "  leader is $leader; rebooting standby $target"

running_kernel="$(on "$VM_PREFIX$target" uname -r)"
# The precondition the plan flags as a risk: if the image already runs the newest
# kernel there is nothing to change, and AC-4 would pass because nothing
# happened. Checked by asking dnf what it WOULD do, so a closed gap stops the
# phase instead of quietly hollowing it out.
# `repoquery` rather than parsing dnf's human-readable transaction table. The
# table version of this check kept reporting "no newer kernel" against a
# repository that plainly had one -- the table is rendered for people, appears on
# both streams through `limactl shell`, and is not a contract. repoquery answers
# the actual question in a format meant for scripts.
#
# Retried, because these mirrors intermittently serve an HTML error page instead
# of repomd.xml. The retry matters less than the DISTINCTION it protects: a probe
# that cannot reach the repository must not report "no newer kernel exists",
# which is a closed gap -- the one thing that would hollow this phase out.
avail=""; probe_ok=""
for i in 1 2 3; do
  avail="$(on "$VM_PREFIX$target" sudo dnf -q repoquery --latest-limit=1 \
    --qf '%{version}-%{release}' kernel 2>/dev/null | tr -d '[:space:]')"
  [[ -n "$avail" ]] && { probe_ok=yes; break; }
  sleep 5
done
installed_kernel="$(on "$VM_PREFIX$target" rpm -q --qf '%{VERSION}-%{RELEASE}\n' kernel 2>/dev/null | sort -V | tail -1)"
if [[ -z "$probe_ok" ]]; then
  fail "could not ask the repository what kernels exist -- this is NOT evidence that the gap is closed"
  echo "FAILED: $failures problem(s)" >&2
  exit 1
fi
if [[ "$(printf '%s\n%s\n' "$installed_kernel" "$avail" | sort -V | tail -1)" == "$avail" \
   && "$avail" != "$installed_kernel" ]]; then
  pass "running $running_kernel, and $avail is available: a real kernel change"
else
  fail "no newer kernel than $installed_kernel is available -- AC-4 cannot be performed, and would otherwise pass because nothing happened"
  echo "FAILED: $failures problem(s)" >&2
  exit 1
fi

before_boot="$(boot_id "$VM_PREFIX$target")"
[[ -n "$before_boot" ]] && pass "boot id before: ${before_boot:0:8}..." || fail "could not read boot id"

echo
echo "=== Install the new kernel, and do NOT reboot ==="
ok=""
for i in 1 2 3; do
  out="$(on "$VM_PREFIX$target" sudo dnf -y $( ((i > 1)) && echo --refresh ) upgrade kernel 2>&1)" && { ok=yes; break; }
  sleep 5
done
[[ -n "$ok" ]] \
  && pass "kernel package installed on $target" \
  || { fail "kernel upgrade failed after 3 attempts"; grep -iE "^error" <<< "$out" | head -2 | sed 's/^/      /' >&2; }

still="$(on "$VM_PREFIX$target" uname -r)"
[[ "$still" == "$running_kernel" ]] \
  && pass "still RUNNING $still: a kernel on disk changes nothing until a reboot" \
  || fail "the running kernel changed to $still without a reboot, which should be impossible"

echo
echo "=== Reboot it, and touch nothing afterwards ==="
# Everything from here until the node is streaming again happens with no operator
# action. That is the claim: an unattended reboot.
on "$VM_PREFIX$target" sudo systemctl reboot >/dev/null 2>&1 &
reboot_start=$SECONDS
sleep 20

rebooted=""
for _ in {1..60}; do
  now="$(boot_id "$VM_PREFIX$target" 2>/dev/null || true)"
  [[ -n "$now" && "$now" != "$before_boot" ]] && { rebooted=yes; break; }
  sleep 5
done
[[ -n "$rebooted" ]] \
  && pass "the boot id moved: the kernel genuinely restarted, $((SECONDS - reboot_start))s in" \
  || fail "the boot id never changed; the node did not actually reboot"

new_kernel="$(on "$VM_PREFIX$target" uname -r)"
[[ "$new_kernel" != "$running_kernel" ]] \
  && pass "and it came up on a DIFFERENT kernel: $running_kernel -> $new_kernel" \
  || fail "it rebooted onto the same kernel $new_kernel; the kernel change did not take"

echo
echo "=== What the new kernel had to bring back, unattended ==="
# The encrypted volumes. A crypttab entry that depends on something mounting
# first fails exactly here and nowhere else.
for mnt in /var/lib/pgsql /var/lib/etcd; do
  on "$VM_PREFIX$target" mountpoint -q "$mnt" \
    && pass "$mnt is mounted: the LUKS volume unlocked without anyone typing a passphrase" \
    || fail "$mnt is NOT a mount point after the reboot; the volume did not unlock"
done
src="$(on "$VM_PREFIX$target" findmnt -no SOURCE /var/lib/pgsql)"
grep -q "dm-\|mapper" <<< "$src" \
  && pass "and it is the mapped LUKS device ($src), not the root filesystem" \
  || fail "/var/lib/pgsql resolves to '$src', which is not a LUKS mapping"

# The ordering that matters: PostgreSQL must not have started before its data
# directory was mounted, or it would have initialised over the mountpoint.
# sudo: the data directory is 0700 postgres, so an unprivileged test reports
# "absent" for a directory that is merely unreadable -- which looked exactly like
# PostgreSQL having initialised over an unmounted path, the fault being checked
# for. A check that cannot distinguish those two is worse than no check.
on "$VM_PREFIX$target" sudo test -f "$PGDATA/PG_VERSION" \
  && pass "the data directory is intact on the volume, so nothing started before the mount" \
  || fail "no PG_VERSION under $PGDATA: PostgreSQL may have started before the mount landed"

# softdog: a kernel module, and the kernel is new.
on "$VM_PREFIX$target" lsmod 2>/dev/null | grep -q '^softdog' \
  && pass "softdog is loaded against the new kernel" \
  || fail "softdog is NOT loaded after the kernel change; this node cannot be promoted"
on "$VM_PREFIX$target" test -c /dev/watchdog \
  && pass "/dev/watchdog exists" \
  || fail "/dev/watchdog is missing after the reboot"

echo
echo "=== It rejoined on its own ==="
back=""
for _ in {1..90}; do
  [[ "$(jq -r --arg m "$target" '.[] | select(.Member == $m) | .State' <<< "$(patroni_json)")" == "streaming" ]] \
    && { back=yes; break; }
  sleep 2
done
total=$((SECONDS - reboot_start))
[[ -n "$back" ]] \
  && pass "$target is streaming again ${total}s after the reboot began, with no operator action" \
  || fail "$target did not return to streaming on its own"

echo
echo "=== The assertion that matters: it can still be PRIMARY ==="
# `test -c /dev/watchdog` proves a device file exists. Promotion proves Patroni
# could ARM it, which is what watchdog.mode: required actually gates. A node that
# cannot arm its watchdog refuses to be primary, silently, and this is the only
# check that would notice.
# The candidate has to be CAUGHT UP, not merely streaming. Issued the instant it
# returned, the switchover was refused and the phase reported that the watchdog
# had not survived the kernel change -- a wrong and alarming conclusion drawn
# from a discarded error message. patronictl's output is kept now.
for _ in {1..30}; do
  [[ "$(jq -r --arg m "$target" '.[] | select(.Member == $m) | ."Lag in MB" // 0' <<< "$(patroni_json)")" == "0" ]] && break
  sleep 2
done
t0=$SECONDS
promoted=""
for attempt in 1 2; do
  sw_out="$(on "$VM_PREFIX$leader" sudo -u postgres patronictl -c "$PATRONI_CONFIG" \
    switchover "$STANZA" --leader "$leader" --candidate "$target" --force 2>&1)"
  for _ in {1..45}; do
    [[ "$(leader_of "$(patroni_json)")" == "$target" ]] && { promoted=yes; break; }
    sleep 2
  done
  [[ -n "$promoted" ]] && break
  echo "      attempt $attempt did not move the leader; patronictl said:" >&2
  grep -viE "^\s*$|^\+|^\| Member" <<< "$sw_out" | head -3 | sed 's/^/        /' >&2
  sleep 10
done
[[ -n "$promoted" ]] \
  && pass "the rebooted node took the leader key in $((SECONDS - t0))s, so it armed its watchdog" \
  || fail "the rebooted node could NOT become primary: the watchdog did not survive the kernel change"

on "$VM_PREFIX$target" sudo journalctl -u percona-patroni --no-pager -n 300 2>/dev/null \
  | grep -qi "watchdog.*not usable" \
  && fail "it logged 'watchdog device is not usable' -- the fault runbook 2 exists for" \
  || pass "and it logged no watchdog fault"

echo
echo "=== AC-7: the cluster is not left degraded ==="
final="$(patroni_json)"
[[ "$(jq -r '[.[] | select(.Role | test("Leader"))] | length' <<< "$final")" == "1" ]] \
  && pass "exactly one leader" || fail "leader count is not 1"
settled=""
for _ in {1..60}; do
  [[ "$(jq -r '[.[] | select(.State == "streaming")] | length' <<< "$(patroni_json)")" == "2" ]] \
    && { settled=yes; break; }
  sleep 5
done
[[ -n "$settled" ]] && pass "two streaming standbys" || fail "the cluster is left degraded"
dcs="$(on "$VM_PREFIX$(leader_of "$final")" sudo -u postgres patronictl -c "$PATRONI_CONFIG" show-config 2>/dev/null)"
grep -q "synchronous_mode_strict: true" <<< "$dcs" \
  && pass "quorum commit is still strict" || fail "strict mode was lost"

echo
if [[ -n "$promoted" ]]; then
  echo "  P4: $target rebooted $running_kernel -> $new_kernel, streaming in ${total}s, and took the leader key afterwards"
else
  echo "  P4: $target rebooted $running_kernel -> $new_kernel, streaming in ${total}s, but could NOT be promoted"
fi
echo
(( failures == 0 )) && { echo "PASS"; exit 0; }
echo "FAILED: $failures problem(s)" >&2
exit 1
