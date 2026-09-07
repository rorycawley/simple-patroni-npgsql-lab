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
| Linux watchdog (`softdog`) | Receives Patroni keepalives and resets an unhealthy node when they stop, fencing it to help prevent split brain. |
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

Create, inspect, and destroy the three Lima VMs with the [Lab 1 VM guide](lab1/README.md).

Encryption at rest and encryption in transit are out of scope for Lab 1. Run it only on an isolated, trusted lab network.

The .NET C# application connects directly to all three nodes and selects the current primary for writes. It uses the static `app_runtime` login, with its password stored in an uncommitted `.secrets/pgpass` file that is readable only by the application identity:

```text
Host=pg1.lab.example,pg2.lab.example,pg3.lab.example;Port=5432;Database=appdb;Username=app_runtime;Passfile=.secrets/pgpass;Target Session Attributes=primary;Timeout=5;Maximum Pool Size=20;SSL Mode=Disable
```

| Setting | Value | Purpose in Lab 1 |
| --- | --- | --- |
| `Host` | `pg1.lab.example,pg2.lab.example,pg3.lab.example` | The three Patroni-managed PostgreSQL nodes. Npgsql tries these hosts to find an eligible server. |
| `Port` | `5432` | The PostgreSQL TCP port used on every host. |
| `Database` | `appdb` | The database to which the client connects. |
| `Username` | `app_runtime` | The non-superuser PostgreSQL login used by the application. |
| `Passfile` | `.secrets/pgpass` | Local file containing the password for `app_runtime`; it is not committed to version control. |
| `Target Session Attributes` | `primary` | Requires Npgsql to connect to the current primary, so the connection can perform reads and writes. |
| `Timeout` | `5` | Limits a connection attempt to five seconds before Npgsql reports an error. |
| `Maximum Pool Size` | `20` | Limits this connection pool to 20 physical PostgreSQL connections. |
| `SSL Mode` | `Disable` | Explicitly disables encryption in transit, which is intentionally out of scope for Lab 1. |

Configure authentication through Patroni's cluster-wide `pg_hba` configuration, using a narrow `host appdb app_runtime <client-network> scram-sha-256` rule. The `app_runtime` role must be non-superuser and have only the permissions needed by the application.

### Acceptance criteria

1. The client can connect to the primary database and run queries.
2. After failover promotes a new database node to primary, the client connects to that new node for read-write work.
