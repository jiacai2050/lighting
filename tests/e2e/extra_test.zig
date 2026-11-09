const std = @import("std");
const helpers = @import("helpers.zig");
const http = helpers.http;
const getTestIo = helpers.getTestIo;

test "e2e: extra.ws upgrade, echo text, ping-pong, and close" {
    const allocator = std.testing.allocator;
    const io = getTestIo();

    var mux = http.ServeMux.init(allocator);
    defer mux.deinit();

    try mux.handleFunc("GET /ws-echo", struct {
        fn handle(w: *http.ResponseWriter, req: *http.Request) anyerror!void {
            var conn = try http.extra.ws.upgrade(w, req, .{});
            defer conn.close();

            while (try conn.readMessage(req.arena)) |msg| {
                switch (msg.type) {
                    .text => {
                        var out_buf: [128]u8 = undefined;
                        const echo = try std.fmt.bufPrint(&out_buf, "echo: {s}", .{msg.payload});
                        try conn.writeText(echo);
                    },
                    .binary => try conn.writeBinary(msg.payload),
                    .close => break,
                }
            }
        }
    }.handle);

    var ts = try helpers.TestServer.start(allocator, io, .{ .handler = mux.handler() });
    defer ts.stop();

    var client = try ts.connect(io);
    defer client.close(io);

    // 1. Send WebSocket handshake request
    const handshake_req =
        "GET /ws-echo HTTP/1.1\r\n" ++
        "Host: localhost\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "Sec-WebSocket-Version: 13\r\n\r\n";
    var vec = [1][]const u8{handshake_req};
    _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &vec } })).net_write;

    // 2. Read 101 Switching Protocols response
    var handshake_buf: [512]u8 = undefined;
    var total_hs: usize = 0;
    while (total_hs < handshake_buf.len and std.mem.indexOf(u8, handshake_buf[0..total_hs], "\r\n\r\n") == null) {
        var r_vec = [1][]u8{handshake_buf[total_hs..]};
        const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &r_vec } })).net_read).data_len;
        if (n == 0) break;
        total_hs += n;
    }
    const hs_resp = handshake_buf[0..total_hs];
    try std.testing.expect(std.mem.indexOf(u8, hs_resp, "101 Switching Protocols") != null);
    try std.testing.expect(std.mem.indexOf(u8, hs_resp, "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=") != null);

    // Helper to send a masked client frame
    const ClientHelper = struct {
        fn sendFrame(t_io: std.Io, h: std.Io.net.Socket.Handle, opcode: u4, data: []const u8) !void {
            const mask_key = [_]u8{ 0x11, 0x22, 0x33, 0x44 };
            var hdr: [6]u8 = undefined;
            hdr[0] = 0x80 | @as(u8, opcode); // FIN + opcode
            hdr[1] = 0x80 | @as(u8, @intCast(data.len)); // MASK bit + len
            @memcpy(hdr[2..6], &mask_key);

            var masked: [128]u8 = undefined;
            @memcpy(masked[0..data.len], data);
            for (masked[0..data.len], 0..) |*b, i| {
                b.* ^= mask_key[i % 4];
            }
            var v = [2][]const u8{ &hdr, masked[0..data.len] };
            _ = try (try t_io.operate(.{ .net_write = .{ .socket_handle = h, .data = &v } })).net_write;
        }

        fn readFrame(t_io: std.Io, h: std.Io.net.Socket.Handle, dest: []u8) !struct { opcode: u4, len: usize } {
            var hdr: [2]u8 = undefined;
            var tot: usize = 0;
            while (tot < 2) {
                var r = [1][]u8{hdr[tot..]};
                const n = (try (try t_io.operate(.{ .net_read = .{ .socket_handle = h, .data = &r } })).net_read).data_len;
                if (n == 0) return error.ConnectionClosed;
                tot += n;
            }
            const op = @as(u4, @truncate(hdr[0] & 0x0F));
            const p_len = @as(usize, @intCast(hdr[1] & 0x7F));
            var p_tot: usize = 0;
            while (p_tot < p_len) {
                var r = [1][]u8{dest[p_tot..p_len]};
                const n = (try (try t_io.operate(.{ .net_read = .{ .socket_handle = h, .data = &r } })).net_read).data_len;
                if (n == 0) return error.ConnectionClosed;
                p_tot += n;
            }
            return .{ .opcode = op, .len = p_len };
        }
    };

    // 3. Send Text frame: "hello"
    try ClientHelper.sendFrame(io, client.socket.handle, 0x1, "hello");

    // 4. Read server echo Text frame
    var text_payload: [64]u8 = undefined;
    const text_res = try ClientHelper.readFrame(io, client.socket.handle, &text_payload);
    try std.testing.expectEqual(@as(u4, 0x1), text_res.opcode);
    try std.testing.expectEqualStrings("echo: hello", text_payload[0..text_res.len]);

    // 5. Send Ping frame: "heartbeat"
    try ClientHelper.sendFrame(io, client.socket.handle, 0x9, "heartbeat");

    // 6. Server must automatically respond with Pong frame
    var pong_payload: [64]u8 = undefined;
    const pong_res = try ClientHelper.readFrame(io, client.socket.handle, &pong_payload);
    try std.testing.expectEqual(@as(u4, 0xA), pong_res.opcode); // 0xA is Pong
    try std.testing.expectEqualStrings("heartbeat", pong_payload[0..pong_res.len]);

    // 7. Send Close frame
    try ClientHelper.sendFrame(io, client.socket.handle, 0x8, "");

    // 8. Server echoes back Close frame
    var close_payload: [64]u8 = undefined;
    const close_res = try ClientHelper.readFrame(io, client.socket.handle, &close_payload);
    try std.testing.expectEqual(@as(u4, 0x8), close_res.opcode);
}

