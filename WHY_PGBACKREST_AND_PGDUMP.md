# Why both pgBackRest and pg_dump

They are not two backup systems, and one is not a spare for the other. They copy
different things, and everything else follows from that.

This file is the reference: the complete case, including when *not* to reach for
each, what neither protects against, and what to take before a manual change.
[The root README](README.md#backups-two-instruments-not-two-backup-systems)
carries the summary; [Lab 3](lab3/README.md) covers how both are configured,
stored and encrypted.

## The one-sentence difference

**pgBackRest copies files. `pg_dump` copies data.**

pgBackRest reads the 8KB pages on disk and the write-ahead log, without
understanding what a table is. `pg_dump` runs queries and writes out what the
data *means*, without understanding what a file is.

Every strength and every limitation below comes from that one distinction.

| Because pgBackRest copies files… | Because `pg_dump` reads through SQL… |
| --- | --- |
| it is fast, and scales to large databases | it is slow, and the restore is slower still |
| it can replay WAL to any moment in time | it captures exactly one instant |
| it restores the cluster exactly as it was | it can restore one table on its own |
| it is locked to the PostgreSQL major version | it moves between versions and platforms |
| it copies corruption faithfully | it cannot copy corruption — it fails instead |

## What each one actually contains

The distinction above is only useful if you know what each one *has in it*. Both
lists below were checked against this cluster rather than recited, because
several entries surprise people — and two of them are the difference between a
restore that works and one that does not.

### pgBackRest: the whole cluster, byte for byte

| In the backup | Not in the backup |
| --- | --- |
| **Every database** — measured here as `template0`, `template1`, `postgres` and `appdb`. It does not know what a database *is*; it copies files | Anything outside the data directory: TLS keys, LUKS keys, the OS, and any tablespace on another path |
| Every table, index, sequence and TOAST relation | **Unlogged table data.** Recovery truncates unlogged relations, so they come back **empty** |
| Large objects, always — they live in a system catalogue, which is just more files | Temporary files and unlogged-relation init forks |
| **Roles, passwords and tablespace definitions** — cluster-wide catalogues under `global/` | — |
| **The server configuration**: `postgresql.conf`, `pg_hba.conf`, `pg_ident.conf`, `postgresql.auto.conf`. Measured — Patroni keeps them inside `PGDATA`, so a restore brings the cluster's own rules back with it | — |
| The continuous WAL archive, which is what makes any of it point-in-time | — |

**Format.** A repository pgBackRest manages itself: full, differential and
incremental backup sets, compressed (gzip here), encrypted (`aes-256-cbc`), with
manifests tying them together. It is **not** a tar file you can unpack. Reading
it needs pgBackRest *and* `repo1-cipher-pass`, and nothing else will do.

**Granularity: the whole cluster, and only the whole cluster.** There is no
"restore one table" — that is the entire reason the other instrument exists.

### `pg_dump`: one database, read through SQL

| In the dump | Not in the dump |
| --- | --- |
| **One database** — its schema and its data | **Every other database.** A dump of `appdb` knows nothing about `postgres` |
| **Unlogged table data** — measured: all 50 rows. It reads through the executor, so it captures what a physical backup cannot | **Roles and passwords.** Measured: zero `CREATE ROLE` statements. They are cluster-wide — `pg_dumpall --globals-only` |
| Large objects, **when dumping the whole database** | Large objects in a **targeted** dump. Measured: `-t lo_probe` yielded **0**; adding `-b` yielded **2** |
| Anything you select: a schema, a table, data only, schema only | Tablespace definitions and server configuration |

**Format.** Here, `--format=custom`: compressed, and the only format that
supports *selective* restore — `pg_restore` can pull one table out of it, which
plain SQL text cannot. It is then encrypted with `openssl aes-256-cbc` before
upload, because it lands outside the pgBackRest repository and
`repo1-cipher-pass` does not reach it.

**Granularity: anything down to a single table.**

### The three asymmetries that catch people

| | pgBackRest | `pg_dump` |
| --- | --- | --- |
| **Unlogged table data** | **Lost** — truncated on recovery | **Captured** |
| **Roles and passwords** | Included | **Absent** — restore into a cluster without them and every `GRANT` fails |
| **Large objects** | Always included | Only with the whole database, **or** `-t` plus `-b` |

The second is the classic unpleasant surprise: a dump that restores cleanly into
a fresh cluster and then denies the application access to everything, because the
roles its grants refer to were never in the file.

The third matters most for exactly the job the dump exists to do. Recovering one
mangled table is a **targeted** dump — and a targeted dump silently leaves large
objects behind unless you ask for them.

> **A caveat specific to this cluster.** The dump job runs as `dumper`, whose
> `pg_read_all_data` covers tables, views and sequences — and **not** large
> objects. Measured: `pg_dump` as `dumper` fails with *permission denied for
> large object* the moment one exists. `appdb` has none, and
> [Lab 3](lab3/README.md) asserts that it has none, so the assumption cannot rot
> silently. A database that uses them needs the dump to run as its owner or as a
> superuser instead.

## The kinds of backup

pgBackRest takes three, and they differ only in *what they copy*:

| Type | Copies | Depends on |
| --- | --- | --- |
| **Full** | Every file in the cluster | Nothing — it stands on its own |
| **Differential** | Files changed since the last **full** | That full |
| **Incremental** | Files changed since the last backup **of any type** | Every backup in the chain back to the full |

The trade runs in one direction: the cheaper a backup is to *take*, the longer
the chain needed to *restore* it. A full is slow and self-sufficient; an
incremental is fast and useless alone. **One damaged or expired link invalidates
every backup after it**, which is why retention is expressed in fulls —
`repo1-retention-full=2` here — and why expiring a full silently expires the
differentials and incrementals that depend on it.

### WAL archiving is the part that actually bounds data loss

It is not a fourth backup type. It is continuous, it runs between backups, and it
is what makes point-in-time recovery possible at all. This cluster archives with
`archive_mode = on` and `archive_timeout = 60s`, pushing each segment through
`pgbackrest archive-push`.

The consequence is the most commonly conflated point in backup design:

> **Backup frequency does not set your RPO. The WAL archive does.**

Taking a full backup once a day does not mean losing up to a day. It means losing
up to `archive_timeout`, *provided the WAL archive between the backup and the
failure is intact*. The backup is the floor you replay from; the WAL is what gets
you from there to the last moment before the incident. Lose the archive and the
backup alone drops you back to whenever it was taken.

### What Labs 1 and 2 actually do today

Worth stating plainly, because the configuration looks complete and is not.
Archiving is fully set up — `archive_command` pushes every segment, the stanza is
created at bootstrap, and `pgbackrest check` runs in `verify_cluster` and passes.

**But no backup is ever taken.** Nothing schedules a full, and `pgbackrest check`
does not need one to pass. So these labs archive WAL continuously with no base
backup for it to be replayed onto, which restores nothing. A second consequence
follows: with no full backup, `repo1-retention-full=2` never expires anything, so
the archive grows without bound — the beginning of
[runbook 6](RUNBOOKS.md#6-disk-filling-or-wal-accumulating).

Scheduled fulls and incrementals, retention that actually runs, and a repository
that survives the node arrive in [Lab 3](lab3/README.md). Until then the honest
description is *WAL archiving is proven to work; backup is not yet configured*.

### `pg_dump` has no equivalent

There is no incremental dump. Every run is standalone and complete, with no
chain, no dependencies, and nothing to invalidate. That is the same distinction
as everywhere else in this file: it copies data rather than files, and "which
files changed" is not a question it can ask.

## Which one to use

| Use **pgBackRest** for… | Use **`pg_dump`** for… |
| --- | --- |
| **A node, or every node, lost.** It rebuilds the whole cluster | **One table mangled, everything else fine.** It restores that table alone, losing nothing else |
| **The state as of 14:32 yesterday.** Only WAL replay reaches a specific moment | **Knowing the data is still *readable*.** It reads every row; completing is the proof |
| **Undoing a change that replicated everywhere.** PITR to just before it | **Moving to a new major version or another platform.** A physical backup cannot cross versions |
| **A large database.** It is the only one of the two that stays practical | **A copy to load into a test environment.** Portable, selective, no cluster required |
| **A new replica without loading the primary.** Patroni builds one straight from the repository | **Inspecting what was backed up.** Plain format is text you can actually read |

Read down a column, not across: the rows are two independent lists, not pairs.
The division is not about size or importance — it is about whether you need the
*cluster* back or the *data* back.

## When **not** to use each

This is the part usually left out.

### Do not use pgBackRest when

- **You only need one table back.** Restoring the whole cluster to a point in time
  discards *every transaction committed since* that point — including all the
  unrelated work done while you were diagnosing the problem. Reaching for it
  first is the most common expensive mistake.
- **You are upgrading PostgreSQL.** A physical backup restores only to the same
  major version. It is not an upgrade path.
- **You want to verify the data is intact.** `pgbackrest verify` checks that the
  *bytes* are undamaged. It cannot tell you whether PostgreSQL can still parse
  what those bytes contain.

### Do not use `pg_dump` when

- **It is your disaster recovery plan.** No point-in-time recovery, no continuous
  archiving, and a restore that rebuilds every index from scratch. On a large
  database this is hours, and everything since the dump is simply gone.
- **You need the exact cluster back.** A dump restores logical contents into a
  cluster you have already built. It does not give you your cluster.
- **You assume it captured everything.** `pg_dump` covers **one database**. Roles,
  passwords and tablespaces are cluster-wide and are not in it — those need
  `pg_dumpall --globals-only`. A dump that restores cleanly into a cluster with no
  matching roles is a very common unpleasant surprise.
- **You run it against a busy standby without thinking.** A long dump can be
  cancelled mid-run by a recovery conflict as WAL replay invalidates rows it is
  still reading.

## The questions people actually ask

**Can `pg_dump` replace pgBackRest?**
No. It cannot recover to a point in time, it cannot rebuild a cluster, and on any
real database it is too slow to be the primary mechanism. Everything committed
between the dump and the disaster is lost.

**Can pgBackRest replace `pg_dump`?**
Not without cost. It can recover a single table only by restoring the entire
cluster to a point in time and discarding everything committed since. That is a
real answer, but an expensive one, and it is the reason to keep the scalpel.

**If I can only have one, which?**
pgBackRest. It is the disaster recovery system. `pg_dump` is what makes the
common, small disasters cheap to fix.

**Do we ever actually use `pg_dump`?**
Yes — in three places, none of which is disaster recovery:

| When | What for | Specified in |
| --- | --- | --- |
| On a schedule, slower than the pgBackRest cycle | The canary. A dump that completes is evidence the data is still readable | [Lab 3](lab3/README.md), AC-2 |
| Before a destructive manual change — `DROP TABLE`, `DROP COLUMN` | A targeted dump of only those tables, so the change stays reversible | [When a transaction is not enough](#when-a-transaction-is-not-enough) |
| After a migration that succeeded and was wrong | Restoring the affected tables without rewinding the whole cluster | [Lab 8](lab8/README.md), AC-3 |

It is never the mechanism for recovering the cluster, and never used for
point-in-time recovery. Note that all three are *specified*, not yet built — as
above, neither tool is scheduled in Labs 1 and 2.

**Why is "it copies corruption" such a big deal?**
Because it is silent. A corrupt page is copied byte for byte into every backup,
so the corruption outlives its retention window and every restore reproduces it
faithfully. A dump reading that page through PostgreSQL *fails* instead — which
is the alarm you want. Page checksums (`data_checksums`) are the first line of
defence; a completing dump is the second.

**How often should each run?**
pgBackRest continuously (WAL archiving) with scheduled full and incremental
backups. `pg_dump` on a slower cycle — its job is surgical recovery and
verification, not recency.

**Is a backup that has never been restored a backup?**
No. It is a hypothesis. That is why restoring is
[its own lab](lab4/README.md) rather than a footnote to taking backups.

**Do I have to restore *over* production to use a backup?**
No, and assuming so is what makes people rewind a whole cluster to recover one
table. A copy restored *beside* production recovers values while losing nothing
and stopping nothing. It is the fourth row of
[the recovery ladder](RUNBOOKS.md#which-recovery-do-you-need), and usually the
right answer.

## Before a manual change, do you need either?

Usually **no** — and reaching for a backup first is often a sign the change is
about to be made the risky way.

This section is the *before*. If a change has already been committed and turned
out to be wrong,
[runbook 9](RUNBOOKS.md#9-undo-a-change-that-was-committed-and-later-found-to-be-wrong)
is the *after*.

### The cheapest protection is not a backup

It is not committing yet.

```sql
BEGIN;
UPDATE accounts SET status = 'closed' WHERE id = 4711;
-- UPDATE 1        <- expected 1. Good.
COMMIT;
```

Had that reported `UPDATE 40000`, a `ROLLBACK` ends it and no backup was ever
needed. This is the only measure that **prevents** the mistake rather than
recovering from it, and it costs nothing. For a manual change — unreviewed,
unversioned, often typed under pressure — that matters more than it does for a
reviewed migration, not less.

### Schema changes are the same, with named exceptions

PostgreSQL has **transactional DDL**, which surprises people arriving from Oracle
or MySQL:

```sql
BEGIN;
ALTER TABLE orders DROP COLUMN legacy_ref;
-- inspect
ROLLBACK;   -- the column is still there
```

So the same discipline covers most schema work. The exceptions are the statements
that cannot run inside a transaction, and those are exactly where real protection
is needed:

- `CREATE INDEX CONCURRENTLY`, `DROP INDEX CONCURRENTLY`, `REINDEX CONCURRENTLY`
- `VACUUM`, `VACUUM FULL`
- `CREATE DATABASE`, `DROP DATABASE`
- `CREATE TABLESPACE`, `DROP TABLESPACE`
- `ALTER SYSTEM`

### When a transaction is not enough

| Situation | What to take |
| --- | --- |
| The statement cannot be wrapped in a transaction | Restore point |
| Correctness cannot be judged until after the commit | Restore point |
| The change destroys data — `DROP TABLE`, `DROP COLUMN` | Targeted `pg_dump` of those tables |
| You will want to know what the schema *was* | `pg_dump --schema-only` |

Note what is absent from that table: **taking a fresh full backup.** The regular
backup already exists. What is missing is a precise point to return to, and that
costs milliseconds rather than minutes:

```sql
SELECT pg_create_restore_point('before_manual_fix_4711');
SELECT pg_switch_wal();
```

The `pg_switch_wal()` is not decoration. A restore point is a record inside the
*current* WAL segment, and it is not in the repository until that segment is
archived.

Treat the restore point as the emergency brake. Using it rewinds the whole
cluster and discards everything committed since, so for one mangled table the
targeted dump is the better instrument — the same escalation
[Lab 8](lab8/README.md) has to measure.

### Two things specific to this cluster

- **Under `synchronous_mode_strict`, a manual change blocks** if no standby can
  confirm it. That is the [intended trade](SLA.md#the-exception-being-closed), but
  at a `psql` prompt it presents as a hang rather than an error. Check the cluster
  is healthy before starting, and if it does hang,
  [runbook 1](RUNBOOKS.md#1-writes-are-blocked-on-synchronous-replication) is how
  to recognise and clear it.
- **Point-in-time recovery is not fully available yet.** Labs 1 and 2 keep
  pgBackRest repositories locally on each node, which is explicitly not a durable
  design. For recovering from a *mistake* that is adequate — the node is still
  there — but it does not survive losing the node, and an off-host repository
  does not arrive until [Lab 3](lab3/README.md).

## What neither protects against

Worth stating, because both are easily assumed to cover it:

- **Losing the repository itself.** One copy in one place is one fault away from
  no backups at all.
- **Losing the encryption passphrase.** Encrypted backups without the key are
  indistinguishable from no backups.
- **A logical error you do not notice in time.** If the mistake predates every
  backup and WAL segment you still hold, there is nothing to go back to.
- **Backups that stop silently.** Nothing throws an error when a backup simply
  stops happening, which is why the [monitoring lab](lab5/README.md) treats
  *backup age* as its headline metric rather than any error count.

The first two are rows in
[what production still needs](README.md#from-lab-to-production): a second
repository, so one loss is not total; and a passphrase held somewhere that losing
the cluster cannot take with it.

## In these labs

This is the designed arrangement, and **none of it is built yet** — Labs 3, 4 and
6 are specified only. What exists today is a pgBackRest repository local to each
node, which demonstrates the configuration and survives nothing.

| | pgBackRest | `pg_dump` |
| --- | --- | --- |
| Set up in | [Lab 3](lab3/README.md) | [Lab 3](lab3/README.md) |
| Restore proven in | [Lab 4](lab4/README.md) | [Lab 8](lab8/README.md) |
| Stored at | `s3://…/pgbackrest/` | `s3://…/dumps/` |
| Encrypted by | `repo1-cipher-pass` | its own passphrase, applied before upload |

The two prefixes are separate because a pgBackRest repository is not a place to
put your own files — its retention and `expire` operate on everything inside
`repo1-path`. And the two passphrases are separate because `repo1-cipher-pass`
protects only what pgBackRest writes: a dump uploaded unencrypted would sit in the
same bucket in plaintext, readable by whoever administers the object store.

Both are catalogued in [`SERVICE-ACCOUNTS.md`](SERVICE-ACCOUNTS.md).
