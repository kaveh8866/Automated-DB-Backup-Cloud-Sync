# Project 03 · Automated DB Backup & Cloud Sync

![Pipeline](https://img.shields.io/badge/pipeline-local%20drill%20certified-2EA043)
![Cloud target](https://img.shields.io/badge/certified%20target-OCI%20Free%20Tier-C74634)
![Infrastructure](https://img.shields.io/badge/IaC-cloud--agnostic%20(OpenTofu)-6E7781)
![Monthly cost](https://img.shields.io/badge/estimated%20cost-%240.00%20%2F%20month-brightgreen)
![PostgreSQL](https://img.shields.io/badge/PostgreSQL-16-4169E1?logo=postgresql&logoColor=white)
![rclone](https://img.shields.io/badge/rclone-S3--compatible-3F79AD)
![Docker Compose](https://img.shields.io/badge/Docker%20Compose-stack-2496ED?logo=docker&logoColor=white)
![OpenTofu](https://img.shields.io/badge/OpenTofu-%E2%89%A5%201.6-FFDA18)
![License](https://img.shields.io/badge/license-MIT-blue)

A scheduled, self-hosted backup pipeline for PostgreSQL — **the backup itself is
the product, not the vendor**. A runner container dumps the database on an
interval, packs the dump into a timestamped archive with a manifest and a
SHA-256 checksum, rotates old archives under a two-rule retention policy, and
pushes the survivors to an S3-compatible bucket.

> Part of the **CloudGuard** portfolio: ten projects, each one production-shaped,
> portable and provable. This one proves a backup is only real when you have
> restored from it.

---

## 📖 Overview

Backups fail in boring ways: a cron entry nobody tested, a dump that silently
wrote zero bytes, a bucket nobody can read when the host is gone. Every design
choice here exists to make a failure visible before it matters.

- **Interval-driven, not cron-driven.** A shell scheduler inside the runner loops
  on `BACKUP_INTERVAL_SECONDS`; the same image runs in Compose, systemd or a
  cloud VM with no crontab to drift.
- **Every archive is self-describing.** The `.tar.gz` carries `manifest.json`
  (database, timestamp, dump bytes, dump SHA-256, client version) beside the dump,
  plus a sidecar `.sha256` for transfer integrity.
- **Retention has two rules, not one.** Age **and** a minimum keep count, so a
  long outage can never rotate away the only copies that exist.
- **Sync is a mode, not a fork.** `local` (mock cloud target inside the archive
  volume), `rclone` (S3-compatible bucket, verified with `rclone check`), `off`.
- **Restore is documented and testable.** `pg_restore` from the archive, with the
  exact commands below — and the row counts that prove it worked.

---

## 🏗 Architecture

```text
[ PostgreSQL Database ] --> [ Automated Backup Runner        ] --> [ rclone S3 API ] --> [ OCI Object Storage ]
   pg_dump source,            (pg_dump + gzip + sha256)                                     / Cloud Bucket
   WAL-safe custom dump       archive + manifest + sidecar                                  (private, versioned)
```

```text
┌─────────────────────────────── Docker host ────────────────────────────────┐
│                                                                            │
│  ┌────────────────────┐      pg_dump (custom)   ┌────────────────────────┐  │
│  │  PostgreSQL 16      │◀───────────────────────│  backup-runner          │  │
│  │  cg-db              │   over backup-net       │  cg-backup-runner       │  │
│  │  pgdata volume      │                         │  alpine + pg_dump 16    │  │
│  └────────────────────┘                         │  + rclone + bash        │  │
│           ▲                                     └───────────┬────────────┘  │
│           │ seed on first boot                              │ every N sec   │
│  configs/postgres/init/01-seed.sql                          ▼               │
│                     backup.sh → <db>_<ts>.tar.gz + manifest.json + .sha256 │
│                                        │                                   │
│                     rotate.sh ─────────┤  age > N days AND newer ≥ minimum │
│                                        │                                   │
│                     sync.sh ───────────┤  local  → /backups/mock-cloud-sync│
│                                        │  rclone → oci-backups:<prefix>    │
│                                        ▼                                   │
│                              backup-archive volume                         │
└────────────────────────────────────────────────────────────────────────────┘
                 │ rclone (S3 API, TLS, checksum-verified)
                 ▼
        ┌───────────────────────────┐
        │  OCI Object Storage       │   private · versioned · lifecycle-tiered
        │  NoPublicAccess, versioning│
        └───────────────────────────┘
```

Data flow in one line: **`[PostgreSQL] → [runner: pg_dump + gzip + sha256] →
[rclone S3 API] → [OCI Object Storage bucket]`**.

---

## ✨ Features

**Backup correctness**

- `pg_dump --format=custom` (restorable with `pg_restore`) with
  `--no-owner --no-privileges`, so a restore never depends on role names.
- Two checksums per backup: SHA-256 of the raw dump *inside* the manifest, and
  SHA-256 of the archive as a sidecar — corruption is caught at either layer.
- `set -Eeuo pipefail` end to end: a failed dump aborts the cycle, so an empty
  archive is never published as if it were a backup.

**Retention**

- Prune only when *older than* `BACKUP_RETENTION_DAYS` **and** at least
  `BACKUP_KEEP_MINIMUM` newer archives exist.
- Ordering is by modification time, not filename, so a renamed or restored
  archive cannot be mistaken for the newest one (this was a real bug, found by a
  drill and fixed in `0deaf28`).
- Sidecar `.sha256` is deleted with its archive — no orphan checksums.

**Sync**

- `local`: copy into `/backups/mock-cloud-sync`, no credentials, inspectable.
- `rclone`: upload then `rclone check --one-way` to prove the remote matches.
- `off`: archive only, for air-gapped hosts.
- Copy-only by design: retention protects the host, bucket lifecycle protects the
  bucket. Neither deletes the other's files.

**Encryption at rest**

- `BACKUP_ENCRYPTION=openssl` encrypts the finished archive with **AES-256-CBC and
  PBKDF2 (200,000 iterations, salted)** before it is checksummed and synced.
- The plaintext archive is **deleted** after encryption; only `<name>.tar.gz.enc`
  and its `.sha256` remain, so "at rest" means at rest on the volume *and* in the
  bucket.
- The passphrase never enters the image or the repo: `BACKUP_ENCRYPTION_PASSPHRASE`
  (drills) or `BACKUP_ENCRYPTION_PASSPHRASE_FILE` (servers, mounted read-only).
- Rotation and sync understand encrypted archives: retention prunes `.enc` files
  with their sidecars, and the S3 upload includes `*.tar.gz.enc`.

**Failure alerting**

- Every abort runs an `ERR` trap, which emits one structured line:
  `[alert] level=critical stage=backup …` — `stage` is the thing that broke
  (`backup`, `rotate` or `sync`).
- Set `ALERT_WEBHOOK_URL` to any JSON endpoint (Slack, Discord, Teams, ntfy, n8n,
  Grafana, a CloudGuard endpoint) and the same event is POSTed, with a 10 s timeout.
- Alerting is **best-effort by contract**: a missing or dead endpoint logs
  `webhook delivery failed — log-only` and never changes the cycle's outcome.

**Operations**

- Health-gated start: the runner waits for `pg_isready` before its first dump.
- Per-service `mem_limit`, `cpus`, `no-new-privileges`, and `json-file` log
  rotation (`10m × 2`), sized for a 1 OCPU Always Free ARM instance.
- PostgreSQL tuned via Compose `-c` flags — no `config_file` mount, so the
  image's own `pg_hba.conf` keeps working.

---

## 🚀 Quick start

```bash
git clone https://github.com/kaveh8866/Automated-DB-Backup-Cloud-Sync.git
cd Automated-DB-Backup-Cloud-Sync

cp .env.example .env                     # set a real POSTGRES_PASSWORD
docker compose --env-file .env -f docker/docker-compose.yml config --quiet
docker compose --env-file .env -f docker/docker-compose.yml up -d --build
docker compose -f docker/docker-compose.yml logs -f backup-runner
```

Expected first cycle:

```text
[entrypoint] runner starting: interval=3600s retention=7d keep>=3 sync=local
[entrypoint] database postgres:5432 reachable after 1 attempt(s)
[backup] archive written: appdb_20261112T195409Z.tar.gz (4308 bytes, dump 9944 bytes)
[rotate] rotation complete: 0 removed, 1 retained (policy 7d / keep>=3)
[sync]   local sync complete: 2 file(s) copied to /backups/mock-cloud-sync
```

Inspect an archive without leaving the host:

```bash
docker exec cg-backup-runner sh -c 'ls -l /backups'
docker exec cg-backup-runner sh -c 'A=$(ls -1t /backups/*.tar.gz | head -1); tar -tzf "$A"'
docker exec cg-backup-runner sh -c 'cd /backups && sha256sum -c *.sha256'
```

Windows note: prefix `docker exec` with `MSYS_NO_PATHCONV=1`, otherwise Git Bash
rewrites `/backups` into a `C:/…` path.

---

## ⚙️ Configuration

All settings live in `.env` (gitignored) and fall back to
[`configs/backup/backup.conf`](configs/backup/backup.conf):

| Variable | Default | Purpose |
| -------- | ------- | ------- |
| `POSTGRES_DB` / `POSTGRES_USER` | `appdb` / `appuser` | Source database |
| `POSTGRES_PASSWORD` | — | Required; used by the cluster **and** the runner |
| `POSTGRES_PORT` | `5432` | Published on `127.0.0.1` only |
| `BACKUP_INTERVAL_SECONDS` | `3600` | Scheduler period (`60` for demos) |
| `BACKUP_RETENTION_DAYS` | `7` | Age rule |
| `BACKUP_KEEP_MINIMUM` | `3` | Floor rule (wins over the age rule) |
| `BACKUP_SYNC_MODE` | `local` | `local` \| `rclone` \| `off` |
| `RCLONE_REMOTE` / `RCLONE_DEST_PATH` | `oci-backups` / `cloudguard/db-backups` | Bucket target |
| `BACKUP_ENCRYPTION` | `off` | `off` \| `openssl` (AES-256-CBC + PBKDF2) |
| `BACKUP_ENCRYPTION_PASSPHRASE` / `_FILE` | — | Passphrase inline (drills) or from a mounted file (servers) |
| `ALERT_WEBHOOK_URL` / `ALERT_TIMEOUT_SECONDS` | empty / `10` | Failure notification endpoint |
| `OCI_REGION`, `OCI_NAMESPACE`, `OCI_BUCKET_NAME` | — | Endpoint and bucket naming |
| `OCI_TENANCY_OCID`, `OCI_USER_OCID`, `OCI_FINGERPRINT`, `OCI_COMPARTMENT_OCID` | — | IaC inputs (never committed) |
| `TZ` | `UTC` | Log timestamps |

---

## 🧰 One-command operations

A `Makefile` wraps the commands that used to be copied out of this README:

```bash
make help           # every target, one line each
make up             # validate + build + start postgres and the runner
make backup         # run one cycle now, bypassing the interval
make verify         # newest archive: contents (or 'encrypted'), size, checksum
make decrypt FILE=/backups/<name>.tar.gz.enc
make restore DB=appdb_restored     # full pg_restore drill into a scratch DB
make lint           # bash -n on every script + tofu fmt -check
```

**One-command OCI deployment** — the whole infrastructure spin, from provider
download to printed endpoints:

```bash
make deploy-oci
# = cd terraform && tofu init && tofu fmt -recursive && tofu validate
#   && tofu plan -out=tfplan && tofu apply tfplan && tofu output connection_endpoints
```

`make tofu-validate` runs init + validate only (no credentials needed), and
`make destroy-oci` is the documented counterpart — empty the bucket first, since
`oci_objectstorage_bucket` has no force-destroy.

---

## ♻️ Restore drill (`pg_restore`)

Never restore into the live database. Create a scratch one and prove the numbers.

```bash
# 0 · if the archive is encrypted, decrypt it first (writes the .tar.gz alongside)
make decrypt FILE=/backups/appdb_<timestamp>.tar.gz.enc

# 1 · pick the newest archive and fetch it (container → host → container)
ARCHIVE=$(docker exec cg-backup-runner sh -c 'ls -1t /backups/*.tar.gz | head -1')
mkdir -p .tmp-restore
docker cp "cg-backup-runner:$ARCHIVE" .tmp-restore/archive.tar.gz
docker cp "cg-backup-runner:${ARCHIVE}.sha256" .tmp-restore/archive.tar.gz.sha256

# 2 · verify the transfer before trusting it
cd .tmp-restore && sha256sum -c archive.tar.gz.sha256 && tar -xzf archive.tar.gz && ls -l

# 3 · create a scratch database and restore into it
docker exec cg-db psql -U appuser -d appdb -qc 'create database appdb_restored;'
docker cp .tmp-restore/*.dump cg-db:/tmp/restore.dump
docker exec cg-db pg_restore --no-owner --no-privileges -U appuser \
  -d appdb_restored /tmp/restore.dump        # exit 0 expected

# 4 · prove the data came back (compare with the source counts)
docker exec cg-db psql -U appuser -d appdb_restored \
  -c 'select count(*) from app.customers;' -c 'select count(*) from app.events;'
docker exec cg-db psql -U appuser -d appdb -tAc 'select count(*) from app.customers;'

# 5 · clean up
docker exec cg-db psql -U appuser -d appdb -qc 'drop database appdb_restored;'
docker exec cg-db rm -f /tmp/restore.dump && rm -rf .tmp-restore /tmp/restore
```

Recorded result from the local drill: `pg_restore` exit **0**, `appdb_restored`
returned **25 customers / 1000 events** — identical to the source.

Stop if `pg_restore` complains about missing roles (dump taken without
`--no-owner`), if the counts differ, or if it needs `--clean` (the target was not
empty — use a fresh database name).

---

## 🔌 Cloud-agnostic portability

The runtime is plain Docker Compose; the infrastructure is OpenTofu with one
module per concern; the bucket is reached through the **S3-compatible API**. One
rclone config block is the only thing that changes between providers:

| Target | rclone `provider` | `endpoint` | Notes |
| ------ | ----------------- | ---------- | ----- |
| **OCI Object Storage** | `Other` | `https://<namespace>.compat.objectstorage.<region>.oraclecloud.com` | validated target |
| AWS S3 | `AWS` | `https://s3.<region>.amazonaws.com` | swap `modules/storage` for `aws_s3_bucket` + `aws_s3_bucket_lifecycle_configuration` |
| Google Cloud Storage | `Google` | native (no endpoint) or S3 interop | `google_storage_bucket` + `google_storage_bucket_lifecycle` |
| Cloudflare R2 | `Cloudflare` | `https://<account-id>.r2.cloudflarestorage.com` | zero egress |
| MinIO | `Minio` | `https://<host>:9000` | self-hosted, no cloud account |

### Certification scope — read this before quoting the project

> **Cloud-agnostic by design; certified on one cloud.** The IaC and rclone
> configuration support S3-compatible storage across AWS S3, Google Cloud
> Storage and OCI Object Storage. **Final production verification and testing
> certification are performed strictly on Oracle Cloud Infrastructure (OCI),
> using OCI trial credits.** AWS, GCP, R2 and MinIO are *documented ports*, not
> certified targets: they carry no test evidence in this repository, and this
> project must not be described as "AWS-verified" or "GCP-verified".
>
> **Current evidence level:** the pipeline itself is certified locally (Stage 4
> drill: cycle, compression, retention, restore). The live OCI deployment was
> **not executed** — the workspace has no OCI credentials — so the statement above
> records the certification *policy and target*, not a completed cloud run. See
> [`docs/teardown-audit.txt`](docs/teardown-audit.txt) for the state audit.

### Migration tips

**→ AWS (S3 + EC2)**

1. Replace `modules/storage` with `aws_s3_bucket` (`force_destroy = false`),
   `aws_s3_bucket_versioning`, `aws_s3_bucket_server_side_encryption_configuration`
   (SSE-S3 or SSE-KMS) and `aws_s3_bucket_lifecycle_configuration`
   (transition to `GLACIER_IR`, noncurrent-version expiry).
2. Replace `modules/compute` with `aws_instance` on `t3.micro` (`ami` from a data
   source, `vpc_security_group_ids`); the security group needs **only** port 22,
   exactly like the OCI security list.
3. IAM: an instance profile with `s3:PutObject`, `s3:ListBucket`,
   `s3:GetObject` scoped to the bucket ARN — no long-lived keys on the host.
4. rclone: `provider = AWS`, `region`, no custom endpoint. Keep `--checksum`.
5. Watch egress: S3 → internet is $0.09/GB after 100 GB, versus 10 TB free on OCI.

**→ GCP (Cloud Storage + Compute Engine)**

1. `google_storage_bucket` with `uniform_bucket_level_access = true`,
   `versioning { enabled = true }`, `lifecycle_rule` (SetStorageClass → NEARLINE
   or ARCHIVE) and `public_access_prevention = "enforced"`.
2. `google_compute_instance` on `e2-micro`; firewall rule allowing `tcp:22` from
   your IP only, with a `google_compute_firewall` deny-by-default posture.
3. Prefer a service account with `roles/storage.objectAdmin` on that bucket, via
   the instance's attached service account — avoids static HMAC keys entirely.
4. rclone: `provider = Google` + `service_account_file` (or GCS S3 interop with
   `provider = Other` and `storage.googleapis.com`).
5. GCS has a 5 GB free tier and 100 GB/month free egress from North America.

**→ Any S3-compatible target (R2, MinIO, Backblaze)**

Only `rclone.conf` and the bucket module change. `BACKUP_SYNC_MODE=rclone` and
every script stay byte-identical — that is the point of keeping the pipeline
provider-blind.

---

## 💰 Cross-Cloud Cost & Benchmark Estimation

**Benchmark footprint** (from the tested stack, normalized to one small VM):
1 vCPU · 1 GB RAM · 50 GB disk · 10 GB of archives stored after retention ·
20,000 PUT + 20,000 GET operations per month · 10 GB egress for restore drills.
List prices for US regions, November 2026, rounded; excluding tax.

| Line item | OCI · Always Free | OCI · Trial credits | AWS · t3.micro | GCP · e2-micro |
| --------- | ----------------- | ------------------- | -------------- | -------------- |
| Compute | 1 OCPU / 6 GB A1 — **$0** (1,500 OCPU-h + 9,000 GB-h allowance) | $0 (charged to the $300 / 30-day credit) | $7.59 (`$0.0104/h × 730`) | **$0** (one free `e2-micro` in `us-central1`/`us-west1`/`us-east1`); ≈$6 outside the free tier |
| Boot disk (50 GB) | **$0** (200 GB block allowance) | $0 | $4.00 (gp3, `$0.08/GB-mo`) | $0.80 (30 GB free standard PD, then `$0.04/GB-mo`) |
| Object storage (10 GB) | **$0** (20 GB allowance) | $0 | $0.23 (S3 Standard `$0.023/GB-mo`) | $0.20 (GCS Standard `$0.020/GB-mo`) |
| API operations (40k) | **$0** (50,000 requests free) | $0 | $0.11 (PUT `$0.005/1k`, GET `$0.0004/1k`) | $0.11 (Class A `$0.05/10k`, Class B `$0.004/10k`) |
| Egress (10 GB) | **$0** (10 TB/month free) | $0 | $0 (first 100 GB free, then `$0.09/GB`) | $0 (100 GB/month free from North America) |
| **Monthly total** | **$0.00** | **$0.00** until credit exhaustion | **≈ $11.93** | **≈ $1.11** with free tier, **≈ $7.42** without |
| **12-month run rate** | **$0.00** | $0.00 (credit lasts ~25 × this footprint) | **≈ $143** | ≈ $13 (free tier) / ≈ $89 |

**Reading the table**

- The pipeline is deliberately *smaller than the free allowance on every
  provider*: 0.75 vCPU and ~576 MB of container limits, archives measured in
  kilobytes for the seed dataset, one `rclone` sync per cycle.
- OCI's differentiator is not per-GB storage ($0.0255 vs $0.023 on S3) — it is
  the **10 TB/month free egress** and the **Always Free A1 allowance**, which
  together make an always-on backup host genuinely $0.00.
- AWS is the most expensive of the three *and* the most predictable: `t3.micro`
  is metered hourly with no equivalent always-free instance anymore.
- GCP wins on paper only inside the free-tier regions; the moment the VM leaves
  `us-central1`/`us-west1`/`us-east1`, its cost lands between the other two.
- Measured baseline: a cycle on the seeded database produced a **4,308-byte
  archive from a 9,944-byte dump** (57 % smaller) in well under a second, so
  compute — not storage or requests — dominates every estimate above.

---

## 🔒 Security posture & zero-leak boundary

| Control | Implementation |
| ------- | -------------- |
| Database exposure | Published on `127.0.0.1` only; the cloud security list opens **22/tcp alone** — no rule exists for 5432 |
| Archive at rest | Private bucket (`NoPublicAccess`) with versioning; lifecycle rule can tier to Archive after 30 days |
| Transfer integrity | TLS to the S3 endpoint; `rclone check --one-way` after upload; SHA-256 sidecars |
| Credentials | Never in the repo: `.env`, `rclone.conf`, `*.pem`, `*.tfvars`, `*.tfstate` are gitignored and verified by `git check-ignore` |
| Cloud auth | IaC uses an OCI API signing key; rclone uses a **Customer Secret Key** (S3 API), kept outside the workspace |
| Containers | `no-new-privileges`, memory/CPU limits, non-root `backup` user, JSON log rotation |
| Least privilege | Restores run `--no-owner --no-privileges`; docs never carry OCIDs or key material |

Latest workspace scan (recorded in [`docs/security-audit.txt`](docs/security-audit.txt)):
**0** private keys, **0** `.env` files, **0** dumps, **0** state files, **0**
secret signatures across all tracked files; `.env.example` holds 18 placeholder
keys and no real values.

---

## ✅ Verified results

| Stage | Check | Result |
| ----- | ----- | ------ |
| 1 | Portability audit (CloudGuard) | `PORTABLE_CERTIFIED` — 100/100, 5/5 checks |
| 1 | Compose schema / shell lint | `compose config` passes; `bash -n` clean on 4 scripts |
| 2 | OpenTofu | `fmt -check` clean, `validate` valid |
| 4 | Stack boot | `cg-db` healthy, `cg-backup-runner` up; seed 25 customers / 1000 events |
| 4 | Backup + compression | 4,311 B archive from 9,944 B dump; `manifest.json` + `.sha256` verify |
| 4 | Retention | 3 × 30-day archives pruned under 7d; **0** pruned at `keep>=10`; floor honoured at `keep>=2` |
| 4 | Local sync | 3/3 archives byte-identical in `/backups/mock-cloud-sync` |
| 4 | Restore drill | `pg_restore` exit 0 → 25 customers / 1000 events |
| 7 | Encryption at rest | ciphertext is `Salted__` (not gzip); decrypt → dump SHA-256 matches the manifest; plaintext removed |
| 7 | Retention on `.enc` | 5 archives (3 aged 30 d, encrypted) → 2 pruned, floor of 3 respected, sidecars consistent |
| 7 | Failure alerting | wrong password → `[alert] level=critical stage=backup`; webhook POST received (JSON captured); dead endpoint degrades to log-only, exit code unchanged |
| 5 | Live OCI deploy | **not executed** — no OCI credentials in the workspace |
| 6 | Teardown audit | no state, no credentials, no resources: **0** containers / volumes / networks / images |

Evidence: [`docs/stage-4-local-verification.txt`](docs/stage-4-local-verification.txt),
[`docs/teardown-audit.txt`](docs/teardown-audit.txt),
[`docs/security-audit.txt`](docs/security-audit.txt).

---

## 📚 Documentation

| Document | Audience |
| -------- | -------- |
| [`MANUAL_PREREQS.md`](MANUAL_PREREQS.md) | Human operator: account, bucket, keys, `.env`, `rclone.conf`, provisioning checklist |
| [`AGENT_GUIDE.md`](AGENT_GUIDE.md) | AI coding agents (Cursor, Claude Code, Windsurf): phases 0–8 with stop conditions |
| [`terraform/README.md`](terraform/README.md) | IaC inputs/outputs, S3 endpoint mapping, teardown order |
| [`docs/`](docs) | Raw verification, teardown and security audit records |

---

## 🗺 Roadmap

| Stage | Scope | State |
| ----- | ----- | ----- |
| **1** | Scaffold, compose stack, backup/rotate/sync scripts, portability profile | ✅ |
| **2** | OpenTofu: OCI VCN, A1.Flex compute, private Object Storage bucket | ✅ |
| **3** | Agent playbook + operator checklist | ✅ |
| **4** | Local drill: boot, backup + compression, retention, sync, restore | ✅ |
| **5** | Live OCI deploy: cycles against the real bucket, restore rehearsal | ⬜ blocked on credentials |
| **6** | Teardown audit and zero-resource verification | ✅ (nothing provisioned) |
| **7** | Encryption at rest (AES-256) + failure alerting webhook | ✅ |
| **8** | Manifest signing (minisign/age), metric surface for dashboards | ⬜ |

---

## 📄 License

MIT — see [LICENSE](LICENSE). Copyright (c) 2026 Mostafa Kaveh.
