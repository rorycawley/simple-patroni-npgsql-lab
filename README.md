# Goal

This lab will have a .NET C# client application use the Npgsql driver to query a Patroni-managed PostgreSQL cluster.

The client application will use a direct, multi-host connection to the database.

The .NET C# application will be resilient to failover, with short connection timeouts, Npgsql multi-host configuration, a configured connection limit, and carefully scoped retries for transient connection failures. It should not blindly retry arbitrary transactions, because a connection loss can leave the application uncertain whether a transaction committed.

## Components

| Component | Role |
| --- | --- |
| Npgsql | .NET PostgreSQL driver. It connects directly to the configured hosts, selects the current primary for writes, and provides connection pooling. |
| Patroni | Manages PostgreSQL instances, records cluster state in etcd, and orchestrates promotion and failover. |
| etcd | Distributed configuration store that holds Patroni cluster state and elects a single leader through quorum. |
| Linux watchdog (`softdog`) | Armed by Patroni on the leader only, and petted on every successful leader-key renewal. If renewals stop, it resets the node at `ttl - safety_margin`, fencing it so a promoted replica cannot end up alongside a still-writable old primary. |
| pgBackRest | Provides PostgreSQL backup, WAL archiving, and restore capabilities. It supports disaster recovery, not automatic failover. |

## Cluster setup

The database cluster is a Patroni-managed, three-node PostgreSQL cluster running on three VMs. Each VM runs PostgreSQL, Patroni, and one member of the etcd cluster. Patroni uses the Linux software watchdog (`softdog`) through `/dev/watchdog` for fencing and split-brain protection.

The lab also uses pgBackRest for backup and restore; it is not part of the automatic-failover path.

No HAProxy, VIP, Keepalived, or PgBouncer is used. The client connects directly to all three database nodes. Connections that perform writes must use Npgsql `Target Session Attributes=primary` (or `read-write`) so that Npgsql selects the current primary.

## Expected failover behaviour

If PostgreSQL on the primary stops while Patroni is still running, Patroni first attempts to restart it. Failover occurs only if the primary does not recover within `primary_start_timeout` (300 seconds by default); setting that value to `0` permits failover as soon as a crash is detected.

If the primary VM becomes unavailable, the two remaining etcd members retain quorum, provided they can still communicate. Once the leader lease expires, Patroni can promote an eligible, healthy replica to primary. Failover timing depends on the configured Patroni timeouts.

During a primary failure and promotion, existing client connections to the old primary are lost and new connections may fail temporarily. Npgsql does not automatically retry commands on another host: the client must handle I/O-related errors, open a new primary connection, and retry only operations known to be safe. With asynchronous replication, transactions recently acknowledged by the failed primary can be lost; synchronous replication is required when that risk is unacceptable.

# PoC Labs

## Lab 1: simplest possible setup

Percona Patroni-managed cluster with three VMs and default settings.

The whole lab runs from `lab1/` with two commands — `make all` to build the
cluster and run every check with a summary report, and `make clean` to destroy
the VMs and delete every generated file. The [Lab 1 guide](lab1/README.md)
covers the individual phases.

Encryption at rest and encryption in transit are out of scope for Lab 1. Run it only on an isolated, trusted lab network.

The .NET C# application connects directly to all three nodes and selects the current primary for writes. It uses the static `app_runtime` login, with its password stored in an uncommitted `.secrets/pgpass` file that is readable only by the application identity:

```text
Host=<pg1-ip>,<pg2-ip>,<pg3-ip>;Port=5432;Database=appdb;Username=app_runtime;Passfile=.secrets/pgpass;Target Session Attributes=primary;Timeout=5;Command Timeout=10;Maximum Pool Size=20;SSL Mode=Disable
```

