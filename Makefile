# -----------------------------------------------------------------------------
# Copyright (c) 2025-2026 Bohdan Artiushenko https://github.com/bohdanartiushenko
# Home: https://github.com/bohdanartiushenko/basaltrock-private-cloud
# Licensed under the MIT License. See LICENSE file in the project root.
# SPDX-License-Identifier: MIT
# -----------------------------------------------------------------------------
#
# Generic private-cloud RAG stack. Include from a locale repo:
#
#   PRIVATE_CLOUD_DIR = .private-cloud
#   include $(PRIVATE_CLOUD_DIR)/Makefile
#
# A locale repo supplies: PROJECT_NAME, SYSTEM_PROMPT_FILE, INDEX_HTML,
# and optionally DOC_ANSI_CODEPAGE / MODEL_RUNNER_LLM_CHAT.

PROJECT_NAME ?= basaltrock-private-cloud
PRIVATE_CLOUD_DIR ?= .

BASALTROCK_GH ?= bohdanartiushenko/basaltrock
BASALTROCK_VERSION ?= $(shell curl -fsSL https://api.github.com/repos/$(BASALTROCK_GH)/releases/latest | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')
BASALTROCK ?= .basaltrock/$(BASALTROCK_VERSION)
# Resolved once; sub-makes inherit it instead of querying the API again.
export BASALTROCK_VERSION
DOCKER_DIR = $(BASALTROCK)/src/main/resources/opensearch/docker

DATA_FOLDER ?= data
DOC_ANSI_CODEPAGE ?= cp1252
MODEL_RUNNER_LLM_CHAT ?= ai/gemma3:4b-q4_K_M
MODEL_RUNNER_LLM_EMBEDDING ?= ai/nomic-embed-text-v2-moe
MODEL_KEEP_ALIVE ?= -1
MODEL_CONTEXT_SIZE ?= 32768

# Bucket named after the data folder: "C:/Users/me/My Docs" -> "my-docs".
S3_BUCKET ?= $(shell echo "$(notdir $(patsubst %/,%,$(subst \,/,$(DATA_FOLDER))))" \
	| tr 'A-Z' 'a-z' | tr -cs 'a-z0-9.-' '-' \
	| sed -e 's/^[^a-z0-9]*//' -e 's/[^a-z0-9]*$$//' -e 's/--*/-/g' | cut -c1-63)
S3_PORT ?= 8333
FILE_PORT ?= 8081
S3_EXTRA_BUCKETS ?=
S3_BUCKETS = $(S3_BUCKET) basaltrock basaltrock-private-cloud $(S3_EXTRA_BUCKETS)

# "make store sync ./folder store://name" — copy a folder into the store.
ifeq (store,$(firstword $(MAKECMDGOALS)))
STORE_WORDS = $(wordlist 2,$(words $(MAKECMDGOALS)),$(MAKECMDGOALS))
STORE_SRC = $(firstword $(filter-out sync store://%,$(STORE_WORDS)))
STORE_DST = $(patsubst store://%,%,$(firstword $(filter store://%,$(STORE_WORDS))))
endif

# "make basaltrock-agent start-ingestion-job" — the Bedrock-shaped spelling.
ifeq (basaltrock-agent,$(firstword $(MAKECMDGOALS)))
AGENT_CMD = $(word 2,$(MAKECMDGOALS))
$(eval $(AGENT_CMD):;@:)
endif
SEED_FILES ?= README.md LICENSE
SEED_SRC_basaltrock = $(BASALTROCK)
SEED_SRC_basaltrock-private-cloud = $(PRIVATE_CLOUD_DIR)

SYSTEM_PROMPT_FILE ?= $(PRIVATE_CLOUD_DIR)/system-prompt.txt
INDEX_HTML ?= $(PRIVATE_CLOUD_DIR)/index.html

COMPOSE = RAG_SYSTEM_PROMPT_TEMPLATE="$$(cat $(SYSTEM_PROMPT_FILE))" \
	docker compose -p $(PROJECT_NAME) \
	-f $(DOCKER_DIR)/docker-compose.yml \
	-f $(PRIVATE_CLOUD_DIR)/docker-compose.private-cloud.yml

export DATA_FOLDER_PATH = $(abspath $(DATA_FOLDER))
export INDEX_HTML_PATH = $(abspath $(INDEX_HTML))
export DOC_ANSI_CODEPAGE
export MODEL_RUNNER_LLM_CHAT
export MODEL_RUNNER_LLM_EMBEDDING
export MODEL_RUNNER_BASE_URL
export S3_BUCKET
export S3_PORT
export SEED_ROOT = $(CURDIR)
export S3_BUCKETS
export DOCKER_DIR_PATH = $(abspath $(DOCKER_DIR))
export INGESTION_S3_PATH = $(abspath $(PRIVATE_CLOUD_DIR)/ingestion-s3.py)
export FILES_SERVER_PATH = $(abspath $(PRIVATE_CLOUD_DIR)/files-server.py)
export FILE_PORT

COMPOSE_S3 = $(COMPOSE) --profile s3

.PHONY: up down restart ingest ingest-local rtf2txt tune-models logs status prune help fetch ls store basaltrock-agent s3-up s3-down s3-pull s3-push s3-buckets s3-seed s3-ls s3-ingest

$(DOCKER_DIR)/docker-compose.yml:
	@echo "Downloading basaltrock $(BASALTROCK_VERSION) from github.com/$(BASALTROCK_GH)"
	@mkdir -p $(BASALTROCK)
	@curl -fsSL https://github.com/$(BASALTROCK_GH)/archive/refs/tags/$(BASALTROCK_VERSION).tar.gz | tar xz -C $(BASALTROCK) --strip-components=1
	@mkdir -p $(DOCKER_DIR)/data

fetch: $(DOCKER_DIR)/docker-compose.yml

up: fetch
	@$(MAKE) --no-print-directory s3-up
	@$(MAKE) --no-print-directory s3-push
	@$(MAKE) --no-print-directory s3-ingest
	$(COMPOSE_S3) up -d --build api
	@echo "Waiting for API..."
	@until curl -sf -X POST http://localhost:80/model/health/count-tokens -H "Content-Type: application/json" -d '{"input":{}}' >/dev/null 2>&1; do sleep 2; done
	@echo "Ready: http://localhost:80"

down:
	$(COMPOSE_S3) down

restart: down up

ingest: s3-push s3-ingest

# Bedrock-shaped aliases, mirroring "aws bedrock-agent <command>".
AGENT_TARGET_start-ingestion-job = ingest
AGENT_TARGET_list-knowledge-base-documents = s3-ls

basaltrock-agent:
	@$(if $(AGENT_TARGET_$(AGENT_CMD)),\
		$(MAKE) --no-print-directory $(AGENT_TARGET_$(AGENT_CMD)),\
		echo "unknown command '$(AGENT_CMD)'; try: start-ingestion-job list-knowledge-base-documents" >&2; exit 1)

ingest-local:
	$(COMPOSE) run --rm ingestion

s3-up: fetch
	$(COMPOSE_S3) up -d s3
	@$(MAKE) --no-print-directory s3-buckets
	FILES_S3_ENDPOINT=http://s3:8333 $(COMPOSE_S3) up -d files
	@echo "S3 on http://localhost:$(S3_PORT), filer UI on http://localhost:8888"

s3-down:
	$(COMPOSE_S3) stop s3

s3-buckets:
	@for b in $(S3_BUCKETS); do \
		$(COMPOSE_S3) run --rm -T s3-sync mkdir "s3:$$b" >/dev/null 2>&1 || true; \
		echo "bucket $$b"; \
	done

s3-seed: s3-buckets
	$(foreach b,$(filter-out $(S3_BUCKET),$(S3_BUCKETS)),$(if $(SEED_SRC_$(b)),\
		$(foreach f,$(SEED_FILES),\
			$(COMPOSE_S3) run --rm -T s3-sync copy "/seed/$(SEED_SRC_$(b))/$(f)" "s3:$(b)";)))

# "make store sync ./folder store://name" — the folder becomes a data source.
store:
	@test -n "$(STORE_SRC)" -a -n "$(STORE_DST)" || \
		{ echo "usage: make store sync <folder> store://<name>" >&2; exit 2; }
	@test -d "$(STORE_SRC)" || { echo "no such folder: $(STORE_SRC)" >&2; exit 2; }
	@$(MAKE) --no-print-directory s3-up
	@DATA_FOLDER_PATH="$(abspath $(STORE_SRC))" \
		$(COMPOSE_S3) run --rm s3-sync sync /data "s3:$(STORE_DST)" --progress

s3-ingest:
	$(COMPOSE_S3) run --rm --build ingestion-s3

s3-pull:
	@for b in $(S3_BUCKETS); do \
		$(COMPOSE_S3) run --rm -T s3-sync sync "s3:$$b" "/data/$$b" --progress; \
	done

s3-push:
	$(COMPOSE_S3) run --rm s3-sync sync /data "s3:$(S3_BUCKET)" --progress

ls: s3-ls

s3-ls:
	@for b in $(S3_BUCKETS); do \
		echo "== $$b"; \
		$(COMPOSE_S3) run --rm -T s3-sync ls "s3:$$b" 2>/dev/null || true; \
	done

rtf2txt:
	@find $(DATA_FOLDER) -name '*.rtf' -exec textutil -convert txt -encoding UTF-8 {} \;

tune-models:
	@docker model configure --keep-alive=$(MODEL_KEEP_ALIVE) --context-size=$(MODEL_CONTEXT_SIZE) $(MODEL_RUNNER_LLM_CHAT)

logs:
	$(COMPOSE) logs -f

status:
	$(COMPOSE) ps

prune: down
	docker volume ls --filter "name=$(PROJECT_NAME)" -q | xargs -r docker volume rm

help:
	@echo "make up        - Download basaltrock + start $(PROJECT_NAME) on :80"
	@echo "make fetch     - Download basaltrock $(BASALTROCK_VERSION) only"
	@echo "make down      - Stop (OpenSearch data kept)"
	@echo "make ingest    - Re-index after changing $(DATA_FOLDER)"
	@echo "make store ... - Copy documents in or out, e.g."
	@echo "                 make store sync ./archive store://archive"
	@echo "make basaltrock-agent start-ingestion-job"
	@echo "               - Same as 'make ingest', spelled like Bedrock"
	@echo "make rtf2txt   - Convert .rtf in $(DATA_FOLDER) to .txt (macOS textutil)"
	@echo "make ls        - List the indexed documents"
	@echo "make logs      - Follow logs"
	@echo "make status    - Show containers"
	@echo "make prune     - Remove volumes (deletes indexed data)"

# Swallow the words after "store"/"basaltrock-agent" so make does not try to
# build them as targets.
$(foreach a,$(STORE_WORDS) $(AGENT_CMD),$(eval $(subst :,\:,$(a)): ; @:))