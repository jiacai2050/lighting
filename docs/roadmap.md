# Lighting Feature Parity & Roadmap

This document provides a gap analysis comparing **Lighting** against Go's standard `net/http` library and outlines the roadmap for future development.

---

## 1. Current State vs. Go `net/http`

Lighting provides a solid foundation for HTTP/1.1 services:

* **Go 1.22+ Pattern Routing**: Method constraints, zero-copy path parameters (`{id}`), wildcards (`{filepath...}`), exact match (`/{$}`), and automatic 405 Method Not Allowed.
* **Structured Concurrency**: Native `std.Io.Group.concurrent` task dispatching (paralleling Go's `go c.serve()`) with user-space Fiber execution.
* **Zero-Copy Protocol Parser**: In-place header and path extraction directly from the socket buffer.
* **Dual-Mode ResponseWriter**: Automatic `Content-Length` buffering (< 4KB) and streaming chunked transfer encoding for larger bodies.
* **Production Hardening**: Slowloris defense via monotonic header deadlines, Keep-Alive connection reuse, RFC 9112 request smuggling prevention, and connection-scoped Arena reuse with high-water mark protection (`request_arena_retain_limit`).

---

## 2. Feature Parity Matrix

The following table summarizes the status of Lighting's phased features:

| Capability | Go `net/http` | Lighting Current | Impact / Notes |
| :--- | :--- | :--- | :--- |
| **`http.Flusher`** | `w.(http.Flusher).Flush()` | ✅ `ResponseWriter.flush()` | Immediate output in **Server-Sent Events (SSE)** and **LLM token streaming**. |
| **`http.Hijacker`** | `w.(http.Hijacker).Hijack()` | ✅ `ResponseWriter.hijack()` | Raw TCP socket handoff for protocol upgrades. |
| **WebSocket** | `golang.org/x/net/websocket` | ✅ `lighting.extra.ws` | Full RFC 6455 handshake, frame parsing, XOR unmasking, Ping/Pong, and echo. |
| **Static File Server** | `http.FileServer(http.Dir)` | ✅ `lighting.extra.fs.FileServer` | RFC 7233 `Range` requests (audio/video seek), `ETag` / `If-Modified-Since` (304), MIME detection, and responsive directory browser. |
| **Query Parameters** | `req.URL.Query()` multi-value map | ✅ `req.url.query()` / `queryParam()` | Multi-value parsed query map (`QueryParams`), single-key zero-copy lookup, and key existence checks. |
| **Cookies** | `req.Cookie()`, `http.SetCookie()` | ✅ `lighting.Cookie`, `req.cookie()`, `w.setCookie()` | RFC 6265 typed cookie parser, iterator, and `Set-Cookie` builder supporting `SameSite`, `HttpOnly`, `Secure`, `Expires`, and `Max-Age`. |
| **Multipart Form** | `req.ParseMultipartForm()` | ✅ `lighting.MultipartForm`, `req.multipartForm()` | Streaming parser for RFC 7578 `multipart/form-data` with disk spilling for file uploads exceeding memory thresholds. |
| **Reverse Proxy** | `httputil.ReverseProxy` | ✅ `lighting.extra.proxy.ReverseProxy` | Reverse proxy forwarding requests, stripping RFC 9110 hop-by-hop headers, injecting `X-Forwarded-*`, and streaming bodies. |
| **Route Timeouts** | `http.TimeoutHandler` | ✅ `lighting.timeoutHandler()` | Route-level timeout middleware canceling handler execution and returning 504 Gateway Timeout on overrun. |
| **HTTP Client** | `http.Client`, `Transport` pool | ✅ `lighting.Client` | High-level HTTP client with `get`, `post`, `postForm`, `do`, `CookieJar`, `ConnPool`, and redirect following. |
| **Panic Recovery** | `defer recover()` per connection | ⚠️ Errors caught, `@panic` fatal | Handler panics crash the task/process instead of returning HTTP 500; `anyerror` gracefully handled as 500. |
| **TLS / HTTPS** | `ListenAndServeTLS` | ❌ Not implemented | Requires an external reverse proxy (e.g. Nginx, Caddy) for SSL termination. |
| **HTTP/2 Support** | Built-in via ALPN negotiation | ❌ HTTP/1.1 only | No multiplexing over a single TCP connection. |

---

## 3. Phased Roadmap

### Phase 1: Real-Time & Streaming Primitives (Completed)
* [x] **`ResponseWriter.flush()`**:
  Allow handlers to immediately push buffered chunks to the TCP socket without closing the connection. Enables Server-Sent Events (SSE) and generative AI chat streaming.
* [x] **`ResponseWriter.hijack()`**:
  Allow handlers to take ownership of the underlying `std.Io.net.Stream`. Enables WebSocket servers and protocol upgrade handshakes.
* [x] **Handler Fault Isolation**:
  Add graceful error reporting and stack recovery if handler code triggers unexpected failures.
* [x] **WebSocket Support (`lighting.extra.ws`)**:
  RFC 6455 compliance with frame parsing, control frames, and interactive echo clients.

### Phase 2: Enhanced Request Parsing & Utilities (Completed)
* [x] **Cookie Support**:
  Add a zero-copy `Cookie` parser and `Set-Cookie` builder supporting RFC 6265 attributes (`HttpOnly`, `Secure`, `SameSite`, `Max-Age`).
* [x] **Comprehensive URL Query Parameter Decoder**:
  Extend `URL.queryParam` into full multi-value iterator and helper to decode percent-encoded query parameters.
* [x] **Multipart Form Data Parser**:
  Streamed parser for `multipart/form-data` with configurable memory and file size limits for file uploads.

### Phase 3: Ecosystem Handlers & Middleware (Completed)
* [x] **Static File Server (`lighting.extra.fs.FileServer`)**:
  Serve directory trees with automatic `Content-Type` deduction, RFC 7233 `Range` requests, and `If-Modified-Since` / `ETag` 304 caching.
* [x] **Reverse Proxy Handler (`lighting.extra.proxy.ReverseProxy`)**:
  Built-in reverse proxy with Director callback to rewrite request headers, strip hop-by-hop headers, and stream responses back.
* [x] **Route-Level Timeout Middleware (`lighting.timeoutHandler`)**:
  Middleware to cancel or abort specific handler executions exceeding an allotted duration.

### Phase 4: Protocol Expansion
* [ ] **Native TLS / HTTPS Support**:
  Integrate with Zig TLS implementations or OS-native TLS facilities to serve HTTPS directly on port 443.
* [ ] **HTTP/2 Protocol Support**:
  Support HTTP/2 framing, header compression (HPACK), and frame-level stream multiplexing.
