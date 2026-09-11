# Lab 4 build plan

How Lab 4 gets built, and why in this order. Every phase names the acceptance
criterion it serves; anything that serves none does not belong here.

The criteria are in [README.md](README.md): **AC-1** replace a node from the
repository, **AC-2** restore beside a live cluster, **AC-3** recover one table
and move nothing else, **AC-4** an exact point-in-time boundary, **AC-5** total
loss recoverable, **AC-6** the result is a cluster, **AC-7** every rung's cost
measured, **AC-8** recovery fails closed.

## What we borrow

| From | How it is used here |
| --- | --- |
| [Lab 3](../lab3/README.md)'s repository **design** | The MinIO store, the encrypted stanza, the leader-gated backup and dump jobs — all carried over. Not Lab 3's *data*: this lab gets its own bucket and stanza and fills them itself, or a `make clean` in Lab 3 would break recovery here |
| Lab 3's `.recovery-inputs/` split | Already survives `make clean` by design, and already survived a real accidental teardown. It becomes this lab's *input contract* rather than a convenience |
| Lab 3's `lab3-s3` signed client | For the tampered-object case in AC-7, which needs to corrupt one object without pgBackRest's help |
| Lab 2's CA and `generate-pki.sh` | Certificates are **reissued** for the rebuilt nodes, not restored. New VMs get new addresses, and the IP SANs must match |
| Nothing for restore | **All restore work is new.** Nothing in this series has ever restored anything |

## Verified before starting

Probed against Lab 3's live cluster before any of this was written down. The
first question was load-bearing: if a restore could not reconstitute a cluster
whose identity came from the repository, this lab would have had no path at all.

| Question | Answer | How |
| --- | --- | --- |
| Can a restore reconstitute a cluster whose identity comes **from the repository**? | **Yes.** The restored copy's system identifier matched the source exactly. Lab 3's `[028]` constraint applies to `stanza-create` adopting an *existing* database, not to `restore` writing a new one | **measured** |
| Can a copy be restored **beside** a live cluster without disturbing it? | **Yes.** Restored to a separate path, started standalone on port 5433, promoted to read-write. Production stayed on its timeline throughout, kept serving, and `pgbackrest check` still passed | **measured** |
| Does a restored copy interfere with the repository? | **It will, if you let it.** It inherits `archive_command` from the backup, so a promoted copy pushes WAL from a divergent timeline into the production stanza. Disabling `archive_mode` kept the repository clean | **measured** — see R3 |
| Can you connect to the copy the obvious way? | **No.** It inherits production's `pg_hba.conf`, so TCP demands SSL and a password. Use the Unix socket and peer auth — `psql -h 127.0.0.1` prompts for a password, and in a script will consume the rest of stdin | **measured**, the hard way |
| Is `--type=time` exact? | **Only to the second, which is not exact enough.** A target captured with `now()::timestamp(0)` excluded five rows committed in that same second. The restore was precise; the target was not | **measured** — and it is why AC-3 targets a restore point or LSN |

That last result is the empirical version of advice this repository already gave:
[`WHY_PGBACKREST_AND_PGDUMP.md`](../WHY_PGBACKREST_AND_PGDUMP.md) calls timestamps
"the weak option: clock skew, and no way to separate two events in the same
second". It took an accidental demonstration to make it concrete.

## Decisions taken

Four choices that shape the work, settled before building rather than discovered
during it.

| Decision | Why, and what it costs |
| --- | --- |
| **Fork Lab 3, then build this lab's own backup history** | Every lab in this series is standalone, and coupling Lab 4 to Lab 3's live repository would mean a `make clean` over there breaks recovery over here. Costs a phase and a few minutes per build |
| **The restore target is its own LUKS volume** | A full copy of production restored onto the root filesystem would sit unencrypted on a cluster whose entire premise is that production data never does. Costs one more encrypted volume per node |
| **AC-4 targets a restore point or LSN, and proves a timestamp cannot** | Asserting exactness with the precise instrument, and keeping the imprecise one as a negative control — because in a real incident nobody created a marker beforehand, and the runbook has to say what that costs |
| **The dataset stays small, and the timings say so** | Recovery finishes in seconds here, which proves the *ordering* of the ladder but says nothing about a real database. The figures go into [`SLA.md`](../SLA.md) labelled as not representative rather than quietly implying they are |

