.PHONY: help create_vms configure_hostnames configure_cluster verify_cluster test_connection test_failover destroy_vms

ANSIBLE_LOCAL_TEMP := /private/tmp/ansible-lab1
ANSIBLE_CONFIG := $(CURDIR)/ansible/ansible.cfg

help:
	@printf '%s\n' 'Targets:'
	@printf '%s\n' '  create_vms   Create or start the three Rocky Linux 9.8 VMs'
	@printf '%s\n' '  configure_hostnames  Add the three Lab 1 aliases to macOS /etc/hosts'
	@printf '%s\n' '  configure_cluster  Install and configure the complete Patroni cluster'
	@printf '%s\n' '  verify_cluster     Verify services, quorum, replication, pgBackRest, and Npgsql'
	@printf '%s\n' '  test_connection    Run an Npgsql primary read-write probe'
	@printf '%s\n' '  test_failover      Stop the primary VM and verify Npgsql reaches its replacement'
	@printf '%s\n' '  destroy_vms  Permanently delete the three Lab 1 VMs'
	@printf '%s\n' ''
	@printf '%s\n' 'Log in directly through Lima:'
	@printf '%s\n' '  limactl shell lab1-pg1'
	@printf '%s\n' '  limactl shell lab1-pg2'
	@printf '%s\n' '  limactl shell lab1-pg3'

create_vms:
	./scripts/vms.sh create

configure_hostnames:
	./scripts/vms.sh hostnames

configure_cluster:
	ANSIBLE_LOCAL_TEMP=$(ANSIBLE_LOCAL_TEMP) ansible-galaxy collection install -r ./ansible/requirements.yml
	./scripts/generate-secrets.sh
	ANSIBLE_CONFIG=$(ANSIBLE_CONFIG) ANSIBLE_LOCAL_TEMP=$(ANSIBLE_LOCAL_TEMP) ansible-playbook ./ansible/playbooks/site.yml

verify_cluster:
	ANSIBLE_CONFIG=$(ANSIBLE_CONFIG) ANSIBLE_LOCAL_TEMP=$(ANSIBLE_LOCAL_TEMP) ansible-playbook ./ansible/playbooks/verify.yml
	./scripts/test-npgsql.sh

test_connection:
	./scripts/test-npgsql.sh

test_failover:
	./scripts/test-failover.sh

destroy_vms:
	./scripts/vms.sh destroy
