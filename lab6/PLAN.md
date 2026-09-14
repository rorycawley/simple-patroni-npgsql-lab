# Lab 6 — build plan

The design and its acceptance criteria are in [`README.md`](README.md), written
before building so they cannot reshape themselves around whatever happened. This
file is the order of work, the decisions taken, and what each phase has to prove.

## What we borrow

[`README.md`](README.md) says this lab forks [Lab 2](../lab2/README.md). That was
written when Lab 2 was the newest encrypted lab; Labs 3, 4 and 5 have been built
since, and each is a fork of the one before it, so Lab 5 already contains
everything Lab 2 offered. **This lab forks [Lab 5](../lab5/README.md).** The
acceptance criteria are unchanged — only the base is newer.

The reason given for forking Lab 2 still holds and now holds harder: patching
means rebooting, and a reboot on the encrypted cluster is where marginal
dependencies surface. Lab 5's fork carries that same encrypted cluster, plus
three things this lab needs:

| Inherited | Why this lab needs it |
| --- | --- |
| **Monitoring that watches the cluster** — Mimir, Loki, Alloy, 16 alert rules, delivery proven to a mailbox | Patching is the operation that most resembles an outage. Whether it *looks* like one to the on-call is now a measurable question, not a rhetorical one |
| **An off-host repository and a restore ladder** | AC-6's rollback must be shown to work **without** rebuilding from the primary. The ladder is what makes "without" meaningful: the expensive alternative is right there, measured |
| **A client that commits continuously** and records what it saw | AC-1 is stated in terms of failed transactions, and Lab 1's client already reports them |

## Verified before starting

Measured in this repository. None are assumptions, and each changes what this
lab must do.

| Finding | Consequence |
| --- | --- |
| **Patroni's `/metrics` is already scraped** by Alloy every 15s, job `patroni`, over mutual TLS | `patroni_pending_restart` is already in Mimir. The alert this lab needs costs a rule, not a collector |
| **Lab 5 does NOT alert on `pending_restart`.** Its sixteen rules are named in `lab5/observability/rules/lab5.yaml`, and none of them is this one | [`README.md`](README.md) claims "Lab 5 alerts on it". That claim is false and is corrected in P0 rather than inherited. The metric exists; the rule never did |
| **`primary_start_timeout: 0`** in `patroni-dcs.yml.j2` | AC-3's premise is real: a restart Patroni did not initiate is seen as a crash, with no grace period. The measurement is worth taking because the number is zero by *configuration*, not by accident |
| **`softdog` is loaded twice over** — `modprobe` now, and a boot-persistence task | So AC-4 is not asking "is it persistent" but the sharper question: does a **kernel update** disturb the thing that loads it. A module built for the running kernel is the classic casualty |
| **Lab 2 detects a real reboot by `boot_id`**, which moves only when the kernel actually restarts | AC-4 gets a mechanism that cannot be faked by a service restart. Reused rather than reinvented |
| **Alert latencies are 130s–260s** ([`SLA.md`](../SLA.md)) | A patch step shorter than an alert's `for:` window will not page. That is the mechanism by which correct maintenance stays quiet, and it means the *duration* of each step is a safety property worth measuring |
| **`pgbackrest verify` exits 0 on a damaged repository** — Labs 3 and 4 | Any check this lab adds reads a verdict from output. No new exit-code gates |
| **A fresh VM answers SSH before its resolver does** — found in Lab 4's rung 6, fixed by a DNS gate in `install.yml` | Patching downloads packages. The same race applies after every reboot, and the same gate belongs in front of every `dnf` step here |

### The one that decides whether this lab is possible at all

**A rolling minor upgrade needs two minor versions to exist.** If Percona's
repository carries only the current PostgreSQL 18 minor, there is nothing to
upgrade *to*, and AC-1 cannot be performed — only mimed.

This is checked **first**, in P0, before any VM is built, by querying the
repository for available versions of `percona-postgresql-18`, `patroni` and
`etcd`. Three outcomes, decided in advance so the answer cannot quietly reshape
the lab:

| What the repository offers | What the lab does |
| --- | --- |
| Two or more minors available | Build pinned to the **older** minor, patch to the newer. The honest form |
| Only one minor, but older versions exist in an archive or vault repo | Same, with the vault repo enabled at build time |
| Genuinely only one version | **Stop and report.** AC-1 is then unachievable as written, and the alternatives — patching a different package, or simulating with a rebuilt RPM — prove something other than what AC-1 claims. That is the owner's call, not a substitution to make quietly |

