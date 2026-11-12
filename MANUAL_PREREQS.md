# MANUAL_PREREQS — Operator Setup Checklist

Everything a human must do before the automated pipeline can run against real
cloud storage. Work top to bottom; each step ends with what you should be
holding.

**Total time:** ~20 minutes of console work, ~5 minutes of provisioning.
Nothing here costs money if you stay inside the Always Free allowances in step 1.

> **Never** paste a password, secret key or private key into a file tracked by
> Git. `.env`, `terraform.tfvars` and `rclone.conf` are gitignored for a reason.

---

## 0 · What you end up with

- [ ] One VCN, public subnet, internet gateway, security list (SSH 22 only).
- [ ] One `VM.Standard.A1.Flex` instance (1 OCPU / 6 GB / 50 GB) with Docker.
- [ ] A **private** Object Storage bucket for the archives.
- [ ] A Customer Secret Key pair that rclone uses over the S3-compatible API.
- [ ] A filled `.env` and `rclone.conf` that live outside version control.
- [ ] Spend at **$0.00** inside the Always Free envelope.

---

## 1 · Oracle Cloud account and free tier

- [ ] Create an account at <https://signup.cloud.oracle.com> and choose your
      **home region** — it cannot be changed, and Always Free resources only
      exist there.
- [ ] Confirm the Always Free tier is active. The allowances this project uses:

      | Resource | Always Free allowance | This project |
      | -------- | --------------------- | ------------ |
      | Ampere A1 compute | 1,500 OCPU-hours + 9,000 GB-hours / month (≈ 2 OCPU + 12 GB continuous) | 1 OCPU + 6 GB (≈ 49 % / 49 %) |
      | Block storage | 200 GB total | 50 GB boot |
      | Object Storage | 20 GB combined (Standard + Archive + Infrequent) | a few hundred MB of archives |
      | Outbound transfer | 10 TB / month | negligible |
      | Free trial credit | US$300, 30 days | optional; the stack fits Always Free |

- [ ] Keep `instance_ocpus × 730 ≤ 1500` if you resize — that ceiling is what
      keeps the instance free.

---

## 2 · API signing key (for OpenTofu only)

Console → avatar → **My profile** → **API keys** → **Add API key** →
**Generate API key pair** → download the private key.

- [ ] Record the four values:

      | Value | Where |
      | ----- | ----- |
      | Tenancy OCID | Profile → Tenancy |
      | User OCID | Profile → User settings |
      | Fingerprint | Shown once the key is added |
      | Private key `.pem` | The file you downloaded |

- [ ] Keep the `.pem` **outside** the repository (e.g. `~/.oci/oci_api_key.pem`).
- [ ] Optional shortcut: put it in `~/.oci/config` and set
      `config_file_profile = "DEFAULT"`, leaving `user_ocid` / `fingerprint` /
      `private_key_path` unset in `terraform.tfvars`.

> This key is for the OCI API (OpenTofu). It is **not** what rclone uses —
> that is the Customer Secret Key in step 6.

---

## 3 · Compartment

- [ ] Console → **Identity & Security → Compartments**. Use the root compartment
      or create one (e.g. `cloudguard`) and copy its OCID.
- [ ] Confirm your user can manage networking, instances and buckets there
      (the `Administrators` group on a personal tenancy already can).

---

## 4 · SSH key pair for the host

```bash
ssh-keygen -t ed25519 -C "cloudguard-db-backup" -f ~/.ssh/cloudguard_db_backup
cat ~/.ssh/cloudguard_db_backup.pub
```

- [ ] `ssh_public_key` in `terraform.tfvars` takes the **content** of the `.pub`
      file (one line starting with `ssh-ed25519`), never a path.
- [ ] The variable validates the key format and rejects anything that is not an
      OpenSSH public key — a pasted private key fails the plan, by design.

---

## 5 · Object Storage bucket

You can let OpenTofu create it (recommended, step 9) or create it by hand:

