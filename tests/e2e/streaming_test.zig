const std = @import("std");
const helpers = @import("helpers.zig");
const http = helpers.http;
const getTestIo = helpers.getTestIo;

test "e2e: ResponseWriter.flush streaming delivery" {
    const allocator = std.testing.allocator;
    const io = getTestIo();

    var mux = http.ServeMux.init(allocator);
    defer mux.deinit();

    try mux.handleFunc("GET /stream", struct {
        fn handle(w: *http.ResponseWriter, _: *http.Request) anyerror!void {
            try w.header().set("Content-Type", "text/plain");
            try w.writeAll("part-1;");
            try w.flush();

            // Simulate delayed second part
            try w.io.sleep(.{ .nanoseconds = 50 * std.time.ns_per_ms }, .boot);
            try w.writeAll("part-2;");
        }
    }.handle);

    var ts = try helpers.TestServer.start(allocator, io, .{ .handler = mux.handler() });
    defer ts.stop();

    var client = try ts.connect(io);
    defer client.close(io);

    const req = "GET /stream HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    var vec = [1][]const u8{req};
    _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &vec } })).net_write;

    // Read until part-1 is received
    var buf: [512]u8 = undefined;
    var total1: usize = 0;
    while (total1 < buf.len and std.mem.indexOf(u8, buf[0..total1], "part-1;") == null) {
        var r_vec = [1][]u8{buf[total1..]};
        const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &r_vec } })).net_read).data_len;
        if (n == 0) break;
        total1 += n;
    }

    const first_str = buf[0..total1];
    try std.testing.expect(std.mem.indexOf(u8, first_str, "200 OK") != null);
    try std.testing.expect(std.ascii.findIgnoreCase(first_str, "transfer-encoding: chunked") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_str, "part-1;") != null);
    // At this point part-2 must not have arrived yet because handler is sleeping
    try std.testing.expect(std.mem.indexOf(u8, first_str, "part-2;") == null);

    // Now read the remainder until part-2 arrives
    var total2: usize = total1;
    while (total2 < buf.len and std.mem.indexOf(u8, buf[0..total2], "part-2;") == null) {
        var rem_vec = [1][]u8{buf[total2..]};
        const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &rem_vec } })).net_read).data_len;
        if (n == 0) break;
        total2 += n;
    }
    // Continue reading until terminal chunk arrives
    while (total2 < buf.len and std.mem.indexOf(u8, buf[0..total2], "0\r\n\r\n") == null) {
        var rem_vec = [1][]u8{buf[total2..]};
        const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &rem_vec } })).net_read).data_len;
        if (n == 0) break;
        total2 += n;
    }
    const full_str = buf[0..total2];
    try std.testing.expect(std.mem.indexOf(u8, full_str, "part-2;") != null);
    try std.testing.expect(std.mem.indexOf(u8, full_str, "0\r\n\r\n") != null);
}

test "e2e: ResponseWriter.hijack raw socket takeover" {
    const allocator = std.testing.allocator;
    const io = getTestIo();

    var mux = http.ServeMux.init(allocator);
    defer mux.deinit();

    try mux.handleFunc("GET /ws-upgrade", struct {
        fn handle(w: *http.ResponseWriter, req: *http.Request) anyerror!void {
            _ = req;
            const raw_stream = try w.hijack();
            defer raw_stream.close(w.io);

            // Write custom protocol frame
            const hello = "CUSTOM_PROTO_ACK\n";
            var w_vec = [1][]const u8{hello};
            _ = try (try w.io.operate(.{ .net_write = .{ .socket_handle = raw_stream.socket.handle, .data = &w_vec } })).net_write;

            // Subsequent w.writeAll should fail with error.AlreadyHijacked
            try std.testing.expectError(error.AlreadyHijacked, w.writeAll("illegal"));

            // Read client message
            var in_buf: [64]u8 = undefined;
            var in_total: usize = 0;
            while (in_total < in_buf.len and std.mem.indexOfScalar(u8, in_buf[0..in_total], '\n') == null) {
                var r_vec = [1][]u8{in_buf[in_total..]};
                const n = (try (try w.io.operate(.{ .net_read = .{ .socket_handle = raw_stream.socket.handle, .data = &r_vec } })).net_read).data_len;
                if (n == 0) break;
                in_total += n;
            }
            try std.testing.expectEqualStrings("PING\n", in_buf[0..in_total]);

            // Reply PONG
            const pong = "PONG\n";
            var p_vec = [1][]const u8{pong};
            _ = try (try w.io.operate(.{ .net_write = .{ .socket_handle = raw_stream.socket.handle, .data = &p_vec } })).net_write;
        }
    }.handle);

    var ts = try helpers.TestServer.start(allocator, io, .{ .handler = mux.handler() });
    defer ts.stop();

    var client = try ts.connect(io);
    defer client.close(io);

    const req = "GET /ws-upgrade HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n";
    var vec = [1][]const u8{req};
    _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &vec } })).net_write;

    // Read custom ack until newline
    var buf: [64]u8 = undefined;
    var total_ack: usize = 0;
    while (total_ack < buf.len and std.mem.indexOfScalar(u8, buf[0..total_ack], '\n') == null) {
        var r_vec = [1][]u8{buf[total_ack..]};
        const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &r_vec } })).net_read).data_len;
        if (n == 0) break;
        total_ack += n;
    }
    try std.testing.expectEqualStrings("CUSTOM_PROTO_ACK\n", buf[0..total_ack]);

    // Send PING
    const ping = "PING\n";
    var ping_vec = [1][]const u8{ping};
    _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &ping_vec } })).net_write;

    // Read PONG until newline
    var pong_buf: [64]u8 = undefined;
    var total_pong: usize = 0;
    while (total_pong < pong_buf.len and std.mem.indexOfScalar(u8, pong_buf[0..total_pong], '\n') == null) {
        var r_vec = [1][]u8{pong_buf[total_pong..]};
        const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &r_vec } })).net_read).data_len;
        if (n == 0) break;
        total_pong += n;
    }
    try std.testing.expectEqualStrings("PONG\n", pong_buf[0..total_pong]);
}

