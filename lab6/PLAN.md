# Lab 6 — build plan

The design and its acceptance criteria are in [`README.md`](README.md), written
before building so they cannot reshape themselves around whatever happened. This
file is the order of work, the decisions taken, and what each phase has to prove.

## What we borrow

Lab 6 forks [Lab 5](../lab5/README.md), which supplies a cluster, an off-host
encrypted repository, a restore ladder with measured costs, and — the reason for
choosing it over Lab 4 — a monitoring stack already proven to fire on eleven
faults and deliver mail that a test can read.

| Inherited | Why this lab needs it |
| --- | --- |
| **Sixteen alert rules, delivery asserted** by reading a real mailbox | AC-8 is the inverse of Lab 5's AC-2 and reuses its harness directly. Without it, "does routine maintenance wake anyone" is unanswerable |
| **An off-host repository and a restore ladder with costs** | AC-6 must show a failed upgrade recovered **without** rebuilding from the primary. The expensive alternative is measured next door, so "without" means something |
| **A client that commits continuously** and reports what it saw | AC-1 is stated in failed transactions, and the client already counts them |
| **`patronictl`, watchdog and quorum assertions** | AC-7's end state is Lab 1's healthy state. It is already asserted by inherited phases; this lab re-uses them rather than restating them |

## Verified before starting

Measured, not assumed. The first four decide whether this lab is possible at all,
and they were checked against the live repositories before a line was written.

| Finding | Consequence |
| --- | --- |
| **Percona ships PostgreSQL 18.1, 18.3, 18.4 and 18.6** for el9 on both arches | A real rolling minor upgrade exists to perform. The build pins **18.4** and patches to **18.6** |
| **Multiple builds of the same minor exist** (18.1-1/-2/-3, 18.4-1/-2) | AC-6 has a same-minor rollback target as well as a cross-minor one |
| **Patroni 4.1.2 → 4.1.5 and etcd 3.5.24 → 3.5.33** are both available | AC-5 is a real upgrade of both, not a reinstall |
| **Rocky 9 carries kernels 687.42 through 687.46 for el9_8** | AC-4 can reboot onto a genuinely different kernel — see the risk below, because this gap is not guaranteed |
| **The roles install `state: present` with no version pin** | Every lab so far took whatever was newest at build time. Lab 6 cannot: without a pin there is nothing to upgrade *from* |
| **`primary_start_timeout: 0`**, confirmed in `patroni-dcs.yml.j2` | AC-3's premise is real and deliberate: a restart Patroni did not initiate is read as a crash, with no grace period at all |
| **`softdog` is loaded twice over** — `modprobe` now, plus a boot-persistence task | So AC-4 asks the sharper question: does a **kernel update** disturb the thing that loads it. A module built for the running kernel is the classic casualty |
| **Lab 2 detects a real reboot by `boot_id`**, which moves only when the kernel restarts | AC-4 gets a mechanism that a service restart cannot fake. Reused rather than reinvented |
| **Lab 5's alerts fire between 130s and 260s** ([`SLA.md`](../SLA.md)) | AC-8 is not automatic. Several patch steps take longer than 130s, so silence has to be designed for and then verified |
| **Lab 5 does NOT alert on `pending_restart`**, though its README claimed it did | Patroni's `/metrics` is already scraped every 15s, so the metric is in Mimir and only the rule is missing. Lab 6 is the operation that clears it, so the alert belongs here |
| **A fresh VM answers SSH before its resolver does** — Lab 4's rung 6, fixed by a DNS gate | Patching downloads packages. The same gate belongs in front of every `dnf` step here |
| **`pgbackrest verify` exits 0 on a damaged repository** — Labs 3 and 4 | Any check this lab adds reads a verdict from output. No new exit-code gates |

## Decisions taken

