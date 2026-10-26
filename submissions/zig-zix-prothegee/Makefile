SHELL := /bin/bash
.SHELLFLAGS := -ec

.DEFAULT_GOAL := help

# Local Postgres and Go cache used by the seed targets.
PGHOST ?= 127.0.0.1
PGPORT ?= 5432
PGUSER ?= conduit
PGPASSWORD ?= conduit
GOCACHE ?= $(CURDIR)/.cache/go-build
SEED_TEMPLATE ?= conduit_dev

# --------------------------------------------------------- #

##@ Info

.PHONY: help
help: ## Show this help message
	@awk 'BEGIN {FS = ":.*##"} \
		/^[a-zA-Z0-9_-]+:.*##/ { printf "  \033[36m%-30s\033[0m %s\n", $$1, $$2 } \
		/^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)

# --------------------------------------------------------- #

##@ Postgres Primary

.PHONY: postgres-primary-up
postgres-primary-up: ## Start postgres primary container
	docker-compose -f ./containers/postgres-primary/compose.yml up -d;

.PHONY: postgres-primary-down
postgres-primary-down: ## Stop & remove postgres primary container
	@read -p "Remove this project postgres primary container? [y/n] " answer; \
	if [[ "$$answer" == "y" || "$$answer" == "Y" ]]; then \
		docker-compose -f ./containers/postgres-primary/compose.yml down; \
	fi

.PHONY: postgres-primary-down-v
postgres-primary-down-v: ## Stop & remove postgres primary container + volume
	@read -p "Remove this project postgres primary container and the volume? [y/n] " answer; \
	if [[ "$$answer" == "y" || "$$answer" == "Y" ]]; then \
		docker-compose -f ./containers/postgres-primary/compose.yml down -v; \
	fi

.PHONY: postgres-primary-start
postgres-primary-start: ## Start postgres primary container
	docker-compose -f ./containers/postgres-primary/compose.yml start;

.PHONY: postgres-primary-stop
postgres-primary-stop: ## Stop postgres primary container
	docker-compose -f ./containers/postgres-primary/compose.yml stop;

.PHONY: postgres-primary-restart
postgres-primary-restart: ## Restart postgres primary container
	docker-compose -f ./containers/postgres-primary/compose.yml restart;

.PHONY: postgres-primary-logs
postgres-primary-logs: ## Tail postgres primary logs
	docker-compose -f ./containers/postgres-primary/compose.yml logs;

# --------------------------------------------------------- #

##@ Sync

.PHONY: sync-project-deps
sync-project-deps: ## Syncronize root project requirements
	cp -rf ../../schema.sql ./containers/postgres-primary/init/schema.sql;

# Generate the seed databases from the root seed script.
.PHONY: sync-seed-dev
sync-seed-dev: ## Generate the 2% seed database (conduit_dev)
	PGHOST=$(PGHOST) PGPORT=$(PGPORT) PGUSER=$(PGUSER) PGPASSWORD=$(PGPASSWORD) GOCACHE=$(GOCACHE) bash ../../seed/make-seed.sh --dev;

.PHONY: sync-seed-full
sync-seed-full: ## Generate the full seed database (conduit_seed)
	PGHOST=$(PGHOST) PGPORT=$(PGPORT) PGUSER=$(PGUSER) PGPASSWORD=$(PGPASSWORD) GOCACHE=$(GOCACHE) bash ../../seed/make-seed.sh;

# Refresh the database the app reads from the seed template.
.PHONY: sync-app
sync-app: ## Refresh conduit from SEED_TEMPLATE (default conduit_dev)
	PGPASSWORD=$(PGPASSWORD) psql -h $(PGHOST) -p $(PGPORT) -U $(PGUSER) -d postgres \
		-c "DROP DATABASE IF EXISTS conduit WITH (FORCE)" \
		-c "CREATE DATABASE conduit TEMPLATE $(SEED_TEMPLATE)";

# --------------------------------------------------------- #

##@ Debug

.PHONY: debug-build
debug-build: ## Debug build conduit
	zig build -Doptimize=Debug;

# --------------------------------------------------------- #

##@ Release

.PHONY: release-build
release-build: ## Release build conduit
	zig build -Doptimize=ReleaseFast;

# --------------------------------------------------------- #

##@ Install

.PHONY: install
install: ## Install the dependencies for this conduit
	sh ./install.sh;

##@ Build

.PHONY: build
build: ## Build the backend for this conduit
	sh ./build.sh;

##@ Start

.PHONY: start
start: ## Start the backend for this conduit
	sh ./start.sh;