- [ ] Console → **Storage → Buckets** → **Create bucket**.
- [ ] Name: `cloudguard-db-backups` (must be unique in your namespace).
- [ ] **Visibility: Private** — never public. Archives are full database dumps.
- [ ] Enable **Object versioning** (recovers from an accidental overwrite).
- [ ] Optional: lifecycle rule → *Archive* objects after 30 days.
- [ ] Note the **namespace** shown in the bucket details (a short, tenancy-wide
      identifier, not an OCID).

> The same bucket works for AWS S3, GCS (S3 interop), R2 or MinIO — only the
> rclone `provider`/`endpoint` changes (step 8). OCI is the certified target.

---

## 6 · Customer Secret Key (S3-compatible credentials)

rclone talks to OCI through the S3 API, which uses **Customer Secret Keys**, not
API signing keys.

- [ ] Console → **Identity & Security → Users** → your user →
      **Customer Secret Keys** → **Create Secret Key**.
- [ ] Name it e.g. `cloudguard-backup-rclone`.
- [ ] Copy the **Secret Key** immediately — the console shows it **once**.
- [ ] Record:

      | Value | Notes |
      | ----- | ----- |
      | Access Key / Key ID | shown in the list afterwards |
      | Secret Key | shown once at creation |
      | Namespace | from step 5 |
      | Region | e.g. `eu-frankfurt-1` |

- [ ] Do not reuse this pair for anything else, and rotate it by creating a new
      one and deleting the old.

---

## 7 · `.env` (runtime configuration)

```bash
cd Automated-DB-Backup-Cloud-Sync
cp .env.example .env
```

- [ ] `POSTGRES_PASSWORD` — a real password; also used by the runner.
- [ ] `BACKUP_INTERVAL_SECONDS` — `3600` for production, `60` for a drill.
- [ ] `BACKUP_RETENTION_DAYS` / `BACKUP_KEEP_MINIMUM` — your retention policy.
- [ ] `BACKUP_SYNC_MODE` — `local` (offline drill) or `rclone` (real bucket).
- [ ] `RCLONE_REMOTE=oci-backups`, `RCLONE_DEST_PATH=cloudguard/db-backups`.
- [ ] `BACKUP_ENCRYPTION=openssl` if the archives must be unreadable at rest, plus
      either `BACKUP_ENCRYPTION_PASSPHRASE` (drills) or
      `BACKUP_ENCRYPTION_PASSPHRASE_FILE=/etc/backup-key/passphrase` mounted from
      outside the repository. **Lose this passphrase and the archives are gone** —
      store it in your password manager before the first encrypted cycle.
- [ ] `ALERT_WEBHOOK_URL` for failure notifications (leave empty for log-only).
- [ ] Confirm it is ignored: `git check-ignore -v .env` must print a match.

---

## 8 · `rclone.conf` (outside the repository)

```bash
cp configs/rclone/rclone.conf.example ~/cloudguard/rclone.conf   # or any path outside the repo
```

- [ ] Fill in `access_key_id`, `secret_access_key`, `endpoint`, `region`.
      OCI endpoint shape:
      `https://<namespace>.compat.objectstorage.<region>.oraclecloud.com`
- [ ] Mount it read-only at `/etc/rclone/rclone.conf` by editing the
      `backup-runner` volume in `docker/docker-compose.yml` to point at your
      file's directory, or copy it into the host and bind that path.
- [ ] Never commit the filled file (`rclone.conf` is gitignored).

Verify credentials **before** starting the stack:

```bash
rclone --config ~/cloudguard/rclone.conf lsd oci-backups:
rclone --config ~/cloudguard/rclone.conf mkdir oci-backups:cloudguard/db-backups
rclone --config ~/cloudguard/rclone.conf lsf oci-backups:cloudguard/db-backups
```

Expected: the bucket is listed without authentication errors.

---

## 9 · `terraform.tfvars`

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

- [ ] `tenancy_ocid`, `compartment_ocid`, `region` from steps 1–3.
- [ ] Either `config_file_profile` **or** `user_ocid` + `fingerprint` +
      `private_key_path`.