| Decision | Why | Cost accepted |
| --- | --- | --- |
| **Fork Lab 5, not Lab 2 as the spec said** | Lab 2 was the newest encrypted lab when that line was written; every lab since is a fork of the one before. Lab 5 contains all of it, plus the monitoring AC-8 needs | A heavier lab to stand up, and 16GB holds one lab at a time, so Lab 5 is destroyed before this is built |
| **Pin the build to 18.4, patch to 18.6** | One realistic minor hop, the shape of an actual monthly patch | The build stops tracking latest, and the pin needs revisiting when the repo moves. Stated in the README so it is not mistaken for neglect |
| **AC-8 adopted before building, and recorded as added** | It only became measurable once Lab 5 existed. Adding it now is legitimate; adding it after a run would be writing the criterion around the result | One more phase, and a real possibility that the answer is "no, maintenance does page" — which is a finding, not a failure |
| **`make check` does not re-run Lab 5's 25-minute alert-coverage phase** | Lab 6's job is patching. Re-proving eleven inherited alerts on every run buys nothing and would push a run past 90 minutes | The inherited phase stays available as a target; it is simply not in the default path |
| **Every wrong move is measured, never described** | AC-2 is what makes the ordering rules load-bearing rather than superstition. A cost in seconds is what survives contact with 02:00 | The negative controls are the most destructive tests in the series: they deliberately block writes and force an election |
| **Rollback by `dnf downgrade`, not by reinit** | AC-6 exists because the usual answer — rebuild from the primary — costs hours where minutes were needed. Minor versions do not change the catalogue, so a binary downgrade is safe; the lab proves it rather than asserting it | If a downgrade turns out to be impossible for some package, that is a finding to report, not to engineer around |

## Phases

| Phase | Proves | In one line |
| --- | --- | --- |
| P0 | — | A cluster on 18.4, a newer minor confirmed installable, and the missing alert added |
| P1 | AC-3, AC-7 | One standby patched through Patroni, cluster undegraded after |
| P2 | AC-2 | Both wrong moves performed and costed |
| P3 | AC-1 | The full four-step cycle, zero failed transactions |
| P4 | AC-4 | A kernel update and reboot, unattended, watchdog armed after |
| P5 | AC-5 | etcd and Patroni upgraded a member at a time, quorum never lost |
| P6 | AC-6 | Broken binaries, rolled back without rebuilding the node |
| P7 | AC-8 | What the on-call would actually have received |

### P0 — Fork Lab 5, pin the version, and add the alert Lab 5 was said to have

Fork into `lab6/`, renaming `lab5` → `lab6` throughout — and **check the prose
while doing it**. That rename has twice falsified comments that refer to a lab by
its purpose rather than its name; the fix is to name the originating lab
explicitly, never "this lab".

Pin `percona-postgresql18-*` to 18.4 at install, and assert 18.6 is installable
before building anything on top of it — the precondition proven by use, the way
rung 6's dry run does it.

Then add the `PendingRestart` rule, with the positive control every Lab 5 alert
carries: set a parameter that requires a restart, watch the alert fire, clear it
with a restart, watch it resolve.

Done when: three nodes run 18.4, 18.6 is confirmed available, and `PendingRestart`
has been watched firing **and** clearing.

### P1 — One standby, patched the right way

The smallest complete step: `patronictl restart` one standby, wait for
`streaming`, assert the leader key never moved, and assert AC-7's full end state —
one leader, two streaming standbys, quorum commit active, watchdog armed, not
paused.

Done when: one standby runs 18.6 while the others run 18.4, the cluster is
healthy, and a mixed-version cluster has been shown to replicate.

### P2 — The two wrong moves, performed and costed

The centre of the lab, and the reason it is not a paragraph.

