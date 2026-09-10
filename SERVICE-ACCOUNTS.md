# Service accounts and secrets

Every identity the cluster needs, what it may do, and which lab introduces it.
Intended for storage in OpenBao, with human identities in Keycloak.

Two things commonly listed here are **not** accounts:

| Not an account | What it actually is |
| --- | --- |
| `softdog` | A kernel module reached through `/dev/watchdog`. The control is device ownership — Patroni's process must hold it, and `watchdog.mode: required` already refuses to be primary otherwise. Nothing to store |
| `pg_dump` | A client tool, not a service. It does need a role to run as, which is `dumper` below — worth defining, because the usual alternative is running it as superuser |

## Identity boundaries: Keycloak, OpenBao, and neither

Three systems hold identity here, and mixing them up is how a database outage
becomes an outage nobody can log in to fix.

> **Keycloak answers "who is this person?"**
> **OpenBao answers "may this workload have this secret?"**
> **Nothing that must work while the cluster is broken may depend on either.**

### Keycloak

| Identity | Why it belongs there |
| --- | --- |
| Grafana login (Lab 5) | Roles and teams map from groups, so dashboard access follows joiner/mover/leaver instead of a local user table |
| Human access to OpenBao | Operators authenticate as themselves rather than sharing a static token — which is what makes the audit trail mean anything |
| Human `psql` sessions | PostgreSQL 18 added OAuth 2.0 (`OAUTHBEARER`), so this is newly possible. Confirm against the Percona 18 build first: server-side validation needs a validator library that not every build ships |
| The CI/CD pipeline (Lab 7) | The pipeline proves who it is to Keycloak, then draws a short-lived `migrator` credential from OpenBao |

Note what the last row does *not* do: Keycloak authenticates the pipeline, but
the database connection is still SCRAM. Keycloak is never in the connection path.

### Not Keycloak

| Identity | Why not |
| --- | --- |
| `postgres`, `replicator`, `rewind` | Patroni needs these to **fail over**. An identity-provider outage must never prevent a promotion |
| `app_runtime` | Would put Keycloak on the write path, and token refresh interacts badly with the client's retry loop across a failover |
| `pgbackrest` | Backups must run *especially* when other things are broken |
| `monitoring` | Same, more so — monitoring matters most when other systems are down |
| etcd and Patroni mTLS | Certificate identity from the Lab 2 CA; an IdP would add a dependency and no security |

The rule behind the table: **nothing on the failover path may depend on an
external identity provider.** Patroni promoting at 03:00 cannot be waiting on a
token endpoint.

### The dependency chain

```text
Keycloak  ->  OpenBao  ->  credential  ->  PostgreSQL
```

Every arrow is something that can be unavailable. During an automatic failover
that is harmless, because nobody is authenticating. For anything a human must do
under pressure, each hop is a place the recovery can stall.

Two consequences follow, and both are easier to check now than to discover
later.

**Break-glass must work when Keycloak is down.** `operator` exists for the
situation where things are broken, and "things are broken" plausibly includes the
identity provider. Keycloak should govern who may retrieve that credential in
normal times, but a sealed offline copy must exist that requires neither Keycloak
nor OpenBao. Otherwise emergency access gains two new failure modes precisely
when it is needed.

