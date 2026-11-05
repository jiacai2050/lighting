# Request Handling

The `*http.Request` struct represents an incoming HTTP/1.1 request. It provides zero-copy access to the HTTP method, parsed URI, path parameters, headers, and streaming body reader.

---

## 1. Request Structure

```zig
pub const Request = struct {
    method: []const u8,                 // e.g. "GET", "POST"
    uri: []const u8,                    // Raw request URI, e.g. "/items?page=2#top"
    proto: []const u8,                  // e.g. "HTTP/1.1"
    headers: HeaderMap,                 // Parsed HTTP headers
    url: Url,                           // Parsed path, query string, etc.
    arena: std.mem.Allocator,           // Per-request arena allocator
    body_reader: BodyReader,            // Streaming body reader (supports chunked & fixed length)
    path_values: std.StringHashMapUnmanaged([]const u8),
    remote_addr: ?std.Io.net.IpAddress, // Client IP address
};
```

---

## 2. Inspecting the URL & Query Parameters

The `req.url` struct provides pre-parsed URL components:

```zig
// Given GET /search?q=zig&page=1
const path = req.url.path;         // "/search"
const raw_query = req.url.raw_query; // "q=zig&page=1"

// Look up a specific query parameter:
if (req.url.query.get("q")) |search_term| {
    std.debug.print("Search query: {s}\n", .{search_term});
}
```

---

## 3. Extracting Path Parameters

When matching wildcard routes (e.g. `/users/{id}`), extract dynamic parameters using `req.pathValue`:

```zig
const user_id = req.pathValue("id") orelse "default";
```

Path parameter slices point directly into the connection's read buffer or request arena. No string copies are performed.

---

## 4. Reading Headers

Request headers can be inspected using `req.headers.get`:

```zig
if (req.headers.get("Authorization")) |token| {
    // Validate Bearer token
}

if (req.headers.get("Accept-Encoding")) |encodings| {
    // Check for gzip or br support
}
```

Header lookups are case-insensitive per RFC 9110.

---

## 5. Reading the Request Body

Lighting provides a streaming `BodyReader` that handles both `Content-Length` and `Transfer-Encoding: chunked` transparently:

### Reading the Entire Body into Memory

Use the per-request arena to read the full body safely with an upper bound:

```zig
// Read up to 1MB of body data
const max_body_size = 1024 * 1024;
const body_bytes = try req.body_reader.readAllAlloc(req.arena, max_body_size);

std.debug.print("Received body ({d} bytes): {s}\n", .{ body_bytes.len, body_bytes });
```

### Streaming the Body Incrementally

For large file uploads or memory-constrained environments, stream chunk by chunk:

```zig
var chunk_buf: [4096]u8 = undefined;
while (true) {
    const bytes_read = try req.body_reader.read(&chunk_buf);
    if (bytes_read == 0) break; // EOF reached

    // Process chunk_buf[0..bytes_read]
}
```

---

## 6. The Per-Request Arena

Every `*http.Request` includes `req.arena: std.mem.Allocator`.

* Any memory allocated with `req.arena` is automatically freed when the request completes.
* You do not need to call `defer arena.free(ptr)`.
* Perfect for parsing JSON payloads, assembling strings, or storing temporary context.
