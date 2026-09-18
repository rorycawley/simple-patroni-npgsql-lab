# Lab 7 — build plan

The design and its acceptance criteria are in [`README.md`](README.md). This file
is the order of work: what is already known, what was decided, what each phase
must prove, and what could go wrong.

## What this lab inherits

Lab 7 forks [Lab 6](../lab6/README.md) and uses five things from it directly:

| Inherited | Used for |
| --- | --- |
| A client that commits continuously and reports what it saw | AC-1 and AC-2, both stated in failed transactions rather than in uptime |
| An encrypted cluster with PKI on every channel | The TLS the JDBC driver has to satisfy — the one inherited component this lab cannot take on trust |
| `synchronous_mode_strict` and quorum commit | The reason a blocked migration hangs instead of failing, and the tax on every backfill batch |
| Failover and fencing, proven and repeatable | AC-5's injection, reused rather than rebuilt |
| Monitoring with a real mailbox | Not required by any criterion here, but it is what would show a migration stalling the cluster |

## Known before starting

From this repository and the labs already built. **Nothing below is measured
against Flyway**, because Flyway has never run here — the four rows in the second
table are the ones that decide whether the lab is possible at all, and P0 exists
to answer them before anything is built on top.

| Known | Consequence |
| --- | --- |
| `migrator` owns the tables it creates ([`SERVICE-ACCOUNTS.md`](../SERVICE-ACCOUNTS.md)) | Default privileges must be set **for role `migrator`**, or the application sees nothing Flyway adds. A migration that "succeeds" and leaves the app unable to read the table is the failure mode |
| `app_runtime` and `migrator` are separate roles | Flyway gets its own VM. Co-locating it on the app host would quietly re-merge a separation the design depends on |
| Under `synchronous_mode_strict`, a write with no standby **blocks** | A migration in that state hangs holding its lock, reporting nothing. A statement timeout is what converts it into a failure someone can see |
| Quorum commit makes every commit wait for a standby fsync | Backfill batch sizing matters more here than on an asynchronous cluster |
| `ALTER TABLE` takes `ACCESS EXCLUSIVE` | The outage comes from the queue behind the lock, not from the DDL. That is what AC-2 measures |
| Transactional DDL, and Flyway's session-scoped advisory lock | AC-5's two feared failures largely cannot happen — which is why AC-5 has to prove its instrument can detect them |
| Lab 6 measured a full rolling upgrade at 67s with zero failed transactions | The client harness already reports what AC-1 needs, in the units AC-1 is stated in |

### What P0 must establish, because it is currently unknown

| Question | Why it decides the lab |
| --- | --- |
| Does a JVM and a Flyway build exist for **Rocky 9 on aarch64**? | Everything here runs on one arm64 laptop. No Flyway, no lab |
| Does **pgJDBC** accept the PEM `sslrootcert` this cluster issues? | Much of the Java ecosystem wants a keystore. .NET on macOS not implementing TLS 1.3 already cost this series once — an unverified assumption about a TLS stack is not a foundation |
| Does `targetServerType=primary` actually follow a failover? | Without it a re-run after failover reaches a replica and fails read-only, which would make AC-5 untestable rather than failing |
| Do **five** VMs fit in 16GB? | Lab 6 ran four and was OOM-killed mid-suite. This is a sizing decision, not a hope |

## Decisions

| Decision | Why | Cost accepted |
| --- | --- | --- |
| Fork Lab 6 | It is the only base carrying the encrypted cluster, the committing client and proven failover together | Lab 6 is destroyed first; nothing here depends on its data |
| Flyway on its own VM | `migrator` and `app_runtime` are different actors; in production the thing that migrates is not the thing that serves traffic | A fifth VM on a host that has already refused four |
| Size `app1` and `flyway1` down, not the database nodes | The database nodes are where the lab's behaviour lives; the other two only need to run a client and a JVM | Flyway starts slower on a small heap |
| Measure the negative control **first** in AC-2 | A test that only demonstrates the safe configuration has not shown the danger it claims to prevent | The most disruptive test in the lab runs against a healthy cluster on purpose |
| A statement timeout on every migration | `synchronous_mode_strict` turns "no standby" into a silent hang | A migration can now fail for a reason unrelated to its SQL, and the message must say which |
| `make check` excludes Lab 6's patching phases | Lab 7's subject is migration. Re-proving the patch cycle every run would push a cycle past 90 minutes | They stay available as targets |

## Hazards carried forward from Lab 6

Four things cost real time in Lab 6 and will cost it again here unless they are
designed for from the start.

| Hazard | What it does here |
| --- | --- |
| **`limactl shell` does not return when its guest command is killed** | Every guest command this lab issues must be bounded on the HOST side, not only with `timeout` inside the guest. One such hang ran for 88 minutes |
| **Phases that cannot run twice** | Three of Lab 6's phases failed their first suite run for this reason alone. Every phase here levels its own preconditions — and `CREATE INDEX CONCURRENTLY` debris makes AC-6 the worst offender |
| **A cold ruler inflates every alert latency** | Any measurement taken minutes after the stack starts reads high: Lab 6 saw 281s for an alert that fires at 131s warm |
| **The host memory ceiling is real, not theoretical** | Lab 6 was OOM-killed mid-phase at four VMs. A kill lands wherever the run happens to be, and P6 here holds an INVALID index the next phase has to cope with |

