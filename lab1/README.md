# Lab 1 VMs

Lab 1 uses three Lima VMs: `lab1-pg1`, `lab1-pg2`, and `lab1-pg3`. Each has the default allocation of 2 CPUs, 4 GiB memory, and a 20 GiB disk (6 CPUs, 12 GiB memory, and 60 GiB total).

Install Lima, Ansible, `jq`, and the .NET 10 SDK first. The VMs use Lima's
[`socket_vmnet` managed network](https://lima-vm.io/docs/config/network/vmnet/),
so install it in the root-owned location and configure Lima's sudoers file as
described by Lima. Confirm that setup with `limactl sudoers --check`.

Then run these commands from this directory:

```sh
make help
make create_vms
make configure_cluster
make verify_cluster
make test_failover
```

`create_vms` creates missing VMs and starts existing ones. `configure_cluster`
applies the complete reusable Ansible configuration; it can also be rerun after
the primary has moved to another node. `verify_cluster` checks every service and
runs an Npgsql read-write probe. `test_failover` force-stops the current primary
VM, verifies Npgsql writes through its promoted replacement, and starts the old
VM again. `destroy_vms` permanently deletes only the three Lab 1 VMs and their
disks. To inspect the VMs, run `./scripts/vms.sh status`.

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

`destroy_vms` removes the marked `/etc/hosts` block and the generated `.env` file. Override the resources or template when needed:

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