test "e2e: extra.ws fragmented message cumulative limit" {
    const allocator = std.testing.allocator;
    const io = getTestIo();

    var mux = http.ServeMux.init(allocator);
    defer mux.deinit();

    try mux.handleFunc("GET /ws-limited", struct {
        fn handle(w: *http.ResponseWriter, req: *http.Request) anyerror!void {
            var conn = try http.extra.ws.upgrade(w, req, .{ .message_bytes_max = 20 });
            defer conn.close();

            // When cumulative message size exceeds 20 bytes, readMessage fails with error.MessageTooLarge
            const msg = try conn.readMessage(req.arena);
            _ = msg;
        }
    }.handle);

    var ts = try helpers.TestServer.start(allocator, io, .{ .handler = mux.handler() });
    defer ts.stop();

    var client = try ts.connect(io);
    defer client.close(io);

    // 1. Handshake
    const handshake_req =
        "GET /ws-limited HTTP/1.1\r\n" ++
        "Host: localhost\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "Sec-WebSocket-Version: 13\r\n\r\n";
    var vec = [1][]const u8{handshake_req};
    _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &vec } })).net_write;

    var handshake_buf: [256]u8 = undefined;
    var total_hs: usize = 0;
    while (total_hs < handshake_buf.len and std.mem.indexOf(u8, handshake_buf[0..total_hs], "\r\n\r\n") == null) {
        var r_vec = [1][]u8{handshake_buf[total_hs..]};
        const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &r_vec } })).net_read).data_len;
        if (n == 0) break;
        total_hs += n;
    }

    // 2. Helper to send client frame with custom FIN bit
    const FrameHelper = struct {
        fn sendFrameFin(t_io: std.Io, h: std.Io.net.Socket.Handle, opcode: u4, data: []const u8, fin: bool) !void {
            const mask_key = [_]u8{ 0x11, 0x22, 0x33, 0x44 };
            var hdr: [6]u8 = undefined;
            hdr[0] = (if (fin) @as(u8, 0x80) else 0) | @as(u8, opcode);
            hdr[1] = 0x80 | @as(u8, @intCast(data.len));
            @memcpy(hdr[2..6], &mask_key);

            var masked: [128]u8 = undefined;
            @memcpy(masked[0..data.len], data);
            for (masked[0..data.len], 0..) |*b, i| {
                b.* ^= mask_key[i % 4];
            }
            var v = [2][]const u8{ &hdr, masked[0..data.len] };
            _ = try (try t_io.operate(.{ .net_write = .{ .socket_handle = h, .data = &v } })).net_write;
        }
    };

    // 3. Send fragment 1: 12 bytes (text, fin = false)
    try FrameHelper.sendFrameFin(io, client.socket.handle, 0x1, "123456789012", false);

    // 4. Send fragment 2: 12 bytes (continuation, fin = true). Total 24 > message_bytes_max 20!
    try FrameHelper.sendFrameFin(io, client.socket.handle, 0x0, "123456789012", true);

    // 5. Server will error with MessageTooLarge and terminate socket (EOF or RST)
    var read_buf: [64]u8 = undefined;
    var r_vec = [1][]u8{&read_buf};
    const res = try io.operate(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &r_vec } });
    const read_res = res.net_read catch |err| switch (err) {
        error.ConnectionResetByPeer => return,
        else => return err,
    };
    try std.testing.expectEqual(@as(usize, 0), read_res.data_len);
}

test "e2e: extra.ws invalid UTF-8 text message rejection" {
    const allocator = std.testing.allocator;
    const io = getTestIo();

    var mux = http.ServeMux.init(allocator);
    defer mux.deinit();

    try mux.handleFunc("GET /ws-utf8", struct {
        fn handle(w: *http.ResponseWriter, req: *http.Request) anyerror!void {
            var conn = try http.extra.ws.upgrade(w, req, .{});
            defer conn.close();

            // When invalid UTF-8 text payload is received, readMessage fails with error.InvalidUtf8
            const msg = try conn.readMessage(req.arena);
            _ = msg;
        }
    }.handle);

    var ts = try helpers.TestServer.start(allocator, io, .{ .handler = mux.handler() });
    defer ts.stop();

    var client = try ts.connect(io);
    defer client.close(io);

    // 1. Handshake
    const handshake_req =
        "GET /ws-utf8 HTTP/1.1\r\n" ++
        "Host: localhost\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "Sec-WebSocket-Version: 13\r\n\r\n";
    var vec = [1][]const u8{handshake_req};
    _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &vec } })).net_write;

    var handshake_buf: [256]u8 = undefined;
    var total_hs: usize = 0;
    while (total_hs < handshake_buf.len and std.mem.indexOf(u8, handshake_buf[0..total_hs], "\r\n\r\n") == null) {
        var r_vec = [1][]u8{handshake_buf[total_hs..]};
        const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &r_vec } })).net_read).data_len;
        if (n == 0) break;
        total_hs += n;
    }

    // 2. Send invalid UTF-8 bytes in a text frame (opcode 0x1)
    const invalid_utf8 = [_]u8{ 0xFF, 0xFE, 0xFD };
    const mask_key = [_]u8{ 0x11, 0x22, 0x33, 0x44 };
    var hdr: [6]u8 = undefined;
    hdr[0] = 0x81; // FIN + text
    hdr[1] = 0x80 | @as(u8, invalid_utf8.len);
    @memcpy(hdr[2..6], &mask_key);

    var masked: [3]u8 = undefined;
    for (invalid_utf8, 0..) |b, i| {
        masked[i] = b ^ mask_key[i % 4];
    }
    var v = [2][]const u8{ &hdr, &masked };
    _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &v } })).net_write;

    // 3. Server should detect InvalidUtf8 and close the connection
    var read_buf: [64]u8 = undefined;
    var r_vec = [1][]u8{&read_buf};
    const res = try io.operate(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &r_vec } });
    const read_res = res.net_read catch |err| switch (err) {
        error.ConnectionResetByPeer => return,
        else => return err,
    };
    try std.testing.expectEqual(@as(usize, 0), read_res.data_len);
}

