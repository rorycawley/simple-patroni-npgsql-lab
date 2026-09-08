# Lab 1: the simplest cluster that survives failover

The shared components, cluster design, failover semantics and prerequisites are
in the [top-level README](../README.md). This file covers Lab 1 only.

## Goal

A .NET client using Npgsql connects directly to a three-node Patroni-managed
PostgreSQL cluster, keeps working when the primary is lost, and never loses or
duplicates an acknowledged transaction.

## Scope

| In scope | Out of scope |
| --- | --- |
| A three-node Patroni cluster on default settings, built from nothing | Encryption at rest and in transit — that is [Lab 2](../lab2/README.md) |
| A client with short timeouts, a bounded pool, and retries scoped to connection failures | Retrying arbitrary transactions; a lost acknowledgement is reported, not reissued |
| Failover from two different faults: the node dies, and PostgreSQL alone dies | Load balancing reads across standbys |
| Split-brain prevention, both watchdog fencing and voluntary demotion | Hardware or hypervisor watchdogs; `softdog` is a kernel timer |
| Quorum commit, so an acknowledged commit survives promotion | `synchronous_mode_strict`; writes stay available when no standby remains |
| pgBackRest installed, with a local per-node repository and WAL archiving | A durable backup design. Local repositories prove configuration, not disaster recovery. Backups are Lab 3 |

Lab 1 runs on an unencrypted disk and an unencrypted network. Run it only on an
isolated, trusted lab network.

## The client

The client connects to all three nodes at once and lets Npgsql choose the
primary:

```text
Host=<pg1-ip>,<pg2-ip>,<pg3-ip>;Port=5432;Database=appdb;Username=app_runtime;Passfile=.secrets/pgpass;Target Session Attributes=primary;Timeout=5;Command Timeout=10;Maximum Pool Size=20;SSL Mode=Disable
```

| Setting | Value | Purpose |
| --- | --- | --- |
| `Host` | the three node addresses | Npgsql tries these hosts to find an eligible server. |
| `Port` | `5432` | The PostgreSQL TCP port on every host. |
| `Database` | `appdb` | The database the client connects to. |
| `Username` | `app_runtime` | The non-superuser login used by the application. |
| `Passfile` | `.secrets/pgpass` | Local, uncommitted password file, readable only by the application identity. |
| `Target Session Attributes` | `primary` | Requires the current primary, so the connection can read and write. |
| `Timeout` | `5` | Bounds a connection attempt at five seconds. |
| `Command Timeout` | `10` | Bounds a single command at ten seconds, so a stalled node cannot block the client indefinitely. |
| `Maximum Pool Size` | `20` | Caps this pool at 20 physical connections. |
| `SSL Mode` | `Disable` | Encryption in transit is intentionally out of scope; Lab 2 changes this. |

While no host is an eligible primary, the client retries the connection against a
90-second budget, which covers Patroni's worst case of `ttl` (30s) plus
`loop_wait` (10s) plus promotion time. Retries are scoped to connection failures:
a rejected password or a missing database fails immediately rather than being
reattempted, and a write is never reissued.

The client reads the three addresses from `LAB1_PG_HOSTS`, which
`scripts/test-npgsql.sh` fills from the shared-network IP addresses that
`make create_vms` writes into `lab1/.env`.

## Acceptance criteria

| ID | Property | Command | Pass condition |
| --- | --- | --- | --- |
| AC-1 | The client can connect to the primary and run queries | `make test_connection` | The client opens a read-write session against whichever node is currently primary, commits, and reports the node it used |
| AC-2 | After a failover, the client connects to the new primary for read-write work | `make test_failover` | Started while no host is an eligible primary, the client rides out the election and commits on a *different* node than before |

Each has one command that proves it and fails loudly otherwise.

### AC-1 — the client connects to the primary and runs queries

```sh
make test_connection
```

This runs the real client (`client/Program.cs`) against all three nodes at once.
To exit zero it must:

1. open a connection with `Target Session Attributes=primary`, which makes
   Npgsql pick whichever of the three nodes is currently primary;
2. run `SELECT inet_server_addr(), pg_is_in_recovery()` and assert the answer is
   *not* a replica, so a misrouted read-write connection fails rather than
   silently succeeding against a standby;
3. commit an `INSERT` into `public.ha_probe` and confirm the returned identifier
   matches what it sent; and
4. print the node it used as JSON: `{"ok":true,"server":"…","primary":true,…}`.

`make verify_cluster` runs the same probe after its Ansible checks, so a healthy
cluster always demonstrates AC-1.

### AC-2 — the client follows a promotion to the new primary

```sh
make test_failover              # both scenarios below
make test_failover_vm           # just the VM loss
make test_failover_postgres     # just the PostgreSQL crash
```

A Patroni cluster has to survive two quite different faults, so the lab injects
both:

