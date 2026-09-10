# Lab 2 build plan

How Lab 2 gets built, and why in this order. Every phase names the acceptance
criterion it serves; anything that serves none does not belong here.

The criteria are in [README.md](README.md): **AC-1** at rest, **AC-2** in
transit, **AC-3** identity verified, **AC-4** availability unharmed.

## What we borrow

`../percona-patroni-npgsql-lab` is a mature TLS implementation of the same
cluster. It has no disk encryption at all, so the split is clean:

| From the sibling lab | How it is used here |
| --- | --- |
| `scripts/generate-pki.sh` | Adapted almost directly. Per-purpose certificates, a `.spec` file per identity so a changed SAN forces reissue, and the CA key never leaving the control machine |
| Certificate model: `<node>-postgres`, `-etcd`, `-patroni`, `-dcs-client` | Adopted as-is. Distinct EKUs mean a stolen Patroni REST key cannot open an etcd client session |
| `scripts/configure-etcd.sh`, `configure-patroni.sh` | Read for the exact config keys; re-expressed as Ansible templates |
| `scripts/test-tls.sh` | Proof technique: `openssl s_client` per endpoint, asserting both a verified success and a rejected downgrade |
| `TLS.md` §1 relationship table | Already folded into the README's in-transit table |
| Nothing for LUKS | **All at-rest work is new** |

## Verified before starting

The plan rests on Lima attaching raw disks under the `vz` hypervisor. That was
not documented, so it was proven on a throwaway VM before any code was written:

| Question | Answer |
| --- | --- |
| Do `additionalDisks` attach under `vz` on Apple Silicon? | Yes — they appear as `/dev/vdb` and `/dev/vdc` |
| Does Lima leave them raw? | **No.** It partitions, formats `ext4` and mounts them at `/mnt/lima-<disk>`, with no `format: true` needed and no `/etc/fstab` entry |
| Is `cryptsetup` in the Rocky 9.8 image? | No, but it installs cleanly from the base repositories |
| Does the full LUKS2 flow work? | Yes — `wipefs` → `luksFormat` → `luksOpen` → `mkfs.xfs` → mount, giving `crypto_LUKS` on `aes-xts-plain64` |
| Does it survive a reboot unattended? | Yes — `crypttab` with a keyfile auto-unlocked and remounted, and a canary file written before the reboot was still there afterwards |
| Does Lima reformat the disk on boot? | No. The LUKS header survives, which is what makes any of this viable |
| Can a disk be deleted while its VM runs? | No — `cannot delete disk in use by instance`. Teardown must delete the VM first |
| Does Npgsql 10 support the client side of AC-3? | Yes — `SslMode.VerifyFull` and `RootCertificate` (keyword `Root Certificate`) exist and round-trip. Confirmed by reflection, no cluster required |

## Phases

Each phase leaves the lab green before the next begins, so a regression is
always attributable to the phase that introduced it.

### P0 — Fork Lab 1

**What.** `lab2/` becomes a working copy of Lab 1, renamed, with no behaviour
change.
**How.** Copy `lab1/`, rename `lab1-*` VMs and identifiers to `lab2-*`, keep
pgBackRest exactly as-is.
**Serves.** Nothing directly. It establishes the baseline AC-4 is measured
against.
**Done when.** `make all` in `lab2/` is 10/10 from scratch.

### P1 — Separate volumes

**What.** `/var/lib/pgsql` and `/var/lib/etcd` move onto their own block devices.
**How.** Two Lima disks per node via `limactl disk create` and `additionalDisks`.
Lima then partitions, formats and mounts them itself under `/mnt/lima-*`, so the
first Ansible task **takes each disk over**: unmount, `wipefs -a`, and treat the
whole device as raw. Add `RequiresMountsFor=` to the etcd and Patroni units.
`make clean` deletes the VMs **before** the disks — Lima refuses to delete a disk
attached to an instance — then asserts none remain, since leftovers block the
next rebuild.
**Serves.** AC-1 (separation), AC-4.
**Done when.** The two paths report distinct devices, `make clean` leaves no
disks behind, and `make check` is unchanged from P0.

### P2 — LUKS

