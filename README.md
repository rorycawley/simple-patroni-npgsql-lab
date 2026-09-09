# Patroni + Npgsql HA labs

A series of proof-of-concept labs in which a .NET client using the Npgsql driver
talks to a Patroni-managed PostgreSQL cluster, and keeps working across the loss
of the primary without losing an acknowledged transaction.

Every lab builds from nothing with two commands and proves its claims with
executable checks rather than prose.

## Where things are documented

Each file below owns one subject and does not repeat another's.

| File | Owns |
| --- | --- |
| this file | What every lab shares: the components, the cluster design, the failover and durability semantics, and the prerequisites |
| [`lab1/README.md`](lab1/README.md) | Lab 1 alone: its scope, acceptance criteria, how each is proven, and how to run it |
| [`lab2/README.md`](lab2/README.md) | Lab 2 alone: what it adds over Lab 1, its acceptance criteria, and how to run it |
| [`lab1/ansible/README.md`](lab1/ansible/README.md), [`lab2/ansible/README.md`](lab2/ansible/README.md) | How that lab's automation installs and configures the nodes, and its network policy |
| [`lab2/PLAN.md`](lab2/PLAN.md) | How Lab 2 was built, the risks it had to mitigate, and what was deferred |
| [`lab6/README.md`](lab6/README.md) | Lab 6's design and acceptance criteria — specified ahead of being built |
| [`SLA.md`](SLA.md) | What the labs establish about RPO, RTO and availability, per failure mode |

## The labs

| Lab | Adds | At rest | In transit | VMs |
| --- | --- | --- | --- | --- |
| [1](lab1/README.md) | The cluster, the client, failover, fencing, quorum commit | plaintext | plaintext | 3 |
| [2](lab2/README.md) | Everything Lab 1 proves, on encrypted disks and an encrypted network | LUKS2, separate volumes for PostgreSQL and etcd | TLS on every channel, mutual where the peer is a machine | 4 |
| 3 — not started | Durable backups: a pgBackRest repository on MinIO, off the database hosts, encrypted and reached over TLS | — | — | — |
| 4 — not started | Recovery: restoring from a Lab 3 backup, including to a point in time, and proving the restored cluster holds the right data | — | — | — |
| 5 — not started | Schema migration with Flyway: applying versioned migrations against the cluster, and surviving a failover mid-migration | — | — | — |
| [6](lab6/README.md) — specified, not built | Shipping a schema change to a live cluster without downtime, with a simulated CI/CD pipeline | — | — | — |
| 7 — not started | Recovering from a bad migration: back up before migrating, then restore to the moment before it ran | — | — | — |

Lab 1 is deliberately unencrypted, so run it only on an isolated, trusted lab
network. Lab 2 removes that constraint.

Backup and recovery are deliberately two labs rather than one. Lab 3 can finish
green while proving nothing about recovery: a repository that accepts writes,
passes `pgbackrest check` and reports a valid backup set is still only evidence
that *taking* a backup works. Lab 4 is where that evidence is tested — restore a
cluster from the repository, bring it back to a chosen point in time, and assert
the data is the data that was committed. A backup nobody has restored is an
assumption, and separating the labs keeps it from being mistaken for a result.

Lab 5 asks what a schema migration does when the primary moves underneath it. A
migration is a write, so Flyway has to find the primary exactly as the
application does, and PostgreSQL's transactional DDL means a single migration
either applies or it does not. The risk is not the DDL — it is the bookkeeping
around it. Flyway records each migration in a history table and holds a lock
while it runs, so a failover mid-migration can leave that history disagreeing
with the schema, or leave the lock held so every later deployment blocks. This
is Lab 1's uncertain-commit problem in a more damaging place: an interrupted
migration that actually succeeded must not be recorded as failed, and must not
be reapplied on the next run.

[Lab 6](lab6/README.md) then asks whether the migration needed a maintenance
window at all. The answer under test is no — provided the schema stays compatible
with both the current and previous application version, and every migration
bounds its own lock wait. Compatibility is what makes an application rollback
possible; taking downtime instead narrows the broken period but *forbids*
rollback, because the old version can no longer run. The lock bound is what stops
a 10ms `ALTER TABLE` becoming a five-minute outage when it queues behind a long
transaction and everything else queues behind it. It is the only lab specified in
detail before being built, because the design is the deliverable — the pipeline
itself is simulated by a script.

Labs 5 and 6 divide cleanly: 5 is the infrastructure interrupting your migration,
6 is your migration interrupting your users.

Lab 7 is the capstone, and the case every earlier lab is blind to. A bad
migration is not a fault: nothing crashes, no node is lost, and the cluster stays
perfectly healthy while doing the wrong thing. Worse, the machinery from Labs 1
and 2 works *against* recovery — quorum commit makes the bad migration durable
before it is acknowledged, replication carries it to both standbys in
milliseconds, and failover just hands over a healthy node carrying the same
broken schema. No node is left holding the old one. The only way back is the
backup taken before the migration ran, restored to the moment before it started,
which is why it comes last: it composes Labs 3, 4, 5 and 6 rather than repeating
them.

It also has a cost worth stating rather than discovering: rewinding to just
before the migration discards every transaction committed after it. Lab 7 has to
measure that window, not just prove the schema came back.

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

> **Status: implemented and verified in Lab 1** — `make test_sync` includes a
> mutation test that runs the same fault with the setting on and off and
> requires opposite outcomes. **Lab 2 still to follow**; until then it falls
> back to asynchronous when the last standby is gone.

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
