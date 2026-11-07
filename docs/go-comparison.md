# Comparison with Go `net/http`

Lighting is designed with deliberate architectural sympathy toward Go's standard `net/http` package. To maintain sharp architectural focus and zero-overhead performance, **Lighting specializes strictly as a high-performance HTTP server engine**. The complementary HTTP client implementation resides in the [stdgo](https://github.com/jiacai2050/stdgo) project (`net/http`).

This document provides a comprehensive feature parity and API mapping comparison between Go `net/http` and Lighting.

---

## 1. Feature Parity Overview

### 1.1 Server-Side Capabilities

| Capability | Go `net/http` | Lighting | Architectural Notes |
| :--- | :--- | :---: | :--- |
| **Go 1.22+ Routing** | `http.ServeMux` | ✅ Full Parity | Pattern routing with method constraints, `{id}`, `{filepath...}`, `/{$}` exact match, and automatic 405 Method Not Allowed. |
| **Structured Concurrency** | `go c.serve()` | ✅ Full Parity | Native `std.Io.Group.concurrent` user-space Fiber dispatching per connection with zero thread starvation. |
| **Dual-Mode ResponseWriter** | `http.ResponseWriter` | ✅ Full Parity | Automatic stack-buffered `Content-Length` (<4KB) and streaming chunked transfer coding (>=4KB). |
| **Flusher** | `w.(http.Flusher).Flush()` | ✅ `w.flush()` | Immediate socket flush without closing connection (essential for Server-Sent Events and LLM token streaming). |
| **Hijacker** | `w.(http.Hijacker).Hijack()` | ✅ `w.hijack()` | Raw TCP socket handoff for protocol upgrades. |
| **WebSocket** | `golang.org/x/net/websocket` | ✅ `lighting.extra.ws` | Full RFC 6455 handshake, frame parsing, XOR unmasking, Ping/Pong, and echo. |
| **Static File Server** | `http.FileServer(http.Dir)` | ✅ `lighting.extra.fs.FileServer` | RFC 7233 Range requests (audio/video seek), ETag/If-Modified-Since (304), MIME deduction, and directory listing. |
| **Query Parameters** | `req.URL.Query()` | ✅ `req.url.query()` | Multi-value parsed query map (`QueryParams`), single-key zero-copy lookup. |
| **Cookies** | `req.Cookie()`, `http.SetCookie()` | ✅ `lighting.Cookie` | RFC 6265 typed cookie parser, iterator, and `Set-Cookie` builder (`w.setCookie`). |
| **Multipart Form** | `req.ParseMultipartForm()` | ✅ `lighting.MultipartForm` | Streaming RFC 7578 multipart/form-data parser with configurable memory limit and disk spilling. |
| **Reverse Proxy** | `httputil.ReverseProxy` | ✅ `lighting.extra.proxy.ReverseProxy` | Forwarding proxy with RFC 9110 hop-by-hop header stripping and `X-Forwarded-*` header injection. |
| **Route Timeouts** | `http.TimeoutHandler` | ✅ `lighting.timeoutHandler()` | Route-level timeout middleware canceling handler execution and returning 504 Gateway Timeout. |

### 1.2 Scope and Client Boundary

