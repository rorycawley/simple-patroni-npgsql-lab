# Lab 2: encrypted at rest and in transit

> **Status: built and verified.** `make all` reports every check green from
> scratch. Where the result differs from the original plan the reason is stated
> below rather than the plan quietly rewritten.

The shared components, cluster design, failover semantics and prerequisites are
in the [top-level README](../README.md). This file covers Lab 2 only: what it
adds over [Lab 1](../lab1/README.md), and how that is proven.

## Goal

Lab 1 proves a three-node Patroni cluster survives node loss, process death and
split brain without losing an acknowledged transaction. It does so on an
unencrypted disk and an unencrypted network, and says so: *"Run it only on an
isolated, trusted lab network."*

Lab 2 keeps every Lab 1 guarantee and removes both assumptions for the database
and its cluster state: unreadable to anyone holding those volumes, and unreadable
to anyone on the wire between components.

## Scope

| In scope | Out of scope |
| --- | --- |
| LUKS2 encryption of the PostgreSQL and etcd data volumes, on separate devices | Encrypting the root filesystem |
| Key material held in a root-only keyfile on each node | KMS, HSM, TPM or network-bound unlock (Tang/Clevis) |
| A private CA issuing per-purpose certificates at build time | Public PKI, certificate rotation, revocation, OCSP |
| TLS on every channel below, mutual where the peer is a machine | Client authentication by certificate for the application (SCRAM inside TLS) |
| The application on its own VM, so it crosses the network like a real client | Hardening the application as a service; it is invoked per test, not long-running |
| — | Backups. pgBackRest is carried over from Lab 1 unchanged, and its local repository is left as it is; encrypting it and moving it off the database hosts are Lab 3, and restoring from it is Lab 4 |

Everything Lab 1 asserts about failover, fencing, quorum commit and the client's
configured limits is inherited unchanged and re-run here. It is documented in the
[Lab 1 guide](../lab1/README.md) rather than repeated.

## Data at rest

Every location cluster data comes to rest, and what protects it:

| Data | Location | Mechanism |
| --- | --- | --- |
| PostgreSQL relations, WAL, temp files | `/var/lib/pgsql` | LUKS2 volume, own device |
| etcd Raft log and cluster state | `/var/lib/etcd` | LUKS2 volume, own device |
| Server private keys | `/etc/lab2/pki` on each node | `0600`, owned by the service user |
| CA private key | `.secrets/pki/` on the control machine | Never copied to a guest; the directory is not tracked |

Separate devices are not only about encryption. etcd is fsync-latency sensitive:
sharing a device with PostgreSQL lets its Raft commits queue behind checkpoint
and WAL I/O, which expires the leader lease and causes failover on a healthy
cluster.

## Data in transit

Every channel that carries cluster data. Each fails closed — plaintext is
refused, not downgraded to.

| # | Client | Server | Port | Server certificate | Client certificate |
| --- | --- | --- | --- | --- | --- |
| 1 | Npgsql application on `lab2-app1` | PostgreSQL | 5432 | `<node>-postgres` | none — SCRAM |
| 2 | Standby streaming replication | Primary PostgreSQL | 5432 | `<node>-postgres` | none — SCRAM |
| 3 | Patroni | PostgreSQL | 5432 | `<node>-postgres` | none — SCRAM |
| 4 | Patroni | etcd client API | 2379 | `<node>-etcd` | **`<node>-dcs-client`** |
| 5 | `etcdctl` | etcd client API | 2379 | `<node>-etcd` | **`<node>-etcd`** |
| 6 | etcd member | etcd peer API | 2380 | `<node>-etcd` | **`<node>-etcd`** |
| 7 | `patronictl` and Patroni | Patroni REST API | 8008 | `<node>-patroni` | **`<node>-patroni`** |

Rows in **bold** are mutual TLS. Rows 1–3 carry a password inside the tunnel
instead, because the peer is a person or an application, not a machine identity.

Two independent controls make row 1 safe, and neither implies the other:

```text
server side   pg_hba.conf uses hostssl     -> a plaintext connection is refused
client side   SSL Mode=VerifyFull          -> an unverified server is refused
```

Certificates carry both DNS and IP subject alternative names, because the client
connects by address. Under `VerifyFull` nothing but an `IP Address:` SAN can
satisfy verification of an address.

Protocol floors vary by what each component supports, which is worth stating
rather than implying uniformity:

| Channel | Floor | Why |
| --- | --- | --- |
| etcd client and peer | TLS 1.3 | `tls-min-version`; only Patroni and `etcdctl` talk to it |
| PostgreSQL | TLS 1.3 | `ssl_min_protocol_version`, reachable only because the client is on Linux |
| Patroni REST API | none | Patroni exposes `cafile`, `certfile`, `keyfile`, `ciphers` and `verify_client`, and no minimum-version setting |

## The client

Identical to Lab 1's, including its retry budget and its refusal to reissue an
uncertain write, with two settings changed:

| Setting | Lab 1 | Lab 2 |
| --- | --- | --- |
| `SSL Mode` | `Disable` | `VerifyFull` |
| `Root Certificate` | — | the lab CA, installed at `/etc/lab2/client/ca.crt` |

`VerifyFull` rather than `Require` is the whole point. `Require` encrypts but
accepts any certificate, so it stops eavesdropping and not impersonation.
`VerifyFull` checks the chain against the lab CA *and* that the name matches.

## Acceptance criteria

