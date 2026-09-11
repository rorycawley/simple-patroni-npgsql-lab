# Patroni + Npgsql: a PostgreSQL high-availability proof of concept

A .NET application, using the Npgsql driver, talks to a three-node PostgreSQL
cluster managed by Patroni. When the primary dies the cluster elects a new one,
the application finds it without help from a proxy, and no transaction the
database already acknowledged is lost along the way.

That sentence is the whole thesis. The repository exists to find out how much of
it survives contact with a real cluster, one stage at a time.

## What this repository is for

It produces two things, and everything here serves one of them.

| Deliverable | What it is | Where it lives | How far along |
| --- | --- | --- | --- |
| **A validated design** | The architecture to build for production, with evidence for each claim instead of assertions | the lab guides, plus [`SLA.md`](SLA.md) | 3 of 8 stages built |
| **An operations runbook** | Procedures for whoever ends up carrying the pager, each labelled with how far it has actually been proven | [`RUNBOOKS.md`](RUNBOOKS.md) | 3 drilled, 6 reasoned, 1 stub |

Each stage is a lab: a self-contained cluster that builds from nothing with two
commands and tests its own claims with executable checks. The labs are the
*evidence*. They are not the product, and they cannot be — they run on a single
laptop, which is enough to show that a mechanism works and nowhere near enough to
support an availability figure. The gap between the two is written down in
[From lab to production](#from-lab-to-production), and closing that gap is the
point of the exercise.

## Status

| Lab | What it adds | Built? |
| --- | --- | --- |
| [1](lab1/README.md) | The cluster, the client, failover, fencing, quorum commit | **Built and verified** |
| [2](lab2/README.md) | Every Lab 1 guarantee, now on LUKS2 volumes — PostgreSQL and etcd on separate devices — with TLS on every channel, mutual where the peer is a machine | **Built and verified** |
| [3](lab3/README.md) | Durable backups — pgBackRest **and** `pg_dump`, to an off-host MinIO repository, encrypted, over TLS | **Built and verified** |
| [4](lab4/README.md) | Recovery at every blast radius: replace a node, restore beside a live cluster, rewind it, or rebuild from nothing | **In progress** — forked and building green; no criterion met yet |
| [5](lab5/README.md) | Monitoring with Grafana LGTM and Alloy: every injectable fault detected, with measured latency | Specified |
| [6](lab6/README.md) | Patching and minor-version upgrades: the rolling order, and the measured cost of getting it wrong | Specified |
| [7](lab7/README.md) | Schema migration with Flyway — no downtime, and what survives a failover mid-migration | Specified |
| [8](lab8/README.md) | Undoing a migration that succeeded and was wrong: by table, or by rewinding the cluster | Specified |

Labs 3 to 8 are complete designs with acceptance criteria, written before
building so the criteria cannot quietly reshape themselves around whatever
happened. **They claim no results.**

The order is deliberate, and it answers *what would you most regret not having*
at each point. Recoverability comes first, because a cluster you cannot restore
is the worst thing to discover late (3, 4). Then the ability to see it, because
`synchronous_mode_strict` deliberately created a failure that never heals itself
and nothing yet detects it (5). Then the operation the team performs most often
and is most likely to be hurt by (6). Schema migration comes last (7, 8): it
matters, but it is the application's lifecycle rather than the platform's, and it
is the only pair here that a customer could reasonably own themselves.

Lab 1 encrypts nothing on purpose — run it only on an isolated, trusted network.
Lab 2 lifts that restriction. Lab 2 is a standalone *copy* of Lab 1 rather than a
layer on top: either can be built, broken and destroyed without disturbing the
other, and the diff between them is precisely what encryption cost.

## Start here

Pick the row that matches why you opened this.

| You want to… | Read, in order |
| --- | --- |
| **Decide whether the design is sound** | this file → [`SLA.md`](SLA.md) → [`lab1/README.md`](lab1/README.md) |
| **Run it yourself** | [Prerequisites](#prerequisites) → [`lab1/README.md`](lab1/README.md) → [`lab1/ansible/README.md`](lab1/ansible/README.md) |
| **Operate the cluster** | [`RUNBOOKS.md`](RUNBOOKS.md) on its own — it is written to need nothing else |
| **Understand the backup strategy** | [Backups](#backups-two-instruments-not-two-backup-systems) below → [`WHY_PGBACKREST_AND_PGDUMP.md`](WHY_PGBACKREST_AND_PGDUMP.md) |

## What the labs prove

Two claims, both stated narrowly, because both are easy to inflate.

### 1. Infrastructure failure cannot lose an acknowledged transaction

The cluster runs quorum commit, so a commit is not acknowledged until a second
node has flushed it to disk. No crash, promotion or fence can therefore discard
one — the surviving node already had it before the application was told anything.
`synchronous_mode_strict` closes the one case where that used to lapse, and page
checksums catch corrupted data before replication propagates it and the next
backup preserves it faithfully. All of this is built and verified in Labs 1 and 2.

Two exclusions, both deliberate:

**Work that was never acknowledged may be lost.** This is correct behaviour and
cannot be otherwise. What matters is that the application knows it does not know:
the client reports an uncertain outcome instead of quietly reissuing the write
and risking doing it twice.

**Undoing a mistake costs data by design.** Rewinding to a point before a bad
migration throws away every transaction committed after it. That is how the
recovery works, not a flaw in it, and [Lab 8](lab8/README.md) is built to measure
the loss rather than gloss over it.

So the guarantee covers *infrastructure* failure. Against human error the series
offers the cheapest tool that does the job — which is why it keeps a logical dump
next to the physical backup, so one table can come back without rewinding
everything.

### 2. The database survives losing any single node

Patroni promotes a standby automatically, fences a primary that can no longer
prove it holds the leader key, and the client locates the new primary unaided.
These are measured, not asserted: [`SLA.md`](SLA.md) carries RPO and RTO for each
failure mode.

The boundaries are just as firm. Lose **two** of three nodes and the cluster is
read-only regardless, because etcd quorum went with them. And where durability
and availability conflict, durability wins: with no standby able to confirm a
write, the cluster blocks rather than accepting something it cannot make durable.

## Backups: two instruments, not two backup systems

[Lab 3](lab3/README.md) sets up pgBackRest **and** `pg_dump`. They are not
redundant, and neither is a fallback for the other. The distinction comes down to
one thing: **pgBackRest copies files, `pg_dump` copies data.**

| | pgBackRest — physical | `pg_dump` — logical |
| --- | --- | --- |
| Recovers | The entire cluster | One table, schema or database |
| Point-in-time recovery | Yes, by replaying WAL | No — one instant per run |
| What using it costs | Everything committed after the target is discarded | Nothing else is disturbed |
| Survives a major-version change | **No**, it is version-locked | Yes |
| Reads through the SQL layer | No | **Yes** |

**pgBackRest is the disaster recovery system.** It copies the cluster byte for
byte and archives WAL continuously, so it can rebuild from nothing or wind back
to a chosen moment. If only one of the two could exist, it would be this one.

**`pg_dump` is a scalpel and a canary.** It restores a single table without
touching anything else — recovering one mangled table from a physical backup
means rewinding the whole cluster and discarding a day of unrelated work. And
because it reads every row through PostgreSQL's own executor, a dump that
finishes is evidence the data is *readable* rather than merely present. That
second job matters more than it sounds: **a physical backup faithfully preserves
corruption, and a logical dump cannot.** A corrupt page is copied byte for byte
into every backup and restored exactly; `pg_dump` hits the same page and fails,
which is the alarm you want.

The full treatment — when *not* to use each, what neither protects against, and
what to do before a manual change — is in
[`WHY_PGBACKREST_AND_PGDUMP.md`](WHY_PGBACKREST_AND_PGDUMP.md).

**Taking backups and restoring them are two labs on purpose.** Lab 3 can finish
green while proving nothing about recovery: a repository that accepts writes,
passes `pgbackrest check` and reports a valid backup set has only demonstrated
that *taking* a backup works. A backup nobody has restored is a hypothesis, and
[Lab 4](lab4/README.md) is where it gets tested — against fresh VMs, with the
local secrets destroyed too, because the real question is not whether pgBackRest
can restore but whether anything needed for recovery was stored only inside the
thing that was lost.

## From lab to production

The labs establish mechanisms on one laptop. This is what a production build
needs that they do not have — the list this proof of concept exists to produce.

| Area | What the labs do | What production needs |
| --- | --- | --- |
| **Fault domains** | Three VMs on one machine | Three independent domains. No single domain may hold two of the three nodes — [`SLA.md`](SLA.md#fault-domains-must-the-nodes-be-on-separate-hypervisors) |
| **Fencing** | `softdog`, a kernel timer | A hardware or hypervisor watchdog. `softdog` cannot fire during a kernel panic, because the timer that would fire it has stopped too |
| **Backup repository** | Off-host and encrypted as of Lab 3, but a **single** MinIO | A second repository. One is a single point of failure for every recovery you might ever attempt |
| **Restore** | Not yet rehearsed — [Lab 4](lab4/README.md) is unbuilt | A restore rehearsed on a schedule, not on the day it is needed |
| **Secrets** | Generated into an uncommitted `.secrets/`; superuser and replication passwords sit in cleartext in `patroni.yml` | A secrets manager, with each workload fetching at start — [`SERVICE-ACCOUNTS.md`](SERVICE-ACCOUNTS.md) |
| **PKI** | A private CA issuing certificates at build time | Issuance, rotation, revocation, and expiry monitoring. Expiry is the one outage that is entirely preventable by watching a number |
| **Disk encryption keys** | A root-only keyfile on the node itself | KMS, TPM or network-bound unlock. Today a stolen *disk* is safe and a stolen *node* is not |
| **Client failover** | Npgsql's `Target Session Attributes=primary` | The same capability in every language in the estate, or a proxy tier. Putting failover in the client obliges every client to honour it |
| **Monitoring** | None — [Lab 5](lab5/README.md) is unbuilt | Detection for the two failures that never heal themselves: writes blocked on synchronous replication, and backups that quietly stopped |
| **Patching and upgrades** | Designed but unbuilt — [Lab 6](lab6/README.md) | A rehearsed rolling procedure for PostgreSQL minor versions, Patroni, etcd and the OS. The operation the team performs most often, and the one this cluster's own constraints make easiest to get wrong |
| **Break-glass** | Not implemented | A named, audited `operator` identity, with an offline copy that works when the identity provider does not |

## The cluster

Three nodes. Each runs PostgreSQL, Patroni, and one member of the etcd cluster.

| Component | What it does here |
| --- | --- |
| Npgsql | The .NET driver. Given several hosts it works out which is the primary, routes writes there, and pools the connections |
| Patroni | Supervises each PostgreSQL instance, keeps cluster state in etcd, and runs promotions. It also maintains `synchronous_standby_names`, so only a standby known to be caught up can be promoted |
| etcd | The distributed store holding that state, agreeing on a single leader through quorum |
| Linux watchdog (`softdog`) | Armed by Patroni on the leader alone and petted whenever a leader-key renewal succeeds. When renewals stop it resets the node at `ttl - safety_margin`, so a promoted replica can never find the old primary still taking writes |
| pgBackRest | Backups, WAL archiving and restore. It serves disaster recovery, sits nowhere near the failover path, and is not involved in promotion |

**No HAProxy, VIP, Keepalived or PgBouncer.** The client is given all three
addresses and uses Npgsql's `Target Session Attributes=primary`, which makes the
driver responsible for finding the primary. That is the experiment: it moves the
burden of failover into the application, where these labs can then check whether
it is carried correctly. It is also the decision with the widest blast radius for
anyone adopting this — see the client-failover row above.

Page checksums are switched on at `initdb` time and asserted by `verify_cluster`.
They turn silent corruption into a reported error before replication spreads it
and the backups preserve it. They also cannot be enabled later without rebuilding
the cluster, which is why a default that nothing checks is worth checking.

The application authenticates as `app_runtime`, a non-superuser login restricted
by a narrow `pg_hba` rule scoped to the client network and `scram-sha-256`. Every
build generates fresh passwords into an uncommitted `.secrets/` directory.

### What happens when the primary is lost

| Fault | What Patroni does | Time to a writable primary |
| --- | --- | --- |
| PostgreSQL crashes, Patroni survives | Normally it restarts PostgreSQL locally, failing over only if recovery exceeds `primary_start_timeout`. These labs set that to `0`, so the leader key goes straight to a healthy replica | ~10–25s |
| The whole node disappears | Nothing releases the leader key, so a replica must wait for it to expire — `ttl` is 30s. The two surviving etcd members keep quorum as long as they can still reach each other | ~40–75s |

In both cases, connections to the old primary drop and new ones fail until a
replica is promoted. **Npgsql will not retry a command on another host by
itself.** The application has to notice the failure, open a fresh primary
connection, and reissue only what is safe to reissue.

That final clause is the difficult part, and it is why these labs exercise the
client rather than only the cluster. A dropped connection can leave an
application genuinely unable to tell whether its transaction committed, and a
blind retry then risks performing the work twice.

### Durability, and what it costs

Both built labs run **quorum commit** — `synchronous_mode: quorum` with
`synchronous_node_count: 1` — which has Patroni maintain
`synchronous_standby_names = ANY 1 (...)`. A commit waits until a standby has
flushed it, and because Patroni tracks the eligible set in etcd, only a node
known to be current can be promoted.

**These labs choose durability over availability every time**, so
`synchronous_mode_strict` is on. Patroni then refuses to clear
`synchronous_standby_names` when nothing can confirm a flush, and commits block
instead of completing on a single disk. The price is explicit: with every standby
unavailable, writes stop until one comes back.

Two obligations follow, and neither is optional. Clients need a command timeout,
because a blocked commit hangs rather than failing quickly. And rolling
maintenance must never remove both standbys at once. The reasoning is in
[`SLA.md`](SLA.md#the-exception-being-closed); recognising and clearing the
blocked state is
[runbook 1](RUNBOOKS.md#1-writes-are-blocked-on-synchronous-replication).

> **Verified in both built labs.** `make test_sync` runs one fault twice, with
> the setting on and then off, and demands opposite outcomes:
>
> ```text
> strict ON    synchronous_standby_names 'ANY 1 (*)'   SyncRep   commit blocked
> strict OFF   synchronous_standby_names ''            none      commit completed
> ```

## Prerequisites

You need Lima, Ansible, `jq`, and the .NET 10 SDK on the host.

The VMs sit on Lima's
[`socket_vmnet` managed network](https://lima-vm.io/docs/config/network/vmnet/),
which hands out addresses reachable both from macOS and between the guests —
etcd and streaming replication each require that. Install `socket_vmnet` into the
root-owned location, set up Lima's sudoers file as its documentation describes,
and check the result:

```sh
limactl sudoers --check
```

## Running a lab

Both built labs behave identically. From inside `lab1/` or `lab2/`:

```sh
make all      # build the cluster, run every check, print one summary
make clean    # destroy the VMs and their disks, delete every generated file
make check    # re-run the checks against a cluster that is already up
make          # list the targets; it builds nothing, because `all` injects faults
```

A failing setup phase halts the run, since there would be nothing left to test.
The checks behave the opposite way: all of them run even after one fails, so a
single invocation tells you everything that is broken instead of only the first
thing. The command exits non-zero if any check failed.

Every check after the initial connection test breaks the running cluster on
purpose — force-stopping a VM, killing PostgreSQL outright, freezing Patroni
until the watchdog reboots the node, severing a node from etcd, or pausing
Patroni to confirm the runbook catches it. Each one repairs the damage and waits
for one leader with two streaming replicas before reporting `PASS`, so they can
run in any order against a healthy cluster. Expect the primary to move between
nodes as they go.

## Where everything is documented

One subject per file, with no file repeating another.

| File | Covers |
| --- | --- |
| this file | Why the series exists, what its stages share, and what production still requires |
| [`RUNBOOKS.md`](RUNBOOKS.md) | What to do while an incident is happening, each procedure marked drilled, reasoned or stub |
| [`SLA.md`](SLA.md) | RPO, RTO and availability per failure mode, and where those numbers come from |
| [`SERVICE-ACCOUNTS.md`](SERVICE-ACCOUNTS.md) | Every identity and secret the cluster needs, what each may do, and which lab introduces it |
| [`WHY_PGBACKREST_AND_PGDUMP.md`](WHY_PGBACKREST_AND_PGDUMP.md) | The two backup tools in full: when to use each, when not to, and what to take before a manual change |
| [`lab1/README.md`](lab1/README.md), [`lab2/README.md`](lab2/README.md) | That lab alone — its scope, its acceptance criteria, how each is proven, and how to run it |
| [`lab3`](lab3/README.md) … [`lab8/README.md`](lab8/README.md) | The design and acceptance criteria for each unbuilt stage |
| [`lab1/ansible/README.md`](lab1/ansible/README.md), [`lab2/ansible/README.md`](lab2/ansible/README.md), [`lab3/ansible/README.md`](lab3/ansible/README.md) | How that lab's automation installs and configures the nodes, and the network policy it applies |
| [`lab2/PLAN.md`](lab2/PLAN.md), [`lab3/PLAN.md`](lab3/PLAN.md), [`lab4/PLAN.md`](lab4/PLAN.md) | How that lab is built rather than what it must prove: the phases, their order, the risks worth watching, and what carries into the next lab |

There is one intentional exception: the two `ansible/README.md` files overlap
heavily. Lab 2 is a standalone copy of Lab 1, and pointing one at the other would
destroy the property that either lab builds and tears down independently.
