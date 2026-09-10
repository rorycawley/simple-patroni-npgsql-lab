# Runbooks

Procedures to follow *during* an incident. Terse on purpose — the reasoning
behind them is in [`WHY_PGBACKREST_AND_PGDUMP.md`](WHY_PGBACKREST_AND_PGDUMP.md)
and [`SLA.md`](SLA.md), and neither belongs in your way at 03:00.

## Verification status

Every procedure carries one of these. A runbook that mixes verified and
unverified steps without saying which is worse than no runbook, because it will
be followed literally.

| Marker | Means |
| --- | --- |
| **VERIFIED** | The steps are exercised by a lab check that passes |
| **REASONED** | Follows from PostgreSQL and Patroni semantics, never executed here |
| **STUB** | Named so it is not forgotten; do not follow it yet |

---

# 1. Writes are blocked on synchronous replication

**Status: VERIFIED** — `make test_sync` reproduces exactly this state and
recovers from it, in both labs.

## Symptom

Commits hang. They do not fail — clients with a command timeout report a
timeout, clients without one simply stop and their connection pools fill.

## Confirm it is this

`patroni.yml` is `0600 postgres` and `psql` is not on `PATH` — every command here
runs as the `postgres` user with the full binary path, as the lab scripts do.

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
> `synchronous_standby_names` as it was. Verified while building the Lab 1 test.

## Do not

- **Do not restart the primary.** It is working correctly. You lose the leader and
  gain nothing.
- **Do not `setenforce`, reboot, or fail over.** None of them are related.

---

# 2. Undo a change that was committed and later found to be wrong

**Status: REASONED** — the decision structure follows from PostgreSQL semantics.
The restore commands are not yet exercised by a lab; [Lab 6](lab6/README.md)
is where they become VERIFIED.

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

| Situation | Do this |
| --- | --- |
| You can reverse it in SQL from what you know | Forward-fix. Nothing lost |
| You know which rows, not their old values | **Restore beside, read the old values, fix forward** |
| Damage too pervasive to reconstruct, and losing everything since is acceptable | Rewind production. Last resort |

## The usual answer: restore beside, not over

Restore a copy to a **separate path or host**, targeting just before the change:

```sh
# The stanza is the cluster name -- `lab1` or `lab2` here.
# Restore somewhere with room that is NOT the live data directory. In Lab 2
# /var/lib/pgsql is the LUKS volume holding production, so do not restore beneath it.
sudo -u postgres pgbackrest --stanza=<cluster> --type=name --target=<marker> \
     --pg1-path=/var/lib/pgsql-restore restore
```

Then read the old values out of the restored copy and `UPDATE` production back.

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
sudo -u postgres patronictl -c /etc/patroni/patroni.yml pause   # FIRST
# ... restore to the marker ...
sudo -u postgres patronictl -c /etc/patroni/patroni.yml resume
```

- **Pause first**, or Patroni tries to repair the node you are deliberately
  rewinding.
- **Both standbys must be rebuilt.** They hold the same wrong state; they are not
  a recovery source.
- **Every transaction after the target is discarded.** Count them and record the
  number — that is the cost of the decision, and it should not be discovered later.
- A restored primary with no standby attached **will block writes** under strict
  mode. See runbook 1. That is expected, not a failed restore.

## What makes this impossible

Retention. If the change predates your oldest base backup plus retained WAL,
nothing above is available. Labs 1 and 2 keep repositories **locally on each
node**, which suffices here because the node is intact, but does not survive
losing it. An off-host repository arrives in [Lab 3](lab3/README.md).

---

# 3. A node will not rejoin the cluster

**Status: REASONED** — assembled from failures seen while building Labs 1 and 2,
but not driven by a single lab check.

```sh
sudo -u postgres patronictl -c /etc/patroni/patroni.yml list
sudo systemctl status percona-patroni etcd
sudo journalctl -u percona-patroni -n 50 --no-pager
```

Check in this order — each has been a real cause here:

| Check | Why |
| --- | --- |
| `getenforce` | Permissive-vs-Enforcing drift was real in both labs |
| **Lab 2 only** — data directory mounted? `findmnt /var/lib/pgsql` | Lab 2 puts it on a LUKS volume, and a service started without it initialises an empty cluster over the mountpoint. **In Lab 1 the root filesystem is correct** — it has no separate volumes |
| `systemctl is-active etcd` and endpoint health | No DCS, no membership |
| Certificate expiry and SANs (Lab 2) | A rebuilt VM gets a new address; a stale IP SAN fails `verify-full` and reads like a cluster fault |
| `journalctl` for `has already been bootstrapped` | etcd first-bootstrap wedge; see `lab2/PLAN.md` |
| Timeline divergence | `check_timeline` is `true`, so a standby that cannot reach the new timeline refuses rather than diverging |

Rebuilding the node from the primary is
`sudo -u postgres patronictl -c /etc/patroni/patroni.yml reinit <cluster> <member>`,
where `<cluster>` is `lab1` or `lab2`.
It discards that node's data directory — safe for a standby, never for the node
holding data you have not got elsewhere.

---

# 4. Total loss — every node gone

**Status: STUB. Do not follow this yet.**

The procedure depends on machinery that is not built: an off-host repository
([Lab 3](lab3/README.md)) and a rehearsed restore ([Lab 4](lab4/README.md)).
Writing confident steps for an untested restore is the exact failure this
repository exists to avoid.

What is already known, from [Lab 4](lab4/README.md)'s recovery inventory, is what
must survive the disaster for any procedure to be possible at all: the
repository, `repo1-cipher-pass`, the CA key, the superuser and replication
passwords, the stanza name — and the procedure itself.
