# Operations runbook — PostgreSQL HA cluster

Procedures to follow *during* an incident on a three-node Patroni cluster.
Terse on purpose: the reasoning behind them lives in
[`WHY_PGBACKREST_AND_PGDUMP.md`](WHY_PGBACKREST_AND_PGDUMP.md) and
[`SLA.md`](SLA.md), and neither belongs in your way at 03:00.

**Start at [Find your incident](#find-your-incident).** If you do not yet know
what is wrong, start at [First five minutes](#first-five-minutes) instead.

## What this cluster is

Three nodes, each running PostgreSQL, Patroni and one member of the etcd
cluster. There is no proxy, VIP or connection pooler in front of it — the
application connects to all three addresses and asks its driver for the current
primary. Patroni promotes, fences, and maintains quorum commit.

Three facts explain most of the incidents in this file. Each is a deliberate
design decision, not a defect, and each has a procedure below.

| Fact | Consequence | Procedure |
| --- | --- | --- |
| **Durability is chosen over availability.** A commit is not acknowledged until a second node has flushed it, and the cluster will not silently drop that requirement | With no standby able to confirm, **writes block** rather than completing on one disk | [1](#1-writes-are-blocked-on-synchronous-replication) |
| **A node that cannot arm its watchdog refuses to be primary at all** | A missing watchdog device presents as *no leader anywhere*, not as a warning | [2](#2-failover-did-not-happen) |
| **Two of the three nodes must be running** | etcd needs a majority. One survivor goes read-only, whatever else is healthy | [4](#4-etcd-has-lost-quorum) |

## Conventions

`patroni.yml` is `0600 postgres`, and PostgreSQL's binaries are not on `PATH`.
Every command here therefore runs as the `postgres` user with a full binary
path, exactly as written. Commands are safe to run on any node unless a step
says otherwise.

These values are site-specific. Substitute yours wherever a command says
`<cluster>`:

| Value | In these labs | Used by |
| --- | --- | --- |
| Cluster and pgBackRest stanza name | `lab1`, `lab2` | `patronictl`, `pgbackrest --stanza` |
| Patroni configuration | `/etc/patroni/patroni.yml` | every `patronictl` command |
| PostgreSQL binaries | `/usr/pgsql-18/bin` | every `psql` command |
| PostgreSQL data directory | `/var/lib/pgsql` | disk checks, restores |
| Service units | `percona-patroni`, `etcd` | every `systemctl` command |
| TLS certificate directory | `<pki-dir>` — per cluster, where TLS is configured | certificate expiry |

## Verification status

Every procedure carries one of these markers. A runbook that mixes rehearsed and
unrehearsed steps without saying which is worse than no runbook, because it will
be followed literally under pressure.

| Marker | Means |
| --- | --- |
| **VERIFIED** | An automated drill induces this exact state, runs the diagnosis below, applies the fix below, and asserts recovery. The steps are known to work because they are executed, not reviewed |
| **REASONED** | Follows from PostgreSQL and Patroni semantics, and in most cases from a failure seen during the build — but never executed end to end as written |
| **STUB** | Named so it is not forgotten. **Do not follow it yet** |

The drill is `make test_runbook`, which also checks that every path, service
unit and account this file names actually exists on the cluster it describes. A
runbook is an assertion until something runs it.

## Find your incident

| What you are seeing | Go to |
| --- | --- |
| Commits hang and never return; connection pools filling up | [1. Writes are blocked on synchronous replication](#1-writes-are-blocked-on-synchronous-replication) |
| The primary is gone and nothing was promoted | [2. Failover did not happen](#2-failover-did-not-happen) |
| Everything looks healthy, but you are not sure failover still works | [3. Patroni is paused and nobody remembers](#3-patroni-is-paused-and-nobody-remembers) |
| The cluster has gone read-only; `patronictl list` is empty or stale | [4. etcd has lost quorum](#4-etcd-has-lost-quorum) |
| A node is up but will not become a standby again | [5. A node will not rejoin the cluster](#5-a-node-will-not-rejoin-the-cluster) |
| Disk filling on a database node, or `pg_wal` growing | [6. Disk filling, or WAL accumulating](#6-disk-filling-or-wal-accumulating) |
| Replication, `patronictl` and the application all failed at once | [7. Certificates have expired](#7-certificates-have-expired) |
| You need to move the primary deliberately, for maintenance | [8. Planned switchover](#8-planned-switchover) |
| A change was committed and was wrong | [9. Undo a change that was committed and later found to be wrong](#9-undo-a-change-that-was-committed-and-later-found-to-be-wrong) |
| Every node is gone | [10. Total loss — every node gone](#10-total-loss--every-node-gone) |

## First five minutes

Three commands, in this order. They answer *what does the cluster think it is*,
*what is this node*, and *can it accept a write* — which between them narrow
almost every incident to one procedure.

```sh
sudo -u postgres patronictl -c /etc/patroni/patroni.yml list

sudo -u postgres /usr/pgsql-18/bin/psql -Atc "select pg_is_in_recovery()"

sudo -u postgres /usr/pgsql-18/bin/psql -Atc "show synchronous_standby_names"
```

A healthy cluster looks exactly like this — one `Leader`, two `Quorum Standby`
in state `streaming`, all on the same timeline, and **no footer line**:

```text
+ Cluster: <cluster> (7683957778360611717) --+-----------+----+
| Member | Host          | Role           | State     | TL |
+--------+---------------+----------------+-----------+----+
| pg1    | 192.168.105.6 | Leader         | running   | 11 |
| pg2    | 192.168.105.7 | Quorum Standby | streaming | 11 |
| pg3    | 192.168.105.8 | Quorum Standby | streaming | 11 |
+--------+---------------+----------------+-----------+----+
```

Read the answers off this table:

| What you see | What it means | Go to |
| --- | --- | --- |
| A footer reading `Maintenance mode: on` | Automatic failover is **off** | [3](#3-patroni-is-paused-and-nobody-remembers) |
| No `Leader` row at all | Nothing was promoted, or the DCS is unreachable | [2](#2-failover-did-not-happen) |
| The command hangs, or the table is empty or stale | Patroni cannot read etcd | [4](#4-etcd-has-lost-quorum) |
| A member missing, or stuck in `start failed` / `stopped` | That node will not rejoin | [5](#5-a-node-will-not-rejoin-the-cluster) |
| `synchronous_standby_names` is `ANY 1 (*)` | Writes are blocked, by design | [1](#1-writes-are-blocked-on-synchronous-replication) |
| Everything above is healthy but the data is wrong | Not a cluster fault | [9](#9-undo-a-change-that-was-committed-and-later-found-to-be-wrong) |

`(*)` is Patroni's unsatisfiable placeholder. On a healthy cluster this setting
names its members — `ANY 1 (pg2,pg3)` — so the difference between the two is the
single most informative character in this document.

## Which recovery do you need?

Every row below gets the data back. They differ by a factor of hundreds in what
that costs, and **the expensive mistake is reaching too far down this table.**
Recovering one dropped table by rewinding the cluster discards every transaction
committed since — including all the unrelated work done while you were working
out what went wrong.

Start at the top and stop at the first rung that fits. The numbers are referred
to elsewhere, so they are worth having.

| Rung | What happened | Reach for | You lose | Downtime |
| --- | --- | --- | --- | --- |
| **0** | It is not committed yet | `ROLLBACK` | nothing | none |
| **1** | One node is gone | Nothing — Patroni already promoted. Rebuild the node when convenient | nothing | none |
| **2** | You can reverse it in SQL from what you know | A forward fix | nothing | none |
| **3** | You know **which rows**, not what they held before | **Restore a copy beside production**, read the old values out of it, fix forward | **nothing** | **none** |
| **4** | One table is mangled, the rest is fine | Restore that table from a logical dump | later writes to that table | that table |
| **5** | The damage is too pervasive to reconstruct | Rewind the cluster to a marker | **everything committed since** | total |
| **6** | Every node is gone | Rebuild from the repository onto new machines | up to `archive_timeout` | hours |

This ladder is about getting **data** back. Losing *two* nodes is a different
problem — the data is fine and the cluster is read-only until one returns — and
it is [runbook 4](#4-etcd-has-lost-quorum), not a rung here.

**Rung 3 is the one people skip**, and it is usually the right answer: a
restore does **not** have to be done *over* production. Restoring a copy
alongside it costs an outage of nothing and loses nothing, and it is the only
row that recovers unknown values without discarding anything.

Rungs 5 and 6 are the only ones that cost committed data. Do not reach for
them because they are the procedures you happen to know.

> Every row above needs the repository. If the repository is gone as well, none
> of this is available — that is the one failure this design does not recover
> from, and the reason a second repository belongs in any production build.

---

# 1. Writes are blocked on synchronous replication

**Status: VERIFIED** — `make test_runbook` reproduces exactly this state and
recovers from it, in both labs.

> **What tells you:** `WritesBlockedOnSyncReplication`, in about 130s. It fires when `synchronous_standby_names` is Patroni's unsatisfiable placeholder `ANY 1 (*)`, which cannot occur on a healthy cluster. [Lab 5](lab5/README.md) induced this fault and watched that alert fire, with the other candidates required to stay quiet.

## Symptom

Commits hang. They do not fail — clients with a command timeout report a
timeout, clients without one simply stop and their connection pools fill.

## Confirm it is this

```sh
sudo -u postgres /usr/pgsql-18/bin/psql -Atc "show synchronous_standby_names"
# ANY 1 (*)   <- unsatisfiable placeholder

sudo -u postgres /usr/pgsql-18/bin/psql -c \
  "select pid, wait_event, state, query from pg_stat_activity where wait_event = 'SyncRep'"
```

`ANY 1 (*)` **cannot occur on a healthy cluster.** If you see it with backends in
`SyncRep`, this is the state and nothing else.

## Why it is happening

This is [the durability trade working as designed](SLA.md#the-exception-being-closed),
not a fault. No standby can confirm a flush, and `synchronous_mode_strict` forbids
the primary from silently accepting writes only one node holds.

## Fix — bring a standby back

```sh
sudo -u postgres patronictl -c /etc/patroni/patroni.yml list   # which are down?
sudo systemctl status percona-patroni                          # on each standby
sudo systemctl start percona-patroni                           # on one that is down
```

**One standby is enough.** `synchronous_node_count` is 1. Writes resume the
moment a single standby is streaming again — you do not need both.

Confirm:

```sh
sudo -u postgres /usr/pgsql-18/bin/psql -Atc \
  "select application_name, sync_state from pg_stat_replication"   # expect quorum
sudo -u postgres /usr/pgsql-18/bin/psql -Atc "show synchronous_standby_names"
# ANY 1 (pg2,pg3)  <- named members, not (*)
```

## If no standby can be brought back quickly

You are choosing between an outage and a durability gap. **Do not make this
choice silently.**

```sh
sudo -u postgres patronictl -c /etc/patroni/patroni.yml edit-config --force \
  -s synchronous_mode_strict=false
```

Writes resume immediately, held on **one disk only**, with no second copy. Record
that you did it, and set it back the moment a standby returns:

```sh
sudo -u postgres patronictl -c /etc/patroni/patroni.yml edit-config --force \
  -s synchronous_mode_strict=true
```

> Toggle it while the cluster is **healthy** where you can. Changing it while
> already blocked does not reliably reconcile — Patroni leaves
> `synchronous_standby_names` as it was. Observed while building the Lab 1 test.

## Do not

- **Do not restart the primary.** It is working correctly. You lose the leader and
  gain nothing.
- **Do not `setenforce`, reboot, or fail over.** None of them are related.

---

# 2. Failover did not happen

**Status: VERIFIED** — `make test_runbook` removes the `softdog` module from
both standbys and then kills the primary, which is the one case the failover
tests cannot cover: they run on nodes whose watchdog works. Measured — **no
leader for 90 seconds**, with etcd healthy and the cluster unpaused, and
promotion happening by itself the moment the module came back.

> **What tells you:** `NoLeaderAnywhere`, in about 190s. It fires when no node has reported itself primary for 90s. If `ClusterPaused` and `EtcdQuorumLost` are NOT also firing, this is the watchdog cause. [Lab 5](lab5/README.md) induced this fault and watched that alert fire, with the other candidates required to stay quiet.

## Symptom

The primary is gone and nothing was promoted. Clients cannot write, and
`patronictl list` shows no `Leader`.

## Confirm and find the cause

```sh
sudo -u postgres patronictl -c /etc/patroni/patroni.yml list
sudo -u postgres /usr/pgsql-18/bin/psql -Atc "select pg_is_in_recovery()"   # on a survivor
```

Work down this list. Each has been a real cause here:

| Check | Cause it points to |
| --- | --- |
| Does `patronictl list` show `Maintenance mode: on`? | Automatic failover is switched off — [3](#3-patroni-is-paused-and-nobody-remembers) |
| `etcdctl endpoint health` on each member | No DCS quorum, so no promotion is possible — [4](#4-etcd-has-lost-quorum) |
| `journalctl -u percona-patroni` for `watchdog` | `watchdog.mode` is `required`, so a node that cannot arm its watchdog **refuses to be primary at all** |
| Are any standbys eligible? | Quorum commit only promotes a node known to be caught up. A badly lagging standby is deliberately not a candidate |
| `getenforce`, and the node-rejoin checks | [5](#5-a-node-will-not-rejoin-the-cluster) |

## The one that surprises people

`watchdog: mode: required` is not a preference. If Patroni cannot open the
watchdog device it will decline to hold the leader key, because it would have no
way to fence itself later. A missing `softdog` module therefore presents as *no
leader anywhere*, not as a warning.

```sh
lsmod | grep softdog || sudo modprobe softdog
ls -l /dev/watchdog
```

The line to grep for on a survivor is **`Watchdog device is not usable`**:

```sh
sudo journalctl -u percona-patroni | grep -i watchdog
```

Two things the drill confirmed, both of which save time here:

- **`modprobe` is the whole fix.** The udev rule reapplies `postgres` ownership
  when the device reappears, so no `chown` is needed — the device returns as
  `postgres 600` and Patroni promotes within a cycle, unaided.
- **etcd is healthy and the cluster is not paused.** This incident looks
  identical to [3](#3-patroni-is-paused-and-nobody-remembers) and
  [4](#4-etcd-has-lost-quorum) from `patronictl list` alone — no `Leader` row —
  which is why the table above checks those two first and this one third.

---

# 3. Patroni is paused and nobody remembers

**Status: VERIFIED** — `make test_runbook` pauses the cluster, runs the check
below, applies the fix, and asserts automatic failover is live again.

> **What tells you:** `ClusterPaused`, in about 190s. It fires when `patroni_is_paused` is 1 somewhere. [Lab 5](lab5/README.md) induced this fault and watched that alert fire, with the other candidates required to stay quiet.

## Why this matters more than it looks

`patronictl pause` disables automatic failover. The cluster then looks
**completely healthy** — one leader, two streaming standbys, every check green —
and has no high availability at all. The next node failure is an outage rather
than a blip.

This is a silent degradation of the same shape as the one
[`synchronous_mode_strict`](SLA.md#the-exception-being-closed) was enabled to
remove. It is also reachable by following instructions correctly:
[runbook 9](#9-undo-a-change-that-was-committed-and-later-found-to-be-wrong)
tells you to pause deliberately, and an interrupted recovery leaves it paused.

## Confirm

```sh
sudo -u postgres patronictl -c /etc/patroni/patroni.yml list
```

The member table is **identical** to a healthy one. The only difference is a
footer line, which is why this is missed:

```text
+--------+---------------+----------------+-----------+----+
 Maintenance mode: on
```

For a scripted check, match that footer rather than reading the table:

```sh
sudo -u postgres patronictl -c /etc/patroni/patroni.yml list \
  | grep -q 'Maintenance mode: on' && echo PAUSED
```

Patroni's REST API reports the same thing as a `"pause": true` field on
`/patroni`, which is easier to parse — but where that API is mutually
authenticated you must present a client certificate to reach it.

## Fix

```sh
sudo -u postgres patronictl -c /etc/patroni/patroni.yml resume
# Success: cluster management is resumed
```

Confirm the footer is gone, and that the REST API no longer reports `pause`.
Nothing else needs restarting: resuming re-enables automatic failover
immediately, and Patroni reconciles any drift on its next loop.

## Do not

- **Do not leave it paused "until the change window ends".** If it must stay
  paused, it needs an owner and an alarm, because nothing else will remind you.
- **Do not pause to stop a flapping cluster.** It suppresses the symptom and
  removes the recovery mechanism at the same time. Find the cause in
  [5](#5-a-node-will-not-rejoin-the-cluster).

---

# 4. etcd has lost quorum

**Status: VERIFIED** — `make test_runbook` stops etcd on **two of three** nodes
and drills this page. Isolating one member is a different incident, which the
cluster survives; losing the majority is this one. Measured: the leader demoted
and refused writes with `cannot execute INSERT in a read-only transaction`, and
Patroni re-acquired the leader key **by itself** once the members were restarted
— no `--force-new-cluster`, exactly as the "Do not" below requires.

> **What tells you:** `EtcdQuorumLost` (140s) and `PatroniLostDcs`, in about 260s. It fires when fewer than two etcd members are reachable, or one node has not reached the DCS for over a minute. [Lab 5](lab5/README.md) induced this fault and watched that alert fire, with the other candidates required to stay quiet.

## Symptom

Patroni cannot write to the DCS. The leader demotes itself and the cluster is
read-only. `patronictl list` may be empty or stale.

## Confirm

```sh
sudo etcdctl endpoint health --cluster
sudo systemctl is-active etcd     # on each node
```

With three members, **two must be running**. One survivor cannot form a majority
and will not serve writes, by design.

## Fix — restore membership, do not force it

```sh
sudo systemctl start etcd         # on each member that is down
sudo etcdctl endpoint health --cluster
```

Patroni recovers on its own once quorum returns; it re-acquires the leader key
within `ttl`.

## Do not

- **Do not reach for `--force-new-cluster`.** It rewrites membership around a
  single node and silently discards the others' state. It is for a genuinely
  unrecoverable majority, not for a member that is merely down, and using it
  early turns a recoverable outage into a rebuild.
- **Do not wipe an etcd data directory to "clean it up".** On a live cluster that
  is the destructive branch `start-etcd.yml` deliberately refuses to take.

---

# 5. A node will not rejoin the cluster

**Status: VERIFIED** — `make test_runbook` corrupts a standby's control file,
runs the diagnosis below, and applies the fix. Drilling it corrected the page:
`reinit` alone was listed as the remedy, and for this whole class of fault it
cannot work, because Patroni is not running to receive it.

> **What tells you:** `PatroniNotScrapable`, in about 150s. It fires when Patroni itself has stopped answering. The agent on that node keeps running, so the node looks alive. [Lab 5](lab5/README.md) induced this fault and watched that alert fire, with the other candidates required to stay quiet.

```sh
sudo -u postgres patronictl -c /etc/patroni/patroni.yml list
sudo systemctl status percona-patroni
sudo journalctl -u percona-patroni -n 50 --no-pager
```

Check in this order — each has been a real cause here:

| Check | Why |
| --- | --- |
| `getenforce` | Permissive-vs-Enforcing drift was real in both labs |
| Data directory mounted? `findmnt /var/lib/pgsql` (Lab 2) | Where the data directory is a separate encrypted volume, a service started without it initialises an empty cluster over the mountpoint. Not applicable where it is on the root filesystem |
| `systemctl is-active etcd` and endpoint health | No DCS, no membership |
| Certificate expiry and SANs (Lab 2) | A rebuilt node gets a new address; a stale IP SAN fails `verify-full` and reads like a cluster fault |
| `journalctl` for `has already been bootstrapped` | etcd first-bootstrap wedge; see `lab2/PLAN.md` |
| Timeline divergence | `check_timeline` is `true`, so a standby that cannot reach the new timeline refuses rather than diverging |

## Fix — and which one depends on whether Patroni is alive there

Ask this first, **on the broken node**. It selects the procedure:

```sh
sudo systemctl is-active percona-patroni
```

**Patroni is running.** Rebuild through it:

```sh
sudo -u postgres patronictl -c /etc/patroni/patroni.yml reinit <cluster> <member>
```

**Patroni is not running, or is crash-looping.** `reinit` is **unavailable**, and
this is not obvious from the page: it works by calling that member's REST API, so
a node whose Patroni has exited cannot receive the command. Measured —

```text
patronictl reinit ... -> HTTPSConnectionPool(host='…', port=8008):
                         Connection refused
```

Faults that take the data directory out also take Patroni out, because it reads
`pg_control` at startup and exits when the cluster identity is wrong:

```text
CRITICAL: system ID mismatch, node pg2 belongs to a different cluster
percona-patroni.service: Main process exited, code=exited, status=1/FAILURE
```

So clear the directory by hand and let Patroni rebuild it on start:

```sh
sudo systemctl stop percona-patroni
sudo rm -rf /var/lib/pgsql/data
sudo install -d -o postgres -g postgres -m 0700 /var/lib/pgsql/data
sudo systemctl start percona-patroni
```

Both routes discard that node's data directory — safe for a standby, **never**
for the node holding data you have not got elsewhere. Neither touches the
leader, and with one healthy standby left the cluster keeps accepting writes
throughout.

---

# 6. Disk filling, or WAL accumulating

**Status: VERIFIED** — `make test_runbook` induces it the way it actually
happens: the repository is made unreachable, so `archive_command` fails. Measured
on the leader — `failed_count` rose, `last_failed_wal` named the stuck segment,
**9 segments piled up awaiting archive**, and once the repository returned the
backlog **drained to zero with no further intervention**. Both traps below were
confirmed in the same run: the standby reported `failed_count=0` throughout, and
`pgbackrest check` on that standby failed `[027]`.

> **What tells you:** `ArchivingFailing` (192s) and `RepositoryDoesNotVerify`, in about 204s. It fires when archive failures are increasing, or the repository no longer verifies. [Lab 5](lab5/README.md) induced this fault and watched that alert fire, with the other candidates required to stay quiet.

> Watch the **archive backlog**, not the file count in `pg_wal`. PostgreSQL
> preallocates and recycles a pool of segments sized by `min_wal_size`, so that
> count stays flat while archiving is demonstrably broken — measured at 32 before
> and after. What accumulates is `pg_wal/archive_status/*.ready`.

## Why these are the same incident

If `archive_command` fails, PostgreSQL **cannot recycle WAL**, because a segment
that was never archived cannot be removed. `pg_wal` then grows without bound
until the filesystem fills and PostgreSQL stops. It begins as a backup problem
and ends as an outage, which is why
[Lab 5](lab5/README.md) treats archive failure as an alert rather than a report.

## Confirm

**Run both of these on the leader.** Archiving is the primary's job, so a standby
answers the wrong question — see below.

```sh
df -h /var/lib/pgsql
sudo -u postgres /usr/pgsql-18/bin/psql -Atc \
  "select archived_count, failed_count, last_failed_time, last_failed_wal from pg_stat_archiver"
```

A rising `failed_count` with a recent `last_failed_time` is the cause, not a
symptom of the disk being full.

> On a standby these counters **do not move**, because with `archive_mode = on`
> only the primary archives. A standby therefore looks healthy during exactly
> this incident.
>
> They are **cumulative and survive a role change**, so a node demoted recently
> still carries the failures it recorded while it was primary — drilling this
> found a standby reading `failed_count=4` from an earlier switchover. Judge by
> whether the count is *rising* and whether `last_failed_time` is recent, never
> by it being zero.

## Fix — repair archiving first

**On the leader**, because `check` inspects the primary:

```sh
sudo -u postgres pgbackrest --stanza=<cluster> check
```

Run on a standby it fails with `[027]: primary database not found`, which reads
like a broken repository and is not one — each node's configuration knows only
its own data directory.

Fix what that reports, then let PostgreSQL recycle normally. Space is reclaimed
once the backlog archives successfully.

## Checking the repository: exit codes are not the answer

**Status: VERIFIED** — measured in [Lab 4](lab4/README.md) by corrupting a real
repository object.

Two pgBackRest commands report success on a repository that is not healthy, so
neither can be used as a pass/fail gate in a script or a cron job:

| Command | On a damaged repository |
| --- | --- |
| `info` | **Exits 0.** It lists what is there; it does not read it. It exits 0 even on a repository it cannot decrypt at all |
| `verify` | **Exits 0.** It finds the damage, prints it, and still returns success |

With one archived WAL segment overwritten in place, `verify` reported:

```
INFO: invalid result 18-1/...0000006A-....gz: unexpected eof in compressed data
INFO: stanza: lab4
      status: error
        archiveId: 18-1, total WAL checked: 6, total valid WAL: 5
INFO: verify command end: completed successfully (15256ms)
```

…and exited **0**. The verdict is in the output, not the status. Check for
`status: error` and `invalid result`:

```sh
out="$(sudo -u postgres pgbackrest --stanza=<cluster> verify 2>&1)"
grep -qiE 'status: *error|invalid result|invalid file' <<< "$out" && echo DAMAGED
```

A clean run prints no counts at any log level, so absence of those markers is the
only positive signal available.

## A wrong cipher passphrase looks like an empty repository

**Status: VERIFIED.** This is the trap most likely to destroy backups during an
incident. Restoring with the wrong `repo1-cipher-pass` reports:

```
WARN: unable to load info file '.../backup.info' or '.../backup.info.copy':
      FormatError: key/value found outside of section at line 1: b6)E...
      HINT: has a stanza-create been performed?
ERROR: [075]: no backup set found to restore
```

The headline error says there are **no backups**, and the hint suggests running
`stanza-create`. Both are wrong, and acting on the hint against a repository that
is merely locked is how a working set of backups gets destroyed.

- The evidence is the `WARN`, not the `ERROR`. At `--log-level-console=error` you
  see only the misleading half.
- Before you conclude a repository is empty, **check the passphrase you supplied**.
- `repo1-cipher-pass` is refused on the command line. Supply it in the config or
  as `PGBACKREST_REPO1_CIPHER_PASS`.

## Do not

- **Never delete files from `pg_wal` by hand.** Removing an unarchived segment
  destroys the ability to recover to any point after it, and removing one still
  needed for recovery corrupts the cluster. If space is critical, move the
  archive destination, not the WAL.
- **Never run `stanza-create` to "fix" a repository that reports no backups**
  until you have ruled out a wrong passphrase — see above.

---

# 7. Certificates have expired

**Status: REASONED. TLS clusters only** — Lab 1 runs without TLS and cannot
reach this state; Labs 2 and 3 can.

## Symptom

Everything fails at once and it looks like a network fault: replication stops,
`patronictl` cannot reach the REST API, etcd peers cannot talk, the client fails
`VerifyFull`.

## Confirm

```sh
for cert in postgres etcd patroni dcs-client; do
  sudo openssl x509 -enddate -noout -in "<pki-dir>/$cert.crt"
done
```

## Fix

Reissue every affected certificate from your CA and redistribute it to the
nodes, then restart the services that hold it open. In these labs that is one
command each, because certificate issuance and distribution are automated:

```sh
./scripts/generate-pki.sh     # reissues whenever a .spec changes
make configure_cluster        # ships the result and restarts the services
```

Expiry is a **dated, predictable** failure. It is the one incident in this file
that can be prevented entirely by watching a number, which is why certificate
expiry belongs in [Lab 5](lab5/README.md)'s alerting alongside backup age.

---

# 8. Planned switchover

**Status: VERIFIED** — `make test_runbook` performs one and asserts the leader
moved to the intended node and the cluster settled afterwards.

This is a *planned operation*, not an incident, and it is the one you will
perform most — every rolling restart, kernel update and node maintenance needs
it.

## Before

```sh
sudo -u postgres patronictl -c /etc/patroni/patroni.yml list
```

Require **one leader and two streaming standbys** before starting. A switchover
from a degraded cluster is how planned maintenance becomes an incident.

## Do it

```sh
sudo -u postgres patronictl -c /etc/patroni/patroni.yml switchover \
  --leader <current> --candidate <target> --force
```

A switchover is a *controlled* handover: the old primary is shut down cleanly
first, so unlike an election there is no `ttl` to wait out. Expect it to complete
in seconds, and expect existing connections to the old primary to be dropped —
clients reconnect to the new one through their own retry path.

## After

Wait for the old primary to come back as a standby **before** touching anything
else:

```sh
sudo -u postgres /usr/pgsql-18/bin/psql -Atc \
  "select application_name, sync_state, state from pg_stat_replication"
```

## The constraint strict mode adds

**Never take both standbys out at once.** With `synchronous_node_count: 1`, one
standby may be lost freely; the second stops writes, exactly as in
[runbook 1](#1-writes-are-blocked-on-synchronous-replication). Rolling
maintenance therefore proceeds **one node at a time**, waiting for each to return
to `streaming` before touching the next.

This procedure is one step of a patch cycle rather than the whole of it. The full
rolling sequence — standbys first, switchover, then the old primary, and what
each wrong order costs — is designed in [Lab 6](lab6/README.md) and is not yet
rehearsed, which is why there is no runbook for it here.

---

# 9. Undo a change that was committed and later found to be wrong

**Status: VERIFIED for the restore mechanics, REASONED for the decision.**
[Lab 4](lab4/README.md) exercises all three routes below end to end against a
live cluster — restoring beside it, restoring one table from a dump, and the
in-place rewind — and each trap called out here is one that run hit. Choosing
*between* them, and judging whether a schema change was lossy, follows from
PostgreSQL semantics and is not itself drilled; [Lab 8](lab8/README.md) is where
undoing a migration becomes a rehearsed procedure.

## Before anything else

**Stop it getting worse.** If the application is still writing on top of the bad
state, reconstruction gets harder every minute.

**Mark where you are now**, so the repair attempt is itself recoverable:

```sh
sudo -u postgres /usr/pgsql-18/bin/psql -Atc \
  "select pg_create_restore_point('before_attempting_repair')"
sudo -u postgres /usr/pgsql-18/bin/psql -Atc "select pg_switch_wal()"
```

The WAL switch is not optional. A restore point lives inside the *current*
segment and is not in the repository until that segment is archived.

## Decide: can you reconstruct the old values?

Not "do you remember what you did" — can you identify the exact rows *and* what
they held before? Usually not: dead tuples are unreliable after vacuum, and WAL is
not queryable.

These are rungs 2, 3 and 5 of
[the ladder](#which-recovery-do-you-need), narrowed to the case where the change
was yours:

| Rung | Situation | Do this |
| --- | --- | --- |
| 2 | You can reverse it in SQL from what you know | Forward-fix. Nothing lost |
| 3 | You know which rows, not their old values | **Restore beside, read the old values, fix forward** |
| 5 | Damage too pervasive to reconstruct, and losing everything since is acceptable | Rewind production. Last resort |

If one table is mangled and the rest is fine, you are on **rung 4** instead —
restore that table from a logical dump, which costs nothing outside it.

## The usual answer: restore beside, not over

Restore a copy to a **separate path or host**, targeting just before the change:

```sh
# The stanza is the cluster name. Restore somewhere with room that is NOT the
# live data directory -- where it is a dedicated volume holding production,
# do not restore beneath it.
sudo -u postgres pgbackrest --stanza=<cluster> --type=name --target=<marker> \
     --pg1-path=/var/lib/pgsql-restore restore
```

Then start the copy — **with archiving off** — and read the old values out of it.

```sh
sudo -u postgres /usr/pgsql-18/bin/pg_ctl -D /var/lib/pgsql-restore -w \
  -o "-p 5433 -c archive_mode=off -c listen_addresses=localhost" start
```

> **`archive_mode=off` is not optional.** The copy inherits `archive_command`
> from the backup it came from. Started with archiving on, it pushes WAL from a
> *divergent timeline* into the same repository — corrupting the thing you are
> recovering from, silently, while both the copy and production appear fine.
> Measured, not theorised.

Connect to it over the **Unix socket**, not TCP. The copy also inherits
`pg_hba.conf`, so a TCP connection demands TLS and a password: adding
`-h 127.0.0.1` makes it prompt, and inside a script that prompt will silently
eat the rest of your input.

```sh
sudo -u postgres /usr/pgsql-18/bin/psql -p 5433 -d appdb   # socket, peer auth
```

Read the old values out, `UPDATE` production back, then stop the copy and remove
its data directory — it is a complete copy of production and should not outlive
the repair.

**Nothing committed after the change is lost** — every unrelated transaction that
happened while you were diagnosing survives. That is the whole point, and it is
why this is preferred over rewinding.

## Schema changes: the question is whether it was lossy

| Change | Forward-fixable? |
| --- | --- |
| `ADD COLUMN`, `CREATE INDEX` | Yes — drop it |
| `ALTER TYPE` widening | Yes |
| `ALTER TYPE` narrowing | **No** — truncated at commit |
| `DROP COLUMN`, `DROP TABLE` | **No** — only a backup holds it |

## Last resort: rewinding production

Only when the damage cannot be reconstructed and the loss is acceptable.

```sh
sudo -u postgres patronictl -c /etc/patroni/patroni.yml pause    # FIRST

# On EVERY node. Two separate acts — see the first trap below.
sudo systemctl stop percona-patroni
sudo -u postgres /usr/pgsql-18/bin/pg_ctl -D /var/lib/pgsql/data -w stop -m fast
ps -eo args | grep '[p]ostgres'          # must print NOTHING before you go on

# On the node being rewound, and only that node.
sudo -u postgres pgbackrest --stanza=<stanza> --delta \
  --type=name --target='<marker>' --target-action=promote restore

# Finish recovery under pg_ctl and watch it promote. Then LEAVE IT RUNNING.
sudo -u postgres /usr/pgsql-18/bin/pg_ctl -D /var/lib/pgsql/data -w -t 300 start
sudo -u postgres /usr/pgsql-18/bin/psql -Atc "select pg_is_in_recovery()"  # wait for 'f'

# Hand the RUNNING primary back. Patroni adopts it and takes the leader lock.
sudo systemctl start percona-patroni
sudo -u postgres patronictl -c /etc/patroni/patroni.yml list     # must show Leader

# Only now the standbys — on each one:
sudo rm -rf /var/lib/pgsql/data && sudo systemctl start percona-patroni

sudo -u postgres patronictl -c /etc/patroni/patroni.yml resume
sudo -u postgres pgbackrest --stanza=<stanza> --type=full backup # not optional
```

- **Pause first**, or Patroni tries to repair the node you are deliberately
  rewinding. If the recovery is interrupted after this point, the cluster is left
  paused — see [3](#3-patroni-is-paused-and-nobody-remembers).
- **Stopping Patroni is not stopping PostgreSQL.** The postmaster outlives its
  unit — systemd says so, `Unit process 2327 (postgres) remains running after
  unit stopped` — and pgBackRest then refuses: `ERROR: [038]: unable to restore
  while PostgreSQL is running`. The orphan also blocks the next start with
  `FATAL: pre-existing shared memory block ... is still in use`. Check `ps`.
- **Do not stop PostgreSQL before handing the node back.** A paused Patroni does
  not start PostgreSQL — it logs `PAUSE: postgres is not running` and waits. The
  node then stays down until the resume, at which point Patroni races for the
  free leader lock, loses it on a WAL position the DCS recorded *before* the
  rewind (`My wal position exceeds maximum replication lag`), and brings the node
  back as a **replica**. The rewind is correct on disk and the cluster has no
  primary. Start Patroni onto the running, promoted primary instead.
- **Either leader-key state is fine, and which one you get is a race.** Nothing
  refreshes the key while the cluster is stopped, so a restore faster than the
  30s `ttl` leaves it held and a slower one lets it expire. Both are verified
  with a rewound node, and they are not the same path:

  | Leader key when Patroni starts | What happens |
  | --- | --- |
  | Still held by this node | It reclaims its own key and continues as leader. No election, so the rewound WAL position is never compared against anything |
  | Expired | It races for a free lock. **With PostgreSQL running it adopts the primary and wins**; with PostgreSQL down it loses on the stale WAL position and demotes — the trap above |

  So the rule that matters is the previous bullet, not the timing. Leave
  PostgreSQL running and both branches end with the rewound node as leader.
- **Take a full backup afterwards.** Every backup in the repository now predates
  the rewind and sits on an abandoned timeline. Until you take one, the only
  route back to the present is an old backup replayed across a timeline switch.
- **Both standbys must be rebuilt.** They hold the same wrong state; they are not
  a recovery source.
- **Every transaction after the target is discarded.** Count them and record the
  number — that is the cost of the decision, and it should not be discovered later.
- A restored primary with no standby attached **will block writes** under strict
  mode. See [1](#1-writes-are-blocked-on-synchronous-replication). That is
  expected, not a failed restore.

## What makes this impossible

Retention. If the change predates your oldest base backup plus retained WAL,
nothing above is available. Labs 1 and 2 keep repositories **locally on each
node**, which suffices there because the node is intact, but does not survive
losing it. An off-host repository arrives in [Lab 3](lab3/README.md).

---

# 10. Total loss — every node gone

**Status: VERIFIED** — [Lab 4](lab4/README.md) destroys all three nodes, their
encrypted volumes and every local secret, then rebuilds from the repository
alone. Measured: **2s restore, 0s replay, 450s from destruction to a redundant
three-node cluster, 0 rows lost.** Those seconds are not representative; the
database is small. The *shape* is.

## What has to survive

Shorter than you would expect, and deliberately so:

| Must survive | Why |
| --- | --- |
| The repository | There is nothing else to restore from |
| `repo1-cipher-pass` | Every backup is unreadable without it — permanently |
| The object store's access credentials | An intact repository nothing can authenticate to is the same as no repository |
| The stanza name | You have the data and cannot address it |
| This procedure | Everything above exists and nobody knows the order |

**The CA key, the superuser password and the replication password do NOT need to
survive.** The rebuilt cluster issues a new CA and generates new credentials, and
step 5 resets the restored roles to match. That is the whole reason to prefer
this route: what a customer must protect through a disaster is a bucket and a
passphrase, not a collection of secrets that die with the machines.

## Do it

```sh
# 1. Fresh machines, and NO database. See the first trap below.
#    Bring up the object store and confirm the nodes can reach it BEFORE restoring.
sudo -u postgres pgbackrest --stanza=<cluster> info      # must list your backups

# 2. Restore onto ONE node.
sudo -u postgres pgbackrest --stanza=<cluster> restore

# 3. Finish recovery under pg_ctl and watch it promote. LEAVE IT RUNNING.
sudo -u postgres /usr/pgsql-18/bin/pg_ctl -D /var/lib/pgsql/data -w -t 600 start
sudo -u postgres /usr/pgsql-18/bin/psql -Atc "select pg_is_in_recovery()"   # wait for 'f'

# 4. Confirm it is the database you lost, not a new one.
sudo -u postgres /usr/pgsql-18/bin/pg_controldata /var/lib/pgsql/data | grep 'system identifier'

# 5. Reset the restored roles. Sync commit must be suspended first — see below.
sudo -u postgres /usr/pgsql-18/bin/psql --no-psqlrc -Atc \
  "alter system set synchronous_standby_names = ''"
sudo -u postgres /usr/pgsql-18/bin/psql --no-psqlrc -Atc "select pg_reload_conf()"
sudo -u postgres /usr/pgsql-18/bin/psql --no-psqlrc -Atc \
  "alter role postgres with password '<new>'"
sudo -u postgres /usr/pgsql-18/bin/psql --no-psqlrc -Atc \
  "alter role replicator with password '<new>'"
sudo -u postgres /usr/pgsql-18/bin/psql --no-psqlrc -Atc \
  "alter system reset synchronous_standby_names"
sudo -u postgres /usr/pgsql-18/bin/psql --no-psqlrc -Atc "select pg_reload_conf()"

# 6. Hand the RUNNING primary to Patroni; it adopts it and takes the leader lock.
sudo systemctl enable --now percona-patroni

# 7. Then the standbys — each builds itself from the repository.
sudo systemctl enable --now percona-patroni     # on each remaining node

# 8. Restart scheduled backups and take a fresh full backup.
sudo -u postgres pgbackrest --stanza=<cluster> --type=full backup
```

## The traps, all of them measured

- **Do not let anything bootstrap a database on the fresh machines.** Patroni's
  default is `initdb`, and a new cluster carries a new system identifier — which
  a pgBackRest stanza, bound to one database by that identifier, will not
  recognise. The surviving backups become unreadable by the very cluster meant to
  restore them. Prepare the machines with Patroni **stopped**, and check
  `/var/lib/pgsql/data` is empty on every node before step 2.
- **The object store must be reachable before you restore.** If its TLS
  certificate was reissued with the rebuilt PKI, start it only after the new
  certificates exist. A repository that is merely unreachable reports
  `[075]: no backup set found to restore` — identical to having no backups.
- **The credential reset deadlocks against `synchronous_mode_strict`.**
  `synchronous_standby_names` comes back *from the backup* naming standbys that do
  not exist yet, so every write blocks; `ALTER ROLE` is a write; and no standby
  can attach until that password is reset. Observed as `wait_event = SyncRep`,
  waiting indefinitely. Hence suspending it in step 5 — and `RESET` rather than
  leaving it cleared, because `postgresql.auto.conf` outranks Patroni's own
  management of that setting for the life of the cluster.
- **Leave PostgreSQL running at step 6.** A paused or freshly-started Patroni
  handed a *stopped* data directory has to decide what the node is; handed a
  running primary it adopts it. See [9](#9-undo-a-change-that-was-committed-and-later-found-to-be-wrong).
- **Take the backup in step 8.** Until you do, every backup in the repository
  predates the disaster and the cluster has no recovery point of its own.

---

# If none of these match

Capture this before restarting anything. A restart destroys most of the evidence,
and the state you are in is often reproducible only once:

```sh
sudo -u postgres patronictl -c /etc/patroni/patroni.yml list
sudo journalctl -u percona-patroni -n 200 --no-pager
sudo -u postgres /usr/pgsql-18/bin/psql -c \
  "select pid, state, wait_event_type, wait_event, query_start, left(query, 120) as query
     from pg_stat_activity where state <> 'idle' order by query_start"
sudo -u postgres /usr/pgsql-18/bin/psql -c "select * from pg_stat_replication"
sudo etcdctl endpoint health --cluster
```

Then work from the general rules this cluster is built on:

- **A hang is usually durability, not a fault.** Writes stop when the cluster
  cannot make them durable. That is [1](#1-writes-are-blocked-on-synchronous-replication).
- **A healthy-looking cluster with no failover is usually pause.** That is
  [3](#3-patroni-is-paused-and-nobody-remembers).
- **Anything affecting all three nodes at once is beneath the database** —
  network, certificates, time, or storage. Nothing in Patroni fails on three
  nodes simultaneously by itself.
- **Never repair a standby by rewinding the primary.** The primary holds the
  data; the standby is rebuildable.
