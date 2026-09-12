# Lab 5 — build plan

The design and its acceptance criteria are in [`README.md`](README.md), written
before building so they cannot reshape themselves around whatever happened. This
file is the order of work, the decisions taken, and what each phase has to prove.

## What we borrow

Lab 5 forks [Lab 4](../lab4/README.md), which supplies more than a cluster: an
off-host encrypted repository, a restore ladder with measured costs, and — most
usefully — a set of faults that can be induced on demand. A monitoring lab whose
faults are hypothetical proves nothing. Labs 1 to 4 between them can now induce,
reproducibly:

| Fault | Induced by |
| --- | --- |
| Primary VM lost | `make test_failover_vm` |
| PostgreSQL killed, Patroni alive | `make test_failover_postgres` |
| Patroni frozen, PostgreSQL serving | `make test_fencing_patroni` |
| Node isolated from etcd | `make test_fencing_etcd` |
| Writes blocked on synchronous replication | runbook 1 drill |
| Cluster paused | runbook 3 drill |
| etcd quorum lost | runbook 4 drill |
| Archiving broken, WAL accumulating | runbook 6 drill |
| A node that will not rejoin | runbook 5 drill |
| Failover blocked by a missing watchdog | runbook 2 drill |
| A corrupted repository object | AC-8 control 3 |

Eleven faults, each already asserted to produce its documented symptom. AC-2 asks
that each raises **its specific alert**, and this is what makes that answerable
rather than aspirational.

## Verified before starting

Measured while building Labs 3 and 4, and each one changes what this lab must do.
None of them are assumptions.

| Finding | Consequence for monitoring |
| --- | --- |
| **`pgbackrest verify` exits 0 on a corrupted repository.** It printed `status: error` and `total valid WAL: 5` of 6, then returned success | An exporter that shells out and reads the exit code reports a healthy repository **forever**. The verdict is in the output. AC-3 must cover backups *rotting*, not only stopping |
| **`pgbackrest info` exits 0 on a repository it cannot even decrypt** | Same shape. Neither command is a health check, and a dashboard built on either is decorative |
| **`pg_stat_archiver` counters are cumulative and survive a role change.** A standby was measured holding `failed_count=4` from when it was primary | Alerting on `failed_count > 0` fires permanently on any node that has ever had an incident. Alert on the **rate of increase** and on `last_failed_time` recency |
| **A standby's archiver counters never move**, because only the primary archives | The alert must be scoped to the node holding the leader key, or it is evaluated where it can never fire |
| **The archive backlog is `pg_wal/archive_status/*.ready`**, not the file count in `pg_wal`, which stayed at 32 while archiving was demonstrably broken | The disk-filling metric is the backlog. The file count is a lagging indicator that only moves once `min_wal_size` is exhausted |
| **`synchronous_standby_names = 'ANY 1 (*)'` with backends in `wait_event = SyncRep`** is the blocked-writes signature. `(*)` is Patroni's unsatisfiable placeholder | An alert on it has no false-positive mode, because it cannot occur on a healthy cluster |
| **"No leader anywhere" has three distinct causes** — paused, etcd quorum lost, watchdog unavailable — and `patronictl list` shows the same empty result for all three | Three alerts, not one. An alert that says "no leader" sends the operator to a page that cannot tell them which of three procedures to follow |
| **A node that cannot arm its watchdog refuses to be primary**, logging `Watchdog device is not usable` | That log line is the only distinguishing signal, so this alert comes from **logs**, not metrics — which is part of why Loki is in scope |

## Decisions taken

| Decision | Why | Cost accepted |
| --- | --- | --- |
| **The stack runs on the control machine**, like MinIO | Monitoring that dies with the cluster it watches is not monitoring. The failure this lab exists for is a cluster that has stopped doing something, and something outside it has to notice | The stack is not itself highly available; that gap is stated rather than solved |
| **Alloy on every node**, shipping metrics and logs | One agent, two signals, and it is what the design already names | Another service per node to install and keep running |
| **A local webhook receiver as the alert destination** | Proving an alert *fires* is easy; proving it *arrives* is the part that is usually skipped, and AC-5 asks for it. A receiver in the lab makes arrival assertable without email or a pager vendor | It proves delivery to a local endpoint, not to a phone at 03:00. Stated as a gap |
| **A custom pgBackRest exporter**, not a shell wrapper around `verify` | Forced by the findings above: the exit codes are useless, so the exporter must parse output and expose `repo_verify_ok`, `last_backup_age_seconds`, and `archive_backlog_segments` | Custom code to maintain, and it must itself be tested against a *corrupted* repository |
| **Tempo and traces deferred** | They only earn their place once the .NET client is instrumented, which is real work outside this lab's question | A failover stays invisible from the client's side. Recorded as deferred, not dropped |
| **Every alert ships with a positive control** | The dominant lesson of Labs 3 and 4: thirteen checks could not fail, and the drill harness printed `FAIL` while reporting `PASS`. An alert nobody has watched fire is not monitoring | Roughly doubles the work per alert, and is the reason to do this lab at all |

## Phases

| Phase | Serves | Gate |
| --- | --- | --- |
| P0 | — | The stack is up and every node ships something |
| P1 | AC-1 | Metrics from all five sources; stopping one is visible as absence |
| P2 | AC-2 (the two that matter) | Blocked writes and stopped backups both alert, both proven to fire |
| P3 | AC-3 | Backup absence **and** corruption alert |
| P4 | AC-4 | A failover reconstructed from logs alone |
| P5 | AC-5 | The pipeline monitors itself, and alerts are proven to arrive |
| P6 | AC-2 (in full) | All eleven faults raise their specific alert — and a healthy run raises none |