| Scenario | Fault injected | What Patroni has to do |
| --- | --- | --- |
| `vm` | `limactl stop --force` on the primary VM | Patroni and PostgreSQL die together, so nothing releases the leader key. A replica can only promote once the key's `ttl` (30s) expires. |
| `postgres` | `SIGKILL` the postmaster on the primary, leaving Patroni running | Patroni sees the crash and, because `primary_start_timeout` is `0`, hands the leader key to a healthy replica instead of restarting PostgreSQL locally. It then rejoins the node as a replica with no VM restart. |

Each scenario runs the same sequence:

1. Record the current primary and prove AC-1 against it.
2. Inject the fault.
3. **Start the client immediately, while no host is an eligible primary.** This
   is the point of the test: the client has to ride out the election through its
   own retry loop, rather than connecting to a cluster that has already settled.
4. Assert Patroni elected a *different* leader.
5. Assert the client exited zero, and that the `server` address in its JSON is a
   different node than the baseline — so the write demonstrably landed on the
   newly promoted primary. Report how many retries that took.
6. Restore the old node and assert the cluster returns to one leader and two
   streaming replicas, so the next scenario starts from a known-good state.

Any of those failing exits non-zero with the client's stderr.

## Additional guarantees

The two criteria above say the client survives a failover. They say nothing about
whether its configured limits are real, whether the new primary has the data, or
whether the old primary actually stopped serving. Three further checks cover
those, and each would pass trivially if it only asserted the happy path — so each
asserts a mechanism instead.

### The client's configured guarantees

```sh
make test_client
```

| Probe | Asserts |
| --- | --- |
| `pool` | Exactly `Maximum Pool Size` connections open; the next is refused after about `Timeout`, not instantly and not indefinitely; releasing one lets the next straight through, which distinguishes a pool limit from a saturated server. |
| `command-timeout` | A `pg_sleep` three times longer than `Command Timeout` is cut off at roughly `Command Timeout`. Lab 1 sets no server-side `statement_timeout`, so only the client-side value can end it. |
| `uncertain-write` | A commit that is durable but never acknowledged, and a client that reports failure without reissuing the write. |

The `uncertain-write` probe commits a row and then blocks, and the harness waits
until a third-party session can see that row — proving the commit is durable —
before terminating the client's backend. The client therefore fails on an
operation that actually succeeded, and cannot tell. It must exit non-zero and
leave exactly one row: reporting success would be a lie, and a second row would
mean it had blindly retried a write whose outcome it did not know.

### Replication is synchronous

```sh
make test_sync
```

Failover tests show a new primary appears; they say nothing about whether it has
your data. This asserts quorum commit at three levels, because the first alone
would pass on a cluster that merely claims to be synchronous.

| Tier | Asserts |
| --- | --- |
| `topology` | `synchronous_standby_names` is an `ANY n (...)` quorum expression rather than `FIRST n`, `synchronous_node_count` is 1, `synchronous_commit` is `on`, and both standbys report `sync_state = quorum` |
| `blocking` | Both walreceivers are frozen, and the committing backend is then observed parked in `wait_event = SyncRep`. Cancelling it makes PostgreSQL report `canceling wait for synchronous replication` |
| `durability` | 200 rows are committed, the primary VM is force-stopped with no clean shutdown, and every acknowledged row is present on the promoted node |

The `blocking` tier is the decisive one. `SyncRep` is PostgreSQL's own name for a
backend waiting on a synchronous standby, so that wait state cannot occur on an
asynchronous cluster at all — no timing heuristic is involved.

### Split-brain prevention, and where softdog fits

```sh
make test_fencing               # both scenarios below
make test_fencing_patroni       # softdog resets the node
make test_fencing_etcd          # Patroni demotes itself
make test_faults                # every fault scenario, failover and fencing
```

Failover decides who is *allowed* to be primary. It says nothing about whether
the old primary has actually stopped serving. A node that can no longer renew its
leader key may still be reachable by clients, and if it keeps accepting writes
while a replica is promoted, the two diverge.

Patroni closes that gap two different ways, and the lab exercises both. Which one
applies depends on a single question: **can Patroni still act?**

| Scenario | Fault | Can Patroni act? | Outcome |
| --- | --- | --- | --- |
| `patroni` | `SIGSTOP` the Patroni process; PostgreSQL keeps running | No — the process is frozen | The watchdog is never petted again, so **softdog resets the node** at `ttl - safety_margin` = 25s |
| `etcd` | Block ports 2379/2380 so Patroni loses the DCS | Yes — Patroni is alive, only etcd is gone | Patroni **demotes itself** to a standby within about ten seconds; the watchdog never fires |

Patroni arms `/dev/watchdog` only on the leader, and pets it only when a leader
key renewal succeeds. So the watchdog is not the normal path — it is the backstop
for when Patroni cannot take itself out of service. Measured on this lab:

```
patroni scenario                      etcd scenario
t+0s   PostgreSQL still primary       t+0s   PostgreSQL still primary
t+22s  node unreachable               t+9s   pg_is_in_recovery() -> true
t+32s  back up, new boot id           t+50s  boot id unchanged, no reboot
       => fenced by reset                    => stepped down voluntarily
```

Each scenario asserts the mechanism rather than the end state, by comparing
`/proc/sys/kernel/random/boot_id` before and after: `patroni` requires it to
change, which only a real kernel restart does, while `etcd` requires it to stay
the same, proving the node stepped down rather than being reset.