**What.** Both volumes become LUKS2, unlocked unattended at boot.
**How.** Install `cryptsetup`, which the Rocky image does not ship. Then
`luksFormat --type luks2` against the raw device from P1, a `0400` root-only
keyfile, an `/etc/crypttab` entry keyed by LUKS UUID, and an `/etc/fstab` entry
for `/dev/mapper/*`. This exact sequence is the one proven above. Both layers of the
R1 mitigation land here: `RequiresMountsFor=` on each unit, and an
`ExecStartPre` asserting the path is a mountpoint backed by the expected
`/dev/mapper` device.
**Serves.** AC-1, AC-4.
**Done when.** `make test_at_rest` passes — including its negative case, where a
service with its volume unmounted **refuses to start** — and a node rebooted by
the existing softdog fencing scenario unlocks and rejoins with no operator
action.

### P3 — PKI

**What.** A lab CA and four certificates per node.
**How.** Port `generate-pki.sh` into `scripts/generate-pki.sh`, run after `.env`
exists so IP SANs are current. All material lands in `.secrets/pki/`, **not** the
sibling lab's `generated/` — `.secrets/` is already ignored wholesale, whereas
`.gitignore` covers `*.key` but not `*.crt`, so a `generated/` layout would make
certificates committable to a public repository. Ship each node only `ca.crt`
plus its own four identities. SANs carry FQDN, short name, `localhost`, the node IP and
`127.0.0.1` — `localhost` because Patroni's own control connection uses it. The
ported script keeps its `.spec` file per identity, which reissues a certificate
whenever its requested SANs change; Lima can hand out different addresses after
a rebuild, and a stale IP SAN fails `VerifyFull` in a way that reads like a
cluster fault rather than a certificate one.
**Serves.** AC-2, AC-3 (prerequisite for both).
**Done when.** Every certificate verifies against the CA with the expected EKU
and SANs, and no `ca.key` exists on any guest.

### P4 — TLS on etcd and Patroni

**What.** Channels 4–7: etcd client and peer, Patroni→etcd, Patroni REST — all
mutual.
**How.** etcd `--peer-*` and client TLS flags with `--client-cert-auth` and
`--peer-client-cert-auth`; Patroni `etcd3:` gains `protocol: https` plus its
`-dcs-client` pair; `restapi:` and **`ctl:`** both gain certificates in the same
change. `ctl:` is not optional housekeeping: every Lab 1 test script drives the
cluster through `patronictl`, so the moment the REST API requires a client
certificate, all of them break at once until `ctl:` is configured. `etcdctl`
needs the same treatment: `--client-cert-auth` makes every bare `etcdctl
endpoint health` in `start-etcd.yml` and `verify.yml` fail until each call passes
`--cacert`, `--cert` and `--key`.
**Serves.** AC-2, AC-3.
**Done when.** Plaintext is refused on 2379, 2380 and 8008, and a client with
no certificate is refused on each. etcd additionally negotiates TLS 1.3 and
rejects TLS 1.2, via `tls-min-version`. The Patroni REST API gets mutual TLS but
no version floor: Patroni exposes `cafile`, `certfile`, `keyfile`, `ciphers` and
`verify_client`, and no minimum-version setting, so pinning it is not available
rather than merely unset. PostgreSQL's floor arrives in P5, but at
TLSv1.2 rather than 1.3: .NET on macOS cannot negotiate TLS 1.3 at all, so
pinning 1.3 would break the client this lab exists to exercise.

### P5 — TLS on PostgreSQL and the client

**What.** Channels 1–3: application, streaming replication, Patroni's local
connection.
**How.** `ssl: "on"` plus certificate paths in the Patroni DCS parameters;
`pg_hba` rewritten so every non-local rule is `hostssl`; the client moves to
`SSL Mode=VerifyFull` with `Root Certificate=`. `test-client.sh` changes in the
same commit, because it asserts the expected connection-string values and would
otherwise fail on the old `SSL Mode=Disable`.
**Serves.** AC-2, AC-3.
**Done when.** A `SSL Mode=Disable` connection is refused, `pg_stat_ssl` confirms
the client's own session is encrypted, and a wrong CA fails closed.

### P6 — Verification

**What.** `test_at_rest`, `test_in_transit`, `test_identity`, wired into
`run-all.sh` and the Makefile.
**How.** Same conventions as Lab 1's scripts: one concern per script, a summary
line per assertion, non-zero exit on failure.
**Serves.** All four, by making them executable rather than aspirational.
**Done when.** `make all` reports every phase green from scratch, twice.

## Order, and why

