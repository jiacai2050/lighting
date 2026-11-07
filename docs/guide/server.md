# Server & Lifecycle

`Server` is the core network orchestrator in Lighting. It manages socket binding, connection accept loops, structured concurrency tasks, socket deadlines, and graceful shutdown.

---

## 1. Initializing the Server

`Server.init` takes an allocator, the Zig `std.Io` runtime handle, and `ServerOptions`:

```zig
const http = @import("lighting");

var server = http.Server.init(allocator, io, .{
    .handler = root_handler,
    .header_bytes_max = 16 * 1024,                  // Max allowed request header size (default: 8KB)
    .read_timeout_ns = 10 * std.time.ns_per_s,      // Whole-request body read timeout
    .read_header_timeout_ns = 2 * std.time.ns_per_s,// Header parsing timeout
    .write_timeout_ns = 10 * std.time.ns_per_s,     // Response flush timeout
    .idle_timeout_ns = 60 * std.time.ns_per_s,      // Keep-alive idle connection timeout
});
```

### ServerOptions Reference

| Option | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `handler` | `Handler` | *(Required)* | The root HTTP handler or router dispatching incoming requests. |
| `header_bytes_max` | `usize` | `8 * 1024` (8KB) | Maximum memory allocated for reading and parsing request headers before returning `431 Request Header Fields Too Large`. |
| `read_header_timeout_ns`| `?u64` | `null` | Maximum duration allowed to read the HTTP request line and headers. |
| `read_timeout_ns` | `?u64` | `null` | Maximum duration allowed to read the full request (including body). |
| `write_timeout_ns` | `?u64` | `null` | Maximum duration allowed to write the response back to the client. |
| `idle_timeout_ns` | `?u64` | `null` | Maximum duration an idle keep-alive connection waits for a new request before closing. |

---

## 2. Starting the Server

Lighting offers two ways to bind and start listening:

### Using Host and Port
```zig
try server.listenAndServe("0.0.0.0", 8080);
```

### Using a Pre-Bound `std.Io.net.Server`
If you need custom socket options or systemd socket activation:
```zig
try server.serve(my_listener);
```

---

## 3. Concurrency Model: Structured Concurrency

Unlike traditional multi-threaded servers that pre-allocate a fixed worker thread pool with unbounded queues, Lighting uses **native `std.Io.Group.concurrent`**:
1. The main fiber runs the non-blocking `accept` loop.
2. For each incoming connection, `group.concurrent(io, serveConnWorker, .{ self, stream })` is called.
3. Each connection executes independently within a lightweight fiber coroutine.
4. When socket I/O blocks (e.g. waiting for client packets), the fiber suspends in the OS kernel epoll/kqueue, yielding CPU immediately with zero spinloop overhead.

---

## 4. Graceful Shutdown and Lifecycle

`Server` manages its resources entirely within the execution scope of `serve()`. No manual `deinit()` is required.

Lighting provides two methods to terminate the server (matching Go's `net/http`):
- `server.close()`: **Non-blocking**. Signals the server to stop accepting new connections and returns immediately (ideal for signal handlers or inside HTTP route handlers).
- `server.shutdown()`: **Blocking**. Triggers termination and waits until all in-flight requests are completed and `serve()` has completely returned.

```zig
var server = http.Server.init(allocator, io, .{
    .handler = mux.handler(),
});

// Non-blocking exit (e.g. from an HTTP admin endpoint):
// server.close();

// Blocking graceful shutdown (e.g. from main thread awaiting drain):
// server.shutdown();

// serve() runs until close() or shutdown() is invoked:
try server.serve(listener);
```

### Shutdown Workflow:
1. When `close()` or `shutdown()` is called, an internal atomic signal wakes up the accept loop and marks the server stopped.
2. In-flight requests are allowed to complete while incoming requests are stopped.
3. All background connection workers in `self.group` are cancelled and awaited.
4. `serve()` returns cleanly with all listeners closed and workers joined, unblocking any waiting `shutdown()` call.
