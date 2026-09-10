# Lab 4: recovery

> **Status: specified, not built.** Everything below is the design and its
> acceptance criteria. No results are claimed.

The shared components, cluster design and prerequisites are in the
[top-level README](../README.md). This file covers Lab 4 only.

## Goal

Destroy everything and get it back — a working three-node Patroni cluster,
holding the data that was committed, rebuilt from what survived the disaster.

## This is a test of the dependency graph, not of pgBackRest

The obvious version of this lab — "prove pgBackRest can restore" — proves very
little. pgBackRest restores; that is not in doubt.

What is in doubt is whether **you** can perform a restore once everything is
gone. So the question the lab actually asks is:

> Is anything required for recovery stored only inside the thing that was lost?

That is why the loss here is deliberately brutal, and why the restore goes onto
fresh VMs. A rebuild onto the original machines, with the original configuration
still lying around, quietly assumes away most of a real disaster.

## The boundary with Lab 6

| | Question | State of the cluster |
| --- | --- | --- |
| **Lab 4** | Can we get the **cluster** back? | Gone |
| **[Lab 6](../lab6/README.md)** | Can we get the **right data** back? | Perfectly healthy, doing the wrong thing |

Recovery from *loss* here; recovery from a *mistake* there. Lab 4 establishes
that point-in-time recovery works at all, which is what lets Lab 6 use it to
reach a chosen marker and argue about what that costs.

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
single point of failure the architecture diagram does not show.

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
| Total loss: VMs, volumes and local secrets destroyed | Recovering from a bad migration — that is [Lab 6](../lab6/README.md) |
| Restore onto fresh VMs with new addresses | Restoring into a different PostgreSQL major version |
| Point-in-time recovery, proven on both sides of the target | Cross-region or offsite repository replication |
| Rebuilding a replacement replica from the repository | Automated or unattended recovery |
| Measuring how long recovery takes | Recovering while the original cluster still runs |

## Acceptance criteria

| ID | Property | Pass condition |
| --- | --- | --- |
| AC-1 | Total loss is recoverable | With all VMs, volumes and local secrets destroyed, a working cluster is rebuilt from the repository plus supplied inputs alone. Nothing is recovered from a surviving node, because there is none |
| AC-2 | The point-in-time boundary is exact | Rows committed before the target are **all present**; rows committed after are **all absent** |
| AC-3 | The result is a cluster, not a data directory | Patroni owns it: one leader, two streaming standbys, quorum commit active, watchdog armed, and the Npgsql client completes a read-write probe |
| AC-4 | A replacement replica builds from the repository | A node is rebuilt using Patroni's `create_replica_methods` with pgBackRest, without a `pg_basebackup` from the primary |
| AC-5 | Recovery time is measured | Report wall-clock from "nothing exists" to AC-3 passing, split into restore and replay |
| AC-6 | Recovery fails closed | Wrong cipher passphrase, a target earlier than the base backup, and a tampered repository object each fail loudly rather than producing a plausible-looking cluster |

### AC-2's second half is the one usually skipped

A restore that includes **too much** is as wrong as one that includes too
little, and only the "absent" half detects it. It is also the half
[Lab 6](../lab6/README.md) depends on, where discarding everything after the
marker is the entire point rather than an accident.

### AC-3 is the bar this lab refuses to lower

It is easy to restore a data directory, start PostgreSQL, see the rows and call
it recovered. That is a running database, not a recovered cluster: no
replication, no fencing, no failover. Until Patroni owns it and a client can
commit through it, the disaster is not over.

### AC-6 is why the negative controls exist

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
migrations as **not established**, sourced to "Labs 3, 4, 6 — not built". Lab 4
is what replaces that with a measured number, in the same way
[Lab 7](../lab7/README.md) is what supplies detection latency.

Until then the honest position stands: the labs can state how fast the cluster
recovers from a node it lost, and cannot yet state how fast it recovers from
losing everything.