- [ ] `ssh_public_key` — public key **content** from step 4.
- [ ] `ssh_allowed_cidr` — your own egress IP (`curl -s https://ifconfig.me`),
      not `0.0.0.0/0`, unless this is a throwaway environment.
- [ ] `bucket_name` / `bucket_namespace` — match step 5.
- [ ] `availability_domain` — leave `null` first; pin it if A1 capacity is tight.

---

## 10 · Provision the host

```bash
tofu init
tofu fmt -recursive
tofu validate
tofu plan
tofu apply
tofu output connection_endpoints
```

- [ ] The plan shows: 5 network resources, 1 instance, 1 bucket (+1 lifecycle
      policy). Nothing else.
- [ ] No ingress rule other than TCP 22.
- [ ] `tofu output instance_public_ip` returns an address.

---

## 11 · Deploy the stack onto the host

```bash
ssh ubuntu@<instance_public_ip>
git clone https://github.com/kaveh8866/Automated-DB-Backup-Cloud-Sync.git
cd Automated-DB-Backup-Cloud-Sync
cp .env.example .env          # same values as step 7
docker compose --env-file .env -f docker/docker-compose.yml up -d --build
docker compose logs -f backup-runner
```

- [ ] Wait for `[backup] archive written: …` and `[sync] rclone sync verified …`.
- [ ] PostgreSQL is **not** reachable from the internet; confirm with
      `nc -vz <ip> 5432` from your laptop — it must time out or be refused.
- [ ] Reach it only through a tunnel: `ssh -L 5432:localhost:5432 ubuntu@<ip>`.

---

## 12 · Post-deploy verification

- [ ] `docker exec cg-backup-runner ls -la /backups` → archives exist.
- [ ] `docker exec cg-backup-runner sh -c 'cd /backups && sha256sum -c *.sha256'` → OK.
- [ ] `rclone --config ~/cloudguard/rclone.conf lsf oci-backups:cloudguard/db-backups` → files listed.
- [ ] Restore drill executed at least once (see `AGENT_GUIDE.md` phase 6).
- [ ] Record the numbers: archive count, restore row counts, sync verification line.

---

## 13 · Teardown and cost

```bash
cd terraform
tofu destroy        # empties nothing — delete objects first if the bucket is not empty
```

- [ ] Empty the bucket (`rclone purge oci-backups:cloudguard/db-backups`) before
      destroying, or keep the bucket intentionally and destroy only compute.
- [ ] Confirm in the console: 0 running instances, 0 buckets (or 1 kept), and
      the cost analysis still at **$0.00**.
- [ ] Delete the Customer Secret Key if the project is finished.

---

## Certification scope

The runtime (Docker Compose) and the infrastructure (OpenTofu) are
**cloud-agnostic**, and the bucket is consumed through an **S3-compatible API**
that also covers AWS S3, Google Cloud Storage, Cloudflare R2 and MinIO.

**Final production verification and testing certification are performed strictly
on Oracle Cloud Infrastructure (OCI), using OCI trial credits.** OCI is the
validated environment: provisioning, backup cycles, bucket sync and the restore
drill are signed off there. AWS, GCP, R2 and MinIO are **documented ports, not
certified targets** — this project must not be described as "AWS-verified" or
"GCP-verified".

---

## Quick troubleshooting

| Symptom | Cause | Fix |
| ------- | ----- | --- |
| `tofu apply`: `401-NotAuthenticated` | key/fingerprint mismatch | re-add the API key, check `private_key_path` permissions |
| `tofu apply`: `Out of host capacity` | A1 capacity in that AD | try another availability domain, then pin it |
| rclone `403` | API signing key used instead of Customer Secret Key | create a Customer Secret Key (step 6) |
| rclone `404` on the bucket | namespace/bucket name mismatch | check step 5 and `RCLONE_REMOTE` |
| `missing rclone config` in logs | filled config not mounted | mount it at `/etc/rclone/rclone.conf` (step 8) |
| Grafana-style UI not reachable | n/a for this project | there is no web UI; verify through `docker exec` and rclone |
| Runner restarts | database not ready / wrong password | `docker logs cg-db`, then fix `.env` and recreate the volume |