test "e2e extra.fs: FileServer serving, caching, ranges, traversal protection, and directory listing" {
    const allocator = std.testing.allocator;
    const io = getTestIo();

    var fs = http.extra.fs.FileServer.init(allocator, .{
        .root_dir = "src",
        .auto_index = true,
    });

    var mux = http.ServeMux.init(allocator);
    defer mux.deinit();

    try mux.handle("/", fs.handler());

    var ts = try helpers.TestServer.start(allocator, io, .{ .handler = mux.handler() });
    defer ts.stop();

    const connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", ts.port);

    // 1. Full GET for regular file
    {
        var client = try connect_addr.connect(io, .{ .mode = .stream });
        defer client.close(io);

        const req = "GET /root.zig HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
        var vec = [1][]const u8{req};
        _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &vec } })).net_write;

        var buf: [4096]u8 = undefined;
        var total: usize = 0;
        while (total < buf.len) {
            var r_vec = [1][]u8{buf[total..]};
            const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &r_vec } })).net_read).data_len;
            if (n == 0) break;
            total += n;
        }

        const resp = buf[0..total];
        try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 200 OK\r\n"));
        try std.testing.expect(std.mem.indexOf(u8, resp, "Content-Type: text/plain; charset=utf-8\r\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, resp, "Accept-Ranges: bytes\r\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, resp, "ETag: W/\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, resp, "Last-Modified: ") != null);
        try std.testing.expect(std.mem.indexOf(u8, resp, "const std = @import(\"std\");") != null);
    }

    // 2. HEAD request: headers present, no body
    {
        var client = try connect_addr.connect(io, .{ .mode = .stream });
        defer client.close(io);

        const req = "HEAD /root.zig HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
        var vec = [1][]const u8{req};
        _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &vec } })).net_write;

        var buf: [4096]u8 = undefined;
        var total: usize = 0;
        while (total < buf.len) {
            var r_vec = [1][]u8{buf[total..]};
            const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &r_vec } })).net_read).data_len;
            if (n == 0) break;
            total += n;
        }

        const resp = buf[0..total];
        try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 200 OK\r\n"));
        try std.testing.expect(std.mem.indexOf(u8, resp, "Content-Length: ") != null);
        const header_end = std.mem.indexOf(u8, resp, "\r\n\r\n").?;
        try std.testing.expectEqual(resp.len, header_end + 4);
    }

    // 3. Conditional GET with If-None-Match (304 Not Modified)
    {
        // First get ETag
        var client1 = try connect_addr.connect(io, .{ .mode = .stream });
        defer client1.close(io);

        const req1 = "HEAD /root.zig HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
        var vec1 = [1][]const u8{req1};
        _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client1.socket.handle, .data = &vec1 } })).net_write;

        var buf1: [2048]u8 = undefined;
        var total1: usize = 0;
        while (total1 < buf1.len) {
            var r_vec = [1][]u8{buf1[total1..]};
            const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client1.socket.handle, .data = &r_vec } })).net_read).data_len;
            if (n == 0) break;
            total1 += n;
        }

        const resp1 = buf1[0..total1];
        const etag_marker = "ETag: ";
        const etag_start = std.mem.indexOf(u8, resp1, etag_marker).? + etag_marker.len;
        const etag_end = std.mem.indexOfPos(u8, resp1, etag_start, "\r\n").?;
        const etag_val = resp1[etag_start..etag_end];

        // Request with If-None-Match
        var client2 = try connect_addr.connect(io, .{ .mode = .stream });
        defer client2.close(io);

        var req2_buf: [512]u8 = undefined;
        const req2 = try std.fmt.bufPrint(&req2_buf, "GET /root.zig HTTP/1.1\r\nHost: localhost\r\nIf-None-Match: {s}\r\nConnection: close\r\n\r\n", .{etag_val});
        var vec2 = [1][]const u8{req2};
        _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client2.socket.handle, .data = &vec2 } })).net_write;

        var buf2: [2048]u8 = undefined;
        var total2: usize = 0;
        while (total2 < buf2.len) {
            var r_vec = [1][]u8{buf2[total2..]};
            const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client2.socket.handle, .data = &r_vec } })).net_read).data_len;
            if (n == 0) break;
            total2 += n;
        }

        const resp2 = buf2[0..total2];
        try std.testing.expect(std.mem.startsWith(u8, resp2, "HTTP/1.1 304 Not Modified\r\n"));
        const header_end = std.mem.indexOf(u8, resp2, "\r\n\r\n").?;
        try std.testing.expectEqual(resp2.len, header_end + 4);
    }

    // 4. Range request: bytes=0-10 -> 206 Partial Content
    {
        var client = try connect_addr.connect(io, .{ .mode = .stream });
        defer client.close(io);

        const req = "GET /root.zig HTTP/1.1\r\nHost: localhost\r\nRange: bytes=0-10\r\nConnection: close\r\n\r\n";
        var vec = [1][]const u8{req};
        _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &vec } })).net_write;

        var buf: [2048]u8 = undefined;
        var total: usize = 0;
        while (total < buf.len) {
            var r_vec = [1][]u8{buf[total..]};
            const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &r_vec } })).net_read).data_len;
            if (n == 0) break;
            total += n;
        }

        const resp = buf[0..total];
        try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 206 Partial Content\r\n"));
        try std.testing.expect(std.mem.indexOf(u8, resp, "Content-Range: bytes 0-10/") != null);
        try std.testing.expect(std.mem.indexOf(u8, resp, "Content-Length: 11\r\n") != null);
        const header_end = std.mem.indexOf(u8, resp, "\r\n\r\n").?;
        const body = resp[header_end + 4 ..];
        try std.testing.expectEqualStrings("const std =", body);
    }

    // 5. Unsatisfiable Range request -> 416
    {
        var client = try connect_addr.connect(io, .{ .mode = .stream });
        defer client.close(io);

        const req = "GET /root.zig HTTP/1.1\r\nHost: localhost\r\nRange: bytes=9999999-\r\nConnection: close\r\n\r\n";
        var vec = [1][]const u8{req};
        _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &vec } })).net_write;

        var buf: [1024]u8 = undefined;
        var total: usize = 0;
        while (total < buf.len) {
            var r_vec = [1][]u8{buf[total..]};
            const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &r_vec } })).net_read).data_len;
            if (n == 0) break;
            total += n;
        }

        const resp = buf[0..total];
        try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 416 Range Not Satisfiable\r\n"));
        try std.testing.expect(std.mem.indexOf(u8, resp, "Content-Range: bytes */") != null);
    }

    // 6. Path traversal attempt -> 403 Forbidden
    {
        var client = try connect_addr.connect(io, .{ .mode = .stream });
        defer client.close(io);

        const req = "GET /../build.zig HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
        var vec = [1][]const u8{req};
        _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &vec } })).net_write;

        var buf: [1024]u8 = undefined;
        var total: usize = 0;
        while (total < buf.len) {
            var r_vec = [1][]u8{buf[total..]};
            const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &r_vec } })).net_read).data_len;
            if (n == 0) break;
            total += n;
        }

        const resp = buf[0..total];
        try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 403 Forbidden\r\n"));
    }

    // 7. Not Found -> 404
    {
        var client = try connect_addr.connect(io, .{ .mode = .stream });
        defer client.close(io);

        const req = "GET /nonexistent_file_xyz.txt HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
        var vec = [1][]const u8{req};
        _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &vec } })).net_write;

        var buf: [1024]u8 = undefined;
        var total: usize = 0;
        while (total < buf.len) {
            var r_vec = [1][]u8{buf[total..]};
            const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &r_vec } })).net_read).data_len;
            if (n == 0) break;
            total += n;
        }

        const resp = buf[0..total];
        try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 404 Not Found\r\n"));
    }

    // 8. Method Not Allowed (POST) -> 405
    {
        var client = try connect_addr.connect(io, .{ .mode = .stream });
        defer client.close(io);

        const req = "POST /root.zig HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nContent-Length: 0\r\n\r\n";
        var vec = [1][]const u8{req};
        _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &vec } })).net_write;

        var buf: [1024]u8 = undefined;
        var total: usize = 0;
        while (total < buf.len) {
            var r_vec = [1][]u8{buf[total..]};
            const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &r_vec } })).net_read).data_len;
            if (n == 0) break;
            total += n;
        }

        const resp = buf[0..total];
        try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 405 Method Not Allowed\r\n"));
        try std.testing.expect(std.mem.indexOf(u8, resp, "Allow: GET, HEAD\r\n") != null);
    }

    // 9. Directory listing -> 200 OK HTML
    {
        var client = try connect_addr.connect(io, .{ .mode = .stream });
        defer client.close(io);

        const req = "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
        var vec = [1][]const u8{req};
        _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &vec } })).net_write;

        var buf: [8192]u8 = undefined;
        var total: usize = 0;
        while (total < buf.len) {
            var r_vec = [1][]u8{buf[total..]};
            const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &r_vec } })).net_read).data_len;
            if (n == 0) break;
            total += n;
        }

        const resp = buf[0..total];
        try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 200 OK\r\n"));
        try std.testing.expect(std.mem.indexOf(u8, resp, "Content-Type: text/html; charset=utf-8\r\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, resp, "Index of /") != null);
        try std.testing.expect(std.mem.indexOf(u8, resp, "root.zig") != null);
    }

    // 10. Percent-encoded traversal: /%2e%2e/build.zig -> 403 Forbidden
    {
        var client = try connect_addr.connect(io, .{ .mode = .stream });
        defer client.close(io);

        const req = "GET /%2e%2e/build.zig HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
        var vec = [1][]const u8{req};
        _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &vec } })).net_write;

        var buf: [1024]u8 = undefined;
        var total: usize = 0;
        while (total < buf.len) {
            var r_vec = [1][]u8{buf[total..]};
            const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &r_vec } })).net_read).data_len;
            if (n == 0) break;
            total += n;
        }

        const resp = buf[0..total];
        try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 403 Forbidden\r\n"));
    }

    // 11. Syntactically invalid Range: bytes=500-400 (start > end) MUST be ignored -> 200 OK
    {
        var client = try connect_addr.connect(io, .{ .mode = .stream });
        defer client.close(io);

        const req = "GET /root.zig HTTP/1.1\r\nHost: localhost\r\nRange: bytes=500-400\r\nConnection: close\r\n\r\n";
        var vec = [1][]const u8{req};
        _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &vec } })).net_write;

        var buf: [4096]u8 = undefined;
        var total: usize = 0;
        while (total < buf.len) {
            var r_vec = [1][]u8{buf[total..]};
            const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &r_vec } })).net_read).data_len;
            if (n == 0) break;
            total += n;
        }

        const resp = buf[0..total];
        try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 200 OK\r\n"));
    }

    // 12. If-None-Match list form: "dummy", <matching_etag> -> 304 Not Modified
    {
        // First get ETag
        var client1 = try connect_addr.connect(io, .{ .mode = .stream });
        defer client1.close(io);

        const req1 = "HEAD /root.zig HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
        var vec1 = [1][]const u8{req1};
        _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client1.socket.handle, .data = &vec1 } })).net_write;

        var buf1: [2048]u8 = undefined;
        var total1: usize = 0;
        while (total1 < buf1.len) {
            var r_vec = [1][]u8{buf1[total1..]};
            const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client1.socket.handle, .data = &r_vec } })).net_read).data_len;
            if (n == 0) break;
            total1 += n;
        }

        const resp1 = buf1[0..total1];
        const etag_marker = "ETag: ";
        const etag_start = std.mem.indexOf(u8, resp1, etag_marker).? + etag_marker.len;
        const etag_end = std.mem.indexOfPos(u8, resp1, etag_start, "\r\n").?;
        const etag_val = resp1[etag_start..etag_end];

        var client2 = try connect_addr.connect(io, .{ .mode = .stream });
        defer client2.close(io);

        var req2_buf: [512]u8 = undefined;
        const req2 = try std.fmt.bufPrint(&req2_buf, "GET /root.zig HTTP/1.1\r\nHost: localhost\r\nIf-None-Match: \"dummy\", {s}, \"other\"\r\nConnection: close\r\n\r\n", .{etag_val});
        var vec2 = [1][]const u8{req2};
        _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client2.socket.handle, .data = &vec2 } })).net_write;

        var buf2: [2048]u8 = undefined;
        var total2: usize = 0;
        while (total2 < buf2.len) {
            var r_vec = [1][]u8{buf2[total2..]};
            const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client2.socket.handle, .data = &r_vec } })).net_read).data_len;
            if (n == 0) break;
            total2 += n;
        }

        const resp2 = buf2[0..total2];
        try std.testing.expect(std.mem.startsWith(u8, resp2, "HTTP/1.1 304 Not Modified\r\n"));
    }

    // 13. Directory redirect preserves query string: /extra?sort=name -> 301 Location: /extra/?sort=name
    {
        var client = try connect_addr.connect(io, .{ .mode = .stream });
        defer client.close(io);

        const req = "GET /extra?sort=name HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
        var vec = [1][]const u8{req};
        _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &vec } })).net_write;

        var buf: [1024]u8 = undefined;
        var total: usize = 0;
        while (total < buf.len) {
            var r_vec = [1][]u8{buf[total..]};
            const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &r_vec } })).net_read).data_len;
            if (n == 0) break;
            total += n;
        }

        const resp = buf[0..total];
        try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 301 Moved Permanently\r\n"));
        try std.testing.expect(std.mem.indexOf(u8, resp, "Location: /extra/?sort=name\r\n") != null);
    }

    // 14. strip_prefix boundary check: /static/root.zig vs /staticfoo (404)
    {
        var fs_prefix = http.extra.fs.FileServer.init(allocator, .{
            .root_dir = "src",
            .strip_prefix = "/static",
            .auto_index = true,
        });
        var mux_prefix = http.ServeMux.init(allocator);
        defer mux_prefix.deinit();

        try mux_prefix.handle("/", fs_prefix.handler());

        var ts_p = try helpers.TestServer.start(allocator, io, .{ .handler = mux_prefix.handler() });
        defer ts_p.stop();

        const connect_p = try std.Io.net.IpAddress.parseIp4("127.0.0.1", ts_p.port);

        // A. /staticfoo must 404 (non-segment match)
        {
            var client = try connect_p.connect(io, .{ .mode = .stream });
            defer client.close(io);

            const req = "GET /staticfoo HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
            var vec = [1][]const u8{req};
            _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &vec } })).net_write;

            var buf: [1024]u8 = undefined;
            var total: usize = 0;
            while (total < buf.len) {
                var r_vec = [1][]u8{buf[total..]};
                const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &r_vec } })).net_read).data_len;
                if (n == 0) break;
                total += n;
            }

            const resp = buf[0..total];
            try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 404 Not Found\r\n"));
        }

        // B. /static/root.zig must 200 OK
        {
            var client = try connect_p.connect(io, .{ .mode = .stream });
            defer client.close(io);

            const req = "GET /static/root.zig HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
            var vec = [1][]const u8{req};
            _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &vec } })).net_write;

            var buf: [1024]u8 = undefined;
            var total: usize = 0;
            while (total < buf.len) {
                var r_vec = [1][]u8{buf[total..]};
                const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &r_vec } })).net_read).data_len;
                if (n == 0) break;
                total += n;
            }

            const resp = buf[0..total];
            try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 200 OK\r\n"));
        }
    }
}