1. **Both standbys at once.** With `synchronous_node_count: 1` and strict mode
   the second one blocks writes. Measure how long writes block, and confirm the
   signature is exactly [runbook 1](../RUNBOOKS.md#1-writes-are-blocked-on-synchronous-replication)'s:
   `ANY 1 (*)` with backends in `SyncRep`.
2. **`systemctl restart` on the primary.** With `primary_start_timeout: 0`
   Patroni reads it as a crash. Measure the election and the client-visible
   failure.

Each is restored to health and asserted healthy before the next begins.

Done when: both costs are numbers, both signatures match the runbooks that
already document them, and the cluster is healthy again.

### P3 — The full cycle, invisible to the client

The four-step order from [`README.md`](README.md) end to end, client committing
throughout: standby A, standby B, switchover, old primary.

One extra check here, **beyond the criteria and reported rather than gated**: run
the cycle with the backup timers live. A patch window colliding with a scheduled
backup is an ordinary Tuesday, and nothing in the series currently says what
happens when a node is restarted mid-backup. If it is ugly, that belongs in the
maintenance runbook.

Done when: every node runs 18.6, the client records **zero** failed transactions,
and the wall-clock cost of a complete cycle is emitted — the number a change
advisory board asks for, which [`SLA.md`](../SLA.md) does not have.

### P4 — A kernel update, and a reboot nobody attends

Where Lab 2 gets audited. Update the kernel on one standby, reboot, and assert by
`boot_id` that the kernel actually restarted — then that the LUKS volumes
unlocked, the mounts landed before PostgreSQL started, `softdog` came back, the
watchdog armed, and the node returned to `streaming` with **no operator action**.

The watchdog assertion is the one to watch. `softdog` is a kernel module, and the
node that cannot arm it does not fail loudly — it quietly refuses to be primary,
which you discover at the next failover.

Done when: a node has survived a real kernel change unattended, and the watchdog
is armed afterwards rather than assumed.

### P5 — etcd and Patroni, one member at a time

Upgrade etcd 3.5.24 → 3.5.33 and Patroni 4.1.x on each node in turn, with
`etcdctl endpoint health` sampled throughout and Patroni's view of the DCS
watched for loss. Never at the same time as a PostgreSQL patch, for the reason
the design already gives: an unhealthy DCS at the moment Patroni is asked to move
a leader.

Done when: every member is upgraded, quorum was never lost, and neither
`EtcdQuorumLost` nor `PatroniLostDcs` fired.

### P6 — The upgrade that will not start

Break the new binaries deliberately on one standby so PostgreSQL fails to start,
then follow the documented rollback — `dnf downgrade` — and return it to
`streaming`. The assertion that matters is negative: **the data directory was
never rebuilt from the primary.** Compare against the ladder's measured `reinit`
cost from Lab 4 to say what the rollback saved.

Done when: a node has been recovered from a failed upgrade without a resync, and
the saving is a number.

### P7 — What the on-call would actually have received

Empty the mailbox, run the complete correct cycle, and assert it is **still
empty**. Then run each AC-2 negative control and assert the named alert fires and
no other — the shape `test-alert-coverage.sh` already implements.

If a correct cycle cannot be made silent, the honest output is the list of alerts
it raised and why, plus a recommendation on thresholds. That is a finding about
the alerting, not a failed patch procedure, and it is worth more than a green tick.

Done when: correct maintenance is proven silent, or its noise is characterised.

## Risk

| Risk | Mitigation |
| --- | --- |
| **The kernel gap disappears.** AC-4 needs the image's kernel to be older than the newest available. It is today, but a refreshed Rocky image could close it, and AC-4 would silently become a test that passes because nothing happened | P0 **asserts the gap exists** and, if it does not, installs an older kernel deliberately and boots into it. The precondition is manufactured rather than hoped for |
| **The version pin rots.** 18.4 will eventually leave the repository | P0 asserts both the pinned version and the target are installable, and fails with a clear message naming the two versions if either is gone |
| **The negative controls damage the cluster** | Both are documented incidents with VERIFIED runbooks (1 and 2). Each is restored and asserted healthy before the next phase |
| **Two clusters will not fit.** 16GB holds one | Lab 5 is destroyed before Lab 6 is built. Its repository and telemetry are disposable; nothing in Lab 6 depends on them |
| **Patching is slow, and a long suite invites concurrent runs** | These phases mutate one shared cluster, and a second run fabricates failures that belong to neither. The suite says so, and the run refuses to start if another is detected |

## What this contributes back

[`RUNBOOKS.md`](../RUNBOOKS.md) has no rolling-maintenance procedure — only
[runbook 8](../RUNBOOKS.md#8-planned-switchover), which is one step of it. This
lab is what lets a full "patch the cluster" runbook be added and marked
**VERIFIED**, with each ordering rule carrying the measured cost of breaking it.

[`SLA.md`](../SLA.md) gains the planned-maintenance figure it currently infers
from a single switchover: the wall-clock cost of a complete patch cycle across
three nodes.

And Lab 5 gains the alert it was documented to have — `PendingRestart` — proven
in the same lab as the operation that clears it.
