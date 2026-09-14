# Lab 6 — build plan

The design and its acceptance criteria are in [`README.md`](README.md). This file
is the order of work: what is already known, what was decided, what each phase
must prove, and what could go wrong.

## What this lab inherits

Lab 6 forks [Lab 5](../lab5/README.md) and uses four things from it directly:

| Inherited | Used for |
| --- | --- |
| Sixteen alert rules, delivery asserted by reading a real mailbox | AC-8, which reuses `test-alert-coverage.sh`'s harness unchanged |
| An off-host repository and a restore ladder with measured costs | AC-6, which must beat `reinit` — the expensive alternative is measured next door, so "without rebuilding" means something |
| A client that commits continuously and reports what it saw | AC-1, stated in failed transactions |
| Existing quorum, watchdog and `patronictl` assertions | AC-7's end state, re-used rather than restated |

## Known before starting

Measured against the live repositories and this repository's own configuration.
The first four decide whether the lab is possible at all.

| Finding | Consequence |
| --- | --- |
| Percona ships PostgreSQL **18.1, 18.3, 18.4, 18.6** for el9 on both arches | A real minor upgrade exists. The build pins **18.4** and patches to **18.6** |
| Several builds exist of the same minor (18.1-1/-2/-3, 18.4-1/-2) | AC-6 gets a same-minor rollback target as well as a cross-minor one |
| **Patroni 4.1.2 → 4.1.5**, **etcd 3.5.24 → 3.5.33** | AC-5 upgrades both for real rather than reinstalling one version |
| Rocky 9 carries kernels **687.42 → 687.46** for el9_8 | AC-4 can boot a genuinely different kernel — but see the first risk below |
| The roles install `state: present`, with no version pin | Without a pin there is nothing to upgrade *from*, so pinning is a prerequisite, not a preference |
| `primary_start_timeout: 0` in `patroni-dcs.yml.j2` | AC-3's premise is deliberate configuration, not an accident worth working around |
| `softdog` is loaded by `modprobe` **and** by a boot-persistence entry | AC-4 therefore tests whether a *kernel change* breaks it, not whether someone forgot to persist it |
| Lab 2 detects a real reboot by `boot_id`, which moves only when the kernel restarts | AC-4 gets a mechanism a service restart cannot fake |
| Lab 5's alerts fire between 130s and 260s | AC-8 is not free: several patch steps outlast those windows |
| `patroni_pending_restart` is scraped every 15s, but no rule watches it | The alert Lab 6 adds costs a rule, not a collector |
| A fresh VM answers SSH before its resolver does (Lab 4, fixed by a DNS gate) | Patching downloads packages, so the same gate belongs before every `dnf` step |
| `pgbackrest verify` exits 0 on a damaged repository (Labs 3 and 4) | Any check added here reads a verdict from output, never an exit code |

## Decisions

| Decision | Why | Cost accepted |
| --- | --- | --- |
| Fork Lab 5 | It is the only base carrying both the encrypted cluster and the monitoring AC-8 needs | A heavier lab, and 16GB holds one at a time, so Lab 5 is destroyed first |
| Pin to 18.4, patch to 18.6 | One realistic minor hop, the shape of a monthly patch | The build stops tracking latest; the pin needs revisiting when the repo moves |
| `make check` excludes Lab 5's 25-minute alert-coverage phase | Lab 6's subject is patching. Re-proving Lab 5's alerts on every run would push a cycle past 90 minutes | The phase stays available as a target, just not in the default path |
| Measure every wrong move, never describe it | A cost in seconds is what survives contact with 02:00 | The negative controls are the most destructive tests in the series |
| Roll back with `dnf downgrade`, not `reinit` | Minor versions do not change the catalogue, so a binary downgrade is safe — the lab proves it rather than asserting it | If a downgrade proves impossible for a package, that is a finding to report, not to engineer around |

## Phases

