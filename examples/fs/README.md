# File Server Example

A high-performance static file server demonstrating HTTP Range requests (partial content for audio/video streaming and broken download resumption), ETag conditional caching (304 Not Modified), path traversal defense, and dynamic directory browsing with an adaptive dark mode UI.

## Features

- **RFC 9110 Range Requests**: Supports `bytes=start-end`, `bytes=start-`, and `bytes=-suffix` with `206 Partial Content` and `416 Range Not Satisfiable` validation.
- **RFC 9111 ETag & Conditional Caching**: Weak ETag calculation (`W/"<mtime>-<size>"`) matching `If-None-Match` to respond with `304 Not Modified`.
- **Directory Auto-Index**: Automatically renders an interactive file browsing page with breadcrumb navigation, instant search filter, file sizes, timestamps, and dark mode preference persistence.
- **Path Traversal Protection**: Rejects `../` and directory escape attacks with `403 Forbidden`.
- **Configurable Directory**: Defaults to the current working directory (`.`), or pass any directory as a positional argument.

## Quick Start

### 1. Serve Current Directory (Default)

```bash
cd examples/fs
zig build run
```

Or from the repository root:

```bash
make run-fs
```

Open [http://127.0.0.1:7000](http://127.0.0.1:7000) in your web browser to browse files with adaptive dark mode.

### 2. Serve a Custom Directory

Pass the target directory path as a CLI argument:

```bash
# Serve the src directory
zig build run -- src

# Serve an arbitrary directory
zig build run -- /var/log
```

### 3. Custom Port

```bash
PORT=8080 zig build run -- .
```

## Testing with cURL

### 1. Range Request (Partial Content)

Fetch only the first 16 bytes of `build.zig`:

```bash
curl -i -H "Range: bytes=0-15" http://127.0.0.1:7000/build.zig
```

Response:
```http
HTTP/1.1 206 Partial Content
Accept-Ranges: bytes
Content-Range: bytes 0-15/...
Content-Length: 16
Content-Type: text/plain; charset=utf-8
```

### 2. ETag Caching (304 Not Modified)

Fetch file and inspect ETag:

```bash
curl -i http://127.0.0.1:7000/build.zig.zon
```

Request with `If-None-Match`:

```bash
curl -i -H 'If-None-Match: W/"..."' http://127.0.0.1:7000/build.zig.zon
```

Response:
```http
HTTP/1.1 304 Not Modified
```

### 3. Path Traversal Defense

Attempting to escape root:

```bash
curl -i http://127.0.0.1:7000/../build.zig
```

Response:
```http
HTTP/1.1 403 Forbidden
```
