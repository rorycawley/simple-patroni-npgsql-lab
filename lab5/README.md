# Lab 5: schema migration meets failover

> **Status: specified, not built.** Everything below is the design and its
> acceptance criteria. No results are claimed.

The shared components, cluster design and prerequisites are in the
[top-level README](../README.md). This file covers Lab 5 only.

## Goal

Run a real schema migration against the cluster, take the primary away
underneath it, and establish exactly what survives — and what does not.

## The boundary with Lab 6

> Lab 5 is the **infrastructure interrupting your migration**.
> [Lab 6](../lab6/README.md) is your **migration interrupting your users**.

Fault-driven here; design-driven there. Lab 5 also establishes the Flyway
installation that Lab 6 needs, and — like every other lab in this series — it is
a standalone copy rather than a layer, so it can be built, broken and destroyed
without touching anything else.

## Most of what people fear here cannot happen

The value of this lab is in demonstrating that, not repeating the folklore.

**PostgreSQL has transactional DDL**, so Flyway applies the migration *and*
writes its `flyway_schema_history` row in the **same transaction**. They cannot
disagree. Kill the primary mid-migration and the result is a clean rollback, not
a half-applied schema with a history table that lies about it.

**The stuck-lock scenario is largely inherited from other databases.** Flyway
serialises runs with a session-level advisory lock on PostgreSQL, and
session-level locks die with the session. A primary that is killed releases it
automatically; there is no lock left behind to block every later deployment.

Both are claims this lab must **test rather than assert** — but the expected
result is that the danger is smaller than its reputation, and saying so with
evidence is worth more than repeating the warning.

## The one case that genuinely breaks

`CREATE INDEX CONCURRENTLY` cannot run inside a transaction, so it forfeits
every guarantee above. Interrupt it and PostgreSQL leaves an **`INVALID` index**
in the catalogue: the migration is recorded as failed, the database holds a
partial artefact, and a naive re-run does not clean it up — the invalid index has
to be dropped explicitly first.

That produces a genuine tension between the two migration labs, on exactly one
construct:

| [Lab 6](../lab6/README.md) says | Lab 5 shows |
| --- | --- |
| Use `CREATE INDEX CONCURRENTLY` so the migration does not lock users out | `CONCURRENTLY` is precisely the migration that breaks when the primary is lost |

Zero-downtime advice and failover-safety advice point in opposite directions
here. Neither is wrong; the resolution is knowing which risk you are taking.

## Scope

| In scope | Out of scope |
| --- | --- |
| Failover injected *during* a migration, transactional and not | Downtime, locking and rollback — all [Lab 6](../lab6/README.md) |
| Flyway's history and lock state after an interruption | Flyway's own configuration management or migration authoring |
| Flyway following a promotion to the new primary | Load-balancing migrations across replicas — there is nowhere else to run them |
| Migration behaviour under `synchronous_mode_strict` | Logical replication or online schema-change tools |
| Recovering from an interrupted non-transactional migration | Recovering from a migration that was *wrong* — that is [Lab 7](../lab7/README.md) |

## Topology

Five VMs. Flyway gets its own, separate from both the cluster and the
application.

| VM | Role |
| --- | --- |
| `lab5-pg1/2/3` | PostgreSQL, Patroni, etcd |
| `lab5-app1` | The .NET client |
| `lab5-flyway1` | Flyway |

Flyway is deliberately not on the application host. They are different actors
with different credentials — `migrator` versus `app_runtime`, per
[`SERVICE-ACCOUNTS.md`](../SERVICE-ACCOUNTS.md) — and in production the thing
that migrates the schema is not the thing that serves traffic. Putting them on
one host would quietly re-merge a separation the whole design depends on.

The application and Flyway hosts need far less than the database nodes; sizing
them down keeps five VMs viable on one laptop, which is the same resource
pressure that ruled out a Tang server in Lab 2.

## Acceptance criteria

| ID | Property | Pass condition |
| --- | --- | --- |
| AC-1 | A transactional migration interrupted by failover leaves no partial state | After the primary is destroyed mid-migration, the schema and `flyway_schema_history` agree: either the migration is fully applied and recorded, or neither |
| AC-2 | The lock is not left held | A subsequent Flyway run acquires the lock and proceeds with no manual intervention |
| AC-3 | The non-transactional case is exactly bounded | `CREATE INDEX CONCURRENTLY` interrupted leaves an `INVALID` index; a re-run does **not** silently repair it; the documented repair does |
| AC-4 | Flyway follows the promotion | With multi-host JDBC and `targetServerType=primary`, a re-run after failover reaches the new primary with no reconfiguration |
| AC-5 | A blocked migration is bounded | Under `synchronous_mode_strict` with no standby available, the migration is ended by a timeout rather than hanging indefinitely |

### AC-2 is vacuous without its negative control

If it passes because PostgreSQL advisory locks are never left held, the test has
proven nothing about its own ability to detect the problem. It must also show a
**deliberately** held lock blocking a second run — demonstrating that the check
can see the condition it reports as absent.

### AC-3 is AC-1's negative control

AC-1 claims interrupted migrations leave no partial state. AC-3 shows the
guarantee has a boundary and exactly where it lies. Proving the safe case alone
would imply a guarantee broader than the one that exists.

### AC-5 matters because a hang is worse than an error

`synchronous_mode_strict` turns "no standby available" from a silent degradation
into a block. That is the [intended trade](../SLA.md#the-exception-being-closed),
but a migration that hangs reports nothing, holds its lock, and stalls the
pipeline behind it. The timeout is what converts it into a failure someone can
see.

## Notes specific to this cluster

- **Flyway needs the same primary-seeking configuration the client has.** The
  JDBC equivalent of `Target Session Attributes=primary` is a multi-host URL with
  `targetServerType=primary`. Without it, a re-run after failover reaches a stale
  host or a replica and fails read-only — noisy, but only by luck.
- **TLS from the JVM is worth verifying early.** pgJDBC accepts a PEM file for
  `sslrootcert`, unlike much of the Java ecosystem, which expects a keystore.
  Confirm it against a live cluster before building around it: an unverified
  assumption about a TLS stack has already cost this series once, when .NET on
  macOS turned out not to implement TLS 1.3.
- **A long migration loses everything on failover.** A backfill running for
  minutes is one transaction; the primary dying rolls all of it back. That is
  correct, and it is the argument for batching that [Lab 6](../lab6/README.md)
  makes on different grounds.
- **Quorum commit taxes every batch.** Each commit waits for a standby fsync, so
  batch sizing matters more here than on an asynchronous cluster.

## What this contributes back

Not a measurement, but a table the other labs can rely on: **which migration
types are failover-safe**, and what each leaves behind when interrupted.

[Lab 6](../lab6/README.md) then has to route its zero-downtime advice around
whatever Lab 5 finds unsafe — which is a real constraint rather than a
cross-reference, given that the two labs recommend opposite things about
`CREATE INDEX CONCURRENTLY`.
