.PHONY: help all check clean test_at_rest test_pki test_in_transit test_identity test_sync create_vms configure_hostnames configure_cluster verify_cluster test_connection test_client test_failover test_failover_vm test_failover_postgres test_fencing test_fencing_patroni test_fencing_etcd test_faults destroy_vms

# `make` on its own prints this help rather than building a cluster, because
# `all` creates VMs and runs destructive fault injection.
.DEFAULT_GOAL := help

ANSIBLE_LOCAL_TEMP := /private/tmp/ansible-lab2
ANSIBLE_CONFIG := $(CURDIR)/ansible/ansible.cfg

help:
	@printf '%s\n' 'Start here:'
	@printf '%s\n' '  all          Create the VMs, configure the cluster, run every check, report'
	@printf '%s\n' '  check        Run every check against an already-configured cluster'
	@printf '%s\n' '  clean        Destroy the VMs and delete every generated local file'
	@printf '%s\n' ''
	@printf '%s\n' 'Targets:'
	@printf '%s\n' '  create_vms   Create or start the three Rocky Linux 9.8 VMs'
	@printf '%s\n' '  configure_hostnames  Add the three Lab 2 aliases to macOS /etc/hosts'
	@printf '%s\n' '  configure_cluster  Install and configure the complete Patroni cluster'
	@printf '%s\n' '  verify_cluster     Verify services, quorum, replication, pgBackRest, and Npgsql'
	@printf '%s\n' '  destroy_vms  Permanently delete the three Lab 2 VMs'
	@printf '%s\n' ''
	@printf '%s\n' 'Acceptance criteria:'
	@printf '%s\n' '  test_connection    Criterion 1: the client connects to the primary and queries it'
	@printf '%s\n' '  test_failover      Criterion 2: both failover scenarios below'
	@printf '%s\n' '  test_failover_vm         ... by force-stopping the primary VM'
	@printf '%s\n' '  test_failover_postgres   ... by killing PostgreSQL on the primary'
	@printf '%s\n' ''
	@printf '%s\n' 'Encryption:'
	@printf '%s\n' '  test_at_rest       Both data volumes are LUKS2 and a missing volume stops the service'
	@printf '%s\n' '  test_pki           Certificates assert the right identities; CA key stays off the guests'
	@printf '%s\n' '  test_in_transit    Every channel encrypted; plaintext and uncertificated refused'
	@printf '%s\n' '  test_identity      Verification fails closed on a wrong CA or mismatched name'
	@printf '%s\n' ''
	@printf '%s\n' 'Client guarantees:'
	@printf '%s\n' '  test_client        Pool limit, command timeout, and no blind retry'
	@printf '%s\n' '  test_sync          Quorum commit is configured, blocks, and loses nothing'
	@printf '%s\n' ''
	@printf '%s\n' 'Split-brain prevention:'
	@printf '%s\n' '  test_fencing       Both split-brain scenarios below'
	@printf '%s\n' '  test_fencing_patroni     Freeze Patroni; softdog resets the node at 25s'
	@printf '%s\n' '  test_fencing_etcd        Cut off etcd; Patroni demotes itself instead'
	@printf '%s\n' '  test_faults        Every fault-injection scenario'
	@printf '%s\n' ''
	@printf '%s\n' 'Log in directly through Lima:'
	@printf '%s\n' '  limactl shell lab2-pg1'
	@printf '%s\n' '  limactl shell lab2-pg2'
	@printf '%s\n' '  limactl shell lab2-pg3'

all:
	./scripts/run-all.sh all

check:
	./scripts/run-all.sh check

# Removes the VMs and their disks (which is where the database data lives), plus
# every file the lab generates locally: the .env, the generated passwords under
# .secrets/, the .NET build output, and the Ansible temp directory.
clean:
	./scripts/vms.sh destroy
	rm -rf $(CURDIR)/client/bin $(CURDIR)/client/obj
	rm -rf $(CURDIR)/.secrets
	rm -rf $(ANSIBLE_LOCAL_TEMP)
	@printf '%s\n' ''
	@printf '%s\n' 'Removed:'
	@printf '%s\n' '  the three Lab 2 VMs and their disks (all database data)'
	@printf '%s\n' '  the Lab 2 block in /etc/hosts'
	@printf '%s\n' '  .env, .secrets/ (generated passwords), client/bin, client/obj'
	@printf '%s\n' '  $(ANSIBLE_LOCAL_TEMP)'
	@printf '%s\n' 'Run "make all" to rebuild from scratch with fresh passwords.'

create_vms:
	./scripts/vms.sh create

configure_hostnames:
	./scripts/vms.sh hostnames

configure_cluster:
	ANSIBLE_LOCAL_TEMP=$(ANSIBLE_LOCAL_TEMP) ansible-galaxy collection install -r ./ansible/requirements.yml
	./scripts/generate-secrets.sh
	./scripts/generate-pki.sh
	# Self-contained linux-arm64 build, so the application VM needs no SDK.
	dotnet publish ./client/Lab2.Client.csproj -c Release -r linux-arm64 \
	  --self-contained true -p:PublishSingleFile=true \
	  -o ./client/publish/linux-arm64 --nologo
	ANSIBLE_CONFIG=$(ANSIBLE_CONFIG) ANSIBLE_LOCAL_TEMP=$(ANSIBLE_LOCAL_TEMP) ansible-playbook ./ansible/playbooks/site.yml

verify_cluster:
	ANSIBLE_CONFIG=$(ANSIBLE_CONFIG) ANSIBLE_LOCAL_TEMP=$(ANSIBLE_LOCAL_TEMP) ansible-playbook ./ansible/playbooks/verify.yml
	./scripts/test-npgsql.sh

test_connection:
	./scripts/test-npgsql.sh

test_client:
	./scripts/test-client.sh all

test_pki:
	./scripts/test-pki.sh

test_in_transit:
	./scripts/test-in-transit.sh

test_identity:
	./scripts/test-identity.sh

test_at_rest:
	./scripts/test-at-rest.sh all

test_sync:
	./scripts/test-sync-replication.sh all

test_failover:
	./scripts/test-failover.sh failover

test_failover_vm:
	./scripts/test-failover.sh vm

test_failover_postgres:
	./scripts/test-failover.sh postgres

test_fencing:
	./scripts/test-failover.sh fencing

test_fencing_patroni:
	./scripts/test-failover.sh patroni

test_fencing_etcd:
	./scripts/test-failover.sh etcd

test_faults:
	./scripts/test-failover.sh all

destroy_vms:
	./scripts/vms.sh destroy
