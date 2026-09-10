# Lab 3 build plan

How Lab 3 gets built, and why in this order. Every phase names the acceptance
criterion it serves; anything that serves none does not belong here.

The criteria are in [README.md](README.md): **AC-1** a backup history exists,
**AC-2** the repository outlives any node, **AC-3** the chain and its retention
are real, **AC-4** a dump proves readability, **AC-5** everything is encrypted,
**AC-6** archiving survives a promotion and the window is measured.

## What we borrow

| From | How it is used here |
| --- | --- |
| [Lab 2](../lab2/README.md)'s CA and `generate-pki.sh` | One more `sign_cert` call for a `minio` identity. The `.spec` reissue mechanism already handles a changed SAN. **No second trust root** — the decision recorded in [`lab2/PLAN.md`](../lab2/PLAN.md#carried-into-lab-3) |
| The sibling lab's MinIO certificate spec | It already carries `DNS:host.lima.internal` and `IP:192.168.105.1`, the macOS side of Lima's shared network, which is what lets guests reach an object store on the host |
| Lab 2's Ansible layout and `run-all.sh` harness | Unchanged. New checks are new phases in the same report |
| Lab 2's four-VM topology | Unchanged. MinIO runs on the control machine, not a fifth VM |
| Nothing for backup scheduling | **All backup-job work is new.** Labs 1 and 2 never take a backup |

## Verified before starting

Lab 2's plan proved its assumptions before any code was written, because an
unverified assumption about a storage or TLS stack has already cost this series
once. The two questions that determined the shape of this plan are settled;
the rest are documented and get proven in the phase that depends on them.

| Question | Answer | How |
| --- | --- | --- |
| Can encryption be added to an **existing** stanza? | **No, and it fails hard.** `stanza-upgrade` with a cipher configured against a plaintext stanza exits **95** with `CryptoError: cipher header invalid`. The cipher is fixed at `stanza-create`; there is no in-place conversion | **measured** on Lab 1, pgBackRest 2.59.0, against an isolated repository under `/tmp` |
| Does Patroni's REST `/leader` return 200 on the leader and 503 elsewhere? | **Yes.** Confirmed against a live three-node cluster: `200` on the leader, `503` on both standbys, cross-checked against `patronictl` | **measured** on Lab 1 |
| Does that endpoint need a client certificate here? | **Yes.** `verify_client: required` means "client certificates are required for **all** REST API calls" — `optional` would check them only for `PUT`/`POST`/`PATCH`/`DELETE`. Lab 2 sets `required` | **documented**, and confirmed against `lab2`'s `patroni.yml` |
| Can the backup job present one? | **Yes, with no new machinery.** The `patroni` identity is owned by `postgres` with a `0600` key, and pgBackRest already runs as `postgres` | read from `lab2_tls_identities` and the unit file |
| What does `pgbackrest expire` do to incrementals under an expired full? | *"When a full backup expires, all differential and incremental backups associated with the full backup will also expire."* | **documented** — still asserted by AC-3, because an expected result is not a demonstrated one |
| Does pgBackRest's S3 support work against MinIO with a **private** CA, and does it need path-style addressing? | **Yes and yes.** `repo1-storage-ca-file` pointed at the lab CA works (`repo-ls` exits 0). `repo1-s3-uri-style=host` fails with `unable to get address for 'lab3-backups.192.168.105.1'`, so path-style is not a preference | **measured** in P1, from a node |
| If the CA file is missing, does pgBackRest fall back to an unverified connection? | **No — it fails closed**, with `unable to verify certificate presented by ...: unable to get local issuer certificate`. A misconfigured CA cannot silently downgrade the transport | **measured** in P1 |
| Can MinIO run on the control machine and be reached from the guests? | **Yes**, at the Lima gateway. But **not on port 9000** — the sibling lab `../percona-patroni-npgsql-lab` already runs a MinIO there, so this lab uses **9100** | **measured** in P1 |

### Two findings that change what gets built