| **This lab owns every rung that reads the repository** | Rung 4 — recovering one table from a dump — was [Lab 8](../lab8/README.md)'s, and an exact-PITR criterion was asserted in both labs. Mechanisms now live in one place and scenarios cite them; Lab 8 keeps only what a mechanism cannot tell you. Costs this lab one more criterion, and removes a duplicate assertion two labs were free to disagree about |

Three further choices, applied without ceremony because the alternative is
indefensible: the copy is started by a wrapper that always disables archiving
(R3); the lab **refuses to build** when `.recovery-inputs/` is absent rather than
regenerating it (R2); and `create_replica_methods` with pgBackRest becomes
permanent configuration, because rebuilding a standby from the primary loads it
under exactly the conditions that caused the failure.

## Phases

Ordered by **rung**, cheapest first, because each rung is a superset of the
previous one's machinery and the cheap ones are the ones an operator actually
needs. Building total loss first would leave the most-used procedure until last.

| Phase | What to run | Why |
| --- | --- | --- |
| **P0** | `make all` | The baseline, once |
| **P1** | `configure_cluster`, `verify_cluster` | It only writes data and takes backups |
| **P2, P3, P4** | `configure_cluster`, `verify_cluster`, plus that phase's checks | Rebuilding one standby, restoring beside, and restoring one table must all leave the cluster serving — which is the property under test, not a reason to run the whole suite |
| **P5, P6** | `make all` | Both rewind or rebuild the cluster. Everything the earlier labs assert has to hold afterwards, or the recovery produced something that only looks like a cluster |

### P0 — Fork Lab 3, and add somewhere to restore to — **done**

> Built from nothing: **23 phases, 22 passing on the first run**, and 20 of 20 on
> re-check after the one failure was fixed. The restore volume is a distinct
> `crypto_LUKS` device on `/dev/vdd`, mounted at `/var/lib/pgsql-restore`,
> `postgres:postgres 0700` and empty, on all three nodes.
>
> **The one failure was a check written yesterday, not the lab.**
> `test_repository` inspects backups but ran *before* `test_backup` created any,
> so on a genuinely fresh build there were none — and the assertion above it,
> "everything listed is in the bucket", **passed vacuously on zero items**. Both
> fixed, in Lab 3 as well: the phase order now guarantees a backup exists, and an
> empty repository fails that check instead of satisfying it.
>
> Lab 3 had only ever passed it because its timers had been running for hours.
> It was timing-dependent and would have failed there too from scratch.
>
> Independence from Lab 3 is now asserted rather than audited. `test_minio`
> checks that **no executable file in this lab names another lab**, ignoring
> comments — a citation is provenance, a name is a shared stanza or port. Proven
> to fail by injecting `lab3-backups` into a script and watching it catch it.


**What.** `lab4/` becomes a working copy of Lab 3, renamed, plus a third
encrypted volume that exists only to hold restored copies.
**How.** Copy `lab3/`, rename `lab3-*` to `lab4-*`, with a **new stanza and a new
bucket**. Add a `restore` LUKS volume per node at `/var/lib/pgsql-restore`,
alongside the existing `pgdata` and `etcd` volumes and sized like `pgdata`.
**Serves.** Nothing directly. The baseline, and the ground rung 3 stands on.
**Done when.** `make all` in `lab4/` is green from scratch, and the restore
volume is a distinct `crypto_LUKS` device mounted and empty.

> Two things the rename is not free for. Lab 3 learned that a `find` for
> `README.md` matches every README including the one being preserved, and that a
> stanza belongs to one database — so a forked lab needs its own stanza and
> bucket, or it inherits Lab 3's repository and refuses to start.
>
> The restore volume is encrypted for the reason Lab 2 exists: a restored copy
> is a **complete copy of production**, and putting it on the root filesystem
> would leave production data at rest unencrypted on a cluster built to prevent
> exactly that. It is the same data; it does not become less sensitive by being
> a copy.

### P1 — A history worth restoring from — **done**

