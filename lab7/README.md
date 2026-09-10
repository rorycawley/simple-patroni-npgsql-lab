# Lab 7: schema migration

> **Status: specified, not built.** Everything below is the design and its
> acceptance criteria. No results are claimed.

The shared components, cluster design and prerequisites are in the
[top-level README](../README.md). This file covers Lab 7 only.

## Goal

Ship a schema change to a live Patroni cluster without taking it down, and know
what is left behind if the infrastructure interrupts it — both halves proven,
not asserted.

## Two ways a migration goes wrong

| | Failure | Covered by |
| --- | --- | --- |
| Your migration interrupts your **users** | It takes a lock, queues every query behind it, and the site stops | AC-1 to AC-4 |
| The infrastructure interrupts your **migration** | The primary fails over mid-flight | AC-5, AC-6 |

They were briefly two labs. Merging them was the right call, because the two
halves disagree about exactly one statement and a reader should not have to
reconcile two documents to find that out.

## The decision under test

Downtime for migrations is the intuitive answer and generally the wrong one. It
does not make a bad migration safe — a wrong `DROP COLUMN` means restoring from
backup either way — and it has costs of its own: migrations get batched into
large risky windows, and on this cluster "bring it down" means stopping the
application and then suppressing the failover machinery with `patronictl pause`,
adding operational steps to a system designed never to stop.

> No downtime, provided the schema is compatible with both the current and the
> previous application version, and every migration bounds its own lock wait.

Compatibility is what makes an application rollback possible at all; a downtime
window narrows the broken period but *forbids* rollback, because the old version
can no longer run. Bounding the lock wait is what stops a 10ms migration becoming
a five-minute outage.

## What PostgreSQL already guarantees

Two widely-feared failures largely cannot happen here, and this lab's job is to
demonstrate that rather than repeat the folklore.

**Transactional DDL** means Flyway writes the migration *and* its
`flyway_schema_history` row in the same transaction. They cannot disagree. Kill
the primary mid-migration and the result is a clean rollback, not a half-applied
schema with a history table that lies about it.

**The lock is session-scoped.** Flyway serialises runs with a session-level
advisory lock on PostgreSQL, and session-level locks die with the session. A
killed primary releases it; there is no lock left behind to block every later
deployment. That scenario is inherited from databases without these properties.

Both are still tested. An expected result is not a demonstrated one.

## The one construct where the two halves disagree

`CREATE INDEX CONCURRENTLY` cannot run inside a transaction, so it forfeits every
guarantee above. Interrupt it and PostgreSQL leaves an **`INVALID` index** in the
catalogue: the migration is recorded as failed, the database holds a partial
artefact, and a naive re-run does not clean it up — the invalid index must be
dropped explicitly first.

It is also exactly what the zero-downtime half recommends, because it is the only
way to add an index without locking writers out.

> Use `CONCURRENTLY` to avoid locking your users out, and know it is the one
> migration that leaves debris if the primary dies mid-flight.

That is one instruction with a caveat, which is why these belong in one lab. Two
labs would have made it look like a contradiction.

## What "simulated" means

There is no CI/CD server. A script plays the pipeline, invoked through `make`
like every other check:

| Real pipeline | Here |
| --- | --- |
| Jenkins/Actions job | `scripts/deploy.sh` — gate, migrate, verify |
| Application release | Two builds of the lab client, `v1` and `v2` |
| Deployment gate | A precondition check against Patroni before migrating |
| Rollback | Re-running the previous client build |

What is worth testing is the *database* behaviour under migration, and none of it
depends on which tool triggers the run.

## Scope

| In scope | Out of scope |
| --- | --- |
| Flyway applying versioned migrations against the current primary | A real CI/CD server, artefacts, or environments |
| Additive migrations with the client committing throughout | Blue/green or canary deployment of the application |
| Expand-contract for a destructive change, across simulated releases | Online schema-change tooling (`pg_repack`, `pgroll`) |
| `lock_timeout` as the bound on blast radius | Logical-replication-based migration |
| Failover injected *during* a migration, transactional and not | Recovering from a migration that was *wrong* — [Lab 8](../lab8/README.md) |
| A deploy gate that refuses a degraded cluster | Multi-tenant or sharded schemas |

## Topology

Five VMs. Flyway gets its own, separate from both the cluster and the
application.