Lighting intentionally confines its core scope to server-side HTTP serving. For client-side HTTP operations (such as `http.Get`, `http.Post`, Keep-Alive pooling, redirect following, and `CookieJar`), use the companion [**stdgo** (https://github.com/jiacai2050/stdgo)](https://github.com/jiacai2050/stdgo) repository (`net/http` package), which mirrors Go's standard client API identically in Zig.

---

## 2. Server API Mapping Reference

The table below maps common Go server idioms directly to their Lighting counterparts:

| Task | Go Idiom | Lighting Equivalent |
| :--- | :--- | :--- |
| Create Router | `mux := http.NewServeMux()` | `var mux = http.ServeMux.init(allocator);` |
| Register Route | `mux.HandleFunc("GET /users/{id}", fn)` | `try mux.handleFunc("GET /users/{id}", handler);` |
| Extract Path Param | `id := req.PathValue("id")` | `const id = req.pathValue("id");` |
| Write Status | `w.WriteHeader(http.StatusOK)` | `w.setStatus(.ok);` |
| Write Header | `w.Header().Set("Content-Type", "text/plain")` | `try w.header().set("Content-Type", "text/plain");` |
| Write Response | `w.Write([]byte("hello"))` | `try w.writeAll("hello");` |
| Stream Flush | `w.(http.Flusher).Flush()` | `try w.flush();` |
| Protocol Hijack | `conn, _, _ := w.(http.Hijacker).Hijack()` | `const stream = try w.hijack();` |
| Listen & Serve | `http.ListenAndServe(":8080", mux)` | `var server = http.Server.init(allocator, io, .{ .handler = mux.handler() });`<br>`try server.listenAndServe("0.0.0.0", 8080);` |
| Non-blocking Close | `srv.Close()` | `server.close();` |
| Graceful Shutdown | `srv.Shutdown(ctx)` | `server.shutdown();` |

---

## 3. Architectural Differences & Current Boundaries

While Lighting strives for developer ergonomics on par with Go, systems differences between Go's runtime and Zig lead to intentional architectural distinctions:

1. **Memory Allocation**:
   - *Go*: Relies on a garbage collector (GC) for request/response lifetimes and escaped buffers.
   - *Lighting*: Uses connection-scoped and per-request `ArenaAllocator` lifecycles with strict bounds. Responses <= 4KB use stack memory without GPA invocations, achieving deterministic latency.
2. **TLS / HTTPS**:
   - *Go*: Includes an in-tree TLS 1.3 implementation (`crypto/tls`) in the standard library.
   - *Lighting*: Focuses strictly on high-performance plaintext HTTP/1.1; SSL termination is typically delegated to fronting reverse proxies (e.g., Nginx, Caddy, or AWS ALB).
3. **HTTP/2**:
   - *Go*: Bundles HTTP/2 framing with automatic ALPN negotiation.
   - *Lighting*: Specializes in ultra-low-latency HTTP/1.1 microservices. HTTP/2 is planned for future phases.
4. **Panic Isolation**:
   - *Go*: Recovers from handler panics per-goroutine via `defer recover()`, returning an HTTP 500 without crashing the server process.
   - *Lighting*: All Zig error returns (`anyerror`) are caught and gracefully converted into HTTP 500 responses. However, language-level `@panic` calls will terminate the process because Zig does not provide a universal cross-platform stack unwind/catch mechanism.

---

## 4. Request and Response Models: Go vs. Lighting

The table below contrasts how Go `net/http` and Lighting model HTTP requests and responses:

| Dimension | Server Request | Server Response | Go Client Request (`stdgo`) | Go Client Response (`stdgo`) |
| :--- | :--- | :--- | :--- | :--- |
| **Go `net/http`** | `*http.Request` | `http.ResponseWriter` (interface) | `*http.Request` (monolithic struct) | `*http.Response` (struct) |
| **Lighting / [`stdgo`](https://github.com/jiacai2050/stdgo)** | `lighting.Request` | `lighting.ResponseWriter` (struct) | `stdgo.net.http.Request` | `stdgo.net.http.Response` |
| **Data Flow** | Inbound (read/parse) | Outbound (serialize/write) | Outbound (construct/send) | Inbound (read/parse) |
| **Target URL** | Relative path and query (`req.url.path`, `req.url.query`) | N/A | Absolute URI with scheme and host | N/A |
| **Memory & Lifecycle** | Zero-copy slices borrowed from socket buffer; per-request Arena lifetime | Dual-mode stack buffer (<4KB) or chunked stream; connection lifetime | Caller-managed payload and outbound headers | Heap headers; streaming socket body reader (`resp.body.read`) |
| **Type Design & Safety** | Zero-copy parsed view. Handlers read paths, query params, and body directly from socket/arena buffers with no allocations. | Active writer/sink supporting flush, cookies, and connection hijacking. | Builder model. Clear separation prevents runtime field collisions (such as Go's `RequestURI` conflict on clients). | Parsed status and streaming reader. Connection returned to Keep-Alive pool upon EOF. |