> `make test_history` passes, and repeatably: two full backups, ten rows either
> side of a marker, the marker's WAL segment confirmed present **in the
> repository** rather than only on the primary, and `verify` passing across the
> window.
>
> It emits the marker in all three forms at one moment, which is what AC-4 needs
> in order to compare them:
>
> ```text
> restore point  lab4_history_20260911153433
> LSN            0/63001F10
> timestamp      2026-09-11 16:34:33.941832+01
> ```
>
> The first version was not repeatable — it asserted exactly ten rows each side,
> so a second run would have counted twenty and failed for a reason unrelated to
> the property. It now clears its own rows first. Worth catching here: a check
> that only works once is a check that fails the first time someone re-runs it
> under pressure.


**What.** The repository gains backups and WAL spanning a known sequence of
writes, before any recovery is attempted.
**How.** Drive a period of writes with markers at known points: a named restore
point, a captured LSN, and a timestamp for the same moment — AC-3 needs all
three to compare. Let the existing timers take a full and several incrementals
across it.
**Serves.** Every later phase. Nothing can be restored until something was backed
up.
**Done when.** `pgbackrest info` shows a full plus incrementals, the archive
spans the marked window with no gap, and each marker is recoverable from the
repository rather than only from the primary's memory.

> This phase exists because the lab is standalone. Coupling to Lab 3's
> repository would have skipped it — and made this lab unrunnable whenever Lab 3
> had been torn down.

### P2 — Rung 1: replace a node from the repository

**What.** A standby is rebuilt without touching the primary.
**How.** Add `pgbackrest` to Patroni's `create_replica_methods`, ahead of
`basebackup`. Destroy a standby's data directory, let Patroni rebuild it, and
assert from the logs that the repository was the source.
**Serves.** AC-1.
**Done when.** The rebuilt node streams again, and the primary served no base
backup — which is the point: a cluster that can only rebuild standbys *from the
primary* degrades under exactly the load that caused the failure.

### P3 — Rung 3: restore beside a cluster that keeps serving

**What.** The rung this lab was extended to cover, and the one an operator
reaches for most.
**How.** Make a deliberate, recorded change to known rows. Restore a copy from
the repository to a separate path, targeted before that change, on a port
Patroni does not manage. Read the old values out of the copy; write them back to
production. A client commits throughout.
**Serves.** AC-2, and AC-7's zero-loss half.
**Done when.** The damaged rows hold their original values, **every unrelated
row written during the operation is still present**, and the client recorded
zero failed transactions.

> The copy must be unmistakably a *restore*: its target precedes the change, so
> the values it yields cannot be read from production at any point. Otherwise
> the check passes on a cluster where nothing was ever restored.

### P4 — Rung 4: one table back, and nothing else moved

**What.** The cheaper of the two instruments for damaged data, and the one an
operator should reach for first.
**How.** Damage a known table. Restore just that table from a logical dump taken
before the damage, while the rest of the database keeps taking writes.
**Serves.** AC-3.
**Done when.** That table holds its pre-damage contents, and **every other table
kept every row written since** — including rows written while the restore ran.

> Restoring one table is easy. Restoring one table *while the database around it
> keeps committing, and keeping all of it*, is the property that makes this rung
> cheaper than rewinding — and the only one worth asserting.

### P5 — Rung 5: rewind the cluster, exactly

**What.** Point-in-time recovery to a marker, on the real cluster.
**How.** `pg_create_restore_point` plus `pg_switch_wal`, writes on both sides of
it, then `patronictl pause`, restore to the marker, resume, and rebuild the
standbys — they hold the future and are not a recovery source.
**Serves.** AC-4, AC-6, and AC-7's costly half.
**Done when.** Every row before the marker is present, every row after it is
absent, the cluster is whole again, and **the number of discarded transactions
is reported**.

### P6 — Rung 6: total loss

**What.** The lab's original premise, now the top of a ladder rather than the
whole of it.
**How.** Destroy the VMs, their volumes **and** `.secrets/`. Rebuild onto fresh
VMs from the repository plus `.recovery-inputs/` alone, reissuing certificates
from the surviving CA for the new addresses.
**Serves.** AC-5, AC-6, AC-7.
**Done when.** A working three-node cluster holds the committed data, an Npgsql
client commits through it, and recovery time is reported split into restore and
replay.