test "e2e: ResponseWriter.hijack flushes buffered data before socket takeover" {
    const allocator = std.testing.allocator;
    const io = getTestIo();

    var mux = http.ServeMux.init(allocator);
    defer mux.deinit();

    try mux.handleFunc("GET /buffered-hijack", struct {
        fn handle(w: *http.ResponseWriter, _: *http.Request) anyerror!void {
            // Write handshake data that gets buffered into 4KB memory buffer
            try w.header().set("Content-Type", "text/plain");
            try w.writeAll("HANDSHAKE_OK\n");

            // Hijack socket: this MUST flush the buffered handshake data out to the wire!
            const raw_stream = try w.hijack();
            defer raw_stream.close(w.io);

            // Send raw post-hijack protocol message
            const raw_msg = "RAW_PAYLOAD\n";
            var msg_vec = [1][]const u8{raw_msg};
            _ = try (try w.io.operate(.{ .net_write = .{ .socket_handle = raw_stream.socket.handle, .data = &msg_vec } })).net_write;
        }
    }.handle);

    var ts = try helpers.TestServer.start(allocator, io, .{ .handler = mux.handler() });
    defer ts.stop();

    var client = try ts.connect(io);
    defer client.close(io);

    const req = "GET /buffered-hijack HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade\r\nUpgrade: proto\r\n\r\n";
    var vec = [1][]const u8{req};
    _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &vec } })).net_write;

    // Read full response until RAW_PAYLOAD arrives
    var buf: [512]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len and std.mem.indexOf(u8, buf[0..total], "RAW_PAYLOAD\n") == null) {
        var r_vec = [1][]u8{buf[total..]};
        const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &r_vec } })).net_read).data_len;
        if (n == 0) break;
        total += n;
    }

    const full_resp = buf[0..total];
    // Verify HTTP 200 header was sent
    try std.testing.expect(std.mem.indexOf(u8, full_resp, "200 OK") != null);
    // Verify Transfer-Encoding: chunked was selected (since no Content-Length was set)
    try std.testing.expect(std.ascii.findIgnoreCase(full_resp, "transfer-encoding: chunked") != null);
    // Pin wire framing: flushed prefix is chunk-framed (13 bytes = 0xd) without terminal chunk,
    // immediately followed by the raw socket bytes
    try std.testing.expect(std.mem.indexOf(u8, full_resp, "\r\n\r\nd\r\nHANDSHAKE_OK\n\r\nRAW_PAYLOAD\n") != null);
}

test "e2e: ResponseWriter.hijack fails with CannotFlushBuffer if status forbids body after buffering" {
    const allocator = std.testing.allocator;
    const io = getTestIo();

    var mux = http.ServeMux.init(allocator);
    defer mux.deinit();

    try mux.handleFunc("GET /bad-hijack", struct {
        fn handle(w: *http.ResponseWriter, _: *http.Request) anyerror!void {
            try w.writeAll("buffered_data");
            w.setStatus(.no_content);
            _ = try w.hijack();
        }
    }.handle);

    var ts = try helpers.TestServer.start(allocator, io, .{ .handler = mux.handler() });
    defer ts.stop();

    var client = try ts.connect(io);
    defer client.close(io);

    const req = "GET /bad-hijack HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    var vec = [1][]const u8{req};
    _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &vec } })).net_write;

    var buf: [128]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        var r_vec = [1][]u8{buf[total..]};
        const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &r_vec } })).net_read).data_len;
        if (n == 0) break;
        total += n;
    }
    // Because handler errored with CannotFlushBuffer, server handles it as 500
    try std.testing.expect(std.mem.indexOf(u8, buf[0..total], "500 Internal Server Error") != null);
}
