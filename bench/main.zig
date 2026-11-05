const std = @import("std");
const http = @import("lighting");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const port: u16 = if (init.environ_map.get("PORT")) |p| std.fmt.parseInt(u16, p, 10) catch 7000 else 7000;

    var mux = http.ServeMux.init(allocator);
    defer mux.deinit();

    // 1. Exact match: GET /ping
    try mux.handleFunc("GET /ping", struct {
        fn handle(w: *http.ResponseWriter, _: *http.Request) anyerror!void {
            try w.header().set("Content-Type", "text/plain; charset=utf-8");
            try w.writeAll("pong\n");
        }
    }.handle);

    // 2. Exact match: POST /echo (reads request body)
    try mux.handleFunc("POST /echo", struct {
        fn handle(w: *http.ResponseWriter, req: *http.Request) anyerror!void {
            const body = try req.readBodyAlloc(64 * 1024);
            try w.header().set("Content-Type", "text/plain; charset=utf-8");
            try w.writeAll("Echo: ");
            try w.writeAll(body);
            try w.writeAll("\n");
        }
    }.handle);

    // 3. Go 1.22 Path parameter: GET /users/{id}
    try mux.handleFunc("GET /users/{id}", struct {
        fn handle(w: *http.ResponseWriter, req: *http.Request) anyerror!void {
            try w.header().set("Content-Type", "application/json");
            const id = req.pathValue("id") orelse "unknown";
            try w.writer().print("{{\"user_id\":\"{s}\"}}\n", .{id});
        }
    }.handle);

    // 4. Method restriction: POST /users
    try mux.handleFunc("POST /users", struct {
        fn handle(w: *http.ResponseWriter, req: *http.Request) anyerror!void {
            const body = try req.readBodyAlloc(16 * 1024);
            w.writeHeader(.created);
            try w.header().set("Content-Type", "application/json");
            try w.writer().print("{{\"status\":\"created\",\"data\":\"{s}\"}}\n", .{body});
        }
    }.handle);

    // 5. Catch-all multi-segment wildcard: GET /files/{filepath...}
    try mux.handleFunc("GET /files/{filepath...}", struct {
        fn handle(w: *http.ResponseWriter, req: *http.Request) anyerror!void {
            try w.header().set("Content-Type", "text/plain; charset=utf-8");
            const path = req.pathValue("filepath") orelse "";
            try w.writer().print("Serving file from wildcard: {s}\n", .{path});
        }
    }.handle);

    // 6. Root exact match: /{$} (Go 1.22 exact root, does not catch other paths)
    try mux.handleFunc("/{$}", struct {
        fn handle(w: *http.ResponseWriter, req: *http.Request) anyerror!void {
            try w.header().set("Content-Type", "text/plain; charset=utf-8");
            try w.writer().print("Welcome to Zig 0.17 HTTP Server! Path: {s}\n", .{req.url.path});
        }
    }.handle);

    var server = http.Server.init(allocator, io, .{
        .handler = mux.handler(),
        .header_bytes_max = 16 * 1024,
        .read_header_timeout_ns = 5 * std.time.ns_per_s, // 5s header read timeout (Slowloris defense)
        .read_timeout_ns = 30 * std.time.ns_per_s, // 30s body read timeout
        .write_timeout_ns = 30 * std.time.ns_per_s, // 30s response write timeout
        .idle_timeout_ns = 120 * std.time.ns_per_s, // 120s keep-alive idle timeout
    });
    defer server.deinit();

    std.log.info("Server listening on http://127.0.0.1:{d}...", .{port});
    try server.listenAndServe("127.0.0.1", port);
}
