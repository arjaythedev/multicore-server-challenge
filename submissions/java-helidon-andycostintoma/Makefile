.DEFAULT_GOAL := help

CONDUIT_PG_PORT ?= 5432
DATABASE_URL ?= postgres://conduit:conduit@127.0.0.1:$(CONDUIT_PG_PORT)/conduit

.PHONY: help build check test fmt fmt-check db-up db-down run generate conformance benchmark profile

help:
	@awk 'BEGIN { FS = ":.*## " } /^[a-zA-Z0-9_-]+:.*## / { printf "%-19s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

build: ## Build the runnable distribution
	./gradlew installDist

check: ## Check formatting and run unit/integration tests (Docker required)
	./gradlew check

test: ## Run unit tests
	./gradlew test

fmt: ## Format handwritten Java
	./gradlew spotlessApply

fmt-check: ## Check Java formatting
	./gradlew spotlessCheck

db-up: ## Start the local PostgreSQL container
	CONDUIT_PG_PORT="$(CONDUIT_PG_PORT)" docker compose up -d --wait

db-down: ## Stop PostgreSQL, preserving its data volume
	docker compose down

run: build ## Build and run with the local or overridden DATABASE_URL
	DATABASE_URL="$(DATABASE_URL)" ./start.sh

generate: ## Regenerate jOOQ sources (Docker required)
	./gradlew generateJooq

conformance: build ## Run the isolated upstream conformance suite
	./conformance.sh

benchmark: build ## Benchmark app, PostgreSQL and loadgen on a private Docker network
	./benchmark.sh

profile: build ## Run the benchmark with JFR enabled (not comparable to unprofiled timings)
	BENCH_PROFILE=1 ./benchmark.sh