**Check whether Keycloak runs on this cluster.** If its own database is here,
the dependency is circular: recovering the cluster needs break-glass,
break-glass needs Keycloak, Keycloak needs the cluster. That is the same shape as
the [repository cipher passphrase](#the-repository-cipher-passphrase-protects-everything-else)
problem — invisible until the one moment it matters. If Keycloak does run here,
its identities cannot be part of this cluster's recovery path.

## OS process users

These are a different thing from the database roles below, and both are needed.
A process user is *not* an OpenBao secret: it is `nologin` with no password, and
its "credential" is the `User=` directive in the systemd unit plus file
ownership. There is nothing to store.

What each process *does* need is an **identity to authenticate to OpenBao with** —
the answer to "who is asking for `repo1-cipher-pass`?" That is an AppRole,
certificate or JWT bound to the workload on that node, and it is the piece most
easily forgotten because it is neither a Unix account nor a database role.

| Service | Runs as | Needs to read from OpenBao |
| --- | --- | --- |
| PostgreSQL | `postgres` | — (Patroni supplies its configuration) |
| Patroni | `postgres` | superuser, replication and rewind passwords |
| pgBackRest | `postgres` | repository credentials and cipher passphrase |
| etcd | `etcd` | its TLS key, if issued rather than pre-placed |
| `node_exporter` | own user | nothing |
| `postgres_exporter` | own user | the `monitoring` role's password |
| Alloy | own user | its Loki/Mimir credentials — see below |

### Three workloads share the `postgres` user

PostgreSQL, Patroni and pgBackRest all run as `postgres`. This is conventional
and largely unavoidable — Patroni must start and stop PostgreSQL, and pgBackRest
must read `PGDATA` — but the consequence is worth stating rather than
discovering: **`/etc/patroni/patroni.yml` contains the superuser and replication
passwords in cleartext**, mode `0600 postgres`. Anything running as that user can
read them, so pgBackRest is effectively as privileged as Patroni.

Fetching those passwords from OpenBao at start rather than templating them into
the file is what would close this, and it is the strongest practical argument for
using a secrets manager here at all.

### The collectors should not share it

For Lab 5 the separation is available and worth taking. `postgres_exporter`
connects as the `monitoring` *database* role and has no reason to be the
`postgres` *OS* user.

Alloy is the one with a real design decision behind it: it must read logs, and
PostgreSQL's are `0600 postgres`. It therefore needs a group, a filesystem ACL,
or journald — and **not** membership of `postgres`, which would hand the log
collector the superuser password.

### Bootstrapping

Certificate authentication is the natural fit here, because every node already
holds a per-purpose identity from the Lab 2 CA. That avoids delivering an
AppRole `secret_id` out of band and makes OpenBao a third consumer of the "one
CA, extended" decision rather than a new trust root.

## PostgreSQL roles

| Role | Introduced by | Purpose | Superuser |
| --- | --- | --- | --- |
| `postgres` | Lab 1 | Patroni bootstrap and administration | yes |
| `replicator` | Lab 1 | Streaming replication | no |
| `rewind` | Lab 1 | `pg_rewind` when a demoted primary rejoins | no |
| `app_runtime` | Lab 1 | The .NET client | no |
| `migrator` | Lab 7 | Flyway schema migrations | no |
| `pgbackrest` | Lab 3 | Backups | no |
| `dumper` | any | Logical dumps | no |
| `monitoring` | Lab 5 | `postgres_exporter` | no |
| `operator` | any | Break-glass intervention | yes |

### The separation that matters most

`app_runtime` and `migrator` must be different roles. The application must not be
able to alter schema, and the migration tool must not be the application — that
is what makes a migration a reviewable, separately-authorised event rather than
something any application bug can trigger.

It has a consequence that catches people out: **`migrator` owns the tables it
creates**, so `app_runtime` gets no access to anything Flyway creates later
unless default privileges are set against `migrator`, not against whoever ran the
`GRANT`.

```sql
-- Roles
CREATE ROLE migrator     WITH LOGIN PASSWORD :'migrator_pw';
CREATE ROLE app_runtime  WITH LOGIN PASSWORD :'app_pw';

GRANT CONNECT ON DATABASE appdb TO migrator, app_runtime;
ALTER SCHEMA public OWNER TO migrator;
GRANT USAGE ON SCHEMA public TO app_runtime;

-- Existing objects
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES    IN SCHEMA public TO app_runtime;
GRANT USAGE, SELECT                  ON ALL SEQUENCES IN SCHEMA public TO app_runtime;

-- Future objects created BY migrator. Without this, every table Flyway adds is
-- invisible to the application until someone re-runs the GRANT by hand.
ALTER DEFAULT PRIVILEGES FOR ROLE migrator IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE migrator IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO app_runtime;
```

### Replication and rewind

```sql
CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD :'repl_pw';
-- No database privileges: replication is not a database connection.
```

Patroni has a dedicated `authentication.rewind` slot and does not need a
superuser for it on PostgreSQL 11 and later. The labs currently fall back to the
superuser here, which is worth closing:

```sql
CREATE ROLE rewind WITH LOGIN PASSWORD :'rewind_pw';
GRANT EXECUTE ON FUNCTION pg_catalog.pg_ls_dir(text, boolean, boolean)                    TO rewind;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_stat_file(text, boolean)                          TO rewind;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_read_binary_file(text)                            TO rewind;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_read_binary_file(text, bigint, bigint, boolean)   TO rewind;
```

### Read-only roles

```sql
CREATE ROLE dumper WITH LOGIN PASSWORD :'dumper_pw';
GRANT CONNECT ON DATABASE appdb TO dumper;
-- pg_read_all_data (PostgreSQL 14+) is the reliable choice: a dump by a role
-- that merely holds SELECT on today's tables silently omits anything it cannot
-- read, producing a backup that restores cleanly and is incomplete.
GRANT pg_read_all_data TO dumper;

CREATE ROLE monitoring WITH LOGIN PASSWORD :'monitoring_pw';
GRANT CONNECT ON DATABASE appdb TO monitoring;
GRANT pg_monitor TO monitoring;   -- covers read_all_settings, read_all_stats, stat_scan_tables
```

### pgBackRest

pgBackRest does **not** need a superuser on PostgreSQL 11+. It needs to read
settings and to call the backup control functions:

```sql
CREATE ROLE pgbackrest WITH LOGIN PASSWORD :'pgbackrest_pw';
GRANT pg_read_all_settings TO pgbackrest;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_backup_start(text, boolean) TO pgbackrest;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_backup_stop(boolean)        TO pgbackrest;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_switch_wal()                TO pgbackrest;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_create_restore_point(text)  TO pgbackrest;
```

> Verify the exact signatures against the pgBackRest guide for PostgreSQL 18
> before applying. `pg_start_backup`/`pg_stop_backup` were renamed to
> `pg_backup_start`/`pg_backup_stop` in PostgreSQL 15, and the argument lists
> differ between versions.

## Infrastructure secrets

| Secret | Introduced by | Notes |
| --- | --- | --- |
| Patroni REST API credentials | Lab 1 | Guards the *unsafe* endpoints — restart, reinitialize, switchover. Worth having even alongside mTLS: holding a valid certificate should not by itself authorise a switchover |
| etcd RBAC user | Lab 2 (optional) | mTLS authenticates the caller; it does not restrict which keys that caller may touch. Only needed if you want authorisation as well as identity |
| CA private key | Lab 2 | The most sensitive key here. Never copied to a guest — Lab 2 asserts this and fails the run if a guest holds it |
| Per-node TLS keys (`postgres`, `etcd`, `patroni`, `dcs-client`) | Lab 2 | Better *issued* by OpenBao's PKI engine than stored as static secrets |
| LUKS volume keys | Lab 2 | See the boot-dependency warning below |
| MinIO access key and secret | Lab 3 | Repository access |
| **pgBackRest `repo1-cipher-pass`** | Lab 3 | See below |
| Dump encryption passphrase | Lab 3 | `pg_dump` output is written outside the pgBackRest repository, so `repo1-cipher-pass` does not cover it. Without its own passphrase the dumps sit in the bucket in plaintext |
| Grafana admin, Alloy → Loki/Mimir credentials | Lab 5 | |

## Three risks worth stating

### The repository cipher passphrase protects everything else

Lose `repo1-cipher-pass` and every backup is unreadable — including the ones you
would use to recover from having lost it. It must be stored with **no dependency
on the cluster it protects**, and OpenBao's own recovery path must not route
through those backups. This is the one secret where a circular dependency is
fatal rather than inconvenient.

### Not everything can be dynamic

OpenBao's database secrets engine suits `app_runtime`, `dumper` and `monitoring`
well — short-lived, rotated freely, no coordination needed.

It does not suit `postgres` or `replicator`. Patroni holds both in `patroni.yml`
and in the DCS; rotating them means updating the distributed configuration and
restarting replicas, so they are static-with-managed-rotation rather than
dynamic. Treating them as dynamic breaks replication at a moment of its
choosing.

### LUKS keys in OpenBao move the risk rather than removing it

Today's root-only keyfile means a stolen **disk** is safe but a stolen **node**
is not. Fetching the key from OpenBao at boot closes that, and introduces a
chicken-and-egg: the node needs network, time and an authenticated identity
before it can mount its data volume, and OpenBao may itself be unavailable. This
is the same trade Tang/Clevis makes, and [Lab 2](lab2/README.md) scoped it out
deliberately. Worth a decision, not a default.

## Break-glass

`operator` is a superuser, separate from `postgres`, audited, and expected to go
unused. Who may retrieve it is a Keycloak question; whether it still works when
Keycloak is down is the [identity-boundary](#the-dependency-chain) question, and
the answer must be yes. It exists because [strict synchronous mode](SLA.md#the-exception-being-closed)
created a state that does not resolve itself: with both standbys gone, writes
block until someone intervenes. That intervention should be a named, logged
identity rather than whichever superuser credential was closest to hand.
