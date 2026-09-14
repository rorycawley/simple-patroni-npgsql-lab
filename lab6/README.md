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

Every other lab here injects a fault. This one injects a **routine Tuesday**: the
operation the team performs most often, and the most common cause of
self-inflicted outages on an HA cluster.

It is also where this cluster's own guarantees turn into constraints. Each is
correct, each was proven in an earlier lab, and each forbids something an
operator would otherwise do:

| Guarantee | What it forbids | If ignored |
| --- | --- | --- |
| `synchronous_node_count: 1`, strict mode | Taking **both** standbys out at once | The second one blocks writes — [runbook 1](../RUNBOOKS.md#1-writes-are-blocked-on-synchronous-replication) |
| `primary_start_timeout: 0` | Restarting PostgreSQL behind Patroni's back | Patroni reads a crash and hands the leader key away: a 2-second restart becomes an election |
| `watchdog: mode: required` | Rebooting without confirming `softdog` came back | A node that cannot arm its watchdog **refuses to be primary at all** — [runbook 2](../RUNBOOKS.md#2-failover-did-not-happen) |
| etcd and PostgreSQL share a node, not a lifecycle | Patching both in the same window | An unhealthy DCS at the moment Patroni is asked to move a leader |

A single `ansible -a "yum update"` across the inventory violates the first three
at once. That is the failure this lab exists to characterise.

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

Three rules follow from the constraints above, and each is a step someone skips:

- **The primary is patched last, and only after a switchover.** A switchover is a
  controlled handover with no `ttl` to wait out, measured at ~2s in
  [`SLA.md`](../SLA.md#per-failure-mode). Restarting the primary directly costs an
  election instead.
- **Restarts go through Patroni, not around it.** `patronictl restart` tells
  Patroni what is about to happen; `systemctl restart` does not. This is the
  single most common mistake made by an operator who knows PostgreSQL but not
  Patroni.
- **Step 3 needs a healthy cluster.** A switchover requires one leader and two
  `streaming` standbys, so a run that has left a standby down must not proceed to
  it.
- **`pending_restart` is checked before and after.** Patroni exposes
  `patroni_pending_restart`, and a configuration change awaiting a restart can sit
  unapplied indefinitely. No alert watches it today; Lab 6 adds one, since this is
  the operation that clears it.

## Scope

| In scope | Out of scope |
| --- | --- |
| PostgreSQL **minor** version upgrades, rolling | **Major** version upgrades — `pg_upgrade` or logical replication, a different problem |
| Patroni and etcd package upgrades, one node at a time | Upgrading across an etcd major version, or a Patroni DCS schema change |
| OS and kernel patching, including the reboot | Unattended or automated patching policy |
| A client committing throughout, measuring what it saw | Patching the application tier |
| Rollback when new binaries will not start | Rebuilding a node from backup — that is [Lab 4](../lab4/README.md) |
| The order above, **and** the measured cost of getting it wrong | Zero-restart patching; a minor upgrade requires a restart by definition |

Major upgrades are excluded deliberately rather than forgotten. They cannot be
rolling on a physical-replication cluster: the standbys cannot replicate across a
major version, so the procedure is a different shape entirely and belongs in its
own lab if it is ever needed.

## Topology

Four VMs: three cluster nodes and an application host. No new infrastructure —
this lab is about a procedure, not a component.

It forks [Lab 5](../lab5/README.md), for two things it needs:

- **An encrypted cluster.** Patching means rebooting, and a reboot here has to
  unlock LUKS volumes unattended, land the mounts before PostgreSQL starts, and
  bring `softdog` back. Those are exactly what a kernel update disturbs.
- **A monitoring stack** already proven to fire on eleven faults and deliver
  mail a test can read. Without it, AC-8 cannot be asked.

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
| AC-8 | Correct maintenance does not page the on-call | Through a complete, correctly ordered patch cycle: **no alert fires**. Through each negative control in AC-2: the alert named in advance fires, **and no other** |

### Four of these can surprise us; four are postconditions

AC-1, AC-3, AC-5 and AC-7 assert that a correct procedure works. They are worth
having and unlikely to teach anyone anything. The other four are where the lab
earns its time:

**AC-2 is what makes the ordering rules load-bearing** rather than superstition.
Every other criterion can pass on a careful run by a careful operator and prove
nothing about the *procedure*. It also produces the directly useful output: a
measured cost for each wrong move, which is what turns "one node at a time" into
an instruction someone follows at 02:00 rather than an unexplained rule.

**AC-4 is where a marginal dependency surfaces.** Surviving a reboot was proven
once, as a property; patching makes it a routine, and routine is where luck runs
out — a `crypttab` entry that works until the keyfile's filesystem mounts a little
later, a unit ordering that held by accident. `softdog` is the sharpest case:
persistence *is* configured here, by a `modules-load.d` entry, so the question is
not whether someone forgot but whether a kernel update replaced the kernel the
module was built for. AC-4 distinguishes those two.

**AC-6 is the one usually skipped.** Patching procedures are written for the case
where the package installs. The interesting question is what an operator does at
23:00 when it does not, and whether the answer requires rebuilding the node —
which here means a `reinit` and a full resync, hours where minutes were needed.

**AC-8 decides whether any of the others get followed.** An alerting system that
fires through every maintenance window teaches people to ignore it, and they stop
reading at exactly the wrong moment. Lab 5's alerts fire between 130s and 260s
and several patch steps take longer than that, so silence is not automatic: it
has to be designed for and verified. If a correct cycle cannot be made quiet,
that is a finding about the thresholds, and better learned here than at 03:00.

## What this contributes back

[`RUNBOOKS.md`](../RUNBOOKS.md) has no rolling-maintenance procedure — only
[runbook 8](../RUNBOOKS.md#8-planned-switchover), which is one step of it. This
lab is what lets a full "patch the cluster" procedure be added and marked
**VERIFIED**, with each ordering rule carrying the measured cost of breaking it.

[`SLA.md`](../SLA.md) gains the planned-maintenance figure it currently infers
from a single switchover: the wall-clock cost of a complete patch cycle across
three nodes, which is the number a change-advisory board actually asks for.

Lab 5 gains `PendingRestart`, the alert it lacks, proven in the same lab as the
operation that clears it.
