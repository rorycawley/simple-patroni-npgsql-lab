# Lab 2 Ansible

This automation turns four Rocky Linux 9.8 Lima VMs into a Patroni-managed
Percona PostgreSQL 18 cluster on encrypted volumes, reachable only over TLS, plus
an application host that runs the .NET client.

What each lab's automation claims and proves is in the
[Lab 2 guide](../README.md). This file covers how it is applied.

## Order

`playbooks/site.yml` runs seven playbooks, and the order carries most of the
design:

| Playbook | Does |
| --- | --- |
| `install.yml` | `data_volumes` then `postgres_node` |
| `configure.yml` | `tls_material` then `cluster_config` |
| `start-etcd.yml` | Forms the etcd cluster over mutual TLS |
| `bootstrap.yml` | Reconciles Patroni's distributed configuration |
| `create-app.yml` | Creates `appdb`, `app_runtime`, and the probe table |
| `app-client.yml` | Provisions `lab2-app1` with the client, the CA, and the password file |
| `flush-disks.yml` | `sync`, so a force-stopped VM does not lose a written config file |

Two of those orderings are load-bearing:

- **`data_volumes` before `postgres_node`.** The package installs create
  `/var/lib/pgsql` and `/var/lib/etcd`. Anything written there before the mount
  would be hidden by it rather than stored on the volume.
- **`tls_material` before `cluster_config`.** The Patroni, etcd and PostgreSQL
  templates all reference certificate paths that must already exist.

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

## Encryption at rest

`roles/data_volumes` resolves each additional disk **by size** rather than by
kernel name, because device naming is not stable across boots. It then:

- takes the device back from Lima if that already mounted it, and `wipefs`es it;
- `cryptsetup luksFormat --type luks2` with a root-only keyfile, but only if the
  device is not already a LUKS container, so a rerun is a no-op rather than a
  reformat;
- records the LUKS UUID in `/etc/crypttab` for unattended unlock at boot; and
- installs `lab2-require-volume`, a guard the service units call from
  `ExecStartPre`.

That guard is the second of two independent layers. `RequiresMountsFor=` makes
systemd pull the mount in, but it does not refuse to start when the mount is
somehow absent — so the guard asserts that the data directory is a mount point
*and* that it resolves to the expected device, and exits non-zero otherwise. The
property being protected is that the service never runs with its data directory
on the root filesystem, where it would silently initialise an empty cluster over
the mountpoint.

## Encryption in transit

`scripts/generate-pki.sh` builds the CA and four certificates per node on the
control machine. `roles/tls_material` distributes them and then asserts the
negative: it fails the run if a guest is holding the CA private key.

`roles/cluster_config` configures every channel:

- **etcd** — `https://` client and peer URLs, `client-cert-auth` and
  `peer-client-cert-auth` both true, `tls-min-version: TLS1.3`;
- **Patroni** — `restapi.verify_client: required`, a matching `ctl:` section so
  `patronictl` presents a certificate, and `etcd3.protocol: https` using the
  node's `dcs-client` certificate;
- **PostgreSQL** — `ssl: on`, `ssl_min_protocol_version: TLSv1.3`, and a
  `pg_hba` in which every non-local rule is `hostssl`, so plaintext is refused
  rather than merely unused.

SELinux is left Enforcing, which is the image default. `verify.yml` asserts it
explicitly, because a default that nothing checks is a default that can drift.

## Cluster configuration

Otherwise this follows Percona's RPM and HA guidance, as Lab 1 does:

- enables EPEL and CRB, disables Rocky's PostgreSQL module, configures the
  Percona PostgreSQL 18 repository, and installs PostgreSQL, Patroni, etcd, and
  pgBackRest;
- does not run `postgresql-18-setup initdb` or start `postgresql-18` directly,
  because Patroni must initialize and own PostgreSQL;
- forms a static three-member etcd cluster, starts Patroni on each node, and
  verifies one leader plus two streaming replicas;
- configures quorum commit (`synchronous_mode: quorum`, `synchronous_node_count: 1`,
  and an explicit `synchronous_commit: on`, without which the quorum expression
  would be inert). `synchronous_mode_strict` is **not yet set here** — the
  decision to enable it lands in Lab 1 first and is carried over afterwards;
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

pgBackRest is carried over from Lab 1 unchanged: local per-node repositories that
prove installation, stanza configuration and WAL archiving, but are not a durable
backup design. Moving them off the database VM and encrypting them is Lab 3.

## The application host

`roles/app_client` installs the client on `lab2-app1` as a self-contained
`linux-arm64` binary cross-published from the control machine, so the guest needs
neither the SDK nor the runtime. It also installs `libicu`, without which .NET
aborts before `Main`, and the CA certificate the client verifies the cluster
against. The client is authenticated by SCRAM inside the tunnel rather than by a
certificate of its own.

`ansible.posix.synchronize` is deliberately not used anywhere here: it builds its
own `ssh` command and ignores `ansible_ssh_common_args`, so it cannot use Lima's
generated SSH configuration.

## Network policy

The firewall assigns `eth0` and `lima0` to a default `DROP` zone. It permits:

- SSH from Lima's isolated management subnet;
- etcd client/peer, PostgreSQL and Patroni REST traffic on ports `2379`, `2380`,
  `5432` and `8008`, only from the three exact node addresses; and
- PostgreSQL on `5432` from the application VM, and from the macOS gateway
  address for `psql` debugging — OpenSSL can negotiate TLS 1.3 where .NET on
  macOS cannot.

The dynamic inventory reads addresses from the generated `.env` file and uses
Lima's generated SSH configuration, so neither guest IPs nor forwarded SSH ports
are hard-coded.

The Percona PostgreSQL 18 repository is defined directly as a `yum_repository`
rather than through `percona-release setup`, so package installation does not
depend on that tool's repository discovery.

## Run

From `lab2`:

```sh
make all
```

`configure_cluster` installs the required Ansible collection, generates static
lab passwords in ignored, mode-`0600` files under `.secrets/` if they do not
already exist, and generates the PKI into `.secrets/pki/` if it is not already
there. `verify_cluster` performs service, etcd, Patroni, replication, watchdog,
SELinux and pgBackRest checks, then runs a real Npgsql primary-only read/write
test from the application VM.

Run `make configure_hostnames` in an interactive terminal if you also want
`pg1.lab2.example`, `pg2.lab2.example`, `pg3.lab2.example` and `app1.lab2.example`
in macOS `/etc/hosts`.
