# Lab 1 VMs

Lab 1 uses three Lima VMs: `lab1-pg1`, `lab1-pg2`, and `lab1-pg3`. Each has the default allocation of 2 CPUs, 4 GiB memory, and a 20 GiB disk (6 CPUs, 12 GiB memory, and 60 GiB total).

Install Lima on macOS with `brew install lima`, then run these commands from this directory:

```sh
make help
make create_vms
make destroy_vms
```

`create_vms` is idempotent: it creates missing VMs and starts existing ones. `destroy_vms` permanently deletes only the three Lab 1 VMs and their disks. To inspect the VMs, run `./scripts/vms.sh status`.

The script uses the pinned Rocky Linux 9.8 image in `rocky-9.8.yaml` and disables host-directory mounts. Override the resources or template when needed:

```sh
VM_CPUS=4 VM_MEMORY_GIB=8 VM_DISK_GIB=30 make create_vms
```

Lima's `limactl` is used directly because it is Lima's supported lifecycle interface. Terraform is not used for this local VM lifecycle.
