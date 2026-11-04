const std = @import("std");
const http = @import("lighting");
const ws = http.extra.ws;

const index_html = @embedFile("index.html");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const port: u16 = if (init.environ_map.get("PORT")) |p| std.fmt.parseInt(u16, p, 10) catch 7000 else 7000;

    var mux = http.ServeMux.init(allocator);
    defer mux.deinit();

    // 1. Serve embedded interactive WebSocket HTML demo client
    try mux.handleFunc("GET /{$}", struct {
        fn handle(w: *http.ResponseWriter, _: *http.Request) anyerror!void {
            try w.header().set("Content-Type", "text/html; charset=utf-8");
            try w.writeAll(index_html);
        }
    }.handle);

    // 2. WebSocket upgrade and message echo endpoint
    try mux.handleFunc("GET /ws", struct {
        fn handle(w: *http.ResponseWriter, req: *http.Request) anyerror!void {
            var conn = ws.upgrade(w, req, .{}) catch |err| {
                std.log.warn("WebSocket upgrade error: {}", .{err});
                return;
            };
            defer conn.close();

            std.log.info("WebSocket client connected", .{});

            while (try conn.readMessage(req.arena)) |msg| {
                switch (msg.type) {
                    .text => {
                        std.log.info("Received text: '{s}' ({d} bytes)", .{ msg.payload, msg.payload.len });
                        var reply_buf: [512]u8 = undefined;
                        const reply = std.fmt.bufPrint(&reply_buf, "Echo: {s}", .{msg.payload}) catch msg.payload;
                        try conn.writeText(reply);
                    },
                    .binary => {
                        std.log.info("Received binary: {d} bytes", .{msg.payload.len});
                        try conn.writeBinary(msg.payload);
                    },
                    .close => {
                        std.log.info("Client requested connection close", .{});
                        break;
                    },
                }
            }
            std.log.info("WebSocket client disconnected", .{});
        }
    }.handle);

    var logging = http.LoggingHandler{ .next = mux.handler() };

    var server = http.Server.init(allocator, io, .{
        .handler = logging.handler(),
    });
    defer server.deinit();

    std.log.info("WebSocket example server running at http://127.0.0.1:{d}/", .{port});
    std.log.info("Open http://127.0.0.1:{d}/ in your browser to test", .{port});
    try server.listenAndServe("127.0.0.1", port);
}