| Phase | Proves | In one line |
| --- | --- | --- |
| P0 | — | A cluster on 18.4, 18.6 confirmed installable, and the missing alert added |
| P1 | AC-3, AC-7 | One standby patched through Patroni, cluster undegraded after |
| P2 | AC-2, and AC-8's negative half | Both wrong moves performed, costed, and their alerting recorded |
| P3 | AC-1 | The full four-step cycle, zero failed transactions |
| P4 | AC-4 | A kernel update and reboot, unattended, watchdog armed after |
| P5 | AC-5 | etcd and Patroni upgraded a member at a time, quorum never lost |
| P6 | AC-6 | Broken binaries, rolled back without rebuilding the node |
| P7 | AC-8's positive half | A correct cycle, and a mailbox that stays empty |

### P0 — Fork, pin, and add the missing alert — **done**

Fork into `lab6/`, renaming `lab5` → `lab6`. Comments that name a lab by its
*purpose* must be re-read rather than renamed: a blind substitution has twice
turned a correct sentence into a false one.

Pin `percona-postgresql18-*` to 18.4, and assert 18.6 is installable before
anything is built on top — the precondition proven by use, as rung 6's dry run
does it.

Add the `PendingRestart` rule with a positive control: set a parameter that
requires a restart, watch the alert fire, clear it with a restart, watch it
resolve.

**Done when:** three nodes run 18.4, 18.6 is confirmed available, and
`PendingRestart` has been watched firing *and* clearing.

> **Done.** Three nodes on 18.4-2. 18.6 proven by use, not by a listing: from
> inside a guest `dnf` offers 18.4-1, 18.4-2 and 18.6-1, and a dry-run upgrade
> resolves to a real transaction — 18.4-1 also gives AC-6 a same-minor rollback
> target. `PendingRestart` fired 300s after a config change, exactly its window,
> and cleared 15s after a rolling restart applied it.
>
> Three fork defects found by building it. Alloy was pushing to Lab 5's ports
> because the rebase missed two Ansible variables, so Mimir held nothing. The new
> rule was indented four spaces where the file uses two, so Mimir rejected the
> whole group with `400 unable to decode rule group`. And the reason that 400 went
> unnoticed: `observability.sh` printed "Alert rules loaded" off curl's exit
> status, which is success whenever the server answers — including when it answers
> 400. The stack came up announcing alerting it did not have. It now reads the
> rules back and counts them.
>
> A full `make all` then passed 32 of 33 phases. The failure was Rung 1, waiting
> on member state that still said `streaming` from before the reinit took effect:
> a 1s "rebuild", and a journal read before pgBackRest had written its report.
> Completion is now detected from the journal, as starting already was.

### P1 — One standby, patched the right way — **done**

`patronictl restart` one standby, wait for `streaming`, assert the leader key
never moved, then assert AC-7's full end state.

**Done when:** one standby runs 18.6 while the others run 18.4, the cluster is
healthy, and a mixed-version cluster has been shown to replicate.

> **Done.** pg2 patched 18.4 → 18.6 and streaming again **5s** after the restart
> began, with the leader key unmoved and the timeline unchanged — AC-3's claim,
> measured. AC-7's end state intact: one leader, two streaming standbys, quorum
> commit still strict, watchdog present on all three, not paused.
>
> Two assertions here exist nowhere else in the lab. Between `dnf upgrade` and
> the restart, pg2 had 18.6 **on disk** while still **running** 18.4 and still
> streaming — the gap that makes the restart step necessary, and which is
> invisible once it has happened. And with the leader on 18.4 and the standby on
> 18.6, a row written on one arrived on the other: mixed-version replication
> proven by moving data across the boundary rather than by citing release notes.

### P2 — The two wrong moves: performed, costed, and their alerting recorded

The mailbox is emptied first, and the expected alerting outcome is written down
**before** each control runs — otherwise "the right alert fired" is a judgement
made after seeing the result. Capturing it here, while the fault is already
induced, is why these controls run once rather than twice.

