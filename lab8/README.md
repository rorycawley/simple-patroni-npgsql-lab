# Lab 8: recovering from a bad migration

> **Status: specified, not built.** Everything below is the design and its
> acceptance criteria. No results are claimed.

The shared components, cluster design and prerequisites are in the
[top-level README](../README.md). This file covers Lab 8 only.

## Goal

Undo a schema migration that succeeded and should not have, and measure what
undoing it costs.

## The case every earlier lab is blind to

A bad migration is not a fault. Nothing crashes, no node is lost, and the cluster
stays perfectly healthy while doing the wrong thing.

Worse, the machinery from Labs 1 and 2 works *against* recovery. Quorum commit
makes the bad migration durable before it is acknowledged, replication carries it
to both standbys in milliseconds, and a failover hands over a healthy node
carrying the same broken schema. **No node is left holding the old state.** Every
guarantee the earlier labs worked to establish is what removes the escape route.

Only a backup answers it, which is why it composes Labs 3, 4 and 7 rather than
repeating them.

## What is actually being protected against

PostgreSQL has transactional DDL, and Flyway wraps each migration in a
transaction. **A migration that crashes rolls back on its own.**

So nothing here protects against a migration *failing*. It protects against one
that **succeeded and was wrong** — which is a narrower and more specific risk
than "we need backups for migrations", and worth stating plainly because it
determines how much of the machinery below is needed.

## You take a marker, not a backup

With Lab 3's WAL archiving already running, a full backup before every migration
is slow and mostly pointless: the base backup exists. What is missing is a
precise, named point to replay to.

```sql
SELECT pg_create_restore_point('before_v42_add_orders_index');
SELECT pg_switch_wal();
```

The `pg_switch_wal()` is not decoration. A restore point is a record inside the
*current* WAL segment; if that segment is never archived, the marker is not in
the repository when it is needed. `archive_timeout = 60s` gets there eventually,
and forcing the switch means not having to hope.

An LSN captured with `pg_current_wal_lsn()` is equally precise and read-only, if
writing to the primary before a migration is unwelcome. Timestamps are the weak
option: clock skew, and no way to separate two events in the same second.

## Three instruments, escalating

This table is about what to **take before** a migration. Which instrument to
**reach for afterwards** is the same question every recovery asks, and it has one
answer for the whole series: the ladder in
[`RUNBOOKS.md`](../RUNBOOKS.md#which-recovery-do-you-need), whose rungs
[Lab 4](../lab4/README.md) proves.

This lab owns **no rung**. Rungs 4 and 5 — recovering one table from a dump, and
rewinding the cluster — are mechanisms, and [Lab 4](../lab4/README.md) proves
both. What this lab adds is the only thing a mechanism cannot tell you: for *this
damage*, which rung is enough, and what the other one would have cost.

Worth reading the ladder first, because it carries a rung this lab does not:
**rung 3**, restoring a copy beside the live cluster to read the old values out.
It recovers a mangled table while losing nothing and stopping nothing, and for a
migration that damaged data rather than schema it is usually the right answer —
cheaper than everything below.

The mistake is reaching for the last one first. Rewinding the cluster to the
marker discards **every transaction committed since** — including all the
unrelated business that happened while the problem was being diagnosed.

| Instrument | Cost to take | Recovers | Loses |
| --- | --- | --- | --- |
| `pg_dump --schema-only` | seconds | nothing | — it tells you *what changed* |
| Targeted `pg_dump` of affected tables | seconds to minutes | those tables | nothing else |
| Named restore point + PITR | milliseconds | the whole cluster | every commit since the marker |

```sh
# The scalpel: only the tables the migration touched.
pg_dump --format=custom --table=orders --table=order_lines appdb > pre_v42.dump

# The emergency brake: everything, back to the marker.
pgbackrest restore --type=name --target=before_v42_add_orders_index
```

This is the concrete reason [Lab 3](../lab3/README.md) carries both pgBackRest
and `pg_dump`. One is a time machine; the other is a scalpel. A lab holding only
the physical backup would be forced to discard a day of unrelated work to undo
two mangled tables.

## Scope

| In scope | Out of scope |
| --- | --- |
| A migration that applies cleanly and is semantically wrong | A migration that fails or crashes — transactional DDL already handles it |
| Restore point and LSN markers, and getting them into the repository | Logical decoding or trigger-based undo |
| Targeted table-level recovery from a logical dump | Restoring into a different major version |
| Full-cluster PITR to the marker, and **measuring what it discards** | Automating the choice between the two paths |
| Rejoining the cluster afterwards | Blue/green database cutover |

## Acceptance criteria

| ID | Property | Pass condition |
| --- | --- | --- |
| AC-1 | The marker survives to the repository | After `pg_create_restore_point` and `pg_switch_wal`, the marker is present in archived WAL — verified from the repository, not from the primary's memory |
| AC-2 | A bad migration is invisible to every HA mechanism | After it applies: one leader, two streaming standbys, no alert, no failover — and **both standbys carry the same broken schema** |
| AC-3 | The cost of each way out is measured, not described | For this migration, report what **rung 4** costs (which tables came back, what else moved) and what **rung 5** costs (how many committed transactions were discarded, and how long the cluster was unavailable) |

The mechanisms themselves — restoring one table from a dump, and rewinding to an
exact point — are [Lab 4](../lab4/README.md)'s rungs 4 and 5, proven there
against a deliberate change. This lab does not re-prove them. It applies them to
the one situation nothing else in the series covers, and measures what choosing
between them costs.

> Two criteria left this lab when [Lab 4](../lab4/README.md) took the ladder.
> They asserted table-level recovery and an exact PITR boundary — both
> *mechanisms*, and the second a straight duplicate of Lab 4's AC-4. Keeping
> them here would have meant proving the same property twice and inviting the
> two labs to disagree about it.

### AC-2 is the point of the lab

It asserts a *negative*: that everything built in Labs 1, 2 and 5 stays quiet.
Green health checks, no promotion, no alert — and the corruption faithfully
replicated to both standbys. Until that is demonstrated, the case for this lab is
theoretical.

### AC-3 is what stops it being a demo

Any restore can be made to look successful. The number that matters is what it
threw away. Without it, "we restored to before the migration" sounds like a clean
recovery instead of the trade it is.

It is also the criterion that makes the ladder's ordering real for this scenario
rather than general. Lab 4 shows that rung 4 costs less than rung 5. This lab
answers the question an operator actually has in front of them: *for the damage
this migration did*, is rung 4 enough, and if not, exactly how much does rung 5
discard?

## Notes specific to this cluster

- **Patroni must be paused before a PITR restore.** Restoring under a running
  Patroni means it sees a node diverging from the DCS and tries to repair what
  is deliberately being rewound. `patronictl pause` first, resume after.
- **The standbys are not a recovery source.** They hold the same broken schema
  within milliseconds. Rebuilding them from the restored primary is part of the
  recovery, not an alternative to it.
- **A restore rewinds the whole cluster, including other databases.** If `appdb`
  shares the cluster with anything else, PITR takes that back too — which is an
  argument for the scalpel wherever it suffices.
- **`synchronous_mode_strict` affects the rebuild.** A freshly restored primary
  with no standby attached cannot accept writes until one rejoins. Expected
  behaviour, and worth knowing before it looks like a failed restore.
