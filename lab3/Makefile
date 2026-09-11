.PHONY: help all check clean minio_start minio_stop minio_status minio_destroy test_minio test_repository test_backup test_chain test_dump test_encryption test_archive test_runbook test_at_rest test_pki test_in_transit test_identity test_sync create_vms configure_hostnames configure_cluster verify_cluster test_connection test_client test_failover test_failover_vm test_failover_postgres test_fencing test_fencing_patroni test_fencing_etcd test_faults destroy_vms

# `make` on its own prints this help rather than building a cluster, because
# `all` creates VMs and runs destructive fault injection.
.DEFAULT_GOAL := help

ANSIBLE_LOCAL_TEMP := /private/tmp/ansible-lab3
ANSIBLE_CONFIG := $(CURDIR)/ansible/ansible.cfg

help:
	@printf '%s\n' 'Start here:'
	@printf '%s\n' '  all          Create the VMs, configure the cluster, run every check, report'
	@printf '%s\n' '  check        Run every check against an already-configured cluster'
	@printf '%s\n' '  clean        Destroy the VMs and generated files, but KEEP the backups'
	@printf '%s\n' '               (rebuilding afterwards needs minio_destroy first -- see below)'
	@printf '%s\n' ''
	@printf '%s\n' 'Targets:'
	@printf '%s\n' '  create_vms   Create or start the four Rocky Linux 9.8 VMs'
	@printf '%s\n' '  configure_hostnames  Add the four Lab 3 aliases to macOS /etc/hosts'
	@printf '%s\n' '  configure_cluster  Install and configure the complete Patroni cluster'
	@printf '%s\n' '  verify_cluster     Verify services, quorum, replication, pgBackRest, and Npgsql'
	@printf '%s\n' '  destroy_vms  Permanently delete the four Lab 3 VMs'
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
	@printf '%s\n' '  test_runbook       RUNBOOKS.md matches this lab; drill its verified procedures'
	@printf '%s\n' ''
	@printf '%s\n' 'Backup object store (runs on this machine, not in a VM):'
	@printf '%s\n' '  minio_start        Start MinIO, create the bucket and the scoped backup user'
	@printf '%s\n' '  minio_stop         Stop it; the repository contents are kept'
	@printf '%s\n' '  minio_status       Is it running, and what does it hold?'
	@printf '%s\n' '  minio_destroy      Stop it and DELETE every backup. Not part of clean,'
	@printf '%s\n' '                     but required before rebuilding after one'
	@printf '%s\n' '  test_minio         Every node reaches it over verified TLS; plaintext refused'
	@printf '%s\n' '  test_backup        AC-1: a backup history exists, and only the leader creates it'
	@printf '%s\n' '  test_chain         AC-3: the chain verifies, and retention expires dependents'
	@printf '%s\n' '  test_dump          AC-4: the dump is readable and reloads'
	@printf '%s\n' '  test_repository    AC-2: the repository is off-host and complete'
	@printf '%s\n' '  test_encryption    AC-5: every object needs its passphrase; plaintext refused'
	@printf '%s\n' '  test_archive       AC-6: archiving survives a promotion; window measured'
	@printf '%s\n' ''
	@printf '%s\n' 'Split-brain prevention:'
	@printf '%s\n' '  test_fencing       Both split-brain scenarios below'
	@printf '%s\n' '  test_fencing_patroni     Freeze Patroni; softdog resets the node at 25s'
	@printf '%s\n' '  test_fencing_etcd        Cut off etcd; Patroni demotes itself instead'
	@printf '%s\n' '  test_faults        Every fault-injection scenario'
	@printf '%s\n' ''
	@printf '%s\n' 'Log in directly through Lima:'
	@printf '%s\n' '  limactl shell lab3-pg1'
	@printf '%s\n' '  limactl shell lab3-pg2'
	@printf '%s\n' '  limactl shell lab3-pg3'

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
	@printf '%s\n' '  the four Lab 3 VMs and their disks (all database data)'
	@printf '%s\n' '  the Lab 3 block in /etc/hosts'
	@printf '%s\n' '  .env, .secrets/ (generated passwords), client/bin, client/obj'
	@printf '%s\n' '  $(ANSIBLE_LOCAL_TEMP)'
	@printf '%s\n' ''
	@printf '%s\n' 'KEPT: the backup repository in .minio/, and the cipher passphrases'
	@printf '%s\n' '      in .recovery-inputs/. Deliberately: Lab 4 restores a destroyed'
	@printf '%s\n' '      cluster from exactly those.'
	@printf '%s\n' ''
	@printf '%s\n' 'So "make all" will now FAIL at stanza-create: a pgBackRest stanza'
	@printf '%s\n' 'belongs to one database, and the rebuild makes a different one.'
	@printf '%s\n' 'Choose:'
	@printf '%s\n' '  make minio_destroy && make all   discard the old backups, fresh lab'
	@printf '%s\n' '  restore from them instead        that is Lab 4, and is not built'

create_vms:
	./scripts/vms.sh create

configure_hostnames:
	./scripts/vms.sh hostnames

configure_cluster:
	ANSIBLE_LOCAL_TEMP=$(ANSIBLE_LOCAL_TEMP) ansible-galaxy collection install -r ./ansible/requirements.yml
	./scripts/generate-secrets.sh
	./scripts/generate-pki.sh
	# Self-contained linux-arm64 build, so the application VM needs no SDK.
	dotnet publish ./client/Lab3.Client.csproj -c Release -r linux-arm64 \
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

minio_start:
	./scripts/minio.sh start

minio_stop:
	./scripts/minio.sh stop

minio_status:
	./scripts/minio.sh status

# Deliberately NOT wired into `clean`: Lab 4's premise is that the cluster can be
# destroyed while the backups survive, so deleting the repository is a separate,
# explicit act.
minio_destroy:
	./scripts/minio.sh destroy

test_minio:
	./scripts/test-minio.sh

test_backup:
	./scripts/test-backup.sh

test_chain:
	./scripts/test-chain.sh

test_dump:
	./scripts/test-dump.sh

test_repository:
	./scripts/test-repository.sh

test_encryption:
	./scripts/test-encryption.sh

test_archive:
	./scripts/test-archive.sh

test_runbook:
	./scripts/test-runbook.sh all

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
