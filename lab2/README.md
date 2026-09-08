# Lab 2: encrypted at rest and in transit

> **Status: specification.** Nothing in this directory is implemented yet. The
> tables below define what will be built and how it will be proven.

## Goal

[Lab 1](../lab1/README.md) proves a three-node Patroni cluster survives node
loss, process death and split brain without losing an acknowledged transaction.
It does so on an unencrypted disk and an unencrypted network, and says so: *"Run
it only on an isolated, trusted lab network."*

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
| — | Backups. pgBackRest is carried over from Lab 1 unchanged, and its local repository is left as it is; encrypting it, moving it to a dedicated host and rehearsing restore are all Lab 3 |

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
| 1 | Npgsql application | PostgreSQL | 5432 | `<node>-postgres` | none — SCRAM |
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
connects by address.

## Acceptance criteria

| ID | Property | Command | Pass condition |
| --- | --- | --- | --- |
| AC-1 | The database and cluster state are encrypted at rest | `make test_at_rest` | `/var/lib/pgsql` and `/var/lib/etcd` are distinct `crypto_LUKS` devices, and neither is on the root filesystem |
| AC-2 | Data in transit is encrypted | `make test_in_transit` | Every channel above negotiates TLS, and a plaintext attempt against each is refused |
| AC-3 | Peer identity is verified | `make test_identity` | The client fails closed against a wrong CA and against a mismatched address, and recovers when the correct CA is restored; mutual-TLS channels reject a client presenting no certificate |
| AC-4 | Encryption does not weaken availability | `make check` | Every Lab 1 check still passes, and a node that reboots unlocks its volumes and rejoins unattended |

AC-4 is the one that matters most. Encryption that survives a healthy cluster but
breaks recovery is worse than none: a node whose volume does not unlock after a
watchdog reset never rejoins, and a service that starts *without* its volume
mounted will initialise an empty data directory over the mountpoint.

## Topology

Three VMs, as in Lab 1, each with two additional disks.

| VM | Role | Additional disks |
| --- | --- | --- |
| `lab2-pg1/2/3` | PostgreSQL, Patroni, etcd | `pgdata` 10G, `etcd` 5G — each LUKS2 |

Lima disks are independent objects that outlive their instance, so teardown
deletes them explicitly.

## Run

```sh
make all      # build, then run every check and report
make clean    # destroy the VMs, their disks, and all generated material
```
