# terraform/ — OCI provisioning for Automated DB Backup & Cloud Sync

OpenTofu ≥ 1.6 / Terraform ≥ 1.6. Provisions the **host** that runs the Stage 1
compose stack and the **private Object Storage bucket** that receives the backup
archives.

## Layout

```text
terraform/
├── versions.tf               # provider pin, local state, OCI auth, namespace lookup
├── variables.tf              # full input contract with validations
├── main.tf                   # wires network / compute / storage, renders cloud-init
├── outputs.tf                # public IP, bucket name, S3 endpoint, connection strings
├── terraform.tfvars.example  # operator template (copy to terraform.tfvars)
├── cloud-init.yaml.tftpl     # first-boot: Docker + Compose plugin + /opt/cloudguard
└── modules/
    ├── network/              # VCN, IGW, route table, SSH-only security list, subnet
    ├── compute/              # VM.Standard.A1.Flex (Always Free ARM)
    └── storage/              # private bucket + optional versioning/lifecycle
```

## What gets created

| Area | Resources | Notes |
| ---- | --------- | ----- |
| Network | `oci_core_vcn`, `oci_core_internet_gateway`, `oci_core_route_table`, `oci_core_security_list`, `oci_core_subnet` | Ingress is **TCP 22 only**. There is no rule for 5432, and the container publishes PostgreSQL on `127.0.0.1`. |
| Compute | `oci_core_instance` (`VM.Standard.A1.Flex`, 1 OCPU / 6 GB / 50 GB) | Ubuntu 24.04 aarch64, image resolved by shape so ARM is correct, cloud-init installs Docker + Compose. |
| Storage | `oci_objectstorage_bucket` (NoPublicAccess, versioning on) + `oci_objectstorage_object_lifecycle_policy` | Archive tier after 30 days by default; optional hard delete. |

## Usage

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # tenancy, compartment, region, SSH public key
tofu init
tofu fmt -recursive
tofu validate
tofu plan
tofu apply
tofu output connection_endpoints
```

### Outputs you will use

| Output | Purpose |
| ------ | ------- |
| `instance_public_ip` | `ssh ubuntu@<ip>` for the Stage 3 deployment |
| `bucket_name` / `bucket_namespace` | rclone remote `path` (`oci-backups:cloudguard/db-backups`) |
| `bucket_endpoint` | S3-compatible endpoint for `configs/rclone/rclone.conf` |
| `connection_endpoints.postgres_tunnel` | `ssh -L 5432:localhost:5432 …` — the only way to reach the DB |
| `bucket_lifecycle` | Which retention rules are active (0 days = disabled) |

## S3 compatibility (AWS / GCP / R2 / MinIO)

The bucket is consumed through OCI's **S3-compatible** endpoint, so the backup
pipeline never learns which cloud it is on. Porting means replacing the module,
not rewriting `scripts/`:

| OCI (here) | AWS | GCP |
| ---------- | --- | --- |
| `oci_objectstorage_bucket` | `aws_s3_bucket` | `google_storage_bucket` (or the S3/XML interop endpoint) |
| `access_type = "NoPublicAccess"` | Block Public Access + bucket policy | uniform bucket-level access, no `allUsers` binding |
| `versioning = "Enabled"` | `versioning { enabled = true }` | `versioning { enabled = true }` |
| `oci_objectstorage_object_lifecycle_policy` | `aws_s3_bucket_lifecycle_configuration` | `google_storage_bucket_lifecycle_rule` |
| `namespace` + name | globally unique bucket name | globally unique bucket name |

Endpoint mapping for `configs/rclone/rclone.conf.example`:

| Target | `provider` | `endpoint` |
| ------ | ---------- | ---------- |
| OCI Object Storage | `Other` | `https://<namespace>.compat.objectstorage.<region>.oraclecloud.com` |
| AWS S3 | `AWS` | `https://s3.<region>.amazonaws.com` |
| Cloudflare R2 | `Cloudflare` | `https://<account-id>.r2.cloudflarestorage.com` |
| MinIO | `Minio` | `https://<host>:9000` |

## Guardrails

- `terraform.tfvars`, `*.tfstate*` and `keys/` are gitignored — the repo must never carry credentials or state.
- `ssh_public_key` is validated to reject anything that is not an OpenSSH **public** key, so a private key cannot land in state by accident.
- Keep `instance_ocpus × 730 ≤ 1500` to stay inside the OCI Always Free A1 budget.
- The bucket is the durable copy; the instance is disposable. Never keep archives only on the boot volume.
- `tofu destroy` removes compute, network and bucket — in that order. The bucket must be emptied first: `oci_objectstorage_bucket` exposes **no `force_destroy`** (verified against the installed provider schema), so a bucket holding objects fails the destroy instead of silently discarding backups. Empty it with `rclone --config <cfg> purge <remote>:<prefix>` first.
- Destroy requires a state file. If `tofu state list` reports *No state file was found*, nothing was ever applied — there is nothing to tear down, and `destroy` refusing on missing variables is the safe outcome, not a failure to investigate.