```text
P0 fork ──► P1 volumes ──► P2 LUKS ──► P6 test_at_rest        (AC-1)
                  │
                  └──────► P3 PKI ──► P4 etcd/Patroni TLS ──► P5 PostgreSQL TLS ──► P6 (AC-2, AC-3)
```

Volumes precede LUKS because encrypting a device is easier than moving a
populated one. At-rest precedes in-transit because it has fewer moving parts and
a broken volume is obvious, whereas a broken certificate can silently downgrade.
etcd and Patroni precede PostgreSQL because Patroni owns PostgreSQL's
configuration: with the control plane already trusted, a PostgreSQL TLS mistake
is diagnosable instead of locking us out of both at once.

Nothing here is a migration. `make all` always builds from empty, so each phase
configures TLS or LUKS at first boot rather than converting a running cluster.

## Risk

One item qualifies. A risk is uncertain, and its consequence is not obvious when
it happens. Everything else that could go wrong here is either a certainty —
handled as a task in the phase that causes it — or a limitation deliberately
accepted, and both are recorded where they belong rather than padding a register
that should hold the things worth watching.

**R1. A service starts with its data volume unmounted, initialises an empty
directory over the mountpoint, and reports healthy.**

This is the only failure here that is silent. Patroni would `initdb` onto the
root filesystem, join the cluster, and pass every existing check while the real
data sat unopened on an encrypted volume nobody mounted.

Two layers, because the obvious one has a hole:

| Layer | Catches | Misses |
| --- | --- | --- |
| `RequiresMountsFor=` on the etcd and Patroni units | A mount that **fails** — a missing keyfile, an unopened LUKS device, a corrupt filesystem | A mount that was never **configured**. With no mount unit for the path, the directive is a no-op |
| `ExecStartPre` asserting the path is a mountpoint on the expected `/dev/mapper` device | A mount that is silently **absent**, which is the case layer 1 cannot see | — |

Both are assertions until something tests them, so `test_at_rest` carries a
negative case: unmount the volume, attempt to start the service, and require it
to **refuse**. A green suite that has never seen the failure it guards against
proves only that the failure has not happened yet.

Availability regressions from encryption — slower unlock, slower fsync, longer
failover — need no separate entry, because AC-4 already runs the whole Lab 1
suite after every phase rather than once at the end.

## Carried into Lab 3

Backups are Lab 3, and it will use MinIO as the repository. Two decisions from
this phase already accommodate that, recorded so they are not rediscovered:

- **One CA, extended.** Lab 3 issues a `minio` identity from this same CA rather
  than standing up a second one; `generate-pki.sh` needs one more `sign_cert`
  call and the `.spec` reissue mechanism covers it. This is what the sibling lab
  does, and it is why P3 was built around per-purpose identities rather than one
  certificate per node.
- **MinIO can run on the control machine, not a fourth VM.** The sibling lab's
  MinIO certificate carries `DNS:host.lima.internal` and `IP:192.168.105.1` --
  the macOS side of Lima's shared network -- so the nodes reach an object store
  on the host. That avoids the resource pressure that ruled out a Tang server
  here.

Lab 3 then has both halves of the backup story: TLS in transit to the object
store, and `repo1-cipher-type=aes-256-cbc` for the repository at rest, which is
the gap left open when backups were scoped out of Lab 2.

Restoring from that repository is **Lab 4**, deliberately not Lab 3. Lab 3 can
go green on evidence that taking a backup works — a repository that accepts
writes, a passing `pgbackrest check`, a valid backup set — none of which is
evidence that the backup can be restored. Keeping recovery in its own lab stops
the first from being read as the second.

## What the build changed

Each phase landed, but four things turned out differently from the plan. They
are recorded because the reasoning matters more than the plan being right.

| Planned | Actual |
| --- | --- |
| A TLS 1.3 floor on every endpoint | Patroni's REST API exposes no minimum-version setting, so 8008 cannot be pinned. etcd and PostgreSQL are at 1.3 |
| The client stays on the host, as in Lab 1 | Moved to `lab2-app1`. .NET on macOS uses Apple's TLS stack, which does not implement TLS 1.3, so PostgreSQL could not be pinned above 1.2 while the client lived there |
| Three VMs | Four. The application host is the direct consequence of the row above, and it makes the failover tests cross the same network and rules as a real client |
| `RequiresMountsFor=` alone would stop a service starting without its volume | It pulls the mount unit in, so systemd repairs the mount and starts normally. The guard is the `ExecStartPre` check, and the property worth asserting is that the service never runs on the wrong device, not that it refuses to start |

