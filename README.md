# Patroni + Npgsql HA labs

A series of proof-of-concept labs in which a .NET client using the Npgsql driver
talks to a Patroni-managed PostgreSQL cluster, and keeps working across the loss
of the primary without losing an acknowledged transaction.

Every lab builds from nothing with two commands and proves its claims with
executable checks rather than prose.

## What the series is for

Two outcomes, stated precisely, because both are easy to overclaim.

**1. No acknowledged transaction is lost to infrastructure failure.** Quorum
commit means a commit is not acknowledged until a second node holds it, so no
node failure, promotion or fence can lose one; `synchronous_mode_strict` removes
the one case where that guarantee used to lapse, in [both built labs](#durability). Page checksums catch corruption before it is replicated and copied into every backup.
Backups and a rehearsed restore cover losing every node at once.

Two things sit outside that claim, deliberately:

- **In-flight work that was never acknowledged can be lost.** That is correct and
  unavoidable. The client's job is to know that it does not know, which is why it
  reports an uncertain commit rather than reissuing it.
- **Recovering from a *logical* error costs data on purpose.** Rewinding to a
  point before a bad migration discards every transaction committed after it.
  That is the recovery mechanism rather than a defect, and
  [Lab 6](lab6/README.md) measures the cost instead of hiding it — which is also
  why the series keeps a logical dump alongside the physical backup, so a single
  table can be restored before the whole cluster is rewound.

The guarantee is therefore about *infrastructure* failure. Against a mistake, the
labs offer the cheapest instrument that works.

**2. PostgreSQL stays available across the loss of any one node.** Automatic
promotion, fencing so a partitioned primary cannot keep serving, and a client
that finds the new primary by itself. Measured rather than asserted:
[`SLA.md`](SLA.md) gives RPO and RTO per failure mode.

Its limits are equally explicit. Losing **two** of three nodes is read-only
either way, because etcd quorum goes with them. And durability is chosen over
availability where they conflict, so if every standby is unavailable the cluster
blocks writes rather than accepting one it cannot make durable.

## Where things are documented

Each file below owns one subject and does not repeat another's — with one
deliberate exception. The two `ansible/README.md` files overlap substantially,
because Lab 2 is a standalone copy of Lab 1 rather than a layer on it, and making
one link to the other would break the property that either lab can be built and
destroyed without the other.

| File | Owns |
| --- | --- |
| this file | What every lab shares: the components, the cluster design, the failover and durability semantics, and the prerequisites |
| [`lab1/README.md`](lab1/README.md) | Lab 1 alone: its scope, acceptance criteria, how each is proven, and how to run it |
| [`lab2/README.md`](lab2/README.md) | Lab 2 alone: what it adds over Lab 1, its acceptance criteria, and how to run it |
| [`lab1/ansible/README.md`](lab1/ansible/README.md), [`lab2/ansible/README.md`](lab2/ansible/README.md) | How that lab's automation installs and configures the nodes, and its network policy |
| [`lab2/PLAN.md`](lab2/PLAN.md) | How Lab 2 was built, the risks it had to mitigate, and what was deferred |
| [`lab3`](lab3/README.md) … [`lab7/README.md`](lab7/README.md) | Each of those labs' design and acceptance criteria — specified ahead of being built |
| [`SLA.md`](SLA.md) | What the labs establish about RPO, RTO and availability, per failure mode |
| [`SERVICE-ACCOUNTS.md`](SERVICE-ACCOUNTS.md) | Every identity and secret the cluster needs, its privileges, and which lab introduces it |

## The labs

| Lab | Adds | At rest | In transit | VMs |
| --- | --- | --- | --- | --- |
| [1](lab1/README.md) | The cluster, the client, failover, fencing, quorum commit | plaintext | plaintext | 3 |
| [2](lab2/README.md) | Everything Lab 1 proves, on encrypted disks and an encrypted network | LUKS2, separate volumes for PostgreSQL and etcd | TLS on every channel, mutual where the peer is a machine | 4 |
| [3](lab3/README.md) — specified, not built | Durable backups: pgBackRest **and** `pg_dump` to a MinIO repository, off the database hosts, encrypted and reached over TLS | — | — | — |
| [4](lab4/README.md) — specified, not built | Recovery: total loss — VMs, volumes and local secrets destroyed — rebuilt onto fresh VMs from the repository alone | — | — | — |
| [5](lab5/README.md) — specified, not built | Schema migration with Flyway: without downtime, and what survives a failover mid-migration | — | — | — |
| [6](lab6/README.md) — specified, not built | Recovering from a bad migration: mark before migrating, then recover by table or rewind the cluster | — | — | — |
| [7](lab7/README.md) — specified, not built | Monitoring with Grafana LGTM and Alloy: every injectable fault detected, with measured latency | — | — | — |

Lab 1 is deliberately unencrypted, so run it only on an isolated, trusted lab
network. Lab 2 removes that constraint.

[Lab 3](lab3/README.md) takes two kinds of backup, because they recover
different disasters. pgBackRest copies bytes and restores the whole cluster to a
point in time; `pg_dump` reads every row through PostgreSQL's own executor and
restores a single table. The sharpest difference is that **a physical backup
faithfully backs up corruption and a logical dump cannot** — a dump that
completes is evidence the data is readable, not merely that bytes were copied.

Backup and recovery are then deliberately two labs rather than one. Lab 3 can
finish green while proving nothing about recovery: a repository that accepts writes,
passes `pgbackrest check` and reports a valid backup set is still only evidence
that *taking* a backup works. A backup nobody has restored is an assumption, and
separating the labs keeps it from being mistaken for a result.

[Lab 4](lab4/README.md) is where that assumption is tested, and it is a test of
the dependency graph rather than of pgBackRest — which restores perfectly well
and was never in doubt. It destroys the VMs, their volumes **and** the local
secrets, then rebuilds onto fresh VMs, which asks the only interesting question:
is anything required for recovery stored solely inside the thing that was lost?
The cipher passphrase, the CA, the passwords and the procedure itself all have to
survive somewhere the disaster did not reach.

[Lab 5](lab5/README.md) covers schema migration, both ways it goes wrong: your
migration interrupting your users, and the infrastructure interrupting your
migration. The answer under test is that no downtime is needed — provided the
schema stays compatible with both the current and previous application version,
and every migration bounds its own lock wait. Compatibility is what makes an
application rollback possible; taking downtime instead narrows the broken period
but *forbids* rollback, because the old version can no longer run.

Most of what people fear about a failover mid-migration cannot happen on
PostgreSQL: transactional DDL lets Flyway write the migration and its history row
in one transaction, and its advisory lock is session-scoped, so a killed primary
releases it. The exception is sharp, and it is why these are one lab rather than
two — `CREATE INDEX CONCURRENTLY` cannot run in a transaction, so an interrupted
one leaves an `INVALID` index that a re-run will not clean up, and it is exactly
the construct the zero-downtime half recommends. One instruction with a caveat,
not two labs contradicting each other.

[Lab 6](lab6/README.md) is the case every earlier lab is blind to. A bad
migration is not a fault: nothing crashes, no node is lost, and the cluster stays
perfectly healthy while doing the wrong thing. Worse, the machinery from Labs 1
and 2 works *against* recovery — quorum commit makes the bad migration durable
before it is acknowledged, replication carries it to both standbys in
milliseconds, and failover just hands over a healthy node carrying the same
broken schema. No node is left holding the old one. The only way back is the
backup taken before the migration ran, restored to the moment before it started.

It also has a cost worth stating rather than discovering: rewinding to just
before the migration discards every transaction committed after it. Lab 6 has to
measure that window, not just prove the schema came back — which is why it holds
two instruments rather than one. A targeted logical dump restores the tables the
migration mangled and loses nothing else; full point-in-time recovery is the
emergency brake, reached for only when the scalpel will not do.

The protection is narrower than it first sounds. Transactional DDL means a
migration that *crashes* rolls back by itself, so what needs recovering is one
that succeeded and was wrong.

[Lab 7](lab7/README.md) is monitoring, and it is the easiest lab here to fake —
a green dashboard proves a dashboard renders, and a broken alerting pipeline
looks exactly like a quiet night. What makes it testable is that the earlier
labs can already break things on purpose, so the criterion becomes: every fault
they inject must raise its own alert within a measured time, and a healthy
cluster must raise none. It matters most for the two failures that do **not**
heal themselves — writes blocked on synchronous replication, and backups that
have quietly stopped — because neither raises an error and both are otherwise
found only when it is too late.

Lab 2 is a standalone copy of Lab 1, not a layer on top of it. The duplication is
intentional: either lab can be built, broken and destroyed without touching the
other, and the diff between them is exactly what encryption cost.

## Components

| Component | Role |
| --- | --- |
| Npgsql | .NET PostgreSQL driver. It connects directly to the configured hosts, selects the current primary for writes, and provides connection pooling. |
| Patroni | Manages the PostgreSQL instances, records cluster state in etcd, and orchestrates promotion and failover. It also maintains `synchronous_standby_names` for quorum commit, so only a standby known to be caught up is eligible for promotion. |
| etcd | Distributed configuration store that holds Patroni cluster state and elects a single leader through quorum. |
| Linux watchdog (`softdog`) | Armed by Patroni on the leader only, and petted on every successful leader-key renewal. If renewals stop, it resets the node at `ttl - safety_margin`, fencing it so a promoted replica cannot end up alongside a still-writable old primary. |
| pgBackRest | PostgreSQL backup, WAL archiving and restore. It supports disaster recovery, not automatic failover, and is not on the failover path. |

## Cluster design

Three nodes, each running PostgreSQL, Patroni, and one member of the etcd
cluster. Patroni uses the Linux software watchdog through `/dev/watchdog` for
fencing.

There is no HAProxy, VIP, Keepalived or PgBouncer. The client connects directly
to all three nodes and uses Npgsql's `Target Session Attributes=primary`, so the
driver — not a proxy — is what finds the current primary. That is the point of
the exercise: it puts the failover burden on the application, where these labs
can then measure whether it is carried correctly.

Page checksums are enabled at `initdb` time on every lab, and `verify_cluster`
asserts it. They are what turns silent corruption into a detected error before it
is replicated to both standbys and copied faithfully into every backup — and they
cannot be added later without rebuilding the cluster, which is why a default
nothing checks is worth checking.

Authentication is a least-privilege, non-superuser `app_runtime` login,
permitted by a narrow `pg_hba` rule scoped to the client network and
`scram-sha-256`. Passwords are generated per build into an uncommitted
`.secrets/` directory.

## Failover behaviour

Common to every lab:

- **PostgreSQL dies, Patroni survives.** Patroni normally restarts it locally and
  only fails over if it does not recover within `primary_start_timeout`. These
  labs set that to `0`, so a crash hands the leader key to a healthy replica
  immediately.
- **The whole node is lost.** Nothing releases the leader key, so a replica can
  only promote once the key's `ttl` (30s) expires. The remaining two etcd members
  keep quorum, provided they can still reach each other.
- **In both cases**, connections to the old primary are lost and new ones fail
  until a replica is promoted. Npgsql does not retry commands on another host by
  itself. The client must handle the connection failure, open a new primary
  connection, and reissue only operations that are safe to reissue.

That last clause is the hard part, and it is why the labs test the client and not
just the cluster: a connection loss can leave the application unable to tell
whether its transaction committed, so a blind retry risks doing the work twice.

## Durability

Both labs run **quorum commit**: `synchronous_mode: quorum` with
`synchronous_node_count: 1`, which makes Patroni maintain
`synchronous_standby_names = ANY 1 (...)`. A commit is not acknowledged until a
standby has flushed it, and Patroni tracks the eligible set in the DCS, so only a
node known to be caught up can be promoted. An acknowledged transaction therefore
cannot be lost in a failover.

**The labs favour durability over availability, without exception**, so
`synchronous_mode_strict` is enabled. Patroni will not clear
`synchronous_standby_names` when no standby can confirm, so a commit blocks
rather than completing on a single node. The accepted cost is that with every
standby unavailable, writes stop until one returns.

Two conditions follow from that and are not optional: clients need a command
timeout, because a blocked commit hangs rather than failing fast, and rolling
maintenance must never take both standbys out at once. The reasoning is in
[`SLA.md`](SLA.md#the-exception-being-closed).

> **Status: implemented and verified in both labs.** `make test_sync` includes a
> mutation test that runs the same fault with the setting on and off and requires
> opposite outcomes:
>
> ```text
> strict ON    synchronous_standby_names 'ANY 1 (*)'   SyncRep   commit blocked
> strict OFF   synchronous_standby_names ''            none      commit completed
> ```

## Prerequisites

Both labs need Lima, Ansible, `jq`, and the .NET 10 SDK on the host machine.

The VMs use Lima's
[`socket_vmnet` managed network](https://lima-vm.io/docs/config/network/vmnet/),
which provides addresses reachable from both macOS and the other VMs — etcd and
streaming replication both require this. Install `socket_vmnet` in the
root-owned location and configure Lima's sudoers file as Lima describes, then
confirm it with:

```sh
limactl sudoers --check
```

## Running a lab

Both labs work the same way, from inside `lab1/` or `lab2/`:

```sh
make all      # build the cluster, run every check, print one summary
make clean    # destroy the VMs and their disks, delete every generated file
make check    # re-run the checks against a cluster that is already up
make          # list the targets; it builds nothing, because `all` injects faults
```

The setup phases stop the run if they fail, since there would be nothing to
test. The checks all run even after one fails, so a single invocation reports
everything that is broken rather than only the first thing, and the command exits
non-zero if any check failed.

Every check after the first connection test deliberately breaks the running
cluster — force-stopping a VM, killing PostgreSQL, freezing Patroni until the
watchdog reboots the node, or cutting a node off from etcd. Each scenario repairs
what it broke and waits for one leader and two streaming replicas before
reporting `PASS`, so the checks can run in any order against a healthy cluster.
Expect the primary to move between nodes.
