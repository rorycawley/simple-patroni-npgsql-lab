# Lab 4: recovery

> **Status: specified, not built.** Everything below is the design and its
> acceptance criteria. No results are claimed.

The shared components, cluster design and prerequisites are in the
[top-level README](../README.md). This file covers Lab 4 only: the recovery
options, and how each is judged. [`PLAN.md`](PLAN.md) covers how it gets built —
the phases, their order, and the two risks worth watching.

## Goal

Get the data back at **whatever blast radius the situation actually calls for** —
from replacing one node, through reading old values out of a copy while
production keeps serving, to rebuilding a destroyed cluster from nothing but the
repository.

The hard part of recovery is not performing a restore. It is choosing the
cheapest instrument that works, under pressure, having never rehearsed the
others. Every option below gets the data back; they differ by a factor of
hundreds in what they cost.

The ladder is defined once, in
[`RUNBOOKS.md`](../RUNBOOKS.md#which-recovery-do-you-need), and its rung numbers
are used here unchanged. This lab proves the four rungs that need the
repository:

| Rung | What happened | Instrument | You lose | Proven by |
| --- | --- | --- | --- | --- |
| **1** | One node lost | Rebuild it from the repository | nothing | AC-1 |
| **3** | You know which rows, not their old values | **Restore beside a live cluster** | **nothing** | AC-2 |
| **4** | One table is mangled, the rest is fine | Restore that table from a logical dump | later writes to that table | AC-3 |
| **5** | Damage too pervasive to reconstruct | Rewind the cluster to a marker or LSN | everything since | AC-4 |
| **6** | Every node, volume and local secret gone | Rebuild onto fresh machines | ≤ `archive_timeout` | AC-5, AC-6 |

Rungs **0** and **2** need no backup at all — they are SQL discipline, argued in
[`WHY_PGBACKREST_AND_PGDUMP.md`](../WHY_PGBACKREST_AND_PGDUMP.md#before-a-manual-change-do-you-need-either).
Every rung that touches the repository is proven here, in one place, so that
choosing between them is a matter of reading one table.

## This is a test of the dependency graph, not of pgBackRest

The obvious version of this lab — "prove pgBackRest can restore" — proves very
little. pgBackRest restores; that is not in doubt.

What is in doubt is whether **you** can perform a restore once everything is
gone. So the question the lab actually asks is:

> Is anything required for recovery stored only inside the thing that was lost?

That is why the loss here is deliberately brutal, and why the restore goes onto
fresh VMs. A rebuild onto the original machines, with the original configuration
still lying around, quietly assumes away most of a real disaster.

## The boundary with Lab 8

The split used to be *cluster gone here, cluster healthy there*. That stopped
being true when this lab took on rung 3, which restores a copy beside a
perfectly healthy cluster. The honest division is not the state of the cluster
but what each lab is for:

| | Owns | Answers |
| --- | --- | --- |
| **Lab 4** | The **mechanisms** — every rung that reads the repository, and what each costs | *Does recovery work, and which rung should I reach for?* |
| **[Lab 8](../lab8/README.md)** | One **scenario** — a migration that succeeded and was wrong | *What does undoing this particular mistake cost me?* |

So point-in-time recovery is proven here (AC-3, an exact boundary) and *applied*
there, against a bad migration, where the interesting question is not whether it
works but how many committed transactions it discards.

## What "total loss" means here

Destroyed, in this order:

1. All three VMs
2. Their LUKS volumes — both `pgdata` and `etcd`, so no data and no cluster state
3. The local `.secrets/` directory — passwords, `pgpass`, and the PKI

Point 3 is what makes the lab honest. Keeping `.secrets/` would leave the most
interesting question untested: not *can pgBackRest restore*, but *where does the
cipher passphrase actually live*. Everything needed for recovery must be
**supplied to the lab as an input**, standing in for OpenBao or an offline copy,
rather than found lying around from the build.

### The recovery inventory

What must survive, and the failure if it does not:

| Must survive | If it does not |
| --- | --- |
| The MinIO repository | Nothing to restore from |
| `repo1-cipher-pass` | Every backup is unreadable — permanently |
| The CA key, or a way to issue certificates | The rebuilt nodes cannot form a TLS cluster |
| Superuser and replication passwords | Patroni cannot bootstrap or attach standbys |
| The stanza name and repository layout | You have the data and cannot address it |
| The procedure itself | Everything above exists and nobody knows the order |

The last row is not a joke. A recovery that depends on one person's memory has a
single point of failure the architecture diagram does not show. The procedures
live in [`RUNBOOKS.md`](../RUNBOOKS.md), where this one is still a **stub** —
writing confident steps for a restore nobody has performed is the failure this
lab exists to prevent.

### The first two rows already survive, and that was not free

[Lab 3](../lab3/README.md) built this rather than leaving it to be arranged here.
Its `make clean` destroys the VMs, their volumes and `.secrets/` — and
deliberately keeps the repository in `.minio/` and both cipher passphrases in
`.recovery-inputs/`, outside everything a teardown removes.

That split was tested by accident within a day of being written. A rebuild
regenerated `.secrets/` with a new CA and new passwords while the repository
survived; because the passphrases had been kept out of it, the surviving backups
were still readable. Had they been born in `.secrets/` like every other
credential, a routine rebuild would have made them **permanently** unreadable —
the failure this table's second row names.

It also surfaced the constraint this lab has to work within: a pgBackRest stanza
belongs to one database, so a rebuilt cluster cannot adopt the old repository.
Recovery here is therefore a *restore*, never a rebuild that happens to find
backups lying around.

## Restoring onto fresh VMs

The rebuilt nodes are new instances with new disks, and Lima will generally give
them different addresses. That is a feature: certificates in
[Lab 2](../lab2/README.md) carry IP SANs, so the restored cluster needs
certificates **reissued from the surviving CA** rather than recovered alongside
the data.

It splits recovery cleanly into the two things that must both work:

| What is restored | From |
| --- | --- |
| PostgreSQL data and WAL | The repository — address-independent |
| Cluster identity: certificates, `pg_hba`, Patroni configuration | Rebuilt for the new hosts from surviving inputs |

A backup that restores the data but leaves you unable to reconstruct the second
column is not a recovery plan.

## Scope

| In scope | Out of scope |
| --- | --- |
| Total loss: VMs, volumes and local secrets destroyed | Recovering from a bad migration — that is [Lab 8](../lab8/README.md) |
| Restore onto fresh VMs with new addresses | Restoring into a different PostgreSQL major version |
| Point-in-time recovery, proven on both sides of the target | Cross-region or offsite repository replication |
| Rebuilding a replacement replica from the repository | Automated or unattended recovery |
| **Restoring a copy beside a cluster that keeps serving** | Losing the repository as well — see below |
| Measuring what each rung costs, in time and in rows | Deciding *for* you which rung applies |

> Restoring beside a live cluster was originally out of scope here, on the
> grounds that this lab was about total loss. That was wrong: it is the rung an
> operator reaches for most, the only one that recovers unknown values while
> losing nothing, and it was specified nowhere and tested nowhere.

### Losing the repository is the limit, and is not tested

Every rung depends on the repository surviving. If it does not, none of this
works — there is nothing to restore from, and no procedure recovers it.

That is stated rather than demonstrated, because demonstrating it would prove
only that an empty bucket is empty. The mitigation is a second repository,
which pgBackRest supports and which
[the production gap list](../README.md#from-lab-to-production) already carries.
One repository is a single point of failure for every recovery in this lab.

## Acceptance criteria

| ID | Property | Pass condition |
| --- | --- | --- |
| AC-1 | **Rung 1** — a node is replaced from the repository, not from the primary | A node is rebuilt using Patroni's `create_replica_methods` with pgBackRest, with no `pg_basebackup` from the primary, and rejoins as a streaming standby |
| AC-2 | **Rung 3** — a copy is restored beside a cluster that never stops serving | With production taking writes throughout: a copy is restored onto its own encrypted volume, targeted before a deliberate change, and started on a port Patroni does not manage; the pre-change values are read out of it and written back to production. A client committing for the whole operation records **zero failed transactions**, **every unrelated row written during it is still present**, and the repository still passes `check` and `verify` afterwards |
| AC-3 | **Rung 4** — one table comes back, and nothing else moves | Restore a single table from a logical dump taken before the damage. That table holds its pre-damage contents; **every other table keeps every row written since**, including rows written while the restore was running |
| AC-4 | **Rung 5** — the point-in-time boundary is exact | Targeting a **named restore point or an LSN**: rows committed before the target are **all present**; rows committed after are **all absent**. Its negative control targets the *same moment by timestamp* and is required to be **inexact** — it cannot separate two events in the same second |
| AC-5 | **Rung 6** — total loss is recoverable | With all VMs, volumes and local secrets destroyed, a working cluster is rebuilt from the repository plus supplied inputs alone. Nothing is recovered from a surviving node, because there is none |
| AC-6 | The result is a cluster, not a data directory | Patroni owns it: one leader, two streaming standbys, quorum commit active, watchdog armed, and the Npgsql client completes a read-write probe |
| AC-7 | Every rung's cost is measured, in time **and** in rows | For each rung: wall-clock to recover, and how many committed transactions it discarded. Rungs 1 and 2 must report **zero rows lost**, or they are not the rungs this lab claims they are. The elapsed times are reported as **not representative** — this database is small enough to restore in seconds |
| AC-8 | Recovery fails closed | A wrong cipher passphrase, a target earlier than the base backup, and a tampered repository object each fail loudly rather than producing a plausible-looking cluster |

### AC-2 is the one that changes how people work

The other rungs recover from a disaster. This one recovers from a *mistake*,
which is far more common, and it is the only rung that costs nothing at all —
no downtime, no discarded transactions, no rebuild of the standbys.

Its two negative halves are what make it more than a demonstration that
`pgbackrest restore` accepts a `--pg1-path`. **Production must never stop
serving**, and **nothing written during the operation may be lost**. A restore
performed *over* production satisfies neither, and is what an operator reaches
for when this rung has never been rehearsed.

It also has to be shown to be a *restore* rather than a lucky read of live data:
the copy is targeted at a point before the change, so the values it yields
cannot be obtained from production at all.

### AC-4 proves the right instrument by failing with the wrong one

Measured while planning this lab, and it is why the criterion names its target
type: a restore targeted at `now()::timestamp(0)` excluded five rows committed in
that same second. The restore was precise; **the target was not.** A timestamp
cannot distinguish two events within one second, so it cannot support a criterion
that asserts an exact boundary in both directions.

The timestamp case stays in as a negative control rather than being dropped,
because it is the case a real incident presents: nobody creates a restore point
before making a mistake. What the runbook needs to say is not "use a restore
point" — it is "if you only have a timestamp, this is the precision you get",
and that requires measuring it.

### AC-4's second half is the one usually skipped

A restore that includes **too much** is as wrong as one that includes too
little, and only the "absent" half detects it. It is also the half
[Lab 8](../lab8/README.md) depends on, where discarding everything after the
marker is the entire point rather than an accident.

### AC-3 is the rung Lab 8 used to own

Recovering one table from a dump is a *mechanism*, and it sits here with the
other four rather than inside the one scenario that happens to need it. Lab 8
keeps what only it can assert: that a bad migration is invisible to every HA
mechanism, and what undoing it costs.

Its second half is the whole claim. Restoring one table is easy; restoring one
table **while the rest of the database keeps taking writes, and keeping all of
them**, is the property that makes this rung cheaper than rewinding.

### AC-6 is the bar this lab refuses to lower

It is easy to restore a data directory, start PostgreSQL, see the rows and call
it recovered. That is a running database, not a recovered cluster: no
replication, no fencing, no failover. Until Patroni owns it and a client can
commit through it, the disaster is not over.

### AC-7 is what makes the ladder a decision and not a preference

A ladder whose rungs are ordered by assertion is folklore. Ordered by measured
cost, it is an instruction someone will follow at 02:00 — and the two figures
that matter are not the same figure. Rung 6 may take hours and lose a minute;
rung 5 may take minutes and lose a day. Reporting only elapsed time would make
the more destructive option look like the cheaper one.

### AC-8 is why the negative controls exist

A restore that silently produces a plausible cluster from a corrupt or
half-decrypted repository is worse than one that fails, because it will be
believed. The tampered-object case in particular tests whether the repository can
detect its own corruption, which is otherwise an assumption.

## Notes specific to this cluster

- **Patroni must be paused for an in-place restore.** Not needed for the fresh-VM
  path, where there is no Patroni yet — but it is the first step of the variant
  people reach for under pressure, and omitting it means Patroni tries to repair
  the node being deliberately rewound.
- **`synchronous_mode_strict` affects the rebuild.** A restored primary with no
  standby attached cannot accept writes until one rejoins. Correct behaviour, and
  easily mistaken for a failed restore — attach a standby before concluding
  anything.
- **PITR starts a new timeline**, and the standbys must follow it. `check_timeline`
  is already `true` in the distributed configuration, so a standby that cannot
  reach the new timeline should refuse to attach rather than silently diverge.
- **etcd is rebuilt, not restored.** It was never backed up, by
  [Lab 3](../lab3/README.md)'s deliberate choice: it holds state Patroni can
  reconstruct. A fresh etcd cluster with restored PostgreSQL data is the correct
  end state.

## What this contributes back

[`SLA.md`](../SLA.md) currently records the RTO for corruption, deletion and bad
migrations as **not established**, sourced to "Labs 3, 4, 8 — not built". Lab 4
is what replaces that with a measured number, in the same way
[Lab 5](../lab5/README.md) is what supplies detection latency.

Until then the honest position stands: the labs can state how fast the cluster
recovers from a node it lost, and cannot yet state how fast it recovers from
losing everything.
