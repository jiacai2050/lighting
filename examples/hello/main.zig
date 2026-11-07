const std = @import("std");
const http = @import("lighting");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const port: u16 = if (init.environ_map.get("PORT")) |p| std.fmt.parseInt(u16, p, 10) catch 7000 else 7000;

    var mux = http.ServeMux.init(allocator);
    defer mux.deinit();

    // 1. Root greeting
    try mux.handleFunc("GET /{$}", struct {
        fn handle(w: *http.ResponseWriter, _: *http.Request) anyerror!void {
            try w.header().set("Content-Type", "text/plain; charset=utf-8");
            try w.writeAll("⚡️ Welcome to Lighting HTTP server!\n\nTry visiting:\n  - GET /hello/world\n  - GET /hello/zig\n");
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

    var logging = http.LoggingHandler{ .next = mux.handler() };

    var server = http.Server.init(allocator, io, .{
        .handler = logging.handler(),
    });

    std.log.info("Hello server listening on http://127.0.0.1:{d}...", .{port});
    try server.listenAndServe("127.0.0.1", port);
}
