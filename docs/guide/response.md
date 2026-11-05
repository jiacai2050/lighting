# Response & Streaming

The `*http.ResponseWriter` struct is used to construct and send the HTTP response to the client. It implements a dual-mode buffering design: small responses stay strictly on the stack, while larger bodies transition into chunked streaming automatically.

---

## 1. Setting Status Codes & Headers

Headers can be manipulated via `w.header()`:

```zig
try w.header().set("Content-Type", "application/json; charset=utf-8");
try w.header().set("X-Server", "Lighting/0.1.0");
try w.header().set("Cache-Control", "no-cache");
```

### Explicit Status Code
By default, the status code is `200 OK`. To return a different status code:

```zig
w.writeHeader(.not_found); // 404 Not Found
// or:
w.writeHeader(.created);   // 201 Created
// or use the setStatus alias:
w.setStatus(.no_content);  // 204 No Content
```

> [!NOTE]
> `w.writeHeader(...)` must be called before writing body bytes. Once bytes are written, the response headers are locked and automatically transmitted to the client.

---

## 2. Writing Body Content

Lighting provides multiple convenient methods to write body data:

### Direct Byte Slices
```zig
try w.writeAll("Hello from Lighting!\n");
```

### Formatted Output (`w.writer()`)
The `w.writer()` method returns a standard Zig `std.io.Writer` supporting `print`:

```zig
try w.writer().print("Counter value: {d}, User: {s}\n", .{ 42, "admin" });
```

---

## 3. The 4KB Stack Buffer Optimization

For optimal latency and throughput, `ResponseWriter` embeds a **4KB internal stack buffer**:

```text
+--------------------------------------------------------------+
|             ResponseWriter (allocated on stack)              |
|                                                              |
|   +------------------------------------------------------+   |
|   | 4KB Stack Buffer (Accumulates headers & small body)  |   |
|   +------------------------------------------------------+   |
+--------------------------------------------------------------+
```

* **Responses <= 4KB**: When `handle` returns, Lighting calculates the exact `Content-Length`, synthesizes the HTTP response header, and sends both the headers and body in a single vectored `writeSocketAll` syscall. **Zero heap allocation occurs.**
* **Responses > 4KB**: As soon as the 4KB buffer overflows, Lighting automatically switches to `Transfer-Encoding: chunked` and flushes buffers sequentially across the network.

---

## 4. Streaming Large Data

For large payloads or file downloads, stream directly into `w.writeAll`:

```zig
try w.header().set("Content-Type", "application/octet-stream");

var offset: usize = 0;
while (offset < total_size) {
    const chunk = getNextChunk(offset);
    try w.writeAll(chunk);
    offset += chunk.len;
}
```

---

## 5. Early Redirects & Common Errors

You can also send standard error responses or redirects quickly:

```zig
// 301 Moved Permanently
try w.header().set("Location", "/new-path");
w.writeHeader(.moved_permanently);

// 400 Bad Request
w.writeHeader(.bad_request);
try w.writeAll("Invalid JSON body\n");
```

---

## 6. Manual Flushing & Connection Hijacking

### Immediate Flushing (`w.flush()`)
By default, responses are buffered in memory and flushed automatically when your handler finishes. If you are serving real-time events (e.g., Server-Sent Events / SSE) or progressive chunks, invoke `w.flush()`:

```zig
try w.writeAll("data: event 1\n\n");
try w.flush(); // Sends headers (if not sent) and flushes the 4KB buffer immediately
```

If `Content-Length` was not specified, the first call to `flush()` automatically transitions the HTTP/1.1 connection to `Transfer-Encoding: chunked`.

### Connection Hijacking (`w.hijack()`)
For custom binary protocols, raw TCP tunnels, or WebSocket upgrades, `w.hijack()` gives you complete ownership of the underlying client `std.Io.net.Stream`:

```zig
const stream = try w.hijack();
// Sockets hijacked this way are unregistered from server shutdown tracking.
// You are now solely responsible for reading, writing, and closing the stream:
defer stream.close(w.io);
```

> [!WARNING]
> Any trailing request bytes already prefetched into the server's connection buffer are not forwarded. Ensure your handshake requires the client to wait for the server's upgrade response before transmitting protocol frames.
