# Quick Start

In this guide, you will build a complete, runnable web application using Lighting in under 5 minutes.

---

## 1. Minimal Server Code

Create `src/main.zig` with the following content:

```zig
const std = @import("std");
const http = @import("lighting");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    // 1. Initialize the router
    var mux = http.ServeMux.init(allocator);
    defer mux.deinit();

    // 2. Register a basic ping endpoint
    try mux.handleFunc("GET /ping", struct {
        fn handle(w: *http.ResponseWriter, _: *http.Request) anyerror!void {
            try w.header().set("Content-Type", "text/plain; charset=utf-8");
            try w.writeAll("pong\n");
        }
    }.handle);

    // 3. Register a route with path parameters
    try mux.handleFunc("GET /hello/{name}", struct {
        fn handle(w: *http.ResponseWriter, req: *http.Request) anyerror!void {
            const name = req.pathValue("name") orelse "stranger";
            try w.header().set("Content-Type", "text/plain; charset=utf-8");

            var buf: [128]u8 = undefined;
            const msg = try std.fmt.bufPrint(&buf, "Hello, {s}!\n", .{name});
            try w.writeAll(msg);
        }
    }.handle);

    // 4. Configure and run the server
    var server = http.Server.init(allocator, io, .{
        .handler = mux.handler(),
        .read_timeout_ns = 5 * std.time.ns_per_s,
        .write_timeout_ns = 5 * std.time.ns_per_s,
    });
    defer server.deinit();

    std.debug.print("🚀 Lighting web server running at http://127.0.0.1:8080\n", .{});
    try server.listenAndServe("127.0.0.1", 8080);
}
```

---

## 2. Running and Testing

Build and launch your application:

```bash
zig build run
```

In another terminal, test the endpoints using `curl`:

```bash
# Test /ping
$ curl -i http://127.0.0.1:8080/ping
HTTP/1.1 200 OK
Content-Type: text/plain; charset=utf-8
Content-Length: 5
Connection: keep-alive

pong

# Test path parameter
$ curl -i http://127.0.0.1:8080/hello/alice
HTTP/1.1 200 OK
Content-Type: text/plain; charset=utf-8
Content-Length: 15
Connection: keep-alive

Hello, alice!
```

---

## What Just Happened?

1. **`ServeMux.init(allocator)`**: Creates a decision-tree router with zero-allocation route lookups.
2. **`handleFunc("GET /route", handlerFn)`**: Binds a stateless function directly to an HTTP method and path pattern.
3. **`req.pathValue("name")`**: Reads extracted path segments in $O(1)$ time without any string copying or heap allocations.
4. **`w.writeAll(...)`**: Streams response data into a 4KB stack buffer, flushing directly to the client socket when full or on completion.
5. **`server.listenAndServe(io, address)`**: Dispatches accepted connections into concurrent `std.Io.Group` tasks managed by the runtime.