| Setting | Value | Purpose in Lab 1 |
| --- | --- | --- |
| `Host` | the three node addresses | The three Patroni-managed PostgreSQL nodes. Npgsql tries these hosts to find an eligible server. |
| `Port` | `5432` | The PostgreSQL TCP port used on every host. |
| `Database` | `appdb` | The database to which the client connects. |
| `Username` | `app_runtime` | The non-superuser PostgreSQL login used by the application. |
| `Passfile` | `.secrets/pgpass` | Local file containing the password for `app_runtime`; it is not committed to version control. |
| `Target Session Attributes` | `primary` | Requires Npgsql to connect to the current primary, so the connection can perform reads and writes. |
| `Timeout` | `5` | Limits a connection attempt to five seconds before Npgsql reports an error. |
| `Command Timeout` | `10` | Limits a single command to ten seconds, so a stalled node cannot block the client indefinitely. |
| `Maximum Pool Size` | `20` | Limits this connection pool to 20 physical PostgreSQL connections. |
| `SSL Mode` | `Disable` | Explicitly disables encryption in transit, which is intentionally out of scope for Lab 1. |

The client reads the three host addresses from `LAB1_PG_HOSTS`, which
`scripts/test-npgsql.sh` fills from the shared-network IP addresses that
`make create_vms` writes into `lab1/.env`. The `pg1.lab.example`,
`pg2.lab.example`, and `pg3.lab.example` names are equivalent, but only resolve
on macOS after `make configure_hostnames` has written them to `/etc/hosts`.

A multi-host Npgsql data source reports a failed connection attempt as an
`NpgsqlException` wrapping an `AggregateException` of the per-host failures.
That wrapper leaves `NpgsqlException.IsTransient` false, so a retry predicate
built on `IsTransient` alone never fires during the failover window. The client
unwraps the aggregate and retries the individual failures, while still failing
immediately on a `PostgresException` such as a rejected password.

#### Proving the client's configured guarantees

```sh
make test_client
```

Failover tests show the client survives; they say nothing about whether the pool
limit or the timeouts are real, or whether the client would quietly double-write
after a lost acknowledgement. `make test_client` asserts those three directly.
Each probe reuses the same `NpgsqlConnectionStringBuilder` as the write probe, so
the assertions cannot drift from the shipped configuration, while the *expected*
values live in `scripts/test-client.sh` — changing a setting in `Program.cs`
therefore fails the test instead of quietly testing the new value.

| Probe | Asserts |
| --- | --- |
| `pool` | Exactly `Maximum Pool Size` connections open; the next one is refused after about `Timeout` seconds, not instantly and not indefinitely; releasing one lets the next straight through, which distinguishes a pool limit from a saturated server. |
| `command-timeout` | A `pg_sleep` three times longer than `Command Timeout` is cut off at roughly `Command Timeout`. Lab 1 sets no server-side `statement_timeout`, so only the client-side value can end it. |
| `uncertain-write` | The hazard in full: a commit that is durable but never acknowledged, and a client that reports failure without reissuing the write. |

The `uncertain-write` probe issues one round trip that commits and then blocks:

```sql
BEGIN; INSERT INTO ha_probe ...; COMMIT; SELECT pg_sleep(60);
```

The harness waits until a *third-party* session can see the row — proving the
commit is durable — then calls `pg_terminate_backend` on the client. The client
therefore fails on an operation that actually succeeded, and cannot tell. It must
exit non-zero and leave exactly one row. The explicit `COMMIT` is load-bearing:
PostgreSQL wraps a multi-statement simple query in one implicit transaction, so
without it the insert would roll back and there would be no uncertainty to test.

Two details make that assertion honest. The row count is taken on a **per-run
`client_name`, not on `probe_id`** — `probe_id` is a primary key, so a retry
reusing it would merely hit a duplicate-key error, while the realistic naive
retry reissues the operation with a fresh id and would be invisible to a
`probe_id` count. And the assertion is verified against a deliberately broken
client: with a blind retry spliced into the failure path, every other assertion
still passes and only the row count catches it, reporting `2` instead of `1`.

