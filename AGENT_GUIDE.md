# AGENT_GUIDE.md — Automated DB Backup & Cloud Sync

An executable playbook for AI coding agents (Cursor, Claude Code, Windsurf) and
humans acting like one. Every phase states what to run, what to read back, and
when to **stop** instead of improvising.

> **Rule zero:** never paste a credential into a tracked file. If a step seems to
> need one, it needs an untracked `.env` or an environment variable instead.

---

## Certification scope & portability

- **Runtime and IaC are cloud-agnostic.** Docker Compose runs the pipeline on any
  host; `terraform/` targets OCI but every module documents its AWS/GCP
  equivalent; the bucket is consumed through an **S3-compatible** endpoint, so
  rclone speaks equally to OCI Object Storage, AWS S3, Google Cloud Storage
  (S3 interop), Cloudflare R2 and MinIO.
- **Final production verification and testing certification are performed
  strictly on Oracle Cloud Infrastructure (OCI), using OCI trial credits.**
  OCI is the validated environment: it is where the host is provisioned with
  OpenTofu, where the backup cycles run, and where the restore drill is signed
  off. AWS, GCP, R2 and MinIO are **documented ports, not certified targets** —
  they carry no test evidence in this repository. Never describe this project as
  "AWS-verified" or "GCP-verified".
- **Current status:** the local stages are built and statically validated
  (compose config, `tofu validate`); the live OCI drill is **pending**. Verify
  before claiming a certification — see the phase map.

| Project stage | Playbook phases | State |
| ------------- | --------------- | ----- |
| Stage 1 — scaffold, compose, scripts | 0, 1 | ✅ delivered |
| Stage 2 — OpenTofu modules (`tofu validate` clean) | — | ✅ code only, never applied |
| Stage 3 — this guide + `MANUAL_PREREQS.md` | — | ✅ delivered |
| Stage 4 — local cycle, retention, restore drill | 2, 3, 4, 5 | ⬜ pending |
| Stage 5 — live OCI deploy, bucket sync | 6, 7 | ⬜ pending |
| Stage 6 — zero-leak audit, cost model, release | 8 | ⬜ pending |

---

## Hard limits for an agent

- Never commit `.env`, `terraform.tfvars`, `*.tfstate`, `keys/`, `rclone.conf`,
  archives (`*.tar.gz`, `*.dump`) — the `.gitignore` blocks them, but a blocked
  file is still a leaked file if it was ever copied into the tree.
- Never run `docker compose down -v` against a database you were asked to keep:
  `-v` deletes the `pgdata` volume.
- Never point a dump at the live database with `pg_restore`. Restores go to a
  **new** database name such as `<db>_restored`.
- Never report a sync as working from the upload log alone — run
  `rclone check` (the script already does) and read its result.
- Never claim a live OCI verification you did not run. Passwords, keys and
  namespaces are operator inputs; if they are missing, stop and say so.

---

## Phase 0 — Preflight

```bash
docker version --format '{{.Server.Version}}'   # engine must answer
docker compose version
git status --porcelain                          # must be empty
git remote -v                                   # origin = this repo
test -f .env && echo "local .env present (untracked)" || echo "no .env yet"
```

**Stop if:** the engine does not answer, the tree is dirty in files you did not
create, or `origin` points somewhere unexpected.

---

## Phase 1 — Verify the scaffold

```bash
docker compose --env-file .env.example -f docker/docker-compose.yml config --quiet
docker compose --env-file .env.example -f docker/docker-compose.yml config --services
for s in scripts/*.sh; do bash -n "$s"; done
```

Expected: exit 0 and services `postgres`, `backup-runner`.

**Stop if:** `config` fails, or a script has a syntax error. Do not “fix” it by
editing the compose file to match a stale `.env`.

---

## Phase 2 — Initialise PostgreSQL and the runner locally

```bash
cp .env.example .env
# set a real password and a short interval for the drill
sed -i "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$(openssl rand -hex 16)/" .env   # throwaway value
sed -i 's/^BACKUP_INTERVAL_SECONDS=.*/BACKUP_INTERVAL_SECONDS=60/' .env

docker compose --env-file .env -f docker/docker-compose.yml up -d --build
docker compose -f docker/docker-compose.yml ps
docker compose -f docker/docker-compose.yml logs -f backup-runner
```

