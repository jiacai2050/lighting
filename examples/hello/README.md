# Hello Example

A minimal starter project demonstrating basic HTTP routing, dynamic path parameters, request logging, and environment configuration in `lighting`.

## Features

- **Juicy Main**: `pub fn main(init: std.process.Init) !void` entry point.
- **Routing**: Path parameters (`/hello/{name}`) and exact root (`/{$}`).
- **Logging**: Per-request status and latency via `http.LoggingHandler`.
- **Configurable**: Port via `PORT` env var (default: 7000).

## Quick Start

```bash
zig build run
```

### Custom Port

```bash
PORT=8080 zig build run
```

## Available Endpoints

| Method | Path | Description | Example |
| :--- | :--- | :--- | :--- |
| `GET` | `/` | Root greeting text | `curl http://127.0.0.1:7000/` |
| `GET` | `/hello/{name}` | Greet with name parameter | `curl http://127.0.0.1:7000/hello/zig` |
