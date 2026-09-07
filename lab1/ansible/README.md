# Lab 1 Ansible

This automation turns the three Rocky Linux 9.8 Lima VMs into a working
Patroni-managed Percona PostgreSQL 18 cluster.

It follows Percona's RPM and HA guidance:

- enables EPEL and CRB, disables Rocky's PostgreSQL module, configures the
  Percona `ppg18` repository, and installs PostgreSQL, Patroni, etcd, and
  pgBackRest;
- does not run `postgresql-18-setup initdb` or start `postgresql-18` directly,
  because Patroni must initialize and own PostgreSQL;
- forms a static three-member etcd cluster, starts Patroni on each node, and
  verifies one leader plus two streaming replicas;
- configures and verifies `softdog` watchdog fencing;
- creates a least-privilege `app_runtime` login, `appdb`, and the write-probe
  table;
- creates a local pgBackRest stanza on each node and enables WAL archiving; and
- reconciles Patroni's distributed configuration, so later runs do not assume
  that `pg1` is still primary.

The local pgBackRest repositories are a three-VM lab simplification. They prove
installation, stanza configuration, and WAL archiving, but they are not a
durable shared backup design. A production design needs storage independent of
the database VM.

No TLS, mTLS, or other encryption-in-transit configuration is included in Lab 1.

## Network policy

The firewall assigns `eth0` and `lima0` to a default `DROP` zone. It permits:

- SSH from Lima's isolated management subnet;
- etcd client/peer, PostgreSQL, and Patroni REST traffic on ports `2379`,
  `2380`, `5432`, and `8008` only from the three exact VM addresses; and
- PostgreSQL on `5432` from the macOS address on Lima's shared subnet.

The dynamic inventory reads addresses from the generated `.env` file and uses
Lima's generated SSH configuration, so neither guest IPs nor forwarded SSH
ports are hard-coded.

## Run

From `lab1`:

```sh
make create_vms
make configure_cluster
make verify_cluster
make test_failover
```

`configure_cluster` installs the required Ansible collection and generates
static lab passwords in ignored, mode-`0600` files under `.secrets/` if they do
not already exist. `verify_cluster` performs service, etcd, Patroni,
replication, watchdog, and pgBackRest checks, then runs a real Npgsql
primary-only read/write test.

Run `make configure_hostnames` in an interactive terminal if you also want
`pg1.lab.example`, `pg2.lab.example`, and `pg3.lab.example` in macOS
`/etc/hosts`.