1. **Both standbys at once.** Measure how long writes block and confirm the
   signature matches [runbook 1](../RUNBOOKS.md#1-writes-are-blocked-on-synchronous-replication)'s:
   `ANY 1 (*)` with backends in `SyncRep`. Held past 130s so the alert has time
   to fire. *Expected: `WritesBlockedOnSyncReplication`, and no other.*
2. **`systemctl restart` on the primary.** Measure the election and the
   client-visible failure. *Expected: **no alert at all**.* The cluster
   self-repairs in ~10–25s, under every threshold in the ruleset. If that holds,
   it is a finding rather than a gap — and it belongs in the maintenance runbook,
   which cannot promise an operator that monitoring would have caught this.

Each is restored and asserted healthy before the next begins.

**Done when:** both costs are numbers, each control's alerting matches what was
named in advance, and the cluster is healthy again.

Only the first cost has a runbook signature to match. The second is measured
against [`SLA.md`](../SLA.md#per-failure-mode): a switchover moves the leader in
~2s and PostgreSQL dying under Patroni costs ~10–25s, so the number to produce is
what restarting the primary directly costs against the ~2s it could have cost.

### P3 — The full cycle, invisible to the client

The four-step order end to end, client committing throughout.

One extra check, **reported rather than gated**: run it with the backup timers
live. A patch window colliding with a scheduled backup is an ordinary Tuesday,
and nothing in this series has tested what happens when a node restarts
mid-backup. If it is ugly, it belongs in the maintenance runbook.

**Done when:** every node runs 18.6, the client records **zero** failed
transactions, and the wall-clock cost of a complete cycle is emitted.

### P4 — A kernel update, and a reboot nobody attends

Update the kernel on one standby, reboot, and assert by `boot_id` that the kernel
actually restarted — then that the volumes unlocked, the mounts landed before
PostgreSQL started, `softdog` came back, the watchdog armed, and the node
returned to `streaming` with no operator action.

The watchdog assertion is the one to watch: a node that cannot arm it does not
fail loudly, it quietly refuses to be primary, and that is discovered at the next
failover.

**Done when:** a node has survived a real kernel change unattended, with the
watchdog armed afterwards rather than assumed.

### P5 — etcd and Patroni, one member at a time

Upgrade etcd and Patroni on each node in turn, sampling `etcdctl endpoint health`
throughout and watching Patroni's view of the DCS. Never in the same window as a
PostgreSQL patch.

**Done when:** every member is upgraded, quorum was never lost, and neither
`EtcdQuorumLost` nor `PatroniLostDcs` fired.

### P6 — The upgrade that will not start

Break the new binaries on one standby so PostgreSQL fails to start, then follow
the documented rollback and return it to `streaming`. The assertion that matters
is negative: **the data directory was never rebuilt from the primary.** Compare
against Lab 4's measured `reinit` cost to state what the rollback saved.

**Done when:** a node has been recovered from a failed upgrade without a resync,
and the saving is a number.

### P7 — A correct cycle, and a mailbox that stays empty

Empty the mailbox, run the complete correct cycle, and assert it is **still
empty** at the end. AC-8's other half — what each wrong move raises — was
recorded in P2, while those faults were already induced.

The cycle is the one P3 performs, run again rather than reused: P3's runs
alongside live backup timers and its own measurements, and a silence assertion
has to be made about a clean run or it proves nothing about maintenance.

If a correct cycle cannot be made silent, the output is the list of alerts it
raised and a recommendation on thresholds. That is a finding about the alerting,
not a failed patch procedure.

**Done when:** correct maintenance is proven silent, or its noise is
characterised.

## Risks

| Risk | Mitigation |
| --- | --- |
| **The kernel gap disappears.** AC-4 needs the image's kernel to be older than the newest available. If a refreshed Rocky image closes that gap, AC-4 silently becomes a test that passes because nothing happened | P0 asserts the gap exists and, if it does not, installs an older kernel deliberately and boots into it. The precondition is manufactured, not hoped for |
| **The version pin rots.** 18.4 will eventually leave the repository | P0 asserts both the pinned version and the target are installable, failing with a message naming both |
| **The negative controls damage the cluster** | Both are documented incidents with VERIFIED runbooks. Each is restored and asserted healthy before the next phase |
| **Two clusters will not fit in 16GB** | Lab 5 is destroyed before Lab 6 is built; nothing here depends on its data |
| **A long suite invites concurrent runs**, which mutate one shared cluster and fabricate failures belonging to neither | The suite refuses to start if another run is detected |

## What carries out of this lab

A maintenance runbook, a planned-maintenance figure for `SLA.md`, and the
`PendingRestart` alert Lab 5 lacks — each described in
[`README.md`](README.md#what-this-contributes-back), which is where the outputs
are specified rather than planned.
