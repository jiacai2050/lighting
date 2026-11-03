# Todo SPA Example (SQLite + Single Page App)

A full-stack Todo application showcasing state injection, SQLite persistence, REST API design, per-request logging, and an embedded Single Page Application (SPA) frontend.

## Features

- **State Injection**: `http.Handler.bind(&app, App.method)` to inject database into handlers.
- **SQLite**: Persistence via [`zig-sqlite`](https://github.com/nDimensional/zig-sqlite).
- **Embedded SPA**: Dark-mode frontend embedded via `@embedFile("index.html")`.
- **Configurable**: `PORT` (default: 7000) and `DB_PATH` (default: `/tmp/lighting-todo.db`).

## Quick Start

```bash
zig build run
```

Once running, visit [http://127.0.0.1:7000](http://127.0.0.1:7000) in your web browser.

### Custom Port and Database Path

```bash
PORT=8000 DB_PATH=./data/todos.db zig build run
```

## API Reference

| Method | Path | Description | Payload / Response |
| :--- | :--- | :--- | :--- |
| `GET` | `/` | Serves the SPA frontend | HTML document |
| `GET` | `/api/todos` | List all todos | `[{"id":1,"title":"...","completed":false}]` |
| `POST` | `/api/todos` | Create a new todo | Request: `{"title":"Buy milk"}`<br/>Response (201): `{"id":1,"title":"Buy milk","completed":false}` |
| `POST` | `/api/todos/{id}/toggle` | Toggle todo completion status | `{"ok":true}` |
| `DELETE` | `/api/todos/{id}` | Delete a todo by ID | `{"ok":true}` |

## Example cURL Commands

```bash
# 1. Create a task
curl -X POST http://127.0.0.1:7000/api/todos \
  -H "Content-Type: application/json" \
  -d '{"title":"Ship Lighting v1.0"}'

# 2. List all tasks
curl http://127.0.0.1:7000/api/todos

# 3. Toggle task completion
curl -X POST http://127.0.0.1:7000/api/todos/1/toggle

# 4. Delete a task
curl -X DELETE http://127.0.0.1:7000/api/todos/1
```