| VM | Role |
| --- | --- |
| `lab7-pg1/2/3` | PostgreSQL, Patroni, etcd |
| `lab7-app1` | The .NET client, `v1` and `v2` |
| `lab7-flyway1` | Flyway |

Flyway is deliberately not on the application host. They are different actors
with different credentials — `migrator` versus `app_runtime`, per
[`SERVICE-ACCOUNTS.md`](../SERVICE-ACCOUNTS.md) — and in production the thing
that migrates the schema is not the thing that serves traffic. Co-locating them
would quietly re-merge a separation the design depends on.

The application and Flyway hosts need far less than the database nodes; sizing
them down keeps five VMs viable on one laptop.

## Acceptance criteria

| ID | Property | Pass condition |
| --- | --- | --- |
| AC-1 | An additive migration is invisible to the client | A client committing continuously through the migration records zero failed transactions and no commit gap beyond its normal latency |
| AC-2 | Lock contention is **bounded**, not merely absent | With a conflicting long transaction held: without `lock_timeout` the client's commits stall behind the queued DDL; with it, the migration aborts quickly and the client is unaffected |
| AC-3 | Both application versions work against both schemas | `v1` and `v2` each succeed against the pre- and post-migration schema — rollout *and* rollback are safe |
| AC-4 | A destructive change ships without downtime | A column rename completes via expand → backfill → switch → contract, with AC-1 and AC-3 holding at every step |
| AC-5 | An interrupted migration leaves no partial state | Killed mid-flight — by an aborted pipeline **or** by a failover — the schema and `flyway_schema_history` agree, no lock is held, and a re-run converges |
| AC-6 | The non-transactional case is exactly bounded | `CREATE INDEX CONCURRENTLY` interrupted leaves an `INVALID` index; a re-run does **not** silently repair it; the documented repair does |

### AC-2 is the one that matters

The others can pass on a quiet cluster and prove little. AC-2 asserts a
mechanism, and needs its negative control to mean anything: the *same* migration,
behind the *same* long-running transaction, must be shown to stall the client
when `lock_timeout` is absent. A test that only demonstrates the safe
configuration has not shown the danger it claims to prevent.

`ALTER TABLE` takes `ACCESS EXCLUSIVE`. When it waits on a conflicting lock,
every subsequent query queues behind it — the outage comes from the queue, not
from the DDL, and it happens whether or not a maintenance window was declared.

### AC-6 is AC-5's negative control

AC-5 claims an interrupted migration leaves nothing behind. AC-6 shows the
guarantee has a boundary and precisely where it lies. Proving the safe case alone
would imply a guarantee broader than the one that exists.

AC-5 must also demonstrate that it *could* detect a held lock — a deliberately
held advisory lock blocking a second run — or its "no lock is held" clause is
vacuous, passing because the condition never occurs rather than because the check
works.

## Notes specific to this cluster

- **Flyway runs as `migrator`, not as the application.** `migrator` owns the
  tables it creates, so the application sees nothing Flyway adds unless default
  privileges were set against `migrator`. See
  [`SERVICE-ACCOUNTS.md`](../SERVICE-ACCOUNTS.md).
- **Flyway needs the same primary-seeking configuration the client has.** The
  JDBC equivalent of `Target Session Attributes=primary` is a multi-host URL with
  `targetServerType=primary`. Without it, a re-run after failover reaches a stale
  host or a replica and fails read-only.
- **Verify the JVM's TLS behaviour early.** pgJDBC accepts a PEM file for
  `sslrootcert`, unlike much of the Java ecosystem, which expects a keystore.
  Confirm it against a live cluster rather than building around it: an unverified
  assumption about a TLS stack has already cost this series once, when .NET on
  macOS turned out not to implement TLS 1.3.
- **A blocked migration must be bounded.** Under
  [`synchronous_mode_strict`](../SLA.md#the-exception-being-closed), a migration
  with no standby available **blocks** rather than failing. That is the intended
  trade, but a hang reports nothing, holds its lock, and stalls the pipeline
  behind it. A statement timeout converts it into a failure someone can see.
- **A long migration loses everything on failover.** A backfill running for
  minutes is one transaction, and the primary dying rolls all of it back —
  correct, and an argument for batching that the zero-downtime half makes on
  entirely different grounds.
- **Quorum commit taxes every batch.** Each commit waits for a standby fsync, so
  batch sizing matters more here than on an asynchronous cluster.
