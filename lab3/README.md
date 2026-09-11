# Lab 3: durable backups

> **Status: built and verified.** All six acceptance criteria are met:
> `make all` is **23 of 23 in 9m19s**, covering every check this lab adds
> alongside every check inherited from Labs 1 and 2. That run was against
> existing VMs; the last from-scratch build was 14m02s, before this lab's own
> checks existed. What this lab does **not** claim is that any of it can be
> restored — that is [Lab 4](../lab4/README.md), and keeping them apart is the
> point.

The shared components, cluster design and prerequisites are in the
[top-level README](../README.md). This file covers Lab 3 only: what it must
establish and how each criterion is judged. [`PLAN.md`](PLAN.md) covers how it
gets built — the phases, their order, and the two risks worth watching.

## Goal

Give this cluster a backup history that **exists**, that lives where losing the
cluster cannot reach it, and that is complete enough to be worth restoring.

The first of those was not rhetorical. **Before this lab there was no backup at
all.** Labs 1 and 2 install pgBackRest, create the stanza, archive WAL
continuously, and pass `pgbackrest check` — but nothing ever takes a base backup,
so the archive has nothing to be replayed onto. Their repository is also local to
each node, so it cannot survive losing the node it exists to protect against
losing.

Both are deliberate: those labs demonstrate that archiving is configured
correctly, which is a real prerequisite and not a backup. This lab is where a
configuration that *looks* like backup becomes one.

| | Labs 1–2 | This lab | Built? |
| --- | --- | --- | --- |
| WAL archiving | Continuous, verified | Unchanged, now off-host | **yes** |
| Repository location | Local to each node | MinIO, off every database host | **yes** |
| Repository encryption | None | `aes-256-cbc`, keyed outside the cluster | **yes** |
| Base backups | **None ever taken** | Scheduled full and incremental, with retention | **yes** |
| Logical dumps | None | Scheduled, encrypted, under their own prefix | **yes** |

All of it is built, through P5 of [`PLAN.md`](PLAN.md). The repository is
off-host and encrypted, holds a real backup history taken by whichever node
currently holds the leader key, and carries logical dumps under their own prefix
with their own passphrase — `pgbackrest info` reports `status: ok` where it
reported `error (no valid backups)` three phases ago.

**All six criteria are met.** The last of them, AC-6, also produced the number
this lab owed [`SLA.md`](../SLA.md): a transaction committed immediately after a
promotion reached the off-host archive in **1s** with a forced segment switch,
and `archive_timeout` bounds the same window at **60s** without one. That is the
RPO for corruption and deletion — bounded by the archive, not by backup age.

## Why there are two

