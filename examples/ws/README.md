# WebSocket Example

An interactive WebSocket echo and chat service demonstrating `lighting.extra.ws`, RFC 6455 protocol upgrades, bi-directional framing, automatic Ping/Pong handling, and an embedded dark-mode browser client.

## Features

- **Protocol Upgrade**: Clean HTTP/1.1 to RFC 6455 upgrade using `lighting.extra.ws.upgrade`.
- **Full-Duplex Echo**: Handles UTF-8 text and binary payloads with automatic framing.
- **Embedded Web UI**: Single-page browser client embedded via `@embedFile("index.html")` with zero external dependencies.
- **Configurable**: Port configurable via `PORT` environment variable (default: 7000).

## Quick Start

Run the server directly from this directory:

```bash
zig build run
```

Or from the repository root:

```bash
make run-ws
```

Then open your browser to [http://127.0.0.1:7000/](http://127.0.0.1:7000/).

### Custom Port

```bash
PORT=8080 zig build run
```

## CLI Testing

You can also test the WebSocket endpoint using standard CLI tools:

### Using `websocat`

```bash
websocat ws://127.0.0.1:7000/ws
```

Type any text and press Enter to receive the echoed message back.

### Using `wscat`

```bash
wscat -c ws://127.0.0.1:7000/ws
```

### Inspecting Handshake via `curl`

```bash
curl -i -N \
  -H "Connection: Upgrade" \
  -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" \
  -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
  http://127.0.0.1:7000/ws
```

Expected response:

```text
HTTP/1.1 101 Switching Protocols
Upgrade: websocket
Connection: Upgrade
Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=
Date: ...
```
