# Why both pgBackRest and pg_dump

They are not two backup systems, and one is not a spare for the other. They copy
different things, and everything else follows from that.

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

## What each one actually produces

**pgBackRest** maintains a *repository*: full, differential and incremental
backup sets, a continuous archive of WAL segments, and the manifests that tie
them together. It is a structured store that pgBackRest manages itself. You do
not read it by hand, and you do not put your own files in it.

**`pg_dump`** produces *one file per run*, containing the schema and data of **one
database** as either SQL text or a portable archive.

## When to use pgBackRest

| Situation | Why |
| --- | --- |
| A node, or every node, has been lost | It rebuilds the whole cluster |
| You need the state as of 14:32 yesterday | Only WAL replay can do this |
| You need to undo a change that has been replicated everywhere | PITR to just before it |
| The database is large | It is the only one of the two that stays practical |
| You want a new replica without loading the primary | Patroni can build one straight from the repository |

## When to use `pg_dump`

| Situation | Why |
| --- | --- |
| One table was mangled and everything else is fine | Restores that table alone, losing nothing else |
| You want to know the data is still *readable* | It reads every row; completing is the proof |
| You are moving to a new major version or another platform | The physical backup cannot cross versions |
| You want a copy to load into a test environment | Portable, selective, no cluster required |
| You want to inspect what was backed up | Plain format is text you can actually read |

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

## Before a manual change, do you need either?

Usually **no** — and reaching for a backup first is often a sign the change is
about to be made the risky way.

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
[Lab 6](lab6/README.md) has to measure.

### Two things specific to this cluster

- **Under `synchronous_mode_strict`, a manual change blocks** if no standby can
  confirm it. That is the [intended trade](SLA.md#the-exception-being-closed), but
  at a `psql` prompt it presents as a hang rather than an error. Check the cluster
  is healthy before starting.
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
  stops happening, which is why the [monitoring lab](lab7/README.md) treats
  *backup age* as its headline metric rather than any error count.

## In these labs

| | pgBackRest | `pg_dump` |
| --- | --- | --- |
| Set up in | [Lab 3](lab3/README.md) | [Lab 3](lab3/README.md) |
| Restore proven in | [Lab 4](lab4/README.md) | [Lab 6](lab6/README.md) |
| Stored at | `s3://…/pgbackrest/` | `s3://…/dumps/` |
| Encrypted by | `repo1-cipher-pass` | its own passphrase, applied before upload |

The two prefixes are separate because a pgBackRest repository is not a place to
put your own files — its retention and `expire` operate on everything inside
`repo1-path`. And the two passphrases are separate because `repo1-cipher-pass`
protects only what pgBackRest writes: a dump uploaded unencrypted would sit in the
same bucket in plaintext, readable by whoever administers the object store.

Both are catalogued in [`SERVICE-ACCOUNTS.md`](SERVICE-ACCOUNTS.md).