This is also why `watchdog.mode` is `required` in `patroni.yml`: if Patroni
cannot arm the watchdog it refuses to be primary at all, because it would have no
way to fence itself later. That makes the `/dev/watchdog` ownership check in
`verify_cluster` a prerequisite, not a nicety — without it the cluster never
elects a leader.

Two limits are worth stating. First, `softdog` is a kernel timer emulating a
hardware watchdog: it catches a hung Patroni or a thrashing machine, but not a
kernel panic, because then the timer that would fire the reset is not running
either. Real deployments use a hardware or hypervisor watchdog. Second, in the
`patroni` scenario PostgreSQL keeps answering as a primary for the whole 25
seconds before the reset, so a client that reaches it in that window can still
commit. Fencing bounds how long that window lasts; it does not eliminate it. What
removes the data-loss risk is quorum commit — under it such a commit is not
acknowledged until a standby has flushed it, so a promoted replica already has
it.

## Topology

Three Lima VMs, each running PostgreSQL, Patroni and one etcd member. The default
allocation is 2 CPUs, 4 GiB memory and a 20 GiB disk each — 6 CPUs, 12 GiB and 60
GiB in total.

| VM | Hostname | PostgreSQL address |
| --- | --- | --- |
| `lab1-pg1` | `pg1.lab.example` | `pg1.lab.example:5432` |
| `lab1-pg2` | `pg2.lab.example` | `pg2.lab.example:5432` |
| `lab1-pg3` | `pg3.lab.example` | `pg3.lab.example:5432` |

The VMs use the pinned Rocky Linux 9.8 image in `rocky-9.8.yaml`, have
host-directory mounts disabled, and attach to Lima's managed `lima:shared`
network.

`create_vms` maintains a marked block in `/etc/hosts` for those hostnames when
non-interactive `sudo` is available; otherwise it asks you to run `make
configure_hostnames` from an interactive terminal. It also generates an
uncommitted `.env` file holding the hostnames and their current shared-network IP
addresses:

```sh
source .env
psql "host=$PG1_HOST port=$PGPORT dbname=appdb user=app_runtime sslmode=disable"
```

The IP addresses are what everything actually uses; the hostnames are a
convenience that only resolves on macOS after `/etc/hosts` has been updated.

Override the resources or template when needed:

```sh
VM_CPUS=4 VM_MEMORY_GIB=8 VM_DISK_GIB=30 make create_vms
```

Lima's `limactl` is used directly because it is Lima's supported lifecycle
interface. Terraform is not used for this local VM lifecycle.

## Run

```sh
make all      # create the VMs, configure the cluster, run every check, report
make clean    # destroy the VMs and delete every generated local file
```

From an empty machine:

```
==============================================================================
 Lab 1 results
==============================================================================
 PASS  Create the three Lima VMs                                         3m30s
 PASS  Install and configure the Patroni cluster                         6m43s
 PASS  Cluster services, quorum, replication, pgBackRest                    6s
 PASS  Criterion 1: client connects to the primary and queries it           1s
 PASS  Client guarantees: pool limit, timeouts, no blind retry             18s
 PASS  Quorum commit: configured, blocking, and lossless                   47s
 PASS  Criterion 2: failover after the primary VM is lost                  57s
 PASS  Criterion 2: failover after PostgreSQL is killed                    14s
 PASS  Split brain: softdog fences a frozen Patroni                        42s
 PASS  Split brain: Patroni demotes itself without etcd                    47s
------------------------------------------------------------------------------
 10 passed, 0 failed, total 14m06s
==============================================================================
```

That is a first run with nothing cached: it downloads the Rocky image and
installs PostgreSQL, Patroni, etcd and pgBackRest on all three nodes. Rerunning
`make all` against existing VMs takes about four minutes, because VM creation and
package installation both become no-ops — the two setup phases drop to seconds,
while the checks take the same time either way.

### Individual phases

```sh
make create_vms         # create missing VMs, start existing ones
make configure_cluster  # apply the full Ansible configuration
make verify_cluster     # every service, plus an Npgsql read-write probe
make test_connection    # AC-1
make test_failover      # AC-2
make test_client        # the client's configured guarantees
make test_sync          # quorum commit really is synchronous
make test_fencing       # split-brain prevention
```

`configure_cluster` can be rerun after the primary has moved to another node. To
inspect the VMs, run `./scripts/vms.sh status`. The
[Ansible guide](ansible/README.md) covers what the configuration actually
applies, and the network policy it installs.

`destroy_vms` deletes the three VMs but keeps the generated passwords in
`.secrets/`, so the cluster can be rebuilt with the same credentials. It also
removes the marked `/etc/hosts` block and the generated `.env`; editing
`/etc/hosts` needs `sudo`, so run it from an interactive terminal that can
prompt. `make clean` is the full teardown: everything `destroy_vms` does, plus
`.secrets/`, the .NET build output and the Ansible temp directory — so `make all`
afterwards starts from scratch with fresh passwords.
