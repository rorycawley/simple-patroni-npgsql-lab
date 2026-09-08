# Lab 1 VMs

Lab 1 uses three Lima VMs: `lab1-pg1`, `lab1-pg2`, and `lab1-pg3`. Each has the default allocation of 2 CPUs, 4 GiB memory, and a 20 GiB disk (6 CPUs, 12 GiB memory, and 60 GiB total).

Install Lima, Ansible, `jq`, and the .NET 10 SDK first. The VMs use Lima's
[`socket_vmnet` managed network](https://lima-vm.io/docs/config/network/vmnet/),
so install it in the root-owned location and configure Lima's sudoers file as
described by Lima. Confirm that setup with `limactl sudoers --check`.

From this directory, the whole lab is two commands:

```sh
make all      # create the VMs, configure the cluster, run every check, report
make clean    # destroy the VMs and delete every generated local file
```

`make all` builds three Rocky Linux VMs, applies the full Ansible configuration,
then runs every check and prints one summary:

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

That is a first run on a machine with nothing cached: it downloads the Rocky
image and installs PostgreSQL, Patroni, etcd, and pgBackRest on all three nodes.
Rerunning `make all` against existing VMs takes about four minutes, because VM
creation and package installation both become no-ops — the two setup phases drop
to seconds, while the checks below them take the same time either way.

The setup phases stop the run if they fail, since there is nothing to test. The
checks all run even after one fails, so a single invocation reports everything
that is broken rather than just the first thing, and the command exits non-zero
if any check failed.

`make check` runs the same checks without the setup, which is what you want when
the cluster is already up. `make` on its own prints the target list; it does not
build anything, because `all` creates VMs and injects destructive faults.

Every check after `test_connection` deliberately breaks the running cluster —
force-stopping a VM, killing PostgreSQL, freezing Patroni until the watchdog
reboots the node, or cutting a node off from etcd. Each scenario repairs what it
broke and waits for one leader and two streaming replicas before reporting
`PASS`, so they can be run in any order against a healthy cluster. Expect the
primary to move between nodes as a result.

## Running the phases individually

```sh
make create_vms
make configure_cluster
make verify_cluster
make test_connection    # acceptance criterion 1
make test_client        # the client's configured guarantees
make test_sync          # quorum commit really is synchronous
make test_failover      # acceptance criterion 2
make test_fencing       # split-brain prevention
```

`create_vms` creates missing VMs and starts existing ones. `configure_cluster`
applies the complete reusable Ansible configuration; it can also be rerun after
the primary has moved to another node. `verify_cluster` checks every service and
runs an Npgsql read-write probe. To inspect the VMs, run `./scripts/vms.sh
status`.

`destroy_vms` deletes the three VMs but keeps the generated passwords in
`.secrets/`, so the cluster can be rebuilt with the same credentials. `make
clean` is the full teardown: it does everything `destroy_vms` does and also
removes `.secrets/`, the .NET build output, and the Ansible temp directory, so
`make all` afterwards starts from scratch with fresh passwords.

`test_connection` and `test_failover` are the two acceptance-criteria checks, and
the [top-level README](../README.md#acceptance-criteria) spells out exactly what
each asserts. `test_failover` runs two fault injections in turn — force-stopping
the primary VM, then killing only the PostgreSQL postmaster on the primary — and
in both cases starts the client while the cluster still has no primary, so the
client's retry loop is what carries it to the promoted node. Run one at a time
with `make test_failover_vm` or `make test_failover_postgres`.

`make test_sync` proves the cluster replicates with quorum commit rather than
asynchronously: that Patroni has PostgreSQL configured for it, that a commit
genuinely parks in a `SyncRep` wait when no standby can confirm, and that no
acknowledged row is lost when the primary is destroyed. See
[proving replication is synchronous](../README.md#proving-replication-is-synchronous).

`make test_client` proves the client's configured guarantees rather than its
failover behaviour: that `Maximum Pool Size` is enforced, that `Timeout` and
`Command Timeout` really bound waiting, and that a commit whose acknowledgement
is lost is reported as a failure without being reissued. See
[proving the client's configured guarantees](../README.md#proving-the-clients-configured-guarantees).

`make test_fencing` covers the two split-brain paths instead: freezing Patroni
with `SIGSTOP`, where softdog resets the node because nothing in userspace can
take it out of service, and cutting Patroni off from etcd, where Patroni is still
alive and demotes itself without the watchdog firing. Run one at a time with
`make test_fencing_patroni` or `make test_fencing_etcd`. Both are documented
under [split-brain prevention](../README.md#split-brain-prevention-and-where-softdog-fits).
`make test_faults` runs all four fault-injection scenarios in one go.

The script uses the pinned Rocky Linux 9.8 image in `rocky-9.8.yaml`, disables host-directory mounts, and attaches every VM to Lima's managed `lima:shared` network. That network provides addresses reachable from both macOS and the other VMs, which etcd and PostgreSQL replication require.

On creation, the script maintains a marked block in `/etc/hosts` for these hostnames when non-interactive `sudo` is available. Otherwise it asks you to run `make configure_hostnames` from an interactive terminal:

| VM | Hostname | PostgreSQL address |
| --- | --- | --- |
| `lab1-pg1` | `pg1.lab.example` | `pg1.lab.example:5432` |
| `lab1-pg2` | `pg2.lab.example` | `pg2.lab.example:5432` |
| `lab1-pg3` | `pg3.lab.example` | `pg3.lab.example:5432` |

It also generates an uncommitted `.env` file with those hostnames and their current shared-network IP addresses. After creating the VMs, load it and connect using a hostname (once PostgreSQL is installed and running):

```sh
source .env
psql "host=$PG1_HOST port=$PGPORT dbname=appdb user=app_runtime sslmode=disable"
```

`destroy_vms` removes the marked `/etc/hosts` block and the generated `.env` file. Editing `/etc/hosts` needs `sudo`, so run it from an interactive terminal that can prompt for your password. Override the resources or template when needed:

```sh
VM_CPUS=4 VM_MEMORY_GIB=8 VM_DISK_GIB=30 make create_vms
```

Lima's `limactl` is used directly because it is Lima's supported lifecycle interface. Terraform is not used for this local VM lifecycle.

## Configure the PostgreSQL nodes

Use the [Ansible playbook](ansible/README.md) to apply the same Percona
PostgreSQL 18, Patroni, etcd, pgBackRest, watchdog, and default-deny firewall
configuration to all three VMs.

The unattended workflow uses the generated shared-network IP addresses. If you
also want the friendly names on macOS, run `make configure_hostnames` separately
from an interactive terminal so `sudo` can update `/etc/hosts`.

When finished:

```sh
make destroy_vms
```
