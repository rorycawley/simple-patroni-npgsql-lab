# Lab 3: durable backups

> **Status: specified, not built.** Everything below is the design and its
> acceptance criteria. No results are claimed.

The shared components, cluster design and prerequisites are in the
[top-level README](../README.md). This file covers Lab 3 only.

## Goal

Move the backup repository off the database hosts, encrypt it, reach it over
TLS, and keep it working while the primary moves — with **two** kinds of backup,
because they recover different disasters.

## Why both pgBackRest and pg_dump

Not redundancy. They fail differently and they recover differently, and holding
only one leaves a real gap.

| | pgBackRest — physical | `pg_dump` — logical |
| --- | --- | --- |
| Unit of recovery | The whole cluster | A single table, schema or database |
| Point-in-time recovery | Yes, via WAL replay | No — one instant per dump |
| Cost of using it | Everything committed after the target is discarded | Nothing else is touched |
| Portable across major versions | **No** — version-locked | Yes |
| Speed to take | Fast, scales to large data | Slow, and the restore is slower still |
| Reads through the SQL layer | No | **Yes** |

That last row is the one that matters most, and it is the argument for keeping
both:

> A physical backup will faithfully back up corruption. A logical dump cannot.

pgBackRest copies bytes. If a page is corrupt, the corruption is preserved and
restored exactly. `pg_dump` reads every row through PostgreSQL's own executor, so
a dump that *completes* is evidence the data is readable, not merely that bytes
were copied. One is a backup; the other doubles as a verification pass.

The second argument is blast radius. Recovering a dropped table from a physical
backup means restoring the whole cluster to a point in time and discarding
everything committed since — the cost [Lab 7](../README.md) has to measure. A
logical dump restores that one table and touches nothing else.

The third is escape. A physical backup is useless for moving to a new major
version or a different platform. `pg_dump` is the migration path when the answer
is "get the data out of here".

## Scope

| In scope | Out of scope |
| --- | --- |
| A pgBackRest repository on MinIO, off the database hosts | Restoring from it — that is [Lab 4](../README.md) |
| `pg_dump` of `appdb`, scheduled and stored in the same repository | Cross-region or offsite replication of the repository |
| Repository encryption (`repo1-cipher-type=aes-256-cbc`) and TLS to MinIO | A second, independent repository |
| Backups and WAL archiving that survive a failover | Backup of etcd — see below |
| Full and incremental backups, with retention | Tuning for databases large enough to need parallel restore |

**etcd is deliberately not backed up.** It holds cluster state Patroni can
rebuild — leader keys, member lists, the sync set. What cannot be rebuilt is the
PostgreSQL data, and that is what this lab protects. Backing up a leader key
would restore a lie.

## Where the repository lives

MinIO on the control machine, reached at the Lima shared-network gateway. Two
decisions already recorded in [`lab2/PLAN.md`](../lab2/PLAN.md) exist to make
this cheap: MinIO gets a `minio` identity from the **same CA**, and it runs on
the host rather than a fourth VM, which is what avoids the resource pressure that
ruled out a Tang server in Lab 2.

The repository is encrypted independently of the transport. TLS protects it in
flight; `repo1-cipher-pass` protects it at rest, including from whoever
administers the object store. See
[`SERVICE-ACCOUNTS.md`](../SERVICE-ACCOUNTS.md) — that passphrase is the one
secret whose loss cannot be recovered from, because the backups needed to recover
it are the ones it encrypts.

## Backups in a cluster that fails over

This is what makes it Lab 3 rather than a pgBackRest tutorial. Three problems a
single-node guide never raises:

**Only one node may run the backup.** A timer on all three nodes takes three
backups. The job must check with Patroni first and exit quietly unless this node
is the leader.

**`archive_command` follows the primary.** WAL archiving runs wherever the
primary currently is, so all three nodes need the configuration and the
repository credentials — and after a promotion, the new primary must continue
archiving into the same stanza without a gap.

**`pg_dump` has nowhere comfortable to run.** On the primary it competes with the
application. On a standby it can be cancelled mid-dump by a recovery conflict,
because replaying WAL invalidates rows the dump is still reading. Setting
`hot_standby_feedback = on` prevents that and moves the cost to the primary as
table bloat. Both are defensible; picking silently is not.

## Acceptance criteria

| ID | Property | Pass condition |
| --- | --- | --- |
| AC-1 | The repository survives the cluster | Backups live on MinIO, not on any database host; destroying any node leaves the repository complete |
| AC-2 | Both kinds of backup succeed and are self-consistent | A full and an incremental pgBackRest backup pass `pgbackrest verify`, and a `pg_dump` of `appdb` completes and reloads into a scratch database |
| AC-3 | The repository is encrypted at rest and in transit | Objects in MinIO are unreadable without `repo1-cipher-pass`; a plaintext connection to MinIO is refused |
| AC-4 | Backups survive a failover | Force a promotion mid-cycle: the new primary continues archiving into the same stanza, `pgbackrest check` passes, and the WAL sequence has no gap |
| AC-5 | Exactly one backup runs per cycle | With the timer enabled on all three nodes, one backup is taken; the two non-leaders exit without touching the repository |

### AC-2 is doing more work than it looks

Reloading the dump into a scratch database is not a restore rehearsal — that is
Lab 4. It is the cheapest available proof that the dump is **readable**, which is
the property `pgbackrest verify` cannot give, because verifying checksums
confirms the bytes are intact and says nothing about whether PostgreSQL can parse
what they contain.

### AC-4 is the one a single-node guide would miss

Archiving is a property of the primary, and the primary moves. A backup regime
that works until the first failover and then silently stops is the exact shape of
failure [Lab 8](../lab8/README.md) exists to detect — and the reason its headline
metric is the age of the last successful backup rather than any error count.

## What this lab does not claim

That any of it can be restored. A repository that accepts writes, passes
`pgbackrest check` and reports a valid backup set is evidence that *taking* a
backup works. Whether the result can rebuild a working cluster is
[Lab 4](../README.md), and keeping them apart is what stops the first result
being read as the second.
