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
**Done when.** Plaintext is refused on 2379, 2380 and 8008, a client with no
certificate is refused on each, and every endpoint negotiates TLS 1.3 while
rejecting TLS 1.2 with a protocol-version alert.

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

## Traceability

| Criterion | Built in | Proven by |
| --- | --- | --- |
| AC-1 at rest | P1, P2 | `make test_at_rest` |
| AC-2 in transit | P3, P4, P5 | `make test_in_transit` |
| AC-3 identity | P3, P4, P5 | `make test_identity` |
| AC-4 availability | every phase | `make check` — Lab 1's ten checks, unchanged |