## Phases

| Phase | Proves | In one line |
| --- | --- | --- |
| P0 | — | Flyway reaches this cluster as `migrator`, over TLS, against the primary |
| P1 | AC-1 | An additive migration the client never notices |
| P2 | AC-2 | The queue behind the lock, measured with and without `lock_timeout` |
| P3 | AC-3 | Both application versions against both schemas |
| P4 | AC-4 | A rename shipped expand → backfill → switch → contract |
| P5 | AC-5 | Interrupted two ways, and the instrument shown able to catch what it claims |
| P6 | AC-6 | The one construct that leaves debris, bounded exactly |

### P0 — Flyway reaches the cluster, and the unknowns are answered

Fork into `lab7/`, renaming `lab6` → `lab7`. Comments that name a lab by its
*purpose* must be re-read rather than renamed: a blind substitution has twice
turned a correct sentence into a false one in this series.

Add `flyway1`, size it and `app1` down, and answer the four unknowns above **by
use rather than by listing** — a dry run that resolves is evidence, a version in
a repository is not. Create `migrator` with default privileges set against the
role, and prove the application can read a table Flyway created.

Build the deploy gate the scope calls for: a precondition check against Patroni
that refuses to migrate a degraded cluster.

**Done when:** Flyway applies a baseline migration through TLS, as `migrator`,
against whichever node currently holds the leader key; the application can read
what it created; and five VMs are running at once without the host swapping.

### P1 — An additive migration, invisible to the client

`ALTER TABLE ... ADD COLUMN` with a default, client committing throughout.

**Done when:** zero failed transactions, and no commit gap beyond the client's
normal latency — the gap is the assertion, because a migration can be invisible
in aggregate while stalling every writer for two seconds.

### P2 — The queue behind the lock, both ways

The criterion that matters, and the only one whose negative control is the point
rather than a safeguard.

1. **Without `lock_timeout`.** Hold a conflicting long transaction, run the
   migration, and measure how long the client's commits stall behind the queued
   DDL. Expected: a stall lasting as long as the blocker is held.
2. **With `lock_timeout`.** The same migration, the same blocker. Expected: the
   migration aborts quickly and the client is unaffected.

Both costs are numbers. The expected alerting outcome is written down **before**
each runs, while the fault is induced, rather than judged afterwards.

**Done when:** both stalls are measured, the second is bounded by the timeout,
and the cluster is healthy again.

### P3 — Both versions, both schemas

The four combinations of `v1`/`v2` against the pre- and post-migration schema.

**Done when:** all four succeed — rollout *and* rollback proven, rather than
rollout alone.

### P4 — A destructive change, shipped without downtime

A column rename via expand → backfill → switch → contract, with AC-1 and AC-3
asserted **at every step** rather than at the end.

The backfill is one transaction unless it is batched, and a failover rolls all of
it back. Batch it, and state the batch size against the quorum-commit tax
measured in P0.

**Done when:** the rename is complete, every step held zero failed transactions,
and both client versions worked at every intermediate schema.

### P5 — Interrupted, two ways, with an instrument that can fail

Kill a migration mid-flight twice: once by aborting the pipeline, once by failing
the primary over underneath it.

**The positive control is the phase.** AC-5's "no lock is held" clause is vacuous
unless the check can detect a lock that *is* held — so a deliberately held
advisory lock must be shown blocking a second run before the clean case means
anything. The same applies to "the schema and history agree": it has to be shown
disagreeing.

**Done when:** both interruptions leave schema and `flyway_schema_history` in
agreement, no lock held, a re-run converges — and each of those three checks has
been watched failing first.

### P6 — The one construct that leaves debris

`CREATE INDEX CONCURRENTLY`, interrupted.

**Done when:** an `INVALID` index is present, a naive re-run is shown **not** to
repair it, and the documented repair does — and the phase leaves the database
clean enough for the suite to run again.

## Risks

| Risk | Mitigation |
| --- | --- |
| **No JVM or Flyway for aarch64 Rocky 9.** The lab cannot be built | P0 answers it first, before anything is built on top. If it fails, the finding is reported rather than engineered around |
| **pgJDBC will not take the cluster's PEM.** A keystore conversion is a day of work and a new secret to manage | P0 proves it against the live cluster by connecting, not by reading documentation |
| **Five VMs do not fit.** Lab 6 was OOM-killed at four | `app1` and `flyway1` are sized down in P0, and the suite is run with the host otherwise idle. If it still will not fit, Flyway moves to the app host and the separation is documented as a compromise rather than silently dropped |
| **A blocked migration hangs the suite** rather than failing it | Every migration carries a statement timeout, and every guest command is bounded on the host side |
| **P6's INVALID index poisons later runs** | The phase cleans up as part of its own assertion, and the suite is run twice before the lab is called done |
| **`CONCURRENTLY` cannot run in Flyway's transaction** | Expected, not a surprise: the migration is marked non-transactional, which is exactly the boundary AC-6 exists to map |

## What carries out of this lab

A migration runbook, an expand-contract procedure with the lock bound stated as a
number, and the repair for an `INVALID` index — each described in
[`README.md`](README.md), which is where the outputs are specified rather than
planned.
