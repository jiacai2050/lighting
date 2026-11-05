# WebSocket

Lighting provides first-class support for real-time bidirectional communication via the `lighting.extra.ws` module. It handles RFC 6455 upgrade handshakes, frame decoding, masking, and message streaming.

---

## 1. Upgrading an HTTP Connection

To upgrade an HTTP connection to a WebSocket connection, invoke `ws.upgrade` from inside any route handler:

```zig
const http = @import("lighting");
const ws = http.extra.ws;

try mux.handleFunc("GET /ws", struct {
    fn handle(w: *http.ResponseWriter, req: *http.Request) anyerror!void {
        // Perform RFC 6455 upgrade handshake
        var conn = ws.upgrade(w, req, .{}) catch |err| {
            std.log.warn("WebSocket handshake failed: {}", .{err});
            return;
        };
        defer conn.close();

        std.log.info("Client connected via WebSocket!", .{});

        // Loop reading frames
        while (try conn.readMessage(req.arena)) |msg| {
            switch (msg.type) {
                .text => {
                    // Echo message back with prefix
                    var reply_buf: [512]u8 = undefined;
                    const reply = try std.fmt.bufPrint(&reply_buf, "Echo: {s}", .{msg.payload});
                    try conn.writeText(reply);
                },
                .binary => {
                    // Handle raw binary frame
                    try conn.writeBinary(msg.payload);
                },
                .close => {
                    std.log.info("Client requested clean close", .{});
                    break;
                },
            }
        }
    }
}.handle);
```

---

## 2. Reading Messages

`conn.readMessage(arena)` parses incoming frames and handles RFC 6455 details:
* **Unmasking**: Incoming client frames are masked; the connection unmasks payloads in place.
* **Control Frames**: Automatically responds to `Ping` frames with `Pong` frames.
* **Fragmentation**: Reassembles fragmented frames across packets.
* **Memory Lifecycle**: Returns payload slices allocated within `req.arena` for zero-leak memory safety.

---

## 3. Sending Messages

* **Text Messages**: `try conn.writeText("hello world")` (sends a UTF-8 encoded text frame).
* **Binary Messages**: `try conn.writeBinary(byte_slice)` (sends a raw binary frame).
* **Close**: `conn.close()` sends a close control frame and cleanly closes the underlying socket.