### P0 — Fork Lab 4, stand up LGTM and Alloy

**What.** `lab5/` becomes a working copy of Lab 4, renamed, plus the LGTM stack on
the control machine and Alloy on each node.
**How.** Copy `lab4/`, rename, new stanza and bucket. A `make observability_start`
target mirroring `minio_start`, so the stack is managed the same way.
**Done when.** `make all` is green from scratch, the stack answers, and every node
is shipping something.

> The one thing to get right here is that the stack must not be a dependency of
> the cluster. If Alloy being down can stop PostgreSQL, the lab has made
> availability worse in the name of watching it.

### P1 — Everything is observable, and absence is visible

**What.** Metrics from Patroni, etcd, PostgreSQL, the node, and pgBackRest.
**How.** Patroni and etcd expose their own; `postgres_exporter` and
`node_exporter` for the next two; the custom exporter for the repository.
**Serves.** AC-1.
**Done when.** All five are present, and **stopping one is detected as absence
rather than read as zero** — which is the same distinction as a check that passes
on an empty result.

### P2 — The two failures that never heal themselves

**What.** The reason this lab exists.
**How.** Alert on `synchronous_standby_names = 'ANY 1 (*)'` together with
backends in `SyncRep`; alert on backup age exceeding its threshold and on the
archive backlog growing.
**Serves.** AC-2, AC-3 in part.
**Done when.** Both alerts fire when the corresponding drill runs, **and neither
fires during a healthy run.**

> These are the two failures from the design where nothing throws. Every other
> fault in the table above is self-healing and already measured; detection
> latency barely matters when recovery is automatic. It matters entirely here.

### P3 — Backups that rot, not just backups that stop

**What.** The half of AC-3 the findings above created.
**How.** The exporter parses `verify` output for `status: error` and
`invalid result`, and exposes it. The positive control corrupts a real repository
object, exactly as Lab 4's AC-8 does.
**Serves.** AC-3.
**Done when.** A corrupted object raises an alert, and the run proves it by
corrupting one and watching the alert fire.

> Absence and corruption are different failures with the same consequence:
> discovering at restore time that there was nothing to restore from. A
> monitoring lab that only alerts on *age* would have reported this repository
> healthy throughout.

### P4 — A failover, reconstructed from logs alone

**What.** Given only Loki, answer: which node was primary, when was it lost, which
was promoted, and how long the gap was.
**Serves.** AC-4.
**Done when.** The answer is derived from log queries, with no reference to the
test that induced it.

### P5 — Monitoring the monitoring

**What.** A stopped Alloy must be **detected**, not read as silence. A silent
alertmanager must be detected. And a fired alert must be shown to have arrived.
**Serves.** AC-5.
**Done when.** Stopping Alloy on one node raises an alert within a stated window,
and the webhook receiver holds the payload of an alert the run deliberately
triggered.

> The failure mode here is the one every monitoring system has: it goes quiet,
> and quiet looks exactly like healthy. The same shape as a check that passes on
> an empty result, and the same remedy — assert on presence, never on absence of
> a complaint.

### P6 — Every fault raises its own alert, and nothing else does

**What.** The full form of AC-2, across all eleven inducible faults.
**How.** Run each fault; assert its specific alert fires; assert no unrelated
alert fires with it.
**Done when.** Eleven faults, eleven specific alerts, and a healthy control run
that raises none.

> "And none are invented" is half the criterion. An alerting system that fires
> three alerts for one fault trains its operators to ignore it, which is a slower
> way of having no monitoring at all.

## Risk

**R1. Alerts that cannot fire.** The defining risk, and the one this series has
already been bitten by repeatedly — thirteen vacuous checks in Labs 3 and 4, and
a drill harness that reported `PASS` while printing `FAIL`. An alert rule that is
syntactically valid, visible in the UI, and incapable of matching anything is the
monitoring equivalent, and it is invisible precisely when it matters.

*Mitigation:* no alert is considered done until something has induced the fault
and watched it fire. That is what P6 is, and it is why the fault table above is
the first section of this plan.

**R2. Alerting on cumulative counters.** Measured, not imagined:
`pg_stat_archiver` survives role changes, so a node that had an incident last
month still reads `failed_count=4`. An alert on the absolute value fires forever
and is then silenced, which is worse than not having it.

*Mitigation:* rate and recency, never absolute counts, and the positive control
must run on a node with a non-zero history.

**R3. The stack becomes the thing being debugged.** LGTM plus Alloy plus three
exporters is more moving parts than the database it watches.

*Mitigation:* it runs on the control machine, it is never a dependency of the
cluster, and P0 asserts that stopping it does not affect PostgreSQL.

## What this contributes back

[`RUNBOOKS.md`](../RUNBOOKS.md) currently tells an operator what to do once they
know something is wrong. Every procedure in it assumes somebody noticed — and the
two most dangerous findings of Labs 3 and 4 were both silent by nature. This lab
supplies the other half: what tells you, and how long it takes.

[`SLA.md`](../SLA.md) records detection as **not established** for every row. It
is the last missing term. An RTO that begins when someone notices is not an RTO,
and until this lab exists the series cannot honestly state one.