Read back, in this order:

1. `database postgres:5432 reachable after N attempt(s)`
2. `[backup] archive written: appdb_<ts>.tar.gz (…)`
3. `[rotate] rotation complete: …`
4. `[sync] local sync complete: …`

Confirm the seed data exists (the backup is worthless if the source is empty):

```bash
docker exec -it cg-db psql -U appuser -d appdb -c 'select count(*) from app.customers;'
# expect 25
docker exec -it cg-db psql -U appuser -d appdb -c 'select count(*) from app.events;'
# expect 1000
```

**Stop if:** `ps` shows `Restarting`, the row counts are 0, or no archive appears
within two intervals. Read `logs backup-runner` before changing anything.

---

## Phase 3 — Manual backup run and compression check

Run a cycle by hand, exactly as the scheduler would:

```bash
docker exec -it cg-backup-runner /usr/local/bin/backup.sh
```

Verify the artefact, not the log line:

```bash
docker exec cg-backup-runner ls -la /backups
ARCHIVE=$(docker exec cg-backup-runner sh -c 'ls -1 /backups/*.tar.gz | tail -1')
echo "$ARCHIVE"

# 1. archive contents
docker exec cg-backup-runner tar -tzf "$ARCHIVE"
# expect: <db>_<ts>.dump and manifest.json

# 2. manifest facts
docker exec cg-backup-runner tar -xzOf "$ARCHIVE" manifest.json

# 3. integrity (sidecar checksum written by backup.sh)
docker exec cg-backup-runner sh -c 'cd /backups && sha256sum -c *.sha256'

# 4. compression actually happened
docker exec cg-backup-runner sh -c 'cd /backups && ls -l *.tar.gz*'

# 5. when BACKUP_ENCRYPTION=openssl: ciphertext must not be readable as gzip
A=$(docker exec cg-backup-runner sh -c 'ls -1 /backups/*.enc | head -1')
docker exec cg-backup-runner sh -c "tar -tzf $A" && echo 'LEAK: plaintext present' || echo 'ok: encrypted'
docker exec cg-backup-runner sh -c "head -c 9 $A"   # expect: Salted__
```

A dump of the seeded database is a few hundred KB; the `.tar.gz` must be smaller
than the `dump_bytes` reported in the manifest (zlib inside `pg_dump --format=custom`
plus the gzip layer).

**Stop if:** the archive is < 4 KB, the manifest reports `dump_bytes: 0`, or
`sha256sum -c` fails. That is a broken backup, not a broken drill.

---

## Phase 4 — Retention rotation drill

Retention needs archives of different ages. Shorten the policy and force cycles:

```bash
# policy: prune anything older than "now", but always keep the 2 newest
BACKUP_RETENTION_DAYS=0 BACKUP_KEEP_MINIMUM=2 \
  docker compose --env-file .env -f docker/docker-compose.yml up -d

docker exec -it cg-backup-runner /usr/local/bin/backup.sh   # 2nd archive
docker exec -it cg-backup-runner /usr/local/bin/backup.sh   # 3rd archive
docker exec -it cg-backup-runner /usr/local/bin/rotate.sh

docker exec cg-backup-runner ls -1 /backups/*.tar.gz | wc -l
# expect exactly 2 — the minimum keep count wins over the age rule
```

Then confirm the rule both ways: with `BACKUP_KEEP_MINIMUM=3`, the third archive
must survive; with `BACKUP_RETENTION_DAYS=7`, nothing is deleted at all.

```bash
docker compose -f docker/docker-compose.yml logs backup-runner | grep rotate
```

**Stop if:** rotation deletes below `BACKUP_KEEP_MINIMUM`, or a `.tar.gz`
disappears while its `.sha256` remains (that means a partial delete).

---

## Phase 5 — Sync verification

### 5a. Local (mock cloud) mode — no credentials required

```bash
docker exec cg-backup-runner ls -la /backups/mock-cloud-sync
docker exec cg-backup-runner sh -c 'cmp /backups/$(ls -1 /backups | grep tar.gz | head -1) /backups/mock-cloud-sync/$(ls -1 /backups | grep tar.gz | head -1) && echo identical'
```