### The etcd first-bootstrap race

etcd's first start could fail and never recover, leaving every retry dying on
`member <id> has already been bootstrapped`. Seen once in seven from-scratch
builds.

An earlier version of this document blamed a half-initialised local data
directory and recovered by deleting it. **That was wrong, and the recovery
could not have worked.** The error comes from etcd's `isMemberBootstrapped`,
which asks the *remote peers* whether this member is already known. It is not a
check on local disk, so deleting this node's `member/` directory cannot change
the answer the peers give. The repair was aimed at the wrong subject, which is
why it was never once observed to fix a real occurrence.

Re-reading Percona's etcd guidance and the sibling lab
(`../percona-patroni-npgsql-lab`) against ours found three real differences:

| | Percona / sibling | Lab 2 before |
| --- | --- | --- |
| Start order | "Try starting all nodes again **at the same time**"; the sibling starts all three in parallel | `strategy: free`, which removes the barrier and lets the three starts drift apart |
| Data directory | The sibling wipes it before every start | Never cleared before the start |
| Retry budget | The sibling retries once, host-orchestrated, after a 3s pause | Left to `Restart=on-failure` with systemd's 100ms default and `StartLimitBurst=5` -- the entire budget spent in half a second, long before three VMs can complete a peer handshake |

`strategy: free` is a real defect: Percona is explicit that a first start may
fail on a quorum timeout and that simultaneity is the remedy, and the free
strategy guaranteed the opposite. Calling it *the* cause would be a claim the
evidence does not support — see the teardown bug below, which is established and
was found only by running the builds. Four changes followed:

1. `strategy: free` removed, so all three nodes reach the start task together.
2. `RestartSec=5` with a bounded `StartLimitBurst=12` over 120s, so a first
   failure is survivable instead of terminal — still bounded, so a genuinely
   broken node surfaces as a failed unit rather than restarting for ever.
3. The member directory is cleared *before* a first bootstrap, as the sibling
   does, so `initial-cluster-state: new` is true when we assert it.
4. Recovery re-forms **all three** members from empty simultaneously, rather
   than trying to repair one node. Since the survivors are what report the
   wedged node as already bootstrapped, repairing it alone is not possible.

Every destructive branch is gated on one discriminator: no node holds a
PostgreSQL data directory. Patroni's state in etcd is meaningless until
PostgreSQL is initialised, so when that holds there is nothing in etcd worth
preserving. Verified against a live cluster before the code could run
destructively — the play reported *"Existing cluster: etcd data will not be
touched"*, `changed=0`, with all seven destructive tasks skipped.

### The recovery, finally exercised

The previous recovery was never once observed repairing a real occurrence, and
an earlier attempt at a positive control was invalid because it staged a state
that cannot arise here. Both are now resolved.

The reason the earlier attempt failed is worth keeping. `isMemberBootstrapped`
asks the peers, and a peer reports a member as bootstrapped only once that member
has **published its client URLs** — which requires it to have started
successfully at least once. Starting a fresh node beside a running cluster
therefore does *not* reproduce the error. The member must first join and publish,
then lose its member directory.

Staged exactly that — all three formed and publishing, then `pg1` stopped, its
member directory removed, and restarted with `initial-cluster-state: new`:

```text
members with published URLs: 3
pg1 etcd state: activating
'has already been bootstrapped' occurrences: 3
WEDGE REPRODUCED
recovery branch FIRED
PASS: etcd recovered and quorum is healthy
```

The wedge is reproduced first and the run aborts if it is not, so a green result
cannot come from a cluster that was never broken. The recovery then re-formed all
three members and quorum returned.

Both controls now hold: the recovery fires and repairs a genuine reproduction of
the failure, and refuses to act on a live cluster.

That flag is deliberately a string comparison rather than a boolean. `set_fact`
does not dependably coerce templated booleans, and the failure is asymmetric: a
mis-typed comparison would count zero initialised nodes, make first-bootstrap
come out true on a live cluster, and wipe its etcd.

### A teardown bug that made "from scratch" untrue

Running seven consecutive from-scratch builds to measure the rate found a
separate and more consequential defect. Build 7 failed, and `make clean` was the
cause:

```text
cannot delete disk `lab2-pg3-pgdata` in use by instance `lab2-pg3`
make: *** [clean] Error 1
```

