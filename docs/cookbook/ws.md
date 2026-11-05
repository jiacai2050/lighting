# Real-Time WebSocket App

This recipe demonstrates setting up real-time bidirectional WebSocket communication with an interactive client interface.

Source code: [`examples/ws/`](https://github.com/jiacai2050/lighting/tree/main/examples/ws)

---

## Server Implementation

```zig
const std = @import("std");
const http = @import("lighting");
const ws = http.extra.ws;

const index_html = @embedFile("index.html");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var mux = http.ServeMux.init(allocator);
    defer mux.deinit();

    // 1. Serve embedded interactive WebSocket HTML client
    try mux.handleFunc("GET /{$}", struct {
        fn handle(w: *http.ResponseWriter, _: *http.Request) anyerror!void {
            try w.header().set("Content-Type", "text/html; charset=utf-8");
            try w.writeAll(index_html);
        }
    }.handle);

    // 2. WebSocket upgrade and message echo loop
    try mux.handleFunc("GET /ws", struct {
        fn handle(w: *http.ResponseWriter, req: *http.Request) anyerror!void {
            var conn = ws.upgrade(w, req, .{}) catch |err| {
                std.log.warn("WebSocket upgrade error: {}", .{err});
                return;
            };
            defer conn.close();

            while (try conn.readMessage(req.arena)) |msg| {
                switch (msg.type) {
                    .text => {
                        var reply_buf: [512]u8 = undefined;
                        const reply = std.fmt.bufPrint(&reply_buf, "Echo: {s}", .{msg.payload}) catch msg.payload;
                        try conn.writeText(reply);
                    },
                    .binary => {
                        try conn.writeBinary(msg.payload);
                    },
                    .close => break,
                }
            }
        }
    }.handle);

    var server = http.Server.init(allocator, io, .{
        .handler = mux.handler(),
    });
    defer server.deinit();

    try server.listenAndServe("127.0.0.1", 7000);
}
```

---

## Running the Example

```bash
make run-ws
```

Visit `http://127.0.0.1:7000` to send text and binary messages and see the real-time responses.
