.PHONY: help create_vms destroy_vms

help:
	@printf '%s\n' 'Targets:'
	@printf '%s\n' '  create_vms   Create or start the three Rocky Linux 9.8 VMs'
	@printf '%s\n' '  destroy_vms  Permanently delete the three Lab 1 VMs'

create_vms:
	./scripts/vms.sh create

destroy_vms:
	./scripts/vms.sh destroy
