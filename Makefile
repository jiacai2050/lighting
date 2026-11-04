.PHONY: help build test fmt fmt-check bench run-hello run-todo run-ws clean

.DEFAULT_GOAL := help

help: ## Show this help message
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

build: ## Build the main library and benchmark server
	zig build

test: ## Run unit and end-to-end integration tests
	zig build test --summary all

fmt: ## Format all Zig source files
	zig fmt src/ bench/ examples/ build.zig

fmt-check: ## Check formatting of all Zig source files
	zig fmt --check src/ bench/ examples/ build.zig

bench: ## Run the benchmark server
	zig build bench

run-hello: ## Run the hello example server
	cd examples/hello && zig build run

run-todo: ## Run the todo SPA & SQLite example server
	cd examples/todo && zig build run

run-ws: ## Run the WebSocket chat & echo example server
	cd examples/ws && zig build run

clean: ## Clean build artifacts and temporary cache
	rm -rf zig-out .zig-cache examples/hello/zig-out examples/hello/.zig-cache examples/todo/zig-out examples/todo/.zig-cache examples/ws/zig-out examples/ws/.zig-cache *.db *.db-journal
