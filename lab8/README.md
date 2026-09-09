# Lab 8: monitoring with Grafana LGTM

> **Status: specified, not built.** Everything below is the design and its
> acceptance criteria. No results are claimed.

The shared components, cluster design and prerequisites are in the
[top-level README](../README.md). This file covers Lab 8 only.

## Goal

Know that something has gone wrong before someone tells you, and prove that
claim the same way every other lab proves its own: by breaking things on purpose
and requiring the monitoring to notice.

## Monitoring is the easiest thing in this series to fake

A lab that stands up Grafana, renders dashboards and declares success has proven
that Grafana renders. Observability failures are silent by construction — a
broken alerting pipeline looks exactly like a quiet night, and the absence of
alerts is indistinguishable from the absence of problems.

What makes this testable is something the series already has: **a fault
injection suite**. Labs 1 and 2 can kill a VM, kill PostgreSQL, freeze Patroni
until the watchdog resets the node, cut a node off from etcd, and stop both
standbys. So the criterion is not "are there dashboards" but:

> For every fault the labs can inject, monitoring must raise a specific alert
> within a measured time — and must raise none of them on a healthy cluster.

## The failures that actually need this

Most faults in Labs 1 and 2 are self-healing. Kill a node, Patroni promotes,
service returns in about a minute. Detection latency barely matters when recovery
is automatic and already measured.

Two failures are different, and they are the point of this lab:

| Failure | Why monitoring is the only defence |
| --- | --- |
| **Writes blocked on synchronous replication** | With [`synchronous_mode_strict`](../SLA.md#the-exception-being-closed), losing both standbys stops writes until someone intervenes. Nothing recovers on its own |
| **Backups silently stopped** | Nothing throws. The repository simply stops filling, and it is discovered when a restore is needed |

Both share the property that makes them dangerous: **no error is raised**. The
system quietly stops doing something it was supposed to keep doing.

The first has an exact signal, observed while building Lab 1 rather than guessed:

```text
synchronous_standby_names = 'ANY 1 (*)'   and   backends in wait_event = SyncRep
```

`ANY 1 (*)` is Patroni's unsatisfiable placeholder. It cannot occur on a healthy
cluster, so an alert on it has no false-positive mode.

## What is monitored

| Component | Source | Notes |
| --- | --- | --- |
| Patroni | **native `/metrics` on 8008** | No exporter. `patroni_primary`, `patroni_cluster_unlocked`, `patroni_pending_restart`, xlog location |
| etcd | **native `/metrics` on 2379** | `etcd_server_has_leader`, `leader_changes_seen_total`, and backend fsync duration — which is the number Lab 2's separate-volume decision was made to protect |
| PostgreSQL | `postgres_exporter` | Replication lag, `sync_state`, backends in `SyncRep`, connections against `max_connections` |
| Node | `node_exporter` | Disk free on the LUKS volumes, CPU, memory |
| pgBackRest | no native exporter — see below | |

Two integration points fall out of Lab 2 rather than being invented here. Its
Patroni REST API and etcd both require **client certificates**, so the collector
needs its own identity issued from the existing CA — the second use of the "one
CA, extended" decision recorded in [`lab2/PLAN.md`](../lab2/PLAN.md). And
`postgres_exporter` needs a least-privilege monitoring login, on the same
reasoning that gave the application `app_runtime` rather than a superuser — the
`monitoring` role in [`SERVICE-ACCOUNTS.md`](../SERVICE-ACCOUNTS.md).

## pgBackRest

Called out separately because its failure mode is unlike everything else here:
the failure is an **absence of activity**, not the presence of an error. Two
complementary sources, because neither alone is sufficient:

| Source | Answers |
| --- | --- |
| `pg_stat_archiver` (native PostgreSQL) | Is WAL archiving working *right now*? `archived_count`, `failed_count`, `last_failed_time` |
| `pgbackrest info --output=json`, parsed to a textfile collector | When did a backup last *succeed*? Age, type, repository size |

The headline metric is the **age of the last successful backup**, and the alert
is on staleness rather than on any error. `pg_stat_archiver` gives the earliest
warning that `archive_command` has broken; the backup age is what catches a
repository that quietly stopped filling.

## Logs, and Alloy

Alloy runs on each node doing both jobs — scraping metrics and shipping logs —
so there is one collector to configure, certificate, and monitor.

Worth collecting: PostgreSQL (`csvlog`), the `percona-patroni` journal where
elections, promotions and self-demotions are recorded, etcd, pgBackRest, and the
kernel journal.

One limitation is worth testing rather than assuming. A softdog reset kills the
node abruptly, so the last seconds of log may never be shipped. Whether a
watchdog reset can be explained *after the fact* is a real question about this
design, and Lab 8 should answer it honestly rather than assume the logs are there.

## Topology

The LGTM stack runs on the control machine, not in more VMs — the same reasoning
that puts MinIO there for Lab 3, and that ruled out a Tang server in Lab 2.
Grafana's `otel-lgtm` image bundles Grafana, Mimir, Loki and Tempo in one
container, reachable from the guests at the Lima shared-network gateway.

## Acceptance criteria

| ID | Property | Pass condition |
| --- | --- | --- |
| AC-1 | Every component is observable | Metrics present from Patroni, etcd, PostgreSQL, the node and pgBackRest; stopping one exporter is itself detected |
| AC-2 | Every injectable fault is detected, and none are invented | Each fault from Labs 1 and 2 raises its specific alert, with the detection latency recorded; a healthy cluster raises none of them |
| AC-3 | Backup failure is detected by absence | Breaking `archive_command` raises an alert; letting backup age exceed its threshold raises another |
| AC-4 | A failover can be reconstructed from logs alone | Given only Loki, identify which node was primary, when it was lost, and which was promoted |
| AC-5 | The monitoring pipeline is itself monitored | A stopped Alloy is detected rather than read as silence, and a deliberately fired alert is observed arriving |

### AC-2 is the one that matters

Its second half is what makes it more than a checklist. A rule that fires on
everything detects every fault and is worthless; requiring silence on a healthy
cluster is what separates detection from noise.

### AC-5 is the one usually skipped

Every other criterion assumes the pipeline works. If Alloy dies, or an alert
fires into a void, the dashboards stay green and the cluster looks healthy —
which is the specific failure this lab exists to rule out.

## What this contributes back

[`SLA.md`](../SLA.md) measures recovery time and says nothing about detection
time. For self-healing faults that is fine. For the two failures above it is
half the answer: their real RTO is *detect + decide + act*, and only the last
part is currently measured.

Lab 8's output is therefore a detection-latency column in `SLA.md`, which is what
makes it a measurement rather than a dashboard exercise.

## Open decisions

| Question | Consideration |
| --- | --- |
| **Tempo and traces** | Only earn their place if the .NET client is instrumented. Then a failover is visible from the client's side — "retried 16 times" correlated with "Patroni promoted pg3" on one timeline, which metrics cannot show. The cost is real .NET work |
| **Alert delivery** | Proving an alert *fires* is easy; proving it *arrives* needs a destination. A local webhook receiver keeps AC-5 self-contained and assertable |
