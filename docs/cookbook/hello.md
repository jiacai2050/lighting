# Minimal REST Service

This recipe demonstrates building a clean, zero-dependency REST microservice with routing, dynamic path variables, and request logging.

Source code: [`examples/hello/main.zig`](https://github.com/jiacai2050/lighting/tree/main/examples/hello)

---

## Code Walkthrough

```zig
const std = @import("std");
const http = @import("lighting");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const port: u16 = if (init.environ_map.get("PORT")) |p|
        std.fmt.parseInt(u16, p, 10) catch 7000
    else
        7000;

    var mux = http.ServeMux.init(allocator);
    defer mux.deinit();

    // 1. Root greeting (Exact match)
    try mux.handleFunc("GET /{$}", struct {
        fn handle(w: *http.ResponseWriter, _: *http.Request) anyerror!void {
            try w.header().set("Content-Type", "text/plain; charset=utf-8");
            try w.writeAll("⚡️ Welcome to Lighting HTTP server!\n");
        }
    }.handle);

    // 2. Dynamic path parameter: /hello/{name}
    try mux.handleFunc("GET /hello/{name}", struct {
        fn handle(w: *http.ResponseWriter, req: *http.Request) anyerror!void {
            const name = req.pathValue("name") orelse "friend";
            try w.header().set("Content-Type", "text/plain; charset=utf-8");
            try w.writer().print("Hello, {s}!\n", .{name});
        }
    }.handle);

    // 3. Wrap with logging middleware
    var logging = http.LoggingHandler{ .next = mux.handler() };

    var server = http.Server.init(allocator, io, .{
        .handler = logging.handler(),
    });
    defer server.deinit();

    std.log.info("Hello server listening on http://127.0.0.1:{d}...", .{port});
    try server.listenAndServe("127.0.0.1", port);
}
```

---

## Running the Example

```bash
make run-hello
```

Test with curl:
```bash
$ curl -i http://127.0.0.1:7000/hello/zig
HTTP/1.1 200 OK
Content-Type: text/plain; charset=utf-8
Content-Length: 11
Connection: keep-alive

Hello, zig!
```
