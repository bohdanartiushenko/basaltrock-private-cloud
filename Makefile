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
DOCKER_DIR = $(BASALTROCK)/src/main/resources/opensearch/docker

DATA_FOLDER ?= data
DOC_ANSI_CODEPAGE ?= cp1252
MODEL_RUNNER_LLM_CHAT ?= ai/gemma3:4b-q4_K_M
MODEL_RUNNER_LLM_EMBEDDING ?= ai/nomic-embed-text-v2-moe
MODEL_KEEP_ALIVE ?= -1
MODEL_CONTEXT_SIZE ?= 32768

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

.PHONY: up down restart ingest rtf2txt tune-models logs status prune help fetch

$(DOCKER_DIR)/docker-compose.yml:
	@echo "Downloading basaltrock $(BASALTROCK_VERSION) from github.com/$(BASALTROCK_GH)"
	@mkdir -p $(BASALTROCK)
	@curl -fsSL https://github.com/$(BASALTROCK_GH)/archive/refs/tags/$(BASALTROCK_VERSION).tar.gz | tar xz -C $(BASALTROCK) --strip-components=1
	@mkdir -p $(DOCKER_DIR)/data

fetch: $(DOCKER_DIR)/docker-compose.yml

up: fetch
	$(COMPOSE) up -d --build
	@echo "Waiting for API..."
	@until curl -sf -X POST http://localhost:80/model/health/count-tokens -H "Content-Type: application/json" -d '{"input":{}}' >/dev/null 2>&1; do sleep 2; done
	@echo "Ready: http://localhost:80"

down:
	$(COMPOSE) down

restart: down up

ingest:
	$(COMPOSE) run --rm ingestion

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
	@echo "make ingest    - Re-run ingestion over $(DATA_FOLDER)"
	@echo "make rtf2txt   - Convert .rtf in $(DATA_FOLDER) to .txt (macOS textutil)"
	@echo "make logs      - Follow logs"
	@echo "make status    - Show containers"
	@echo "make prune     - Remove volumes (deletes OpenSearch data)"