### P7 — Fails closed, and the ladder's cost table

**What.** The negative controls, and the numbers that make the ladder a decision.
**How.** Three deliberate corruptions: a wrong cipher passphrase, a target
earlier than the oldest base backup, and one repository object altered with
`lab4-s3`. Then collect each rung's measured time and row loss into one table.
**Serves.** AC-7, AC-8.
**Done when.** All three fail loudly, and the cost table is emitted by the run
rather than written by hand.

## Risk

Two items qualify: uncertain, and silent when they happen.

**R1. A restore produces a plausible cluster that is quietly wrong.**

This is the defining risk of the whole lab. A half-decrypted repository, a
target that overshot, or a tampered object can each yield a cluster that starts,
accepts connections and looks entirely healthy — while holding the wrong data.
Unlike every failure in Labs 1 to 3, **nothing raises an error**, and the result
will be believed precisely because it was produced by a recovery procedure.

| Layer | Catches |
| --- | --- |
| AC-4 asserts the boundary in **both** directions | A target that overshot, which a "rows are present" check cannot see |
| AC-8's three negative controls | Corruption and wrong keys, by requiring a loud failure rather than a plausible result |
| AC-6 requires a *cluster*, not a data directory | A restore that produced a running postmaster and nothing else |

**R2. Something needed for recovery turns out to be a build product.**

The lab proves nothing if an input it "supplies" is quietly regenerated by the
build. Lab 3 came within one design decision of this: had the cipher passphrase
been born in `.secrets/` with every other credential, a teardown would have
destroyed it and the surviving repository would have been permanently unreadable.

Mitigated by making the input contract explicit and **failing** rather than
regenerating: if `.recovery-inputs/` is absent, this lab must refuse to build
rather than helpfully create it. A recovery lab that can regenerate its own
recovery inputs is testing nothing.

**R3. A restored copy poisons the repository it was restored from.**

Measured, not imagined. A copy restored from the repository inherits
`archive_command` from the backup. Promote it — which rung 3 requires, so the
copy can be read — and it begins pushing WAL from a **divergent timeline** into
the production stanza. The repository being corrupted is the one failure that
makes every other rung on this ladder unavailable, and it would be caused by the
recovery procedure itself.

It is silent in both directions: the copy works perfectly, and production keeps
running. The damage is only visible later, to a restore that needed those WAL
segments.

| Layer | Catches |
| --- | --- |
| The copy is started by a wrapper that always sets `archive_mode=off` | The operator forgetting, which is the realistic case |
| The copy's restore target is its own volume and its own port, never the production data directory | A restore performed *over* production by mistake |
| `pgbackrest check` and `verify` after every rung | Pollution that happened anyway, before it is relied upon |

## Carried into Lab 5

[Lab 5](../lab5/README.md) is monitoring, and two of its metrics only become
meaningful once this lab exists:

- **The age of the last successful backup** is the headline metric there. This
  lab supplies what it is worth: a measured restore time per rung, so an alert
  on backup age can be tied to a stated recovery cost rather than a feeling.
- **Restore rehearsal age** is a metric this lab creates the need for. A backup
  regime that has not been restored since the last schema change is a hypothesis
  again, and nothing else in the series would notice.

## What this contributes back

[`SLA.md`](../SLA.md) records the RTO for corruption, deletion and a bad
migration as **not established**. Lab 3 filled the RPO half of that row. This
lab fills the other half — and it should fill it as a **range across the
ladder**, not a single number, because that is the honest answer: minutes and no
data lost at rung 3, hours and a bounded window at rung 6.

[`RUNBOOKS.md`](../RUNBOOKS.md) gains the most from this lab. Runbook 10 is
currently a **stub** that says not to follow it, and runbook 9's restore
commands are **REASONED**. Both become VERIFIED here, and the
[decision table](../RUNBOOKS.md#which-recovery-do-you-need) stops being advice
and starts being a summary of measured results.

That table is also the reason this lab took rung 4 from Lab 8. A ladder is only
useful if its rungs are comparable, and they are only comparable if one run
measures them the same way. Split across two labs, rung 4's cost and rung 5's
cost would have been produced by different harnesses, months apart, and the
ordering between them would have been an assertion again.
