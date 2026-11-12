# syntax=docker/dockerfile:1
# =============================================================================
# Automated DB Backup & Cloud Sync — backup runner image
# =============================================================================
# Small Alpine image carrying exactly what a backup cycle needs:
#   postgresql16-client  -> pg_dump / pg_isready matching the PG16 server
#   rclone               -> S3-compatible sync (OCI Object Storage)
#   coreutils/tar/gzip   -> archive + checksum tooling
#   openssl              -> optional AES-256 at-rest encryption of archives
#   curl                 -> optional failure webhook (scripts/alert.sh)
#
# The image is configuration-free: every value arrives as an environment
# variable, and the scripts are baked in so parsing/paths cannot drift between
# hosts. No credential is ever written into the image.

FROM alpine:3.20

RUN apk add --no-cache \
      bash \
      ca-certificates \
      coreutils \
      curl \
      findutils \
      gzip \
      openssl \
      postgresql16-client \
      rclone \
      tar \
      tzdata \
 && addgroup -S backup \
 && adduser -S -G backup -h /home/backup backup

COPY scripts/ /usr/local/bin/
RUN chmod 0755 /usr/local/bin/*.sh \
 && mkdir -p /backups \
 && chown backup:backup /backups

USER backup
WORKDIR /home/backup

ENV BACKUP_ARCHIVE_DIR=/backups \
    BACKUP_CONF=/etc/backup/backup.conf \
    PATH=/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