One incidental finding worth knowing if you write your own retry logic: after a
`57P01` termination, Npgsql marks the host bad in its cluster-state cache and an
immediate reconnect fails with `No suitable host was found` until
`HostRecheckSeconds` (default 10) elapses.

Those retries run against a 90-second budget rather than a fixed attempt count.
The two failure modes fail at different speeds — an unreachable host costs up to
the five-second `Timeout`, while a node whose postmaster was killed refuses
instantly — so a fixed attempt count would cover very different amounts of wall
clock depending on which fault occurred. The budget covers Patroni's worst case
of `ttl` (30s) plus `loop_wait` (10s) plus promotion time, with margin.

Configure authentication through Patroni's cluster-wide `pg_hba` configuration, using a narrow `host appdb app_runtime <client-network> scram-sha-256` rule. The `app_runtime` role must be non-superuser and have only the permissions needed by the application.

### Acceptance criteria

1. The client can connect to the primary database and run queries.
2. After failover promotes a new database node to primary, the client connects to that new node for read-write work.

Each criterion has one command that proves it and fails loudly otherwise.

#### Criterion 1 — the client connects to the primary and runs queries

```sh
make test_connection
```

This runs the real client (`lab1/client/Program.cs`) against all three nodes at
once. To exit zero it must:

1. open a connection with `Target Session Attributes=primary`, which makes
   Npgsql pick whichever of the three nodes is currently primary;
2. run `SELECT inet_server_addr(), pg_is_in_recovery()` and assert the answer is
   *not* a replica, so a misrouted read-write connection fails rather than
   silently succeeding against a standby;
3. commit an `INSERT` into `public.ha_probe` and confirm the returned identifier
   matches what it sent; and
4. print the node it used as JSON: `{"ok":true,"server":"…","primary":true,…}`.

`make verify_cluster` runs the same probe after its Ansible checks, so a healthy
cluster always demonstrates criterion 1.

#### Criterion 2 — the client follows a promotion to the new primary

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

1. Record the current primary and prove criterion 1 against it.
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

### Split-brain prevention, and where softdog fits

```sh
make test_fencing               # both scenarios below
make test_fencing_patroni       # softdog resets the node
make test_fencing_etcd          # Patroni demotes itself
make test_faults                # every scenario, failover and fencing
```

Failover decides who is *allowed* to be primary. It says nothing about whether
the old primary has actually stopped serving. A node that can no longer renew
its leader key may still be reachable by clients, and if it keeps accepting
writes while a replica is promoted, the two diverge.

Patroni closes that gap two different ways, and the lab exercises both. Which
one applies depends on a single question: **can Patroni still act?**

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

Each scenario asserts the mechanism, not just the end state. `patroni` reads
`/proc/sys/kernel/random/boot_id` before and after and requires it to **change**,
which only a real kernel restart does. `etcd` requires `pg_is_in_recovery()` to
flip true while that same boot id stays **unchanged**, proving the node stepped
down rather than being reset. Swapping the two outcomes fails the test.

This is also why `watchdog.mode` is `required` in `patroni.yml`: if Patroni
cannot arm the watchdog it refuses to be primary at all, because it would have no
way to fence itself later. That makes the `/dev/watchdog` ownership check in
`verify_cluster` a prerequisite, not a nicety — without it the cluster never
elects a leader.

Two honest limits. First, `softdog` is a kernel timer emulating a hardware
watchdog: it catches a hung Patroni or a thrashing machine, but not a kernel
panic, because then the timer that would fire the reset is not running either.
Real deployments use a hardware or hypervisor watchdog. Second, in the `patroni`
scenario PostgreSQL keeps answering as a primary for the whole 25 seconds before
the reset, so a client that reaches it in that window can commit a write that is
lost when the node is rewound. Fencing bounds how long that window lasts; it does
not eliminate it. Synchronous replication is what removes the data-loss risk.
