# Lab 3: durable backups

> **Status: specified, not built.** Everything below is the design and its
> acceptance criteria. No results are claimed.

The shared components, cluster design and prerequisites are in the
[top-level README](../README.md). This file covers Lab 3 only.

## Goal

Move the backup repository off the database hosts, encrypt it, reach it over
TLS, and keep it working while the primary moves — with **two** kinds of backup,
because they recover different disasters.

## What each one is for

They are not two backup systems. They do different jobs, and only one of them is
the disaster recovery mechanism.

**pgBackRest is the disaster recovery system.** It backs up the whole cluster
byte for byte and archives WAL continuously, so it can rebuild everything from
nothing and can wind the cluster back to any moment it holds WAL for. If only one
of the two existed, it would be this one.

**`pg_dump` is a scalpel and a canary.** It is not a second disaster recovery
system — it cannot do point-in-time recovery, and restoring a large database from
a dump is slow. It earns its place by doing two things pgBackRest cannot:
recover *one table* without disturbing anything else, and prove the data is
**readable** rather than merely present.

Which to reach for:

| Situation | Instrument | Where |
| --- | --- | --- |
| Every node lost | pgBackRest — full restore | [Lab 4](../lab4/README.md) |
| The cluster must be wound back before a bad change | pgBackRest — PITR to a marker | [Lab 6](../lab6/README.md) |
| One table mangled, everything else fine | `pg_dump` of that table | [Lab 6](../lab6/README.md) |
| "Is the data actually readable?" | a `pg_dump` that completes | this lab, AC-2 |
| Moving to a new major version | `pg_dump` | out of scope |

The middle row is the one that justifies the extra machinery. Recovering a
dropped table from a physical backup means restoring the whole cluster to a point
in time and discarding **everything committed since**. A logical dump of that one
table costs nothing else.

### Why the canary matters

| | pgBackRest — physical | `pg_dump` — logical |
| --- | --- | --- |
| Unit of recovery | The whole cluster | A single table, schema or database |
| Point-in-time recovery | Yes, via WAL replay | No — one instant per dump |
| Cost of using it | Everything committed after the target is discarded | Nothing else is touched |
| Portable across major versions | **No** — version-locked | Yes |
| Speed to take | Fast, scales to large data | Slow, and the restore is slower still |
| Reads through the SQL layer | No | **Yes** |

That last row is the important one:

> A physical backup will faithfully back up corruption. A logical dump cannot.

pgBackRest copies bytes. A corrupt page is preserved exactly and restored
exactly. `pg_dump` reads every row through PostgreSQL's own executor, so a dump
that *completes* is evidence the data can still be read — which is why the dump
doubles as a verification pass over the same data pgBackRest is copying blind.

## Where each kind of backup is stored

One MinIO bucket, two prefixes, because they are managed by different things:

```text
s3://lab3-backups/pgbackrest/   pgBackRest owns this entirely
s3://lab3-backups/dumps/        written and expired by the lab's own job
```

A pgBackRest repository is a structured store it manages itself — backup sets,
the WAL archive, manifests, `backup.info` — and it is not a place to drop
arbitrary files. Dumps therefore need their own prefix, outside `repo1-path`, so
pgBackRest's retention and `expire` can never see or reap them.

One bucket rather than two keeps it to a single endpoint, credential and CA,
which is less to configure and less to get wrong.

### The dumps must be encrypted separately

This is the part that is easy to miss. pgBackRest encrypts its own repository
with `repo1-cipher-pass`, and that protection **does not extend to anything
written outside it**. A dump uploaded as it comes out of `pg_dump` would sit in
the same bucket in plaintext, readable by whoever administers the object store —
defeating the property AC-3 exists to establish, for half the data.

Dumps are therefore encrypted client-side before upload, with their own
passphrase from the same secret store as `repo1-cipher-pass`. TLS protects them
in flight; that passphrase protects them at rest, on the same terms as the
physical backups.

## Scope

| In scope | Out of scope |
| --- | --- |
| A pgBackRest repository on MinIO, off the database hosts | Restoring from it — that is [Lab 4](../lab4/README.md) |
| `pg_dump` of `appdb`, scheduled, encrypted, and stored under its own prefix | Cross-region or offsite replication of the repository |
| Repository encryption (`repo1-cipher-type=aes-256-cbc`) and TLS to MinIO | A second, independent repository — see the limitation below |
| Backups and WAL archiving that survive a failover | Backup of etcd — see below |
| Full and incremental backups, with retention | Tuning for databases large enough to need parallel restore |

**etcd is deliberately not backed up.** It holds cluster state Patroni can
rebuild — leader keys, member lists, the sync set. What cannot be rebuilt is the
PostgreSQL data, and that is what this lab protects. Backing up a leader key
would restore a lie.

### The repository is a single point of failure

Stated rather than left implicit, because it is the largest gap between this lab
and the outcome it serves. One MinIO instance holds every backup: lose it and the
cluster is back to having no recoverable history, however healthy it looks.

pgBackRest supports a second repository, and production designs use one. It is
out of scope here for the same reason a Tang server was in Lab 2 — resources on a
single laptop — and that is an accepted limitation of the lab, not a claim that
one repository is sufficient.

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
| AC-3 | **Every** object is encrypted at rest, and the transport is encrypted | Nothing under either prefix is readable straight from the bucket: pgBackRest objects need `repo1-cipher-pass`, dumps need the dump passphrase. A plaintext connection to MinIO is refused |
| AC-4 | Backups survive a failover | Force a promotion mid-cycle: the new primary continues archiving into the same stanza, `pgbackrest check` passes, and the WAL sequence has no gap |
| AC-5 | Exactly one backup runs per cycle | With the timer enabled on all three nodes, one backup is taken; the two non-leaders exit without touching the repository |

### AC-3 covers both prefixes on purpose

The obvious version of this criterion checks the pgBackRest objects and stops
there, which would leave the dumps in plaintext beside them and still pass. Every
object in the bucket has to fail to open without its passphrase, or the criterion
tests the easier half of the data.

### AC-2 is doing more work than it looks

Reloading the dump into a scratch database is not a restore rehearsal — that is
Lab 4. It is the cheapest available proof that the dump is **readable**, which is
the property `pgbackrest verify` cannot give, because verifying checksums
confirms the bytes are intact and says nothing about whether PostgreSQL can parse
what they contain.

### AC-4 is the one a single-node guide would miss

Archiving is a property of the primary, and the primary moves. A backup regime
that works until the first failover and then silently stops is the exact shape of
failure [Lab 7](../lab7/README.md) exists to detect — and the reason its headline
metric is the age of the last successful backup rather than any error count.

## What this lab does not claim

That any of it can be restored. A repository that accepts writes, passes
`pgbackrest check` and reports a valid backup set is evidence that *taking* a
backup works. Whether the result can rebuild a working cluster is
[Lab 4](../lab4/README.md), and keeping them apart is what stops the first result
being read as the second.