### 5b. rclone mode — offline rehearsal with a local rclone remote

Proves the rclone path (arguments, `--checksum`, `--one-way` check) before any
cloud account exists:

```bash
cat > /tmp/rclone.drill.conf <<'EOF'
[mock]
type = local
EOF

docker cp /tmp/rclone.drill.conf cg-backup-runner:/tmp/rclone.drill.conf
docker exec -e BACKUP_SYNC_MODE=rclone -e RCLONE_REMOTE=mock \
  -e RCLONE_DEST_PATH=/tmp/mock-bucket -e RCLONE_CONFIG=/tmp/rclone.drill.conf \
  cg-backup-runner /usr/local/bin/sync.sh
# expect: "rclone sync verified against mock:/tmp/mock-bucket"
```

### 5c. Real OCI Object Storage

Only with operator credentials (`MANUAL_PREREQS.md` steps 5–8). Never paste keys
into a tracked file; mount the filled `rclone.conf` from outside the repository,
then:

```bash
docker compose -f docker/docker-compose.yml logs --tail=40 backup-runner | grep sync
# expect: rclone sync verified against oci-backups:cloudguard/db-backups
```

**Stop if:** `rclone check` reports differences, or `403`/`401` appears — that is
an endpoint/credential problem, not a code problem.

### 5d. Failure alerting

Prove the hook fires and that it never changes the outcome:

```bash
# log-only (no webhook configured)
docker exec -e PGPASSWORD=wrong cg-backup-runner /usr/local/bin/backup.sh
# expect: "[alert] level=critical stage=backup backup cycle aborted with exit 1"

# with a webhook, then with a dead one
docker exec -e PGPASSWORD=wrong -e ALERT_WEBHOOK_URL=http://host.docker.internal:8899/alert \
  cg-backup-runner /usr/local/bin/backup.sh
docker exec -e PGPASSWORD=wrong -e ALERT_WEBHOOK_URL=http://127.0.0.1:9/dead \
  cg-backup-runner /usr/local/bin/backup.sh
# expect: "webhook delivery failed — log-only", exit code still 1
```

**Stop if:** a dead webhook changes the exit code, blocks for longer than
`ALERT_TIMEOUT_SECONDS`, or the alert fires more than once per failed cycle.

---

## Phase 6 — Restore drill (`pg_restore`)

Never restore into the live database. Create a scratch one:

> On Windows, Git Bash rewrites `/backups` and `/tmp` inside `docker exec`
> arguments into `C:/…` paths. Prefix the command with
> `MSYS_NO_PATHCONV=1` (and expect `docker cp` to refuse
> container-to-container copies — route the file through the host, as below).

```bash
# 1. pick and fetch an archive
ARCHIVE=$(docker exec cg-backup-runner sh -c 'ls -1 /backups/*.tar.gz | tail -1')
docker cp "cg-backup-runner:${ARCHIVE}" /tmp/
docker cp "cg-backup-runner:${ARCHIVE}.sha256" /tmp/

# 2. verify the transfer before trusting it
cd /tmp && sha256sum -c "$(basename "$ARCHIVE").sha256"

# 3. unpack
mkdir -p /tmp/restore && tar -xzf "/tmp/$(basename "$ARCHIVE")" -C /tmp/restore
ls -l /tmp/restore

# 4. create the scratch database
docker exec -it cg-db psql -U appuser -d appdb -c 'create database appdb_restored;'

# 5. restore
DUMP=$(ls -1 /tmp/restore/*.dump | head -1)
docker cp "$DUMP" cg-db:/tmp/restore.dump
docker exec -it cg-db pg_restore --no-owner --no-privileges \
  -U appuser -d appdb_restored /tmp/restore.dump

# 6. prove the data came back
docker exec -it cg-db psql -U appuser -d appdb_restored \
  -c 'select count(*) from app.customers;' \
  -c 'select count(*) from app.events;' \
  -c 'select max(occurred_at) from app.events;'
```

Expected: 25 customers, 1000 events — identical to the source counts you recorded
in Phase 2.