test "e2e: TimeoutHandler normal completion and timeout trigger" {
    const io = getTestIo();
    const gpa = std.testing.allocator;

    const fastHandler = struct {
        fn handle(w: *http.ResponseWriter, _: *http.Request) anyerror!void {
            w.setStatus(.ok);
            try w.writeAll("fast ok");
        }
    }.handle;

    const timeoutTriggerHandler = struct {
        fn handle(_: *http.ResponseWriter, _: *http.Request) anyerror!void {
            return error.Timeout;
        }
    }.handle;

    var fast_th = http.timeoutHandler(http.Handler.fromFn(fastHandler), 200 * std.time.ns_per_ms, "Fast Timeout");
    var slow_th = http.timeoutHandler(http.Handler.fromFn(timeoutTriggerHandler), 200 * std.time.ns_per_ms, "Custom Gateway Timeout Message");

    var mux = http.ServeMux.init(gpa);
    defer mux.deinit();
    try mux.handle("/fast", fast_th.handler());
    try mux.handle("/timeout", slow_th.handler());

    var ts = try helpers.TestServer.start(gpa, io, .{ .handler = mux.handler() });
    defer ts.stop();

    const connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", ts.port);

    // 1. Fast path -> 200 OK
    {
        var client = try connect_addr.connect(io, .{ .mode = .stream });
        defer client.close(io);

        const req = "GET /fast HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
        var vec = [1][]const u8{req};
        _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &vec } })).net_write;

        var buf: [1024]u8 = undefined;
        var total: usize = 0;
        while (total < buf.len) {
            var r_vec = [1][]u8{buf[total..]};
            const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &r_vec } })).net_read).data_len;
            if (n == 0) break;
            total += n;
        }

        const resp = buf[0..total];
        try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 200 OK\r\n"));
        try std.testing.expect(std.mem.indexOf(u8, resp, "fast ok") != null);
    }

    // 2. Timeout path -> 504 Gateway Timeout
    {
        var client = try connect_addr.connect(io, .{ .mode = .stream });
        defer client.close(io);

        const req = "GET /timeout HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
        var vec = [1][]const u8{req};
        _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &vec } })).net_write;

        var buf: [1024]u8 = undefined;
        var total: usize = 0;
        while (total < buf.len) {
            var r_vec = [1][]u8{buf[total..]};
            const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &r_vec } })).net_read).data_len;
            if (n == 0) break;
            total += n;
        }

        const resp = buf[0..total];
        try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 504 Gateway Timeout\r\n"));
        try std.testing.expect(std.mem.indexOf(u8, resp, "Custom Gateway Timeout Message") != null);
        try std.testing.expect(std.mem.indexOf(u8, resp, "Connection: close") != null);
    }
}

