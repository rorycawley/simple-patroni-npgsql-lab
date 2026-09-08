# Lab 2 Ansible

This automation turns the three Rocky Linux 9.8 Lima VMs into a working
Patroni-managed Percona PostgreSQL 18 cluster.

It follows Percona's RPM and HA guidance:

- enables EPEL and CRB, disables Rocky's PostgreSQL module, configures the
  Percona PostgreSQL 18 repository, and installs PostgreSQL, Patroni, etcd, and
  pgBackRest;
- does not run `postgresql-18-setup initdb` or start `postgresql-18` directly,
  because Patroni must initialize and own PostgreSQL;
- forms a static three-member etcd cluster, starts Patroni on each node, and
  verifies one leader plus two streaming replicas;
- configures quorum commit (`synchronous_mode: quorum`, `synchronous_node_count: 1`,
  and an explicit `synchronous_commit: on`, without which the quorum expression
  would be inert), so an acknowledged transaction cannot be lost in a failover;
- configures and verifies `softdog` watchdog fencing;
- creates a least-privilege `app_runtime` login, `appdb`, and the write-probe
  table;
- creates each node's local pgBackRest stanza as soon as that node's PostgreSQL
  reports healthy, because `archive_mode` is on from the moment Patroni starts
  it and every `archive-push` fails until the stanza exists; and
- reconciles Patroni's distributed configuration, so later runs do not assume
  that `pg1` is still primary.

`roles/cluster_config/templates/patroni-dcs.yml.j2` is the single source for the
distributed configuration. `patroni.yml.j2` includes it for the one-time
`bootstrap.dcs` block, and `playbooks/bootstrap.yml` applies the same file to the
running cluster with `patronictl edit-config`, so the two paths cannot drift.

The local pgBackRest repositories are a three-VM lab simplification. They prove
installation, stanza configuration, and WAL archiving, but they are not a
durable shared backup design. A production design needs storage independent of
the database VM.

No TLS, mTLS, or other encryption-in-transit configuration is included in Lab 2.

## Network policy

The firewall assigns `eth0` and `lima0` to a default `DROP` zone. It permits:

- SSH from Lima's isolated management subnet;
- etcd client/peer, PostgreSQL, and Patroni REST traffic on ports `2379`,
  `2380`, `5432`, and `8008` only from the three exact VM addresses; and
- PostgreSQL on `5432` from the macOS address on Lima's shared subnet.

The dynamic inventory reads addresses from the generated `.env` file and uses
Lima's generated SSH configuration, so neither guest IPs nor forwarded SSH
ports are hard-coded.

The Percona PostgreSQL 18 repository is defined directly as a `yum_repository`
rather than through `percona-release setup`, so package installation does not
depend on that tool's repository discovery.

## Run

From `lab2`, `make all` does everything and reports; see the
[Lab 2 guide](../README.md) for the individual phases:

```sh
make all
```

`configure_cluster` installs the required Ansible collection and generates
static lab passwords in ignored, mode-`0600` files under `.secrets/` if they do
not already exist. `verify_cluster` performs service, etcd, Patroni,
replication, watchdog, and pgBackRest checks, then runs a real Npgsql
primary-only read/write test. `test_sync`, `test_client`, `test_failover`, and
`test_fencing` are the fault-injection and guarantee checks.

Run `make configure_hostnames` in an interactive terminal if you also want
`pg1.lab2.example`, `pg2.lab2.example`, and `pg3.lab2.example` in macOS
`/etc/hosts`.
