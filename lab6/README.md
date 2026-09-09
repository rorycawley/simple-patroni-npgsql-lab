# Lab 6: schema migration without downtime

> **Status: specified, not built.** Everything below is the design and its
> acceptance criteria. No results are claimed.

The shared components, cluster design and prerequisites are in the
[top-level README](../README.md). This file covers Lab 6 only.

## Goal

Ship a schema change to a live Patroni cluster without taking it down, and prove
that claim rather than assert it — including for a destructive change, which is
where "zero downtime" usually quietly stops being true.

## The decision this lab tests

Downtime for migrations is the intuitive answer and generally the wrong one. It
does not make a bad migration safe — a wrong `DROP COLUMN` means restoring from
backup either way — and it has costs of its own: migrations get batched into
large risky windows, and on this cluster "bring it down" means stopping the app
and then suppressing the failover machinery with `patronictl pause`, adding
operational steps to a system designed never to stop. PostgreSQL's transactional
DDL removes most of the historical reason for the practice.

The position under test:

> No downtime, provided the schema is compatible with both the current and the
> previous application version, and every migration bounds its own lock wait.

Both halves matter. Compatibility is what makes an application rollback possible
at all; a downtime window narrows the broken period but *forbids* rollback,
because the old version can no longer run. Bounding the lock wait is what stops a
10ms migration from becoming a five-minute outage.

## What "simulated" means

There is no CI/CD server. A script plays the pipeline, invoked through `make`
like every other check:

| Real pipeline | Here |
| --- | --- |
| Jenkins/Actions job | `scripts/deploy.sh` — gate, migrate, verify |
| Application release | Two builds of the lab client, `v1` and `v2` |
| Deployment gate | A precondition check against Patroni before migrating |
| Rollback | Re-running the previous client build |

The substitution is deliberate. What is worth testing is the *database* behaviour
under migration, and none of it depends on which tool triggers the run.

## Scope

| In scope | Out of scope |
| --- | --- |
| Flyway applying versioned migrations against the current primary | A real CI/CD server, artefacts, or environments |
| Additive migrations with the client committing throughout | Blue/green or canary deployment of the application |
| Expand-contract for a destructive change, across simulated releases | Online schema-change tooling (`pg_repack`, `pgroll`) |
| `lock_timeout` as the bound on blast radius | Logical-replication-based migration |
| A deploy gate that refuses a degraded cluster | Multi-tenant or sharded schemas |
| Re-running an interrupted pipeline | Data migration at a scale needing hours of backfill |

Recovering from a migration that was *wrong* is [Lab 7](../README.md). This lab
is about applying a correct migration safely; Lab 7 is the backstop when the
migration should never have shipped.

## Acceptance criteria

| ID | Property | Pass condition |
| --- | --- | --- |
| AC-1 | An additive migration is invisible to the client | A client committing continuously through the migration records zero failed transactions and no commit gap beyond its normal latency |
| AC-2 | Lock contention is **bounded**, not merely absent | With a conflicting long transaction held open: without `lock_timeout` the client's commits stall behind the queued DDL; with `lock_timeout` the migration aborts quickly and the client is unaffected |
| AC-3 | Both application versions work against both schemas | `v1` and `v2` clients each succeed against the pre- and post-migration schema — rollout *and* rollback are safe |
| AC-4 | A destructive change ships without downtime | A column rename completes via expand → backfill → switch → contract, with AC-1 and AC-3 holding at every step |
| AC-5 | An interrupted pipeline is re-runnable | After the migration is killed mid-flight, re-running it converges: no held Flyway lock, and `flyway_schema_history` agrees with the actual schema |

### AC-2 is the one that matters

The others can pass on a quiet cluster and prove little. AC-2 asserts the
mechanism, and it needs its negative control to mean anything: the *same*
migration, behind the *same* long-running transaction, must be shown to stall the
client when `lock_timeout` is absent. A test that only demonstrates the safe
configuration has not shown the danger it claims to prevent.

`ALTER TABLE` takes `ACCESS EXCLUSIVE`. When it waits on a conflicting lock,
every subsequent query queues behind it — the outage comes from the queue, not
from the DDL, and it happens whether or not a maintenance window was declared.

### AC-5 and this cluster

PostgreSQL's transactional DDL means an interrupted migration rolls back
cleanly, so the schema is not the risk. Flyway's own bookkeeping is: its history
row and its lock can disagree with reality, and a lock left held blocks every
later deployment. That is [Lab 5](../README.md)'s failure mode reached by a
different route — there by failover, here by an aborted pipeline.

## Notes specific to this cluster

- **Flyway must reach the primary**, exactly as the application does. Against a
  replica it fails read-only — noisy but safe.
- **Quorum commit taxes backfills.** Every batch commit waits for a standby
  fsync, so batch size matters more here than on an asynchronous cluster.
- **If [`synchronous_mode_strict`](../SLA.md#the-one-exception) is enabled**, a
  migration running while both standbys are unavailable will block rather than
  proceed. Correct behaviour, and the reason AC-5's gate checks cluster health
  before migrating rather than after failing.