`limactl delete --force` returns before Lima has released its reference to the
instance's disks, so the immediately following `disk delete` can still fail.
Lima disks outlive their instance, so the disk survived, the next `make all`
reattached it, and the "fresh" build came up holding the **previous run's
PostgreSQL and etcd data**. Confirmed directly: on that build `pg3` had 34
entries in its data directory before Patroni had ever run, while `pg1` and `pg2`
were empty.

Two things made this invisible:

- The teardown already had a check for surviving disks, but `set -e` aborted the
  script on the first failed delete, before that check could report. The
  deletion is now non-fatal so the explicit check is what speaks.
- `make clean` failing was not obviously fatal to the *next* build, because the
  next build appeared to succeed at creating VMs.

Fixed by retrying the delete and calling `limactl disk unlock` between attempts
to clear the stale reference, then letting the existing check fail loudly if
anything survives. Verified against the exact stale state: six disks, four
running VMs, all deleted, exit 0.

This is also why only Lab 2 ever showed the problem. Lab 1 attaches no
independent Lima disks — its storage is the instance's own disk, which is
deleted with the instance — so it has no equivalent exposure.

**What this does and does not explain.** The teardown bug is established, with
logs. It is *not* established that it caused the original one-in-seven failure,
and the signatures differ: build 7 failed with an unformable cluster and
`connection refused`, never once logging "already been bootstrapped", whereas
the original did log exactly that. They are two distinct faults. Both are now
fixed; only one of them is fully understood.

**Result after the fixes.** Seven further from-scratch builds: six green, one
failure, and that failure was the softdog fencing check rather than anything in
this area — the fence worked (boot id changed) but no leader was elected inside
the 90s budget. Across both loops that check has failed once in ten. Zero
teardown failures and zero occurrences of "already been bootstrapped" in any of
the seven.

Seven clean bootstraps do not prove a one-in-seven race is gone; they are
consistent with it being gone and would also be consistent with bad luck. The
evidence that carries weight is the reproduction above, where the failure is
staged deliberately and the recovery is watched repairing it.

**Lab 1 took the same fix.** It had the identical `strategy: free` and the same
untuned restart budget, so it carried the same exposure even though the failure
was only ever seen here. Validated with one from-scratch build — 10 of 10, clean
bootstrap — which is the right amount of evidence for the question it answers:
whether the rewritten playbook works against Lab 1's own variables, paths and
topology. Measuring a rate was Lab 2's job and is already done.

### SELinux Enforcing was a coincidence, not a setting

`verify.yml` had asserted SELinux was Enforcing since P4, and it passed seven
consecutive builds. On the eighth it failed on two nodes of three, reporting
Permissive.

The uptimes explained it. All three read Enforcing when inspected afterwards, but
the two that had failed were up one and two minutes while the third was up
eighteen -- the fencing checks had rebooted them *after* verify ran. The Rocky
cloud image reaches Enforcing only after its first-boot relabel and the reboot
that follows, so whether a build finds it Enforcing depends on timing. Nothing in
either lab ever *set* it.

`cluster_config` now runs `restorecon` over the paths the lab creates and then
`setenforce 1`, before any service starts. Order matters: enforcing over
unlabelled files would deny the services their own data directories, and here
those are freshly created filesystems on the LUKS volumes, which carry no labels
until `restorecon` runs. The rebuild showed the task doing real work -- `changed`
on two nodes, `skipped` on the one already Enforcing, the same two-of-three split
as the failure.

Lab 1 asserted nothing about SELinux at all, so it could have been running
Permissive throughout with nothing to say so. It now sets and asserts it too.

Two further bugs were found only by building from empty rather than iterating on a
running cluster: `/etc/lab2` was created `0700` as a side effect of the LUKS key
directory, so every service was denied its certificates with a "permission
denied" that looked exactly like SELinux; and the Rocky image ships no `libicu`,
without which .NET aborts before `Main`. Self-contained publishing removes the
need for a runtime, not for system libraries.

## Traceability

| Criterion | Built in | Proven by |
| --- | --- | --- |
| AC-1 at rest | P1, P2 | `make test_at_rest` |
| AC-2 in transit | P3, P4, P5 | `make test_in_transit` |
| AC-3 identity | P3, P4, P5 | `make test_identity` |
| AC-4 availability | every phase | `make check` — Lab 1's ten checks, unchanged |
