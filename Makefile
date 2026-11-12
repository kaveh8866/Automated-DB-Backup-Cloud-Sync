# =============================================================================
# Automated DB Backup & Cloud Sync — operator entry points
# =============================================================================
# One place for the commands that used to be copied out of the README.
#   make help          list everything
#   make up            validate + build + start the stack
#   make deploy-oci    init -> fmt -> validate -> plan -> apply -> outputs
#
# Every target is a thin wrapper: no logic lives here that is not also a
# documented command, so an operator without make can copy the recipe.
# =============================================================================

SHELL        := /bin/bash
ENV_FILE     ?= .env
COMPOSE_FILE := docker/docker-compose.yml
COMPOSE      := docker compose
DC           := $(COMPOSE) --env-file $(ENV_FILE) -f $(COMPOSE_FILE)
RUNNER       := cg-backup-runner
TOFU_DIR     := terraform
TOFU         ?= tofu

.DEFAULT_GOAL := help

.PHONY: help config up down logs ps backup rotate verify decrypt restore lint \
        tofu-init tofu-validate deploy-oci destroy-oci

help: ## list targets
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

config: ## validate the compose file (no containers started)
	@$(COMPOSE) --env-file $$(test -f $(ENV_FILE) && echo $(ENV_FILE) || echo .env.example) \
	  -f $(COMPOSE_FILE) config --quiet && echo "compose config valid"

up: config ## build and start postgres + backup runner
	@$(DC) up -d --build
	@$(DC) ps

down: ## stop and remove containers (volumes and archives are kept)
	@$(DC) down

logs: ## follow the runner log
	@$(DC) logs -f backup-runner

ps: ## container status
	@$(DC) ps

backup: ## run one backup cycle now, bypassing the interval
	@docker exec $(RUNNER) /usr/local/bin/backup.sh

rotate: ## run retention rotation only
	@docker exec $(RUNNER) /usr/local/bin/rotate.sh

verify: ## list the newest archive, its contents and its checksum
	@docker exec $(RUNNER) sh -c 'A=$$(ls -1t /backups/*.tar.gz* | grep -v "\.sha256$$" | head -1); \
	  echo "archive: $$A"; ls -l "$$A"; \
	  case "$$A" in *.enc) echo "(encrypted: decrypt with make decrypt FILE=$$A)";; \
	  *) tar -tzf "$$A";; esac; \
	  cd /backups && sha256sum -c "$$(basename $$A).sha256"'

decrypt: ## decrypt an archive: make decrypt FILE=/backups/x.tar.gz.enc
	@test -n "$(FILE)" || { echo "usage: make decrypt FILE=/backups/<name>.tar.gz.enc"; exit 1; }
	@docker exec $(RUNNER) sh -c 'F="$$1"; test -n "$$BACKUP_ENCRYPTION_PASSPHRASE" || \
	  { echo "set BACKUP_ENCRYPTION_PASSPHRASE in $(ENV_FILE) first"; exit 1; }; \
	  openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -in "$$F" \
	    -out "$${F%.enc}" -pass env:BACKUP_ENCRYPTION_PASSPHRASE && echo "wrote $${F%.enc}"' -- "$(FILE)"

restore: ## restore drill into a scratch DB: make restore DB=appdb_restored
	@test -n "$(DB)" || { echo "usage: make restore DB=appdb_restored"; exit 1; }
	@docker exec $(RUNNER) sh -c 'A=$$(ls -1t /backups/*.tar.gz 2>/dev/null | head -1); \
	  test -n "$$A" || { echo "no plaintext archive: run make decrypt FILE=/backups/<name>.tar.gz.enc"; exit 1; }; \
	  rm -rf /tmp/restore && mkdir -p /tmp/restore && tar -xzf "$$A" -C /tmp/restore && ls -1 /tmp/restore'
	@rm -rf .tmp-restore && mkdir -p .tmp-restore
	@MSYS_NO_PATHCONV=1 docker cp $(RUNNER):/tmp/restore/. .tmp-restore/
	@MSYS_NO_PATHCONV=1 docker cp "$$(ls -1 .tmp-restore/*.dump | head -1)" cg-db:/tmp/restore.dump
	@docker exec cg-db psql -U appuser -d appdb -qc 'create database $(DB);'
	@docker exec cg-db pg_restore --no-owner --no-privileges -U appuser -d $(DB) /tmp/restore.dump
	@docker exec cg-db psql -U appuser -d $(DB) -c 'select count(*) as customers from app.customers;'
	@rm -rf .tmp-restore

lint: ## shell syntax + tofu formatting
	@for s in scripts/*.sh; do bash -n "$$s" && echo "  ok $$s"; done
	@cd $(TOFU_DIR) && $(TOFU) fmt -recursive -check >/dev/null && echo "  tofu fmt clean"

tofu-init: ## initialise the OpenTofu providers (no state changes)
	@cd $(TOFU_DIR) && $(TOFU) init -backend=false -input=false

tofu-validate: tofu-init ## initialise and validate the configuration
	@cd $(TOFU_DIR) && $(TOFU) fmt -recursive && $(TOFU) validate

deploy-oci: ## ONE COMMAND: provision OCI (VCN, A1 compute, private bucket) and print endpoints
	@cd $(TOFU_DIR) && \
	  $(TOFU) init -input=false && \
	  $(TOFU) fmt -recursive && \
	  $(TOFU) validate && \
	  $(TOFU) plan -input=false -out=tfplan && \
	  $(TOFU) apply -input=false tfplan && \
	  echo "--- connection endpoints ---" && \
	  $(TOFU) output connection_endpoints

destroy-oci: ## destroy all OCI resources (empty the bucket first; see terraform/README.md)
	@echo "This removes compute, network and bucket in the project compartment."
	@cd $(TOFU_DIR) && $(TOFU) destroy -auto-approve -input=false