test "e2e: extra.proxy ReverseProxy header rewrite and streaming" {
    const io = getTestIo();
    const gpa = std.testing.allocator;

    // --- 1. Set up Upstream Server ---
    const upstreamHandler = struct {
        fn handle(w: *http.ResponseWriter, req: *http.Request) anyerror!void {
            if (std.mem.eql(u8, req.url.path, "/upstream/hello")) {
                w.setStatus(.ok);
                try w.header().set("Content-Type", "text/plain");
                try w.writeAll("hello upstream, xff=");
                if (req.headers.get("X-Forwarded-For")) |xff| {
                    try w.writeAll(xff);
                }
                return;
            } else if (std.mem.eql(u8, req.url.path, "/upstream/echo")) {
                w.setStatus(.ok);
                if (req.body()) |reader| {
                    var buf: [512]u8 = undefined;
                    while (true) {
                        const n = try reader.read(&buf);
                        if (n == 0) break;
                        try w.writeAll(buf[0..n]);
                    }
                }
                return;
            }
            w.setStatus(.not_found);
        }
    }.handle;

    var upstream_ts = try helpers.TestServer.start(gpa, io, .{
        .handler = http.Handler.fromFn(upstreamHandler),
    });
    defer upstream_ts.stop();
    const upstream_target_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", upstream_ts.port);

    // --- 2. Set up ReverseProxy Server ---
    var rev_proxy = http.extra.proxy.reverseProxy(.{
        .target_addr = upstream_target_addr,
    });

    // Another proxy with unreachable upstream for 502 test
    const dead_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 1);
    var dead_proxy = http.extra.proxy.reverseProxy(.{
        .target_addr = dead_addr,
    });

    var proxy_mux = http.ServeMux.init(gpa);
    defer proxy_mux.deinit();
    try proxy_mux.handle("/upstream/{filepath...}", rev_proxy.handler());
    try proxy_mux.handle("/dead/{filepath...}", dead_proxy.handler());

    var proxy_ts = try helpers.TestServer.start(gpa, io, .{
        .handler = proxy_mux.handler(),
    });
    defer proxy_ts.stop();
    const proxy_connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", proxy_ts.port);

    // Test 1: Forward GET and verify X-Forwarded-For injection
    {
        var client = try proxy_connect_addr.connect(io, .{ .mode = .stream });
        defer client.close(io);

        const req = "GET /upstream/hello HTTP/1.1\r\nHost: myproxy.local\r\nConnection: close\r\n\r\n";
        var vec = [1][]const u8{req};
        _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &vec } })).net_write;

        var buf: [1024]u8 = undefined;
        var total: usize = 0;
        while (total < buf.len) {
            var r_vec = [1][]u8{buf[total..]};
            const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &r_vec } })).net_read).data_len;
            if (n == 0) break;
            total += n;
        }

        const resp = buf[0..total];
        try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 200 OK\r\n"));
        try std.testing.expect(std.mem.indexOf(u8, resp, "hello upstream, xff=127.0.0.1") != null);
    }

    // Test 2: Forward POST body and receive streamed response body
    {
        var client = try proxy_connect_addr.connect(io, .{ .mode = .stream });
        defer client.close(io);

        const payload = "streaming payload from client through proxy to upstream and back";
        const req = std.fmt.comptimePrint(
            "POST /upstream/echo HTTP/1.1\r\nHost: myproxy.local\r\nConnection: close\r\nContent-Length: {d}\r\n\r\n{s}",
            .{ payload.len, payload },
        );
        var vec = [1][]const u8{req};
        _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &vec } })).net_write;

        var buf: [1024]u8 = undefined;
        var total: usize = 0;
        while (total < buf.len) {
            var r_vec = [1][]u8{buf[total..]};
            const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &r_vec } })).net_read).data_len;
            if (n == 0) break;
            total += n;
        }

        const resp = buf[0..total];
        try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 200 OK\r\n"));
        try std.testing.expect(std.mem.indexOf(u8, resp, payload) != null);
    }

    // Test 3: Dead upstream returns 502 Bad Gateway
    {
        var client = try proxy_connect_addr.connect(io, .{ .mode = .stream });
        defer client.close(io);

        const req = "GET /dead/hello HTTP/1.1\r\nHost: myproxy.local\r\nConnection: close\r\n\r\n";
        var vec = [1][]const u8{req};
        _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &vec } })).net_write;

        var buf: [1024]u8 = undefined;
        var total: usize = 0;
        while (total < buf.len) {
            var r_vec = [1][]u8{buf[total..]};
            const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &r_vec } })).net_read).data_len;
            if (n == 0) break;
            total += n;
        }

        const resp = buf[0..total];
        try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 502 Bad Gateway\r\n"));
        try std.testing.expect(std.mem.indexOf(u8, resp, "Bad Gateway") != null);
    }
}