## Decisions taken

| Decision | Why | Cost accepted |
| --- | --- | --- |
| **Fork Lab 5, not Lab 2** | Everything Lab 2 had, plus the monitoring that makes "does maintenance page anyone" answerable | A heavier lab to stand up, and patching now runs with an observability stack alongside it |
| **Build pinned to an older minor version**, then upgrade | The only way AC-1 is a real upgrade rather than a reinstall of the same bits | The build no longer tracks latest, and the pin needs revisiting whenever the repo moves |
| **Every wrong move is measured, not described** | AC-2 is the criterion that makes the ordering rules load-bearing. A cost in seconds is what makes "one node at a time" survive contact with 02:00 | The negative controls are the most destructive tests in the series: they deliberately block writes and force an election |
| **Restarts via `patronictl`, with `systemctl` as the negative control** | AC-3 is a comparison, so both halves must actually be performed on a live primary | One deliberate, unnecessary failover per run |
| **Rollback by `dnf downgrade`, not by reinit** | AC-6 exists because the usual answer — rebuild from the primary — costs hours where minutes were needed. The downgrade path must be shown to work on a node that is already broken | If a downgrade proves impossible for a package, that is a finding to report, not to engineer around |
| **The client runs throughout every phase**, not only AC-1's | A procedure that is invisible to clients in isolation and disruptive in sequence is the failure mode worth catching | Longer runs, and a client that must survive deliberate outages in the negative controls |

## Proposed addition, for the owner to accept or decline

The criteria in [`README.md`](README.md) were frozen before building, which is
the point of them. One property has become measurable since they were written,
and it is proposed here **before** any building starts rather than added
afterwards:

> **AC-8 — Correct maintenance does not page the on-call.** Through a complete,
> correctly ordered patch cycle, no alert fires. Through each negative control in
> AC-2, the alert that fires is named in advance and no other does.

This is the inverse of Lab 5's AC-2 ("every fault raises its own alert and no
other") and reuses its harness directly. It matters because an alerting system
that cries wolf during every maintenance window trains people to ignore it, which
is the most common way monitoring fails in practice — quietly, and long before
the incident it was built for.

If declined, the lab still measures alert behaviour during patching and reports
it; it simply is not a pass condition.

## Phases

| Phase | Proves | In one line |
| --- | --- | --- |
| P0 | — | A real upgrade exists to perform, and the fork is honest |
| P1 | AC-3, AC-7 | One standby patched through Patroni, cluster undegraded after |
| P2 | AC-2 | Both wrong moves performed and costed |
| P3 | AC-1 | The full four-step cycle, with zero failed transactions |
| P4 | AC-4 | A kernel update and reboot, unattended, volumes and watchdog back |
| P5 | AC-5 | etcd upgraded a member at a time, quorum never lost |
| P6 | AC-6 | Broken binaries, rolled back without rebuilding the node |
| P7 | AC-8 (if accepted) | The whole cycle, and what the on-call would have received |

### P0 — Fork Lab 5, and establish that there is something to patch

Answer the version question above **first** — it decides whether the rest of the
plan is worth starting. Then fork Lab 5 into `lab6/`, pin the build to the older
minor, and correct the false `pending_restart` claim in `README.md`.

Add the `PendingRestart` rule Lab 5 was said to have and does not, with the
positive control every Lab 5 alert carries: set a parameter that requires a
restart, watch the alert fire, clear it by restarting, watch it resolve.

Done when: the cluster is up on the pinned older minor, a newer minor is
confirmed installable, and `PendingRestart` has been watched firing and clearing.

### P1 — One standby, patched the right way

The smallest complete step of the procedure: `patronictl restart` one standby,
wait for `streaming`, assert no leader change occurred, and assert AC-7's full
end state — one leader, two streaming standbys, quorum commit active, watchdog
armed, not paused.

Done when: a standby is on the new minor, the leader key never moved, and the
cluster is not left degraded.

### P2 — The two wrong moves, performed and costed

The lab's centre of gravity, and the reason it is not a paragraph.

