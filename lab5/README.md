# Lab 5: monitoring with Grafana LGTM

> **Status: built and verified — all five criteria met.** The acceptance
> criteria below are unchanged from before the work started, which is the point
> of writing them first. `make check` runs 29 phases. Nine alerts have been
> watched firing with their latency measured — five induced in the alerting
> phase, which asserts each raises its own alert **and no other**, and four in
> the phases before it.

The shared components, cluster design and prerequisites are in the
[top-level README](../README.md). This file covers Lab 5 only.

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
| Restore rehearsal | the timestamp of the last successful recovery drill | see below |

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

### The second staleness metric: when was a restore last proven?

[Lab 4](../lab4/README.md) creates the need for this one. A backup regime that
has not been restored since the last schema change, PostgreSQL upgrade or
certificate rotation is a hypothesis again — and **nothing else in this series
would notice**. Backup age answers "is the repository still filling?"; restore
rehearsal age answers "does any of it still work?", and only the second one
catches a repository that fills perfectly with backups nobody can use.

It is the cheapest alert here and the one most likely to be missing, because it
measures a human activity rather than a system's.

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
design, and Lab 5 should answer it honestly rather than assume the logs are there.

## Topology

The LGTM stack runs on the control machine, not in more VMs — the same reasoning
that puts MinIO there for Lab 3, and that ruled out a Tang server in Lab 2.
Grafana, Mimir and Loki run there, reachable from the guests at the Lima
shared-network gateway. **Mimir and Loki keep their data in MinIO** — `lab5-mimir`
and `lab5-loki` — which is how they are run anywhere that matters, and which the
lab can afford because the object store, its TLS and its scoped credentials
already exist.

Prometheus is not used: it writes a local TSDB and has no S3 backend, so
S3-backed metrics means Mimir. Tempo is not built at all, because traces are
deferred until the .NET client is instrumented, and storage nothing writes to is
not worth configuring.

The cost of that choice is stated rather than hidden: backups and telemetry now
share one object store. A MinIO outage stops the backups *and* blinds the
monitoring that should report it. Separate buckets and separate credentials limit
the blast radius; only a separate instance would remove it.

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

[`SLA.md`](../SLA.md) measured recovery time and said nothing about detection
time. For self-healing faults that is fine. For the two failures above it was
half the answer: their real RTO is *detect + decide + act*, and only the last
part was measured.

It now carries a **detection** section with nine measured latencies, 130s to
260s, and the instruction to add them to the RTO of any row that does not
self-repair — which is what makes this a measurement rather than a dashboard
exercise. [`RUNBOOKS.md`](../RUNBOOKS.md) gained a *What tells you* line on
every procedure that has an alert behind it, naming the alert, its latency and
what trips it; runbook 7 says plainly that nothing tells you, because no rule
here watches a certificate's expiry date.

## Decisions taken

Both were open when this file was written. [`PLAN.md`](PLAN.md) carries the full
reasoning and the costs accepted.

| Question | Decided |
| --- | --- |
| **Tempo and traces** | **Not built.** They only earn their place once the .NET client is instrumented, which is real work outside this lab's question. The cost is stated rather than paid: a failover stays invisible from the client's side. No Tempo means no third bucket — storage nobody writes to is not worth configuring |
| **Alert delivery** | **Mailpit, over SMTP — not a webhook sink.** Email is the channel these alerts would really use, and it exercises what a webhook cannot: Alertmanager's `email_configs` and the templating inside every annotation. A JSON dump would accept `<no value>` as a subject line without comment; a rendered mail does not, and AC-5 asserts on the rendered mail |
| **Which alertmanager** | **A standalone Alertmanager**, not Mimir's built-in one. Measured: Mimir's delivers exactly one notification after a restart and fails every later one with `invalid service state: Terminated`, while `/services` still reports it Running and every rule reads firing. Its per-tenant config upload, sharding ring and replicated state target multi-tenant SaaS and earn nothing here. The standalone one takes a mounted config file, so a missing route stops the container instead of dropping alerts |
