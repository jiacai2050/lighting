# Hello Example

A minimal starter project demonstrating basic HTTP routing, dynamic path parameters, request logging, and environment configuration in `lighting`.

## Features

- **Juicy Main**: Uses Zig 0.17's `pub fn main(init: std.process.Init) !void` entry point without manual allocator/IO boilerplate.
- **Go 1.22+ Style Routing**: Exact matching (`GET /{$}`) and path wildcard parameters (`GET /hello/{name}`).
- **Per-request Logging**: Built-in `http.LoggingHandler` printing method, path, HTTP status, and latency.
- **Configurable Port**: Reads `PORT` from environment variables, defaulting to `7000`.

## Quick Start

### 1. Run inside this directory

```bash
cd examples/hello
zig build run
```

### 2. Run from repository root

```bash
zig build run-hello
```

### 3. Run on custom port

```bash
PORT=8080 zig build run
```

## Available Endpoints

| Method | Path | Description | Example |
| :--- | :--- | :--- | :--- |
| `GET` | `/` | Root greeting text | `curl http://127.0.0.1:7000/` |
| `GET` | `/hello/{name}` | Greet with name parameter | `curl http://127.0.0.1:7000/hello/zig` |
