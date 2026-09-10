# Lab 6: patching and minor-version upgrades

> **Status: specified, not built.** Everything below is the design and its
> acceptance criteria. No results are claimed.

The shared components, cluster design and prerequisites are in the
[top-level README](../README.md). This file covers Lab 6 only.

## Goal

Apply PostgreSQL minor updates, Patroni and etcd updates, and OS patches to a
running cluster — without downtime, without losing an acknowledged transaction,
and in an order that is *proven* safe rather than assumed.

## Why this is a lab and not a paragraph

Every other lab here injects a fault. This one injects a **routine Tuesday**, and
that is the point: it is the operation the team will perform most often, and the
most common cause of self-inflicted outages on an HA cluster.

It is also the operation where this cluster's own guarantees turn into
constraints. Three of them collide here, and none is obvious from its own lab:

| Guarantee | What it forbids during patching |
| --- | --- |
| `synchronous_node_count: 1` with strict mode | Taking **both** standbys out at once. The second one stops writes — [runbook 1](../RUNBOOKS.md#1-writes-are-blocked-on-synchronous-replication), reached by patching in parallel |
| `primary_start_timeout: 0` | Restarting PostgreSQL behind Patroni's back. Patroni sees a crash and hands the leader key away immediately, turning a 2-second restart into an election |
| `watchdog: mode: required` | Rebooting without checking `softdog` is loaded again. A node that cannot arm its watchdog **refuses to be primary at all** — [runbook 2](../RUNBOOKS.md#2-failover-did-not-happen) |

A single `ansible -a "yum update"` across the inventory violates all three at
once. That is the failure this lab exists to characterise.

## The safe order, which is what is under test

PostgreSQL minor upgrades replace binaries and restart. There is no `pg_upgrade`,
no catalogue rewrite, and **replication between adjacent minor versions is
supported** — so a transiently mixed-version cluster is fine, and is what makes a
rolling upgrade possible at all.

```text
1. standby A     patch, restart through Patroni, wait for `streaming`
2. standby B     the same -- only after A is streaming again
3. switchover    move the leader to an already-patched standby
4. old primary   now a standby: patch it the same way
```

Two things about that sequence are worth stating, because both are where it goes
wrong:

**The primary is patched last, and only after a switchover.** Rebooting or
restarting the primary directly costs an election — `ttl` (30s) if the node dies
outright, and client-visible failure either way. A switchover is a controlled
handover with no `ttl` to wait out, measured at ~2s in
[`SLA.md`](../SLA.md#per-failure-mode).

**Restarts go through Patroni, not around it.** `patronictl restart` tells
Patroni what is about to happen; `systemctl restart postgresql-18` does not, and
with `primary_start_timeout: 0` the difference is an unnecessary failover. This
is the single most common mistake made by an operator who knows PostgreSQL but
not Patroni.

## Scope

| In scope | Out of scope |
| --- | --- |
| PostgreSQL **minor** version upgrades, rolling | **Major** version upgrades — `pg_upgrade` or logical replication, a different problem |
| Patroni and etcd package upgrades, one node at a time | Upgrading across an etcd major version, or a Patroni DCS schema change |
| OS and kernel patching, including the reboot | Unattended or automated patching policy |
| A client committing throughout, measuring what it saw | Patching the application tier |
| Rollback when new binaries will not start | Rebuilding a node from backup — that is [Lab 4](../lab4/README.md) |
| The order above, **and** demonstrating the cost of getting it wrong | Zero-restart patching; a minor upgrade requires a restart by definition |

Major upgrades are excluded deliberately rather than forgotten. They cannot be
rolling on a physical-replication cluster: the standbys cannot replicate across a
major version, so the procedure is a different shape entirely and belongs in its
own lab if it is ever needed.

## Topology

Four VMs, identical to [Lab 2](../lab2/README.md): three cluster nodes and an
application host. No new infrastructure — this lab is about a procedure, not a
component.

It forks Lab 2 rather than Lab 1 on purpose. Patching means rebooting, and a
reboot on the encrypted cluster is strictly more interesting: the LUKS volumes
must unlock unattended, the mount must land before PostgreSQL starts, and
`softdog` must come back. Those are exactly the things a kernel update disturbs,
and Lab 2's AC-4 already proved they survive *one* reboot — this lab does it on
purpose, repeatedly, as part of a procedure.

## Acceptance criteria

| ID | Property | Pass condition |
| --- | --- | --- |
| AC-1 | A rolling minor upgrade is invisible to the client | A client committing continuously through the whole sequence records **zero failed transactions**, and every node ends on the new version |
| AC-2 | The unsafe order is shown to be unsafe | The **negative control**: patching both standbys together blocks writes, and restarting the primary directly costs an election. Both measured, not asserted |
| AC-3 | Restarts go through Patroni | `patronictl restart` completes without a leader change; `systemctl restart` on the primary is shown to trigger one, because `primary_start_timeout` is `0` |
| AC-4 | A patched node returns to full membership unattended | After a kernel update and reboot: volumes unlocked, `softdog` loaded, watchdog armed, Patroni running, and the node `streaming` again with no operator action |
| AC-5 | etcd is upgraded without losing quorum | One member at a time; `etcdctl endpoint health` shows the cluster healthy throughout, and Patroni never loses the DCS |
| AC-6 | A failed upgrade is recoverable | With a deliberately broken package, the node's new binaries fail to start; the documented rollback returns it to service **without** rebuilding it from the primary |
| AC-7 | The cluster is not left degraded | Afterwards: one leader, two `streaming` standbys, quorum commit active, watchdog armed, **and not paused** — the state [runbook 3](../RUNBOOKS.md#3-patroni-is-paused-and-nobody-remembers) exists to catch |

### AC-2 is the one that matters

Every other criterion can pass on a careful run by a careful operator and prove
nothing about the *procedure*. AC-2 is what establishes that the ordering rules
are load-bearing rather than superstition — the same reason
[Lab 7](../lab7/README.md)'s `lock_timeout` criterion needs its negative control,
and the same reason `test_sync` runs its mutation test with
`synchronous_mode_strict` on and off.

It is also the criterion that produces something directly useful: a measured cost
for each wrong move, which is what makes "one node at a time" an instruction
someone will actually follow at 02:00 rather than an unexplained rule.

### AC-4 is where Lab 2 gets audited

Lab 2 proved a node survives a reboot. It proved it **once**, as a property.
Patching turns that into a routine, and routine is where a marginal dependency
surfaces: a `crypttab` entry that works until the keyfile's filesystem mounts a
little later, a `softdog` module loaded by something that a kernel update
replaced, a unit ordering that held by luck.

### AC-6 is the one usually skipped

Patching procedures are written for the case where the package installs. The
interesting question is what an operator does at 23:00 when it does not, and
whether the answer requires rebuilding a node — which on this cluster means a
`reinit` from the primary and a resync of the whole data directory, hours where
minutes were needed.

## Notes specific to this cluster

- **Never patch two nodes in parallel.** With `synchronous_node_count: 1`, one
  standby may be down freely; the second stops writes. This is the same
  constraint [runbook 8](../RUNBOOKS.md#8-planned-switchover) states for
  maintenance, and this lab is where it gets measured instead of asserted.
- **Check `pending_restart` before and after.** Patroni exposes
  `patroni_pending_restart`, and a configuration change that requires a restart
  can sit unapplied indefinitely. [Lab 5](../lab5/README.md) alerts on it; this
  lab is the operation that clears it.
- **`softdog` is not automatically persistent.** If it is loaded by hand rather
  than by a `modules-load.d` entry, the first kernel reboot removes it and the
  node quietly becomes ineligible for promotion. This is worth asserting during
  the lab rather than discovering during a failover.
- **A switchover needs a healthy cluster.** The precondition in runbook 8 — one
  leader, two `streaming` standbys — applies at step 3, so a patch run that has
  left a standby down must not proceed to the switchover.
- **etcd and PostgreSQL are patched on different schedules.** They share a node
  but not a lifecycle, and doing both at once means an unhealthy DCS at exactly
  the moment Patroni is being asked to move a leader.

## What this contributes back

[`RUNBOOKS.md`](../RUNBOOKS.md) has no rolling-maintenance procedure. It has
[runbook 8](../RUNBOOKS.md#8-planned-switchover), which is one step of it, marked
VERIFIED because a drill performs it. This lab is what would let a full
"patch the cluster" procedure be added and marked VERIFIED rather than REASONED —
the same relationship [Lab 4](../lab4/README.md) has to the total-loss stub.

It also gives [`SLA.md`](../SLA.md) the planned-maintenance figure it currently
records from a single switchover: the wall-clock cost of a complete patch cycle
across three nodes, which is the number a change-advisory board actually asks
for.