1. **Both standbys at once.** With `synchronous_node_count: 1` and strict mode,
   the second one blocks writes. Measure how long writes are blocked and confirm
   the signature is exactly [runbook 1](../RUNBOOKS.md#1-writes-are-blocked-on-synchronous-replication)'s
   — `ANY 1 (*)` with backends in `SyncRep`.
2. **`systemctl restart` on the primary.** With `primary_start_timeout: 0`,
   Patroni sees a crash. Measure the election and the client-visible failure.

Both are restored to health before continuing, and the cost of each is recorded
as a number the runbook can quote.

Done when: both costs are measured, both signatures match the runbooks that
already document them, and the cluster is healthy again.

### P3 — The full cycle, invisible to the client

The four-step order from [`README.md`](README.md), start to finish, with the
client committing throughout: standby A, standby B, switchover, old primary.

Done when: every node is on the new minor, the client records **zero** failed
transactions, and the wall-clock cost of the complete cycle is emitted — the
number a change-advisory board asks for, which [`SLA.md`](../SLA.md) currently
lacks.

### P4 — A kernel update, and a reboot nobody attends

Where Lab 2 gets audited. Update the kernel on one standby, reboot it, and assert
by `boot_id` that the kernel actually restarted — then that the LUKS volumes
unlocked, the mounts landed before PostgreSQL started, `softdog` came back,
the watchdog armed, and the node returned to `streaming` with **no operator
action**.

Done when: a node has survived a real kernel change unattended, and the watchdog
is armed afterwards rather than merely assumed.

### P5 — etcd, one member at a time

Upgrade etcd on each node in turn, with `etcdctl endpoint health` sampled
throughout and Patroni's view of the DCS watched for loss. Never concurrently
with a PostgreSQL patch, for the reason the design already states: an unhealthy
DCS at the moment Patroni is asked to move a leader.

Done when: every member is upgraded, quorum was never lost, and no `EtcdQuorumLost`
or `PatroniLostDcs` alert fired.

### P6 — The upgrade that will not start

Break the new binaries deliberately on one standby so PostgreSQL fails to start,
then follow the documented rollback — `dnf downgrade` — and return the node to
`streaming`. The assertion that matters is the negative one: **the data directory
was never rebuilt from the primary.** Compare against the ladder's measured
`reinit` cost from Lab 4 to state what the rollback saved.

Done when: a node has been recovered from a failed upgrade without a resync, and
the saving is a number.

### P7 — What the on-call would have received

If AC-8 is accepted: run the complete correct cycle with the mailbox emptied
first, and assert it is still empty at the end. Then run each AC-2 negative
control and assert the named alert fires **and no other** — Lab 5's
`test-alert-coverage.sh` already does exactly this shape of check.

Done when: correct maintenance is proven silent, and each wrong move is proven to
page for the right reason.

## Risk

| Risk | Mitigation |
| --- | --- |
| **No second minor version exists** | Settled in P0 before anything is built. If it cannot be resolved, the lab stops and reports rather than simulating an upgrade |
| **Rebooting a Lima guest is not a real server reboot** | `boot_id` proves the kernel restarted. What Lima cannot prove — firmware, hardware watchdog behaviour — is already a stated production gap, and stays stated |
| **The negative controls damage the cluster** | Both are already documented incidents with VERIFIED runbooks (1 and 2). Each is restored and asserted healthy before the next phase |
| **Two clusters will not fit** | 16 GB holds one lab at a time. Lab 5 is destroyed or stopped before Lab 6 is built, and the labs' own `make clean` handles it |
| **The monitoring stack makes patching look healthy when it is not** | Every alert this lab relies on has been watched firing in Lab 5. Any new rule gets the same positive control before it is trusted |

## What this contributes back

[`RUNBOOKS.md`](../RUNBOOKS.md) has no rolling-maintenance procedure — only
[runbook 8](../RUNBOOKS.md#8-planned-switchover), one step of it. This lab is what
lets a full "patch the cluster" runbook be added and marked **VERIFIED**, with
each ordering rule carrying the measured cost of breaking it.

[`SLA.md`](../SLA.md) gains the planned-maintenance figure it currently infers
from a single switchover: the wall-clock cost of a complete patch cycle across
three nodes.

And Lab 5 gains the alert it was documented to have: `PendingRestart`, with the
operation that clears it proven in the same lab.