| ID | Property | Command | Pass condition |
| --- | --- | --- | --- |
| AC-1 | The database and cluster state are encrypted at rest | `make test_at_rest` | `/var/lib/pgsql` and `/var/lib/etcd` are distinct `crypto_LUKS` devices, and neither is on the root filesystem |
| AC-2 | Data in transit is encrypted | `make test_in_transit` | Every channel above negotiates TLS, and a plaintext attempt against each is refused |
| AC-3 | Peer identity is verified | `make test_identity` | The client fails closed against a wrong CA and against a mismatched address, and recovers when the correct CA is restored; mutual-TLS channels reject a client presenting no certificate |
| AC-4 | Encryption does not weaken availability | `make check` | Every Lab 1 check still passes, and a node that reboots unlocks its volumes and rejoins unattended |

`make test_pki` supports AC-2 and AC-3 by asserting the certificates themselves —
that each carries the right subject, EKU and SANs — before any of them is used on
a live connection.

AC-4 is the one that matters most. Encryption that survives a healthy cluster but
breaks recovery is worse than none: a node whose volume does not unlock after a
watchdog reset never rejoins, and a service that starts *without* its volume
mounted will initialise an empty data directory over the mountpoint.

## Topology

Four VMs. Three cluster nodes as in Lab 1, plus a host for the application.

| VM | Hostname | Role | Additional disks |
| --- | --- | --- | --- |
| `lab2-pg1/2/3` | `pg1/2/3.lab2.example` | PostgreSQL, Patroni, etcd | `pgdata` 10G, `etcd` 5G — each LUKS2 |
| `lab2-app1` | `app1.lab2.example` | The .NET client | none |

The client runs in a VM rather than on the host for two reasons. It crosses the
same network, firewall and `pg_hba` rules as any real client, so the failover
tests prove something closer to production. And .NET on macOS uses Apple's TLS
stack, which does not implement TLS 1.3 at all — while the client lived on the
host, PostgreSQL could not be pinned above TLS 1.2.

The macOS gateway address stays permitted on 5432 for `psql` debugging, since
OpenSSL negotiates TLS 1.3 where .NET on macOS cannot.

Lima disks are independent objects that outlive their instance, so teardown
deletes the VMs first and then the disks.

## Run

```sh
make all      # build, then run every check and report
make clean    # destroy the VMs, their disks, and all generated material
```

From an empty machine:

```
==============================================================================
 Lab 2 results
==============================================================================
 PASS  Create the four Lima VMs                                          3m18s
 PASS  Install and configure the Patroni cluster                         1m59s
 PASS  Cluster services, quorum, replication, pgBackRest                    4s
 PASS  Encryption at rest: LUKS2 volumes, and a missing one stops the service      45s
 PASS  PKI: certificates assert the right identities                        1s
 PASS  Encryption in transit: every channel, plaintext refused              2s
 PASS  Identity: verification fails closed on a wrong CA                    1s
 PASS  Criterion 1: client connects to the primary and queries it           1s
 PASS  Client guarantees: pool limit, timeouts, no blind retry             16s
 PASS  Quorum commit: configured, blocking, and lossless                 1m00s
 PASS  Criterion 2: failover after the primary VM is lost                  57s
 PASS  Criterion 2: failover after PostgreSQL is killed                    12s
 PASS  Split brain: softdog fences a frozen Patroni                        37s
 PASS  Split brain: Patroni demotes itself without etcd                    57s
------------------------------------------------------------------------------
 14 passed, 0 failed, total 10m11s
==============================================================================
```

The four encryption checks sit above the Lab 1 ones deliberately: if the cluster
is not encrypted there is little point asking whether it fails over correctly.

That block is one run. Across seven consecutive from-scratch builds the aggregate
is less uniform, and worth stating rather than leaving a single green result to
imply reliability:

| Criterion | Checks | Result |
| --- | --- | --- |
| AC-1 at rest | `test_at_rest` | 7 / 7 |
| AC-2 in transit | `test_in_transit`, `test_pki` | 7 / 7 |
| AC-3 identity | `test_identity` | 7 / 7 |
| AC-4 availability | every Lab 1 check | **6 / 7** |

The single failure was `test_fencing_patroni`: the fence itself worked — the node
reset and its boot id changed — but no new leader was elected inside the 90s
budget. Roughly one in ten across all runs to date. Whether encryption
contributes is not established: the failure has no obvious link to LUKS or TLS,
and Lab 1 passes the same check unencrypted, but one comparison run is not
evidence. That path now emits full diagnostics on failure, so the next occurrence
produces something to work from.

### Individual phases

```sh
make create_vms         # create missing VMs and their LUKS disks, start existing ones
make configure_cluster  # PKI, encrypted volumes, cluster, app host
make verify_cluster     # every service, plus an Npgsql read-write probe
make test_at_rest       # AC-1
make test_in_transit    # AC-2
make test_identity      # AC-3
make test_pki           # the certificates themselves
make check              # AC-4: everything above plus every Lab 1 check
```

The Lab 1 checks — `test_connection`, `test_client`, `test_sync`,
`test_failover`, `test_fencing` — exist here under the same names and assert the
same things; see the [Lab 1 guide](../lab1/README.md#acceptance-criteria).

The [Ansible guide](ansible/README.md) covers what the configuration applies and
the network policy it installs. [`PLAN.md`](PLAN.md) records how this lab was
built, the risks it had to mitigate, and what was carried into Lab 3.