test "e2e: extra.proxy upstream unlisted status code 429 and transparent 599 forwarding" {
    const allocator = std.testing.allocator;
    const io = getTestIo();

    // 1. Upstream server returning 429 Too Many Requests and 599
    var upstream_mux = http.ServeMux.init(allocator);
    defer upstream_mux.deinit();

    try upstream_mux.handleFunc("GET /rate-limited", struct {
        fn handle(w: *http.ResponseWriter, _: *http.Request) anyerror!void {
            w.setStatus(.too_many_requests);
            try w.writeAll("Slow down\n");
        }
    }.handle);

    try upstream_mux.handleFunc("GET /custom-599", struct {
        fn handle(w: *http.ResponseWriter, _: *http.Request) anyerror!void {
            const stream = try w.hijack();
            defer stream.close(w.io);
            const raw =
                "HTTP/1.1 599 Custom Error\r\n" ++
                "Content-Length: 4\r\nConnection: close\r\n\r\nfail";
            var raw_vec = [1][]const u8{raw};
            _ = try (try w.io.operate(.{
                .net_write = .{ .socket_handle = stream.socket.handle, .data = &raw_vec },
            })).net_write;
        }
    }.handle);

    try upstream_mux.handleFunc("GET /invalid-code-12345", struct {
        fn handle(w: *http.ResponseWriter, _: *http.Request) anyerror!void {
            const stream = try w.hijack();
            defer stream.close(w.io);
            const raw =
                "HTTP/1.1 12345 Very Long Nonconforming Status Code " ++
                "Reason Phrase For Testing\r\n" ++
                "Content-Length: 4\r\nConnection: close\r\n\r\nfail";
            var raw_vec = [1][]const u8{raw};
            _ = try (try w.io.operate(.{
                .net_write = .{ .socket_handle = stream.socket.handle, .data = &raw_vec },
            })).net_write;
        }
    }.handle);

    var upstream_ts = try helpers.TestServer.start(
        allocator,
        io,
        .{ .handler = upstream_mux.handler() },
    );
    defer upstream_ts.stop();

    const upstream_target_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", upstream_ts.port);

    // 2. Proxy server
    var proxy = http.extra.proxy.reverseProxy(.{
        .target_addr = upstream_target_addr,
    });

    var proxy_server = try helpers.TestServer.start(allocator, io, .{ .handler = proxy.handler() });
    defer proxy_server.stop();

    const proxy_connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", proxy_server.port);

    // Test 429 forwarded without crash
    {
        var client = try proxy_connect_addr.connect(io, .{ .mode = .stream });
        defer client.close(io);

        const req = "GET /rate-limited HTTP/1.1\r\nHost: proxy\r\nConnection: close\r\n\r\n";
        var vec = [1][]const u8{req};
        _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &vec } })).net_write;

        var buf: [1024]u8 = undefined;
        var total: usize = 0;
        while (total < buf.len) {
            var r_vec = [1][]u8{buf[total..]};
            const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &r_vec } })).net_read).data_len;
            if (n == 0) break;
            total += n;
        }

        const resp = buf[0..total];
        try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 429 Too Many Requests\r\n"));
    }

    // Test 599 unknown code falls back to 502 Bad Gateway without crash
    {
        var client = try proxy_connect_addr.connect(io, .{ .mode = .stream });
        defer client.close(io);

        const req = "GET /custom-599 HTTP/1.1\r\nHost: proxy\r\nConnection: close\r\n\r\n";
        var vec = [1][]const u8{req};
        _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &vec } })).net_write;

        var buf: [1024]u8 = undefined;
        var total: usize = 0;
        while (total < buf.len) {
            var r_vec = [1][]u8{buf[total..]};
            const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &r_vec } })).net_read).data_len;
            if (n == 0) break;
            total += n;
        }

        const resp = buf[0..total];
        try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 599\r\n"));
    }

    // Test non-conforming 5-digit code safely normalizes to 502 Bad Gateway
    {
        var client = try proxy_connect_addr.connect(io, .{ .mode = .stream });
        defer client.close(io);

        const req = "GET /invalid-code-12345 HTTP/1.1\r\nHost: proxy\r\nConnection: close\r\n\r\n";
        var vec = [1][]const u8{req};
        _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &vec } })).net_write;

        var buf: [1024]u8 = undefined;
        var total: usize = 0;
        while (total < buf.len) {
            var r_vec = [1][]u8{buf[total..]};
            const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &r_vec } })).net_read).data_len;
            if (n == 0) break;
            total += n;
        }

        const resp = buf[0..total];
        try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 502 Bad Gateway\r\n"));
    }
}

