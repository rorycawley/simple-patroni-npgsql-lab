# Lab 1 Ansible

This automation turns the three Rocky Linux 9.8 Lima VMs into a working
Patroni-managed Percona PostgreSQL 18 cluster.

What Lab 1 claims and how it proves it is in the [Lab 1 guide](../README.md).
This file covers how the configuration is applied.

It follows Percona's RPM and HA guidance:

- enables EPEL and CRB, disables Rocky's PostgreSQL module, configures the
  Percona PostgreSQL 18 repository, and installs PostgreSQL, Patroni, etcd, and
  pgBackRest;
- does not run `postgresql-18-setup initdb` or start `postgresql-18` directly,
  because Patroni must initialize and own PostgreSQL;
- forms a static three-member etcd cluster, starts Patroni on each node, and
  verifies one leader plus two streaming replicas;
- configures quorum commit (`synchronous_mode: quorum`, `synchronous_node_count: 1`,
  `synchronous_mode_strict: true`, and an explicit `synchronous_commit: on`,
  without which the quorum expression would be inert), so an acknowledged
  transaction cannot be lost in a failover. Strict mode means the guarantee has
  no exception: with no standby able to confirm, a commit blocks rather than
  completing on one node;
- puts SELinux into Enforcing mode explicitly, after restoring contexts on the
  paths it creates, rather than trusting the image default — which only becomes
  Enforcing after the first-boot relabel and reboot, and so is a race rather than
  a setting. `verify.yml` asserts it;
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

No TLS, mTLS, or other encryption-in-transit configuration is included in Lab 1,
and the data volumes are not encrypted. [Lab 2](../../lab2/README.md) adds both.

## Forming the etcd cluster

`start-etcd.yml` starts all three members **together**, under Ansible's default
linear strategy. This is load-bearing rather than incidental: etcd's static
bootstrap only works when every member starts from an empty data directory at
roughly the same time, and Percona's guidance says so directly — a first start
may fail on a quorum timeout, and the remedy is to start all nodes again at the
same time. An earlier version used `strategy: free`, which removed that barrier.

When a member fails and the others form the cluster without it, the survivors
report it as already known, and it can never bootstrap:

```text
member <id> has already been bootstrapped
```

That check queries the *peers*, not local disk, so clearing the failed node's
data directory does not help. The recovery therefore clears **all three** and
restarts them simultaneously — gated on no node holding a PostgreSQL data
directory, which is what makes wiping etcd safe. On a live cluster every
destructive task is skipped.

The failure was observed in [Lab 2](../../lab2/README.md), not here. Lab 1 has
the same static bootstrap and had the same `strategy: free`, so it carried the
same exposure and takes the same fix.

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

From `lab1`, `make all` does everything and reports; see the
[Lab 1 guide](../README.md) for the individual phases:

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
`pg1.lab.example`, `pg2.lab.example`, and `pg3.lab.example` in macOS
`/etc/hosts`.
