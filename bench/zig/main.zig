const std = @import("std");
const http = @import("lighting");
const zio = @import("zio");

pub const std_options: std.Options = .{
    .log_level = .info,
};

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.smp_allocator;
    const port: u16 = if (init.environ_map.get("PORT")) |p| std.fmt.parseInt(u16, p, 10) catch 7000 else 7000;
    const io_backend = init.environ_map.get("IO") orelse "zio";

    var rt_opt: ?*zio.Runtime = null;
    defer if (rt_opt) |rt| rt.deinit();

    const is_std = std.ascii.eqlIgnoreCase(io_backend, "std");
    const io = if (is_std)
        init.io
    else blk: {
        const rt = try zio.Runtime.init(allocator, .{
            .executors = .auto,
        });
        rt_opt = rt;
        break :blk rt.io();
    };

    const io_name = if (is_std) "std.Io" else "lalinsky/zio";

    var mux = http.ServeMux.init(allocator);
    defer mux.deinit();

    // 1. Minimal plaintext ping
    try mux.handleFunc("GET /ping", struct {
        fn handle(w: *http.ResponseWriter, _: *http.Request) anyerror!void {
            try w.header().set("Content-Type", "text/plain; charset=utf-8");
            try w.writeAll("pong\n");
        }
    }.handle);

    // 2. Dynamic path parameter & JSON response
    try mux.handleFunc("GET /users/{id}", struct {
        fn handle(w: *http.ResponseWriter, req: *http.Request) anyerror!void {
            try w.header().set("Content-Type", "application/json");
            const id = req.pathValue("id") orelse "unknown";
            try w.writer().print("{{\"user_id\":\"{s}\"}}\n", .{id});
        }
    }.handle);

    // 3. Request body read and echo
    try mux.handleFunc("POST /echo", struct {
        fn handle(w: *http.ResponseWriter, req: *http.Request) anyerror!void {
            const body = try req.readBodyAlloc(64 * 1024);
            try w.header().set("Content-Type", "text/plain; charset=utf-8");
            try w.writeAll("Echo: ");
            try w.writeAll(body);
            try w.writeAll("\n");
        }
    }.handle);

    // 4. Wildcard catch-all multi-segment routing
    try mux.handleFunc("GET /files/{filepath...}", struct {
        fn handle(w: *http.ResponseWriter, req: *http.Request) anyerror!void {
            try w.header().set("Content-Type", "text/plain; charset=utf-8");
            const path = req.pathValue("filepath") orelse "";
            try w.writer().print("Serving: {s}\n", .{path});
        }
    }.handle);

    var server = http.Server.init(allocator, io, .{
        .handler = mux.handler(),
        .header_bytes_max = 16 * 1024,
        .read_header_timeout_ns = 5 * std.time.ns_per_s,
        .idle_timeout_ns = 120 * std.time.ns_per_s,
    });

    std.log.info("Zig (Lighting) server listening on http://127.0.0.1:{d} using backend: {s}...", .{ port, io_name });
    try server.listenAndServe("127.0.0.1", port);
}