```bash
# 7. clean up the scratch database and extracted files
docker exec cg-db psql -U appuser -d appdb -c 'drop database appdb_restored;'
docker exec cg-db rm -f /tmp/restore.dump
rm -rf /tmp/restore "/tmp/$(basename "$ARCHIVE")" "/tmp/$(basename "$ARCHIVE").sha256"
```

**Stop if:** `pg_restore` complains about missing roles/owners (the dump was taken
without `--no-owner`), the counts differ from the source, or the restore requires
`--clean` (that means the target was not empty — use a fresh database name).

---

## Phase 7 — Provision the host (OCI, the certified target)

One command from the repository root (init → fmt → validate → plan → apply →
outputs), or the same steps by hand:

```bash
make deploy-oci

# equivalent, step by step
cd terraform
cp terraform.tfvars.example terraform.tfvars   # operator fills: tenancy, compartment, ssh key
tofu init && tofu fmt -recursive && tofu validate
tofu plan
tofu apply
tofu output connection_endpoints
```

Then deploy the stack on the host:

```bash
ssh ubuntu@$(tofu output -raw instance_public_ip) \
  'git clone https://github.com/kaveh8866/Automated-DB-Backup-Cloud-Sync.git &&
   cd Automated-DB-Backup-Cloud-Sync &&
   cp .env.example .env && docker compose --env-file .env -f docker/docker-compose.yml up -d --build'
```

Lock down SSH first: `ssh_allowed_cidr` should be your own egress IP
(`curl -s https://ifconfig.me`), not `0.0.0.0/0`.

**Stop if:** the plan wants to open any port other than 22, or creates resources
outside the project compartment.

---

## Phase 8 — Zero-leak audit and release

```bash
git status --porcelain                                   # empty
git ls-files | grep -E '\.env$|\.pem$|\.key$|\.tfstate|\.tfvars$|\.tar\.gz$|\.dump$'
find . -name '*.tar.gz' -o -name '*.dump' -o -name '*.pem' -o -name '*.key'
docker exec cg-backup-runner sh -c 'cat /backups/*/manifest.json' 2>/dev/null | head
```

Record the four measured facts for the report: archive count, retention result,
restore row counts, sync verification line.

---

## Troubleshooting

| Symptom | Cause | Fix |
| ------- | ----- | --- |
| Runner restarts in a loop | `pg_isready` never succeeded | check `docker logs cg-db` and the `pgdata` volume permissions |
| `pg_dump: connection … failed` | password/db mismatch | the runner must use the same values the cluster was initialised with; recreate `pgdata` if you changed them after init |
| Archive is a few KB | dump aborted or DB empty | read `[backup]` lines above the archive line; re-check the seed counts |
| `no archives present, nothing to rotate` | first cycle not finished | wait one interval or run `backup.sh` by hand |
| `missing rclone config at /etc/rclone/rclone.conf` | only the `.example` is mounted | copy the template to `rclone.conf` outside Git and mount it |
| `403` from the S3 endpoint | API signing key used instead of a Customer Secret Key | create a Customer Secret Key (MANUAL_PREREQS step 6) |
| `sha256sum -c` fails after `docker cp` | truncated transfer | re-copy the archive; never restore from a failed checksum |
| `pg_restore: role does not exist` | dump taken without `--no-owner` | always use `scripts/backup.sh` |
| `ls: cannot access 'C:/Users/…/backups'` | Git Bash path conversion on Windows | prefix with `MSYS_NO_PATHCONV=1` |
| `copying between containers is not supported` | `docker cp` container→container | copy to the host first, then into the target container |
| `tofu apply` → out of host capacity | A1 capacity in that AD | try another `availability_domain`, then pin it in `terraform.tfvars` |

---

## Report template

```markdown
## Stage <n> report
- Compose: config valid (exit 0), services postgres + backup-runner
- Cycle: <n> archives, sizes <…>, manifest dump_bytes=<…>
- Retention: <n> removed / <n> retained (policy <days>d, keep>= <k>)
- Restore: appdb_restored → customers=<n>, events=<n>
- Sync: mode=<local|rclone>, verified=<yes/no>, target=<…>
- Zero-leak: findings=<n>, ignored=<n>, tracked files=<n>
- Portability: PORTABLE_CERTIFIED <score>/100 (<passed>/5 checks)
- Certification target: OCI (trial credits) — AWS/GCP are ports, not certified
```
