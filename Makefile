.PHONY: help build test fmt fmt-check bench bench-all run-hello run-todo run-ws run-fs docs docs-serve clean

.DEFAULT_GOAL := help

help: ## Show this help message
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

build: ## Build the main library
	zig build

test: ## Run unit and end-to-end integration tests
	zig build test --summary all

fmt: ## Format all Zig source files
	zig fmt src/ bench/ examples/ build.zig

fmt-check: ## Check formatting of all Zig source files
	zig fmt --check src/ bench/ examples/ build.zig

bench: ## Run the Zig benchmark server
	cd bench/zig && zig build run -Doptimize=ReleaseFast

bench-all: ## Run the comparative benchmark suite across Zig, Go, and Rust
	python3 bench/run.py

run-hello: ## Run the hello example server
	cd examples/hello && zig build run

run-todo: ## Run the todo SPA & SQLite example server
	cd examples/todo && zig build run

run-ws: ## Run the WebSocket chat & echo example server
	cd examples/ws && zig build run

run-fs: ## Run the static file server example
	cd examples/fs && zig build run

docs: ## Build documentation with mdBook
	mdbook build

docs-serve: ## Serve documentation locally with mdBook
	mdbook serve --open

clean: ## Clean build artifacts and temporary cache
	rm -rf zig-out .zig-cache book bench/zig/zig-out bench/zig/.zig-cache bench/go/bench-go bench/rust/target examples/hello/zig-out examples/hello/.zig-cache examples/todo/zig-out examples/todo/.zig-cache examples/ws/zig-out examples/ws/.zig-cache examples/fs/zig-out examples/fs/.zig-cache *.db *.db-journal
