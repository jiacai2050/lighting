# Lighting Feature Parity & Roadmap

This document provides a gap analysis comparing **Lighting** against Go's standard `net/http` library and outlines the roadmap for future development.

---

## 1. Current State vs. Go `net/http`

Lighting provides a solid foundation for HTTP/1.1 services in Zig 0.17:

* **Go 1.22+ Pattern Routing**: Method constraints, zero-copy path parameters (`{id}`), wildcards (`{filepath...}`), exact match (`/{$}`), and automatic 405 Method Not Allowed.
* **Structured Concurrency**: Native `std.Io.Group.concurrent` task dispatching (paralleling Go's `go c.serve()`) with user-space Fiber execution.
* **Zero-Copy Protocol Parser**: In-place header and path extraction directly from the socket buffer.
* **Dual-Mode ResponseWriter**: Automatic `Content-Length` buffering (< 4KB) and streaming chunked transfer encoding for larger bodies.
* **Production Hardening**: Slowloris defense via monotonic header deadlines, Keep-Alive connection reuse, and RFC 9112 request smuggling prevention.

---

## 2. Feature Parity Matrix

The following table summarizes the differences between Go's standard library and Lighting:

| Capability | Go `net/http` | Lighting Current | Impact / Notes |
| :--- | :--- | :--- | :--- |
| **`http.Flusher`** | `w.(http.Flusher).Flush()` | ✅ `ResponseWriter.flush()` | Immediate output in **Server-Sent Events (SSE)** and **LLM token streaming**. |
| **`http.Hijacker`** | `w.(http.Hijacker).Hijack()` | ✅ `ResponseWriter.hijack()` | Raw TCP socket handoff for protocol upgrades. |
| **WebSocket** | `golang.org/x/net/websocket` | ✅ `lighting.extra.ws` | Full RFC 6455 handshake, frame parsing, XOR unmasking, Ping/Pong, and echo. |
| **Panic Recovery** | `defer recover()` per connection | ⚠️ Errors caught, `@panic` fatal | Handler panics crash the task/process instead of returning HTTP 500. |
| **Cookies** | `req.Cookie()`, `http.SetCookie()` | ⚠️ Raw headers only | Lacks typed cookie serialization and `SameSite`, `HttpOnly`, `Expires` attributes. |
| **Multipart Form** | `req.ParseMultipartForm()` | ❌ Not implemented | Essential for HTML file uploads and form-data payloads. |
| **Query Parameters** | `req.URL.Query()` multi-value map | ⚠️ Raw query string | Requires manual percent-decoding and key-value splitting. |
| **Static File Server** | `http.FileServer(http.Dir)` | ❌ Not implemented | Missing `Range` requests (streaming media/resumes), `If-Modified-Since` (304), and MIME detection. |
| **Reverse Proxy** | `httputil.ReverseProxy` | ❌ Not implemented | Useful for API gateways, microservice routing, and load balancing. |
| **Route Timeouts** | `http.TimeoutHandler` | ⚠️ Global timeouts only | Cannot set custom timeouts for individual heavy-computation routes. |
| **TLS / HTTPS** | `ListenAndServeTLS` | ❌ Not implemented | Requires an external reverse proxy (e.g. Nginx, Caddy) for SSL termination. |
| **HTTP/2 Support** | Built-in via ALPN negotiation | ❌ HTTP/1.1 only | No multiplexing over a single TCP connection. |
| **HTTP Client** | `http.Client`, `Transport` pool | ❌ Server only | Focus is currently on server-side architecture. |

---

## 3. Phased Roadmap

### Phase 1: Real-Time & Streaming Primitives (High ROI)
* [x] **`ResponseWriter.flush()`**:
  Allow handlers to immediately push buffered chunks to the TCP socket without closing the connection. Enables Server-Sent Events (SSE) and generative AI chat streaming.
* [x] **`ResponseWriter.hijack()`**:
  Allow handlers to take ownership of the underlying `std.Io.net.Stream`. Enables WebSocket servers and protocol upgrade handshakes.
* [x] **Handler Fault Isolation**:
  Add graceful error reporting and stack recovery if handler code triggers unexpected failures.

### Phase 2: Enhanced Request Parsing & Utilities
* [ ] **Cookie Support**:
  Add a zero-copy `Cookie` parser and `Set-Cookie` builder supporting RFC 6265 attributes (`HttpOnly`, `Secure`, `SameSite`, `Max-Age`).
* [ ] **URL Query Parameter Decoder**:
  Provide an iterator and helper to decode percent-encoded query parameters from `req.url.query`.
* [ ] **Multipart Form Data Parser**:
  Streamed parser for `multipart/form-data` with configurable memory and file size limits for file uploads.

### Phase 3: Ecosystem Handlers & Middleware
* [ ] **Static File Server (`http.FileServer`)**:
  Serve directory trees with automatic `Content-Type` deduction, RFC 7233 `Range` requests, and `If-Modified-Since` / `ETag` 304 caching.
* [ ] **Reverse Proxy Handler (`http.ReverseProxy`)**:
  Built-in reverse proxy with Director callback to rewrite request headers and stream responses back.
* [ ] **Route-Level Timeout Middleware**:
  Middleware to cancel or abort specific handler executions exceeding an allotted duration.

### Phase 4: Protocol Expansion
* [ ] **Native TLS / HTTPS Support**:
  Integrate with Zig TLS implementations or OS-native TLS facilities to serve HTTPS directly on port 443.
* [ ] **HTTP/2 Protocol Support**:
  Support HTTP/2 framing, header compression (HPACK), and frame-level stream multiplexing.
