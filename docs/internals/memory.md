# Memory Model & Buffer Recycling

Lighting is designed to avoid heap fragmentation and provide deterministic memory usage under sustained network loads.

---

## 1. The 4KB Dual-Mode `ResponseWriter`

Every `ResponseWriter` allocates a 4KB fixed buffer directly on the thread stack:

```text
+--------------------------------------------------------------+
|            ResponseWriter (4KB Stack Fast-Path)              |
|                                                              |
|   [ Status Line ] + [ Headers ] + [ Body Data <= 4KB ]       |
+--------------------------------------------------------------+
```

### Fast Path ($\le 4\text{KB}$)
1. Headers and body data are accumulated in memory.
2. When the handler exits, Lighting computes `Content-Length: <len>` automatically.
3. Slices are packaged into a stack-allocated IO vector array (`[3]std.posix.iovec`).
4. A single vectored write transmits the entire HTTP frame to the network socket.
5. **No heap allocations are performed.**

### Overflow Path ($> 4\text{KB}$)
1. Once 4KB is exceeded, Lighting flushes headers with `Transfer-Encoding: chunked`.
2. Subsequent writes stream in chunks directly to the socket.

---

## 2. Per-Request Arena Allocator

Instead of using the general-purpose allocator (`GPA`) for request processing, Lighting provisions a `std.heap.ArenaAllocator`:

```zig
var arena_state = std.heap.ArenaAllocator.init(self.allocator);
defer arena_state.deinit();

var req = Request{
    .arena = arena_state.allocator(),
    // ...
};
```

* All temporary objects (URL query maps, parsed headers, route parameters, JSON DOMs) use `req.arena`.
* Upon request completion, `arena_state.deinit()` (or `reset()`) reclaims all memory in $O(1)$ time.
* This eliminates pointer tracking, prevents use-after-free bugs, and drastically reduces memory fragmentation.

---

## 3. Residual Body Draining

When a client sends a request with a large body that the handler ignores (e.g., an unauthorized `POST /upload` returning `401 Unauthorized` without reading the file), unread bytes remain in the TCP socket.

If the server simply attempts to read the next HTTP request, it will mistake the leftover upload data for HTTP verbs, leading to parse failures and desync attacks.

Lighting implements bounded automatic draining:
* **Drain Threshold**: Up to 256KB of leftover body is drained automatically.
* **DoS Protection**: If leftover body exceeds 256KB, Lighting closes the connection immediately rather than wasting CPU cycles downloading discarded bytes.