test "e2e: extra.ws writeClose truncates safely under 125 bytes with valid UTF-8" {
    const allocator = std.testing.allocator;
    const io = getTestIo();

    var mux = http.ServeMux.init(allocator);
    defer mux.deinit();

    try mux.handleFunc("GET /ws-long-close", struct {
        fn handle(w: *http.ResponseWriter, req: *http.Request) anyerror!void {
            var conn = try http.extra.ws.upgrade(w, req, .{});
            defer conn.close();

            // 200-byte reason with multibyte UTF-8 characters "你好世界" repeated
            const long_reason =
                "Hello你好世界Hello你好世界Hello你好世界Hello你好世界Hello你好世界" ++
                "Hello你好世界Hello你好世界Hello你好世界Hello你好世界Hello你好世界";
            try conn.writeClose(1000, long_reason);
        }
    }.handle);

    var ts = try helpers.TestServer.start(allocator, io, .{ .handler = mux.handler() });
    defer ts.stop();

    var client = try ts.connect(io);
    defer client.close(io);

    const handshake_req =
        "GET /ws-long-close HTTP/1.1\r\n" ++
        "Host: localhost\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "Sec-WebSocket-Version: 13\r\n\r\n";
    var vec = [1][]const u8{handshake_req};
    _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &vec } })).net_write;

    var resp_buf: [512]u8 = undefined;
    var total: usize = 0;
    while (total < resp_buf.len) {
        var r_vec = [1][]u8{resp_buf[total..]};
        const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &r_vec } })).net_read).data_len;
        if (n == 0) break;
        total += n;
        if (std.mem.indexOf(u8, resp_buf[0..total], "\r\n\r\n") != null) break;
    }

    // Read the Close frame emitted by server
    const hdr_end = (std.mem.indexOf(u8, resp_buf[0..total], "\r\n\r\n") orelse total) + 4;
    var close_frame: [256]u8 = undefined;
    var frame_len: usize = 0;
    if (hdr_end < total) {
        const extra = resp_buf[hdr_end..total];
        @memcpy(close_frame[0..extra.len], extra);
        frame_len = extra.len;
    }
    while (frame_len < close_frame.len) {
        var r_vec = [1][]u8{close_frame[frame_len..]};
        const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &r_vec } })).net_read).data_len;
        if (n == 0) break;
        frame_len += n;
    }

    // Frame opcode must be close (0x88)
    try std.testing.expect(frame_len >= 2);
    try std.testing.expectEqual(@as(u8, 0x88), close_frame[0]);
    const payload_len = close_frame[1] & 0x7F;
    // RFC 6455: control frame payload length must be <= 125
    try std.testing.expect(payload_len <= 125);
    // Payload contains 2-byte code + UTF-8 reason
    try std.testing.expect(payload_len >= 2);
    // Unmasked server frame: 2-byte frame header + 2-byte status code => reason starts at 4
    const reason_slice = close_frame[4 .. 2 + payload_len];
    try std.testing.expect(std.unicode.utf8ValidateSlice(reason_slice));
}