**P3 is a script, not a redesign.** The gate is `curl` presenting the node's
existing `patroni` certificate. That held.

> The rest of this prediction did not, and is left standing rather than quietly
> rewritten. It said: *"a `200`/`503` distinction is unambiguous, and a curl that
> fails is distinguishable from one that returns `503` — which is precisely 'I
> could not tell' versus 'I am not the leader'."*
>
> **Patroni also answers `503` for an unknown path**, so `/leader` cannot carry
> the distinction after all. Measured in P3, and it is the single most useful
> thing this lab has found — see
> [What the build changed](#what-the-build-changed).

**`pgbackrest info` exits 0 on a repository it cannot read.** Discovered while
answering the first question: with the wrong cipher configured, `info` printed
`status: error (other)` and a `CryptoError`, and still exited **0**. Any check
that shells out to `info` and tests `$?` will call an unreadable repository
healthy. Every criterion here therefore asserts parsed output, never an exit
status — see AC-1 and AC-3 in [README.md](README.md#acceptance-criteria).

### The leader gate is needed by more than the backup job

`pgbackrest check` only works on the node that is currently primary. On a standby
it fails with `[027]: primary database not found`, because each node's
configuration knows only its own `pg1-path` and there is no `pg1-host` pointing
anywhere else. `verify.yml` already delegates its check to the current primary
for this reason.

So the gate P3 builds is not a backup-job detail — `check`, `expire` and the dump
job all need the same answer to "am I the leader?". It should be one mechanism
used by all of them rather than three implementations that can disagree, and its
failure mode is R1 for every one of them.

## Phases

Each phase leaves the lab green before the next begins, so a regression is
always attributable to the phase that introduced it.

**Green does not mean `make all` every time.** The inherited fault-injection
suite — quorum commit, both failover scenarios, both fencing scenarios — exercises
PostgreSQL and Patroni semantics that most phases here cannot touch, and costs
about six minutes a run. Running it after a change it could not possibly affect is
ceremony, not evidence.

| Phase | What to run | Why |
| --- | --- | --- |
| **P0** | `make all` | The one full run. It establishes the baseline that a later regression is attributed against — without it, a P2 failure is indistinguishable from a bad fork |
| **P2** | `make all` | It rewrites `archive_command`, which runs on the primary's commit path. A repository that blocks or hangs is an availability regression, so the whole suite earns its time here |
| **P3** | `configure_cluster`, `verify_cluster`, its own checks, **plus `test_failover_vm`** | The leader gate must survive a promotion — AC-1 requires the *new* leader to take the next backup, and only a failover shows that |
| **P1, P4, P5, P6** | `configure_cluster`, `verify_cluster`, plus that phase's own checks | None of them touch the write path. An object store, a retention policy and a dump job cannot break failover |

### P0 — Fork Lab 2 — **done**

> 15 of 15 checks passed from nothing in **14m02s**, matching Lab 2. The baseline
> exists. Two things the run established beyond the rename: the runbook lint and
> all three of its drills pass against an encrypted, TLS cluster, and the
> `test-runbook.sh` copy Lab 2 never executed is now proven by Lab 3's.


**What.** `lab3/` becomes a working copy of Lab 2, renamed, with no behaviour
change.
**How.** Copy `lab2/`, rename `lab2-*` VMs and identifiers to `lab3-*`, keep the
local pgBackRest repository exactly as it is.
**Serves.** Nothing directly. It establishes the baseline every later phase is
measured against.
**Done when.** `make all` in `lab3/` is green from scratch, matching Lab 2 — the
one time the full suite runs for its own sake rather than to test a change.

What this phase can actually break is narrow: the rename touches VM and disk
names, the cluster and stanza name, `/etc/lab3/*`, the `LAB3_*` environment
variables and the client assembly. Those fail in `create_vms`,
`configure_cluster`, `verify_cluster` and the encryption checks — early and
loudly. The fault-injection suite that follows is here for the baseline, not
because a rename could plausibly break failover.

### P1 — MinIO, with an identity from the existing CA — **done**

> `make test_minio` passes: all three database nodes reach the store over TLS
> verified against the lab CA, are refused without it, are refused in plaintext,
> and get `403` rather than a listing anonymously. The scoped `lab3-pgbackrest`
> credential authenticates, can list its bucket, and **cannot create another** —
> so least privilege is demonstrated by a denial rather than asserted.
>
> Three things the phase changed from what was planned:
>
> - **Port 9100, not 9000.** The sibling lab already runs a MinIO on 9000. A lab
>   that cannot be built while another is running is not standalone.
> - **The store lives in `.minio/`, outside `.secrets/`.** `make clean` wipes
>   `.secrets/`, and Lab 4's premise is that the cluster dies while the backups
>   live. Deleting the repository is `make minio_destroy`, never `clean`.
> - **`generate-secrets.sh` now adds missing keys instead of writing the file
>   once.** Adding a credential must not rotate the superuser and replication
>   passwords a running cluster is already using.
>
> The application host is deliberately **not** tested against the store: it runs
> no pgBackRest, holds its CA elsewhere, and has no business reaching the
> backups.


**What.** An object store on the control machine that the guests can reach over
verified TLS.
**How.** Run MinIO on the host, reached at the Lima shared-network gateway. Add a
`minio` `.spec` to `generate-pki.sh` carrying `DNS:host.lima.internal` and the
gateway IP. Create the `lab3-backups` bucket and a credential for the nodes.
Ship the nodes `ca.crt` only — MinIO's key never leaves the control machine, the
same rule the CA key already follows.
**Serves.** AC-2, AC-5 (transport half).
**Done when.** Every node lists the bucket over TLS with verification enabled,
and a plaintext attempt is refused.

### P2 — Move the repository off-host, encrypted from the first byte — **done**

> The full suite passed **17 of 17** afterwards, which is what this phase's time
> was spent on: relocating `archive_command` to a remote store did not cost
> availability. The repository is encrypted from its first byte — the raw object
> in the bucket begins `Salted__`, and reading it with `--repo1-cipher-type=none`
> fails with `FormatError`.


**What.** pgBackRest stops writing to `/var/lib/pgbackrest` and starts writing to
MinIO, encrypted.
**How.** Replace `repo1-path` with `repo1-type=s3`, the endpoint, bucket,
`repo1-s3-uri-style`, and `repo1-storage-ca-file` pointing at the lab CA. Set
`repo1-cipher-type=aes-256-cbc` and `repo1-cipher-pass` **before**
`stanza-create`, because the cipher is fixed when the stanza is created. All
three nodes get the configuration and the credential, because `archive_command`
runs wherever the primary currently is.
**Serves.** AC-2, AC-5, and the precondition for AC-6.
**Done when.** `pgbackrest check` passes **on the leader**, `repo-ls` succeeds
from **all three** nodes, WAL segments appear under the `pgbackrest/` prefix, and
nothing new is written to the local path.

> That criterion originally read "`check` passes from all three nodes", which is
> impossible: `check` inspects the primary and fails on a standby with
> `[027] primary database not found`. Corrected rather than quietly dropped —
> the per-node property that actually matters is that every node can *reach* the
> repository, because `archive_command` runs wherever the primary currently is.

> This is not a migration. `make all` always builds from empty, so the stanza is
> created against MinIO at first boot rather than converted from a local one.

### P3 — Scheduled backups, taken by the leader alone — **done**

> `make test_backup` passes. The timers produce backups unprompted; running the
> job on all three nodes adds exactly one; both standbys decline without
> touching the repository. **The gate had to be redesigned mid-phase** — see
> [What the build changed](#what-the-build-changed).


**What.** The thing that does not exist anywhere in this series yet: a job that
takes a backup.
**How.** A systemd timer on all three nodes, running a wrapper that asks Patroni
whether this node holds the leader key and exits quietly if not. Full and
incremental on a lab-compressed cycle, so one `make all` run observes a real
chain rather than a single backup.

The gate must distinguish **"I am not the leader"** from **"I could not tell"**.
The first is a quiet exit; the second is an error, or R1 below happens.
**Serves.** AC-1.
**Done when.** `pgbackrest info` shows a full plus at least two incrementals, and
across a cycle exactly one node produced them.

### P4 — Retention, and the expiry cascade — **done**

> `make test_chain` passes first time. A full plus two incrementals, then two
> more fulls: the oldest full expired and **took both its incrementals with
> it**, the two newest were retained, `verify` passed before and after, and
> nothing `info` lists is missing from the repository.


**What.** `repo1-retention-full=2` actually running, for the first time in this
series.
**How.** Take enough fulls to force an expire, then assert what went with it.
**Serves.** AC-3.
**Done when.** Expiring a full also expires the differentials and incrementals
that depend on it, `pgbackrest verify` passes afterwards, and `backup.info`
references nothing that is no longer present.

### P5 — Logical dumps, separately encrypted — **done**

> `make test_dump` passes. A dump is taken by the leader alone, lands under
> `dumps/` where pgBackRest's expire cannot see it, is `Salted__` rather than
> `PGDMP` when read straight from the bucket, and **reloads into a scratch
> database with a row count matching the source** — which is the whole point of
> AC-4. Its own retention keeps three.
>
> **Where it runs was a decision, not a default:** the leader, gated like the
> backup job. A standby would keep the read load off the primary, but a long
> dump there can be cancelled mid-run by a recovery conflict, and the fix
> (`hot_standby_feedback = on`) moves the cost back to the primary as bloat. The
> database here is small, and a verification pass that vanishes under load is
> the one thing this job must not be.
>
> Two things had to be built that the plan did not anticipate — see
> [What the build changed](#what-the-build-changed).


**What.** A scheduled `pg_dump` of `appdb`, under its own prefix, under its own
passphrase.
**How.** Same leader gate as P3. Encrypt client-side **before** upload —
`repo1-cipher-pass` protects only what pgBackRest writes, and the `dumps/` prefix
sits outside `repo1-path` deliberately so pgBackRest's `expire` can never reap
it. Its retention is therefore this lab's own job, not pgBackRest's.

Decide and record where the dump runs: on the primary it competes with the
application; on a standby a recovery conflict can cancel it mid-dump unless
`hot_standby_feedback = on`, which moves the cost back to the primary as bloat.
Both are defensible. Choosing silently is not.
**Serves.** AC-4, AC-5 (the half that is easy to miss).
**Done when.** A dump completes, is unreadable straight from the bucket, and
reloads into a scratch database.

### P6 — Verification

**What.** The checks that turn all of the above into acceptance criteria.
**How.** New scripts wired into `run-all.sh` in the existing style — each repairs
what it broke and leaves a settled cluster:

| Target | Asserts |
| --- | --- |
| `make test_repository` | AC-2 — every object is on MinIO; destroying a node leaves the repository complete |
| `make test_backup` | AC-1 — a history exists, and exactly one node per cycle produced it |
| `make test_chain` | AC-3 — `verify` passes, and expiry cascades without orphans |
| `make test_dump` | AC-4 — the dump completes and reloads |
| `make test_encryption` | AC-5 — nothing under either prefix opens without its passphrase; plaintext to MinIO is refused |
| `make test_archive` | AC-6 — promotion mid-cycle leaves no WAL gap, the new leader takes the next backup, and the recoverable window is measured |

**Serves.** Every criterion.
**Done when.** `make all` reports each of the above alongside Lab 2's checks, and
the run exits non-zero if any failed.

## Order, and why

```text
P0 fork ──► P1 MinIO ──► P2 repository off-host ──┬─► P3 scheduled backups ──► P4 retention ──► P6
                                                  │                                             (AC-1, AC-3)
                                                  ├─► P5 dumps ─────────────────────────────► P6
                                                  │                                             (AC-4)
                                                  └─────────────────────────────────────────► P6
                                                                                          (AC-2, AC-5, AC-6)
```

The repository moves **before** anything schedules a backup, so no backup is ever
taken against a location that is about to change — and because the cipher cannot
be added afterwards, the first backup this series ever takes is already encrypted
and already off-host.

Dumps come after pgBackRest rather than beside it because they are the smaller
half of the story and the easier one to get wrong quietly: with the physical
repository already encrypted, a plaintext dump beside it is a visible
inconsistency rather than an oversight nobody notices.

Verification is last as a phase but not as an activity — each earlier phase has
its own "done when", and P6 is where those become criteria that run on every
build.

## Risk

Two items qualify. A risk here is uncertain **and** silent when it happens.
Everything else that could go wrong is either a certainty — handled as a task in
the phase that causes it — or a limitation deliberately accepted and recorded in
[README.md](README.md#the-repository-is-a-single-point-of-failure).

**R1. The leader gate fails closed, and no node takes a backup.**

The backup job runs on three nodes and must produce one backup. If the gate
cannot reach Patroni — an expired client certificate, a REST endpoint that moved,
a `patronictl` that now needs a different flag — the natural implementation
returns "not leader" on all three, every node exits 0, and **nothing is backed
up, quietly and indefinitely**. Every timer reports success.

This is the same shape as the failure Lab 1's `synchronous_mode_strict` was
enabled to remove: a degradation with no error attached to it.

| Layer | Catches |
| --- | --- |
| The gate distinguishes a `503` (not the leader) from a failed request (cannot tell), and treats only the first as a quiet exit | An unreachable or moved endpoint being read as "not leader" on every node |
| AC-1 asserts a backup **exists** per cycle, not that the job exited 0 | Any path that produces zero backups, whatever its exit status |
| [Lab 5](../lab5/README.md)'s headline metric is the age of the last successful backup | The same failure in production, where no test is watching |

The first layer is not theoretical caution. `/health` returns `200` on **all
three** nodes, so a gate pointed one endpoint away from `/leader` backs up
everywhere instead of nowhere — the same class of mistake with the opposite
symptom, and equally silent.

**R2. The repository is created unencrypted, and looks perfect.**

If `repo1-cipher-pass` is absent at `stanza-create`, pgBackRest builds a working,
healthy, entirely readable repository. `check` passes, `info` looks right,
backups verify — and every object sits in the bucket in plaintext. The defect is
invisible from the database side and is discovered by whoever administers the
object store.

Mitigated by ordering rather than by checking: P2 sets the cipher before the
stanza exists, and AC-5 asserts unreadability from the bucket rather than
asserting that a setting is present in a file.

## Carried into Lab 4

[Lab 4](../lab4/README.md) destroys the VMs, their volumes **and** `.secrets/`,
then rebuilds from the repository plus supplied inputs. Three decisions here
determine whether that is possible, and all three are easier to get right now
than to discover then:

- **`repo1-cipher-pass` must not be born in `.secrets/`.** Lab 4 deletes that
  directory by design. The passphrase has to be an *input* to the build — standing
  in for a secrets manager or an offline copy — rather than something generated
  during it. The same applies to the dump passphrase, which is a second secret
  and is easy to forget precisely because it is not pgBackRest's.
- **`make clean` must not destroy the repository.** Lab 4's premise is that the
  cluster is gone and the backups are not. A teardown that removes the MinIO
  bucket alongside the VMs would make the lab unrunnable, and it is exactly the
  kind of convenience that gets added without thinking.
- **The stanza name and repository layout are recovery inputs.** They appear in
  Lab 4's inventory as things that must survive the disaster. Whatever P2 chooses
  is what Lab 4 has to be told.

## What the build changed

Written during the build, not before it.

### `/leader` cannot answer "am I the leader?"

The plan assumed it could: 200 on the leader, 503 elsewhere, and anything else
means the endpoint is unreachable. That is how the first gate was written, and
its negative control failed immediately.

**Patroni answers `503` for an unknown path as well**, on every node:

```text
                        leader   standby
/leader                  200       503
/nonexistent-endpoint    503       503      <- indistinguishable
/patroni                 200       200
/health                  200       200
```

So a renamed, moved or mistyped endpoint reads exactly like "not the leader".
Every node declines, no backup is taken, every timer reports success, and
nothing raises an error — **which is R1, arrived at by a route the risk register
did not anticipate**. R1 imagined an unreachable endpoint; a *reachable* one
answering the wrong question is worse, because it looks healthy.

The gate now reads `/patroni`, which returns 200 on every node with the role in
its body. Anything but 200 is unknown; a recognised role is a positive statement
about this node; an unrecognised role is unknown rather than a guess. Both
failure shapes have controls, and the wrong-path one is the control that would
have caught the original design.

The general lesson is worth keeping: **a status code shared by "no" and "broken"
cannot carry a decision that must distinguish them.**

### Counting backups is the wrong way to prove one was taken

`test_backup` asserted that a backup cycle increases the number of backups by
one. It failed with `-1`: taking a full triggers retention, which expired an
older full **and every incremental depending on it** in the same operation, so
the total fell while the backup succeeded.

The fix is to compare the *set of backup labels* and require exactly one
addition. The original assertion measured population where the question was
identity — and it only failed because a real retention policy was running, which
is the first time in this series that was true.

### `curl --aws-sigv4` exists on Rocky 9 and does not work

The dump job was written to upload with `curl --aws-sigv4`, on the strength of
the flag being present — curl 7.76.1 is the *first* release that has it. MinIO
rejects its signatures with `SignatureDoesNotMatch`, on `GET` and `PUT` alike.

Checking that a flag exists is not checking that a feature works, and this is the
second time in this series an unverified assumption about a client library has
cost a rebuild — .NET on macOS not implementing TLS 1.3 was the first.

The replacement is `lab3-s3`, about eighty lines of Python signing SigV4 with the
standard library. `mc` or `awscli` would each mean fetching a binary or enabling
another repository at build time, for three HTTP verbs. **pgBackRest is
unaffected** — it does its own S3 and was working from P2.

### The dump connects as `dumper`, with no password anywhere

[`SERVICE-ACCOUNTS.md`](../SERVICE-ACCOUNTS.md) defines a `dumper` role and warns
that the usual alternative is running `pg_dump` as a superuser. Honouring that
looked like it needed a new password, an `pg_hba` rule and a `.pgpass`.

It does not. `pg_hba` is first-match-wins, so one rule ahead of the general
`local all all peer`, plus a `pg_ident` map, lets the `postgres` OS user connect
as the `dumper` database role over the local socket:

```text
pg_hba:   local appdb dumper peer map=dumpmap
pg_ident: dumpmap postgres dumper
```

Verified: `select current_user, session_user` returns `dumper|dumper`. A secret
that does not exist cannot leak, and the role holds `pg_read_all_data` rather
than SELECT grants — because a dump by a role holding SELECT on today's tables
silently omits anything it cannot read, producing a backup that restores cleanly
and is incomplete.

### The application host is not tested against the object store

`test_minio` originally checked all four VMs and failed on `lab3-app1`, whose CA
is installed at a different path. The right answer was not to fix the path: the
application host runs no pgBackRest and has no business reaching the backups, so
it was removed from the check. A test that had been "fixed" here would have
quietly asserted the opposite of the intended access boundary.

## Traceability

| Criterion | Built in | Proven by |
| --- | --- | --- |
| AC-1 backup history exists | P3 | `make test_backup` |
| AC-2 repository outlives any node | P1, P2 | `make test_repository` |
| AC-3 chain and retention | P4 | `make test_chain` |
| AC-4 dump is readable | P5 | `make test_dump` |
| AC-5 everything encrypted | P1, P2, P5 | `make test_encryption` |
| AC-6 survives promotion, window measured | P2, P3 | `make test_archive` |
| No regression in Labs 1–2 | every phase | `make check` — every earlier check, unchanged |
