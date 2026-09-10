# Availability, RPO and RTO

> ### Decision taken — `synchronous_mode_strict` will be enabled
>
> **Durability is favoured over availability, without exception.** An
> acknowledged transaction must survive, and the cluster must refuse to
> acknowledge one it cannot make durable on a second node.
>
> This closes the gap where the cluster silently fell back to asynchronous once
> the last standby was gone. The accepted cost: with both standbys unavailable,
> writes **block** until one returns. That is a real outage, chosen deliberately
> in exchange for a guarantee that never lapses.
>
> Rationale and consequences: [The exception being closed](#the-exception-being-closed).
>
> **Status: implemented and verified in both built labs.** Each proves it with a
> mutation test — the same fault, the same cluster, only the setting changed:
>
> ```text
> strict ON    synchronous_standby_names 'ANY 1 (*)'   SyncRep   commit blocked
> strict OFF   synchronous_standby_names ''            none      commit completed
> ```
>
> `ANY 1 (*)` is Patroni's unsatisfiable placeholder — the concrete artefact of
> it refusing to degrade.

What the labs establish about data loss and downtime, per failure mode.

Two caveats govern everything below.

**RPO and RTO are measured or configured; availability is derived.** A three-VM
lab on one laptop cannot substantiate an availability percentage — that needs
failure rates observed over time on representative hardware. The availability
figures here answer only the arithmetic question: *given the measured RTO, how
many such events fit inside each tier per year?*

**These describe the cluster, not a service.** They assume the client behaves as
Labs 1 and 2 prove it does: bounded timeouts, retries scoped to connection
failures, no blind reissue of a write. A client that retries blindly turns an RPO
of zero into duplicate data, and no cluster setting prevents that.

## The choice: durability over availability

**When durability and availability conflict, this cluster protects the data and
accepts the downtime.** An acknowledged transaction must survive, even at the
cost of refusing to acknowledge it in the first place.

That is not the default and not free. `synchronous_mode: quorum` with
`synchronous_node_count: 1` means a commit is not acknowledged until a standby
has flushed it:

| | Effect |
| --- | --- |
| Every commit | Costs a network round trip plus a standby fsync before acknowledgement |
| A slow standby | Slows the primary; the commit waits rather than proceeding unconfirmed |
| No standby able to confirm | The backend parks in a `SyncRep` wait — the write blocks rather than completing unsafely |
| Promotion | Can only pick a node known to be caught up, tracked in the DCS |

The payoff is RPO **0 for an acknowledged commit**, proven rather than inferred:
[`make test_sync`](lab1/README.md#replication-is-synchronous) commits 200 rows,
force-stops the primary with no clean shutdown, and finds every acknowledged row
on the promoted node.

Asynchronous replication was the alternative: faster commits, never blocks, and a
failover silently loses whatever had not yet reached the standby. For a lab whose
premise is that the client must not lose an acknowledged transaction, that trade
is the wrong way round.

### The exception being closed

Quorum commit alone left one gap. Without `synchronous_mode_strict`, Patroni
clears `synchronous_standby_names` when no standby can confirm, and the primary
carries on asynchronously — silently. The client is not told, and its durability
guarantee weakens with no signal. That invisibility is the strongest argument
against keeping it.

The decision is to set it:

```yaml
synchronous_mode: quorum
synchronous_node_count: 1
synchronous_mode_strict: true   # durability over availability, unconditionally
```

Strict mode refuses to clear `synchronous_standby_names`, so commits block in
`SyncRep` until a standby returns rather than completing on one node.

**The availability cost is smaller than it first appears.** etcd runs on the same
three nodes, so losing two nodes already means losing etcd quorum: the survivor
cannot renew its leader key, demotes itself, and the cluster is read-only whatever
this setting says. The two options only diverge in a narrower case.

| Situation | Non-strict | Strict |
| --- | --- | --- |
| One standby lost | No impact | No impact |
| Two nodes lost entirely | Read-only — etcd quorum gone | Read-only — identical |
| Both standby databases down, nodes up | Accepts writes held on **one disk only** | Blocks |

The last row is the whole decision, and it is a realistic one: both replicas
restarting, both lagging, a disk full on both, a botched rolling change.

Two operating conditions come with the decision, and both are requirements
rather than caveats:

- **It presents as a hang, not an error.** A blocked commit waits; it does not
  fail fast. Clients need a command timeout or their pools fill and the
  application stalls, turning a database problem into an application-wide
  outage. The lab client sets `Command Timeout=10`, which is why this is
  survivable here — the same timeout that bounds a stalled node also bounds a
  blocked commit.
- **Rolling maintenance must never take both standbys out at once.** With
  `synchronous_node_count: 1`, one can always be lost freely; the second is what
  stops writes.

The opposite choice remains legitimate for a workload that would rather keep
accepting orders on a single node than stop. It is not this one.

## Per failure mode

RTO is time until a client can commit again, not until the cluster is fully
redundant. Rejoining the lost node takes longer and does not block writes.

| Failure mode | RPO | RTO | Fits 99.99% at | Source |
| --- | --- | --- | --- | --- |
| Primary VM lost | **0** | ~40–75s | ≤ 40 events/yr | measured |
| PostgreSQL killed, Patroni alive | **0** | ~10–25s | ≤ 120 events/yr | measured |
| Patroni frozen, PostgreSQL serving | **0** | ~25–60s | ≤ 50 events/yr | measured |
| Node isolated from etcd | **0** — demotes rather than diverging | ~10s to demote; no cluster outage | n/a | measured |
| Every standby lost at once | **0** | writes block until a standby returns | [the decision](#the-exception-being-closed) | **measured** |
| Corruption, deletion, bad migration | bounded by backup age and WAL archive interval | hours — restore plus replay | **not established** | Labs 3, 4, 6 — not built |

**The last row is outside what HA can address.** Failover, fencing and quorum
commit all assume a node stopped working. A bad migration or an erroneous
`DELETE` is the cluster working correctly on a wrong instruction: replication
carries it to every standby in milliseconds, and quorum commit makes it durable
before it is acknowledged. No healthy node retains the old state. Only a backup
answers it, which is why Labs 3, 4 and 6 exist and why that RTO is blank rather
than guessed.

## Where the numbers come from

Configured bounds, exact:

| Setting | Value | Consequence |
| --- | --- | --- |
| `ttl` | 30s | A leader key held by a dead node must expire before any promotion |
| `loop_wait` | 10s | Patroni's decision interval |
| `retry_timeout` | 10s | `ttl` sits on Patroni's floor of `loop_wait + 2 × retry_timeout` |
| `primary_start_timeout` | 0 | A crash fails over immediately instead of restarting locally — why row 2 is an order of magnitude faster than row 1 |
| `safety_margin` | 5 | softdog resets a frozen leader at `ttl - safety_margin` = 25s |
| client `Timeout` | 5s | Upper cost of one attempt against an unreachable host |
| client retry delay | 2s | Interval between connection attempts |
| client budget | 90s | Covers `ttl` + `loop_wait` + promotion |

Measured, from failover and fencing checks across repeated from-scratch builds —
retries the client needed before committing on the newly promoted primary:

```
min 0    max 16    mean 7.1    n = 8
```

At a 2s delay plus up to 5s per failed attempt, 16 retries is roughly 40–75s.
Zero retries means promotion completed before the client's first attempt.

Ranges, not guarantees: the sample is small and it is a laptop.

## Availability budget

| Tier | Downtime per year | Primary VM lost (~60s) | PostgreSQL killed (~20s) |
| --- | --- | --- | --- |
| 99.9% | 8h 45m | ~525 events | ~1,576 events |
| 99.95% | 4h 22m | ~262 events | ~788 events |
| 99.99% | 52m 34s | ~52 events | ~157 events |
| 99.999% | 5m 15s | ~5 events | ~15 events |

The last row is the useful one. Failover of this kind is comfortably a 99.99%
mechanism and reaches five nines only if failures are rare — roughly five a year.
Going beyond is not a Patroni tuning exercise; it needs the outage to stop being
visible to the client at all, which means connection-level failover in front of
the database rather than a faster election.

## Fault domains: must the nodes be on separate hypervisors?

**Yes, and the usual phrasing is too weak.** The rule the design actually
implies:

> **No single fault domain may contain a majority of the nodes.**

Everything rests on etcd quorum, 2 of 3. Losing one node is survivable; losing
two is not — the survivor cannot form a majority, Patroni cannot write to the
DCS, and the cluster goes read-only. The question is never "are they all in one
place?" but "can one event take out two?"

| Placement | Worst single-domain loss | Result |
| --- | --- | --- |
| 3 nodes, 1 hypervisor | 3 of 3 | Total loss |
| 2 + 1 across two | 2 of 3 | **Quorum lost** — read-only until a node returns |
| 1 + 1 + 1 across three | 1 of 3 | Survives — the only placement that works |

No two-domain arrangement of three nodes is valid, since one domain must hold
two. Three nodes require three independent domains — not a best practice, but the
condition under which the design functions.

### What co-location costs

Not everything. On one hypervisor the cluster still protects against process- and
OS-level failure — a PostgreSQL crash, an OOM kill, a hung Patroni, a corrupt
data directory — which is common, and exactly what Labs 1 and 2 inject.

What is lost is the host:

```text
availability(cluster)  <=  availability(most-shared component)
```

Three VMs on one host cannot be more available than that host. Every mechanism
here is defeated by one power supply, one kernel panic, or one patch reboot. The
machinery still runs; it has nowhere to fail over to. Co-location is not a lie
about the mechanisms, but it is a lie about the availability — and that is the
number people act on.

### Separate hypervisors is necessary, not sufficient

Fault domains nest. Separate hosts sharing anything beneath them share that too:

| Shared | Common-mode failure |
| --- | --- |
| Storage array or SAN | Three hosts, one array — the array is the SPOF |
| Top-of-rack switch | Nodes up but unable to reach each other; etcd loses quorum |
| Power circuit / PDU | One breaker takes the rack |
| Rack | Physical and cooling faults |
| Availability zone | Usually the failure being bought against |

Each level answered moves the SPOF one level down. The question is what is the
lowest thing all three still share, and how often that fails.

### Anti-affinity must be enforced and verified

Correctly placed nodes get quietly co-located later by live migration, DRS
rebalancing, or evacuation during host maintenance. The rule must be a hard
constraint, not a preference: a soft rule is violated precisely when a host is
being evacuated, which is when redundancy is already reduced. And placement is an
assertion until something checks it — nothing announces that a scheduler moved a
node.

### Independence costs commit latency

Spreading nodes buys independence and costs performance, and
[the durability stance](#the-choice-durability-over-availability) is what makes
it bite: quorum commit puts a standby fsync *and* a network round trip inside
every acknowledgement. Hosts, racks or zones within a metro add well under a
millisecond. Separate regions add tens of milliseconds to **every write** and make
etcd's Raft heartbeats marginal, causing spurious elections on a healthy cluster.

So: three fault domains, close enough that the round trip is negligible.
Cross-region belongs to asynchronous replicas or backups, not to this cluster's
synchronous quorum. With only two real sites there is no quorum-safe placement;
the fix is a third site holding an etcd witness — a vote and a network path, not
a database.

## Not covered

- **Correlated failure.** Every lab VM runs on one laptop — the least valid row
  in the placement table above, and the largest gap between what these labs prove
  (mechanisms) and what a deployment needs (availability).
- **Planned maintenance.** `patronictl switchover` is a controlled promotion and
  should beat an election, but the labs do not measure it.
- **The application tier.** Everything here stops at the database.
- **Sustained load.** RTO is measured idle; promotion under heavy write load has
  more WAL to replay and will be slower.