They are not two backup systems, and neither is a spare for the other:
**pgBackRest copies files, `pg_dump` copies data.** What each recovers, what
reaching for it costs, and why one of them detects the corruption the other
preserves all follow from that single distinction. The summary is in
[the root README](../README.md#backups-two-instruments-not-two-backup-systems);
the full treatment, including when *not* to use each, is in
[`WHY_PGBACKREST_AND_PGDUMP.md`](../WHY_PGBACKREST_AND_PGDUMP.md).

What this lab needs from that argument is only which instrument answers which
disaster, and where each is proven:

| Situation | Instrument | Proven in |
| --- | --- | --- |
| Every node lost | pgBackRest — full restore | [Lab 4](../lab4/README.md) |
| The cluster must be wound back before a bad change | pgBackRest — PITR to a marker | [Lab 8](../lab8/README.md) |
| One table mangled, everything else fine | `pg_dump` of that table | [Lab 8](../lab8/README.md) |
| "Is the data actually readable?" | a `pg_dump` that completes | this lab, AC-4 |

The third row is what justifies the extra machinery. Recovering one dropped table
from a physical backup means restoring the whole cluster to a point in time and
discarding **everything committed since**; a logical dump of that table costs
nothing else. The fourth is why the dump doubles as a verification pass over the
same data pgBackRest is copying blind — see
[AC-4](#ac-4-is-doing-more-work-than-it-looks).

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
| AC-1 | A backup history exists, and only the leader creates it | On schedule, a full and subsequent incrementals are taken and appear in `pgbackrest info` **output** — not merely a zero exit status, which `info` returns even for a repository it cannot read. With the timer enabled on all three nodes, exactly one backup is produced per cycle, and after a promotion it is the **new** leader that produces it |
| AC-2 | The repository outlives any node | Every backup and WAL segment is on MinIO, off all three database hosts. Destroying any node leaves the repository complete |
| AC-3 | The chain is real, and retention respects it | `pgbackrest verify` passes across the whole repository. Expiring a full under `repo1-retention-full` expires the differentials and incrementals that depend on it, and leaves nothing referenced by `backup.info` that is no longer present |
| AC-4 | A dump proves the data is *readable*, not merely present | A `pg_dump` of `appdb` completes and reloads into a scratch database |
| AC-5 | **Every** object is encrypted at rest, and every transfer in transit | Nothing under either prefix is readable straight from the bucket: pgBackRest objects need `repo1-cipher-pass`, dumps need the dump passphrase. A plaintext connection to MinIO is refused |
| AC-6 | Archiving survives a promotion, and the recoverable window is measured | Force a promotion mid-cycle: the new primary continues archiving into the same stanza, the WAL sequence has no gap, and `pgbackrest check` passes. Report how far past the last backup the archive reaches |

### AC-1 is the criterion this lab exists for

**`pgbackrest check` passing is not evidence that a backup exists.** It validates
the configuration and confirms archiving works, and it passes perfectly well
against a repository containing no backup at all — which is precisely the state
Labs 1 and 2 are in. A criterion that accepted `check` would certify the current,
unrecoverable arrangement as a success.

Nor is a zero exit status evidence of anything. Measured while planning this lab:
`pgbackrest info` against a repository it could not decrypt printed
`status: error (other)` with a `CryptoError` — and **exited 0**. Every criterion
here reads parsed output for that reason.

So AC-1 asserts the *artefact* rather than the configuration. Its second half
matters as much: a timer on three nodes must not produce three backups, and must
not produce zero once the leader moves. Both failures are silent.

### AC-3 is where retention is most dangerous

An incremental is worthless without every backup back to its full, so retention
that counts fulls is also, implicitly, retention over everything depending on
them. That cascade is correct behaviour and looks like data loss when it is not
expected — and a repository that expires a full while leaving its dependents
behind is worse still, because `pgbackrest info` will list backups that cannot be
restored.

Asserting the cascade is what distinguishes a repository that is pruning itself
from one that is quietly corrupting its own history.

### AC-4 is doing more work than it looks

Reloading the dump into a scratch database is not a restore rehearsal — that is
Lab 4. It is the cheapest available proof that the dump is **readable**, which is
the property `pgbackrest verify` cannot give, because verifying checksums
confirms the bytes are intact and says nothing about whether PostgreSQL can parse
what they contain.

### AC-5 covers both prefixes on purpose

The obvious version of this criterion checks the pgBackRest objects and stops
there, which would leave the dumps in plaintext beside them and still pass. Every
object in the bucket has to fail to open without its passphrase, or the criterion
tests the easier half of the data.

### AC-6 is the one a single-node guide would miss

Archiving is a property of the primary, and the primary moves. A backup regime
that works until the first failover and then silently stops is the exact shape of
failure [Lab 5](../lab5/README.md) exists to detect — and the reason its headline
metric is the age of the last successful backup rather than any error count.

Its second half is what makes this lab measurable rather than merely green.
"How far past the last backup can recovery reach" is the number that turns a
backup schedule into an RPO, and it is bounded by `archive_timeout`, not by how
often a backup runs.

## Running it

```sh
make all      # build, start the object store, run every check, report
make check    # re-run the checks against a cluster that is already up
make clean    # destroy the VMs and generated files -- but NOT the backups
```

The last one is the difference from every earlier lab, and it will surprise you
once. `make clean` deliberately keeps the repository in `.minio/` and the cipher
passphrases in `.recovery-inputs/`, because [Lab 4](../lab4/README.md)'s whole
premise is restoring a destroyed cluster from exactly those.

**So `make all` after a `make clean` fails**, at `stanza-create`:

```text
ERROR: [028]: backup and archive info files exist but do not match the database
```

That is pgBackRest refusing to do something dangerous, not a broken lab. A
stanza belongs to one database, identified by its system id, and a rebuild
creates a different one. Adopting the old stanza would put two unrelated
databases in one history, which is how a restore quietly returns the wrong data.

Two ways forward, and they are the two this series keeps separate:

| You want | Do |
| --- | --- |
| A fresh lab; the old backups no longer matter | `make minio_destroy && make all` |
| The data back | Restore from the repository — [Lab 4](../lab4/README.md), not built |

`make minio_destroy` is the only command here that deletes a backup. Nothing
else does, on purpose.

## What this contributes back

[`SLA.md`](../SLA.md) records the row for corruption, deletion and a bad
migration as *"bounded by backup age and WAL archive interval"*, with the RTO
**not established** and sourced to "Labs 3, 4, 8 — not built". This lab supplies
the first half of that row.

With a backup history that exists and an archive that keeps up with the primary,
the recoverable window stops being bounded by *backup age* and becomes bounded by
`archive_timeout` — which is the distinction drawn in
[`WHY_PGBACKREST_AND_PGDUMP.md`](../WHY_PGBACKREST_AND_PGDUMP.md#wal-archiving-is-the-part-that-actually-bounds-data-loss).
AC-6 is what measures it instead of asserting it.

The RTO half stays blank until [Lab 4](../lab4/README.md) measures a restore.
Taking a backup bounds what you could lose; only restoring one bounds how long
you are down.

## What this lab does not claim

That any of it can be restored. A repository that accepts writes, passes
`pgbackrest check` and reports a valid backup set is evidence that *taking* a
backup works. Whether the result can rebuild a working cluster is
[Lab 4](../lab4/README.md), and keeping them apart is what stops the first result
being read as the second.

The same caution applies within this lab. AC-3 asserts the repository is
internally consistent, and AC-4 asserts one dump is readable. Neither is a
restore, and `pgbackrest verify` succeeding on every backup still leaves the
question Lab 4 exists to answer.
