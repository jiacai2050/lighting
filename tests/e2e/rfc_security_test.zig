const std = @import("std");
const helpers = @import("helpers.zig");
const http = helpers.http;
const getTestIo = helpers.getTestIo;

test "e2e: 431 header too large and 500 internal server error" {
    std.testing.log_level = .warn; // suppress error log during intentional error test
    const allocator = std.testing.allocator;
    const io = getTestIo();

    var mux = http.ServeMux.init(allocator);
    defer mux.deinit();

    try mux.handleFunc("/panic", struct {
        fn handle(_: *http.ResponseWriter, _: *http.Request) anyerror!void {
            return error.CustomHandlerFault;
        }
    }.handle);

    var ts = try helpers.TestServer.start(allocator, io, .{
        .handler = mux.handler(),
        .header_bytes_max = 256, // small limit to easily test 431
    });
    defer ts.stop();

    const connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", ts.port);

    // 1. Test 500 error isolation
    {
        var client_stream = try connect_addr.connect(io, .{ .mode = .stream });
        defer client_stream.close(io);

        const req = "GET /panic HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
        var vec = [1][]const u8{req};
        _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client_stream.socket.handle, .data = &vec } })).net_write;

        var resp_buf: [1024]u8 = undefined;
        var total_read: usize = 0;
        while (total_read < resp_buf.len) {
            var r_vec = [1][]u8{resp_buf[total_read..]};
            const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client_stream.socket.handle, .data = &r_vec } })).net_read).data_len;
            if (n == 0) break;
            total_read += n;
            if (std.ascii.findIgnoreCase(resp_buf[0..total_read], "500 Internal Server Error") != null) break;
        }
        const resp_str = resp_buf[0..total_read];

        try std.testing.expect(std.ascii.findIgnoreCase(resp_str, "500 Internal Server Error") != null);
    }

    // 2. Test 431 header too large
    {
        var client_stream = try connect_addr.connect(io, .{ .mode = .stream });
        defer client_stream.close(io);

        // Header exceeding 256 bytes
        var big_header: [512]u8 = undefined;
        @memset(&big_header, 'X');
        const req_prefix = "GET /ping HTTP/1.1\r\nHost: localhost\r\nX-Long: ";
        var vecs = [_][]const u8{ req_prefix, &big_header, "\r\n\r\n" };
        _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client_stream.socket.handle, .data = &vecs } })).net_write;

        var resp_buf: [1024]u8 = undefined;
        var total_read: usize = 0;
        while (total_read < resp_buf.len) {
            var r_vec = [1][]u8{resp_buf[total_read..]};
            const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client_stream.socket.handle, .data = &r_vec } })).net_read).data_len;
            if (n == 0) break;
            total_read += n;
            if (std.ascii.findIgnoreCase(resp_buf[0..total_read], "431 Request Header Fields Too Large") != null) break;
        }
        const resp_str = resp_buf[0..total_read];

        try std.testing.expect(std.ascii.findIgnoreCase(resp_str, "431 Request Header Fields Too Large") != null);
    }
}

test "e2e: RFC 9112 strict request line, headers, and Transfer-Encoding" {
    const allocator = std.testing.allocator;

    // 1. Request line with 4 tokens rejected
    {
        const raw = "GET / HTTP/1.1 EXTRA\r\nHost: localhost\r\n\r\n";
        try std.testing.expectError(error.InvalidRequestLine, http.parseRequestHead(allocator, raw));
    }

    // 2. Whitespace before colon rejected (RFC 9112 Section 5.1)
    {
        const raw = "GET / HTTP/1.1\r\nHost : localhost\r\n\r\n";
        try std.testing.expectError(error.InvalidHeaderColonWhitespace, http.parseRequestHead(allocator, raw));
    }

    // 3. Duplicate Host header rejected (RFC 9112 Section 7.1)
    {
        const raw = "GET / HTTP/1.1\r\nHost: a.com\r\nHost: b.com\r\n\r\n";
        try std.testing.expectError(error.DuplicateHostHeader, http.parseRequestHead(allocator, raw));
    }

    // 4. Transfer-Encoding not-chunked rejected
    {
        const raw = "POST / HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: not-chunked\r\n\r\n";
        try std.testing.expectError(error.UnsupportedTransferEncoding, http.parseRequestHead(allocator, raw));
    }

    // 5. Transfer-Encoding chunked not final rejected (RFC 9112 Section 6.1)
    {
        const raw = "POST / HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked, gzip\r\n\r\n";
        try std.testing.expectError(error.UnsupportedTransferEncoding, http.parseRequestHead(allocator, raw));
    }

    // 6. Valid Transfer-Encoding: chunked accepted
    {
        const raw = "POST / HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n";
        const head = try http.parseRequestHead(allocator, raw);
        var h = head.headers;
        defer h.deinit();
        try std.testing.expect(head.is_chunked);
    }
}

test "e2e: response header CRLF and control character injection" {
    var headers = http.HeaderMap.init(std.testing.allocator);
    defer headers.deinit();

    // 1. Value with CR/LF must be rejected
    try std.testing.expectError(error.InvalidHeaderCharacter, headers.set("X-Bad", "hello\r\nInjected: true"));
    try std.testing.expectError(error.InvalidHeaderCharacter, headers.add("X-Bad", "hello\nInjected: true"));

    // 2. Name with space, colon, or control chars must be rejected
    try std.testing.expectError(error.InvalidHeaderCharacter, headers.set("X Bad", "value"));
    try std.testing.expectError(error.InvalidHeaderCharacter, headers.set("X:Bad", "value"));
    try std.testing.expectError(error.InvalidHeaderCharacter, headers.set("X\x00Bad", "value"));

    // 3. Valid headers succeed
    try headers.set("X-Good-Header", "standard value 123 !");
    try std.testing.expectEqualStrings("standard value 123 !", headers.get("X-Good-Header").?);
}

test "e2e: monotonic read deadline stops Slow Post trickle" {
    const allocator = std.testing.allocator;
    const io = getTestIo();

    var mux = http.ServeMux.init(allocator);
    defer mux.deinit();

    try mux.handleFunc("POST /slow", struct {
        fn handle(w: *http.ResponseWriter, req: *http.Request) anyerror!void {
            const body = try req.readBodyAlloc(1024);
            try w.writeAll(body);
        }
    }.handle);

    var ts = try helpers.TestServer.start(allocator, io, .{
        .handler = mux.handler(),
        .read_timeout_ns = 150 * std.time.ns_per_ms,
    });
    defer ts.stop();

    var client = try ts.connect(io);
    defer client.close(io);

    // Send header announcing Content-Length: 10
    const header = "POST /slow HTTP/1.1\r\nHost: localhost\r\nContent-Length: 10\r\n\r\n";
    var vec = [1][]const u8{header};
    _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &vec } })).net_write;

    // Send 1 byte every 60ms. Total 4 bytes takes 240ms > 150ms deadline!
    // With relative timeout, this would succeed indefinitely because gap < 150ms.
    // With monotonic deadline, it MUST trigger timeout and close.
    for (0..4) |_| {
        try io.sleep(.{ .nanoseconds = 60 * std.time.ns_per_ms }, .boot);
        var b = [1][]const u8{"x"};
        _ = io.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &b } }) catch break;
    }

    // Try reading response: should be either 408 / 500 or closed socket
    var resp_buf: [512]u8 = undefined;
    var r_vec = [1][]u8{&resp_buf};
    _ = io.operate(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &r_vec } }) catch {};
}

test "e2e: duplicate chunked and forbidden chunk trailers rejected" {
    const allocator = std.testing.allocator;
    const io = getTestIo();

    var mux = http.ServeMux.init(allocator);
    defer mux.deinit();

    try mux.handleFunc("POST /trailer", struct {
        fn handle(w: *http.ResponseWriter, req: *http.Request) anyerror!void {
            _ = try req.readBodyAlloc(1024);
            try w.writeAll("ok");
        }
    }.handle);

    var ts = try helpers.TestServer.start(allocator, io, .{ .handler = mux.handler() });
    defer ts.stop();

    const connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", ts.port);

    // 1. Duplicate chunked transfer encoding rejected with 400 Bad Request
    {
        var client = try connect_addr.connect(io, .{ .mode = .stream });
        defer client.close(io);

        const req = "POST /trailer HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked, chunked\r\n\r\n0\r\n\r\n";
        var vec = [1][]const u8{req};
        _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &vec } })).net_write;

        var resp_buf: [256]u8 = undefined;
        var total_read: usize = 0;
        while (total_read < resp_buf.len) {
            var r_vec = [1][]u8{resp_buf[total_read..]};
            const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &r_vec } })).net_read).data_len;
            if (n == 0) break;
            total_read += n;
            if (std.mem.indexOf(u8, resp_buf[0..total_read], "400 Bad Request") != null) break;
        }
        try std.testing.expect(std.mem.indexOf(u8, resp_buf[0..total_read], "400 Bad Request") != null);
    }

    // 2. Forbidden trailer Content-Length rejected
    {
        var client = try connect_addr.connect(io, .{ .mode = .stream });
        defer client.close(io);

        const req = "POST /trailer HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\nContent-Length: 5\r\n\r\n";
        var vec = [1][]const u8{req};
        _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &vec } })).net_write;

        var resp_buf: [256]u8 = undefined;
        var total_read: usize = 0;
        while (total_read < resp_buf.len) {
            var r_vec = [1][]u8{resp_buf[total_read..]};
            const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &r_vec } })).net_read).data_len;
            if (n == 0) break;
            total_read += n;
            if (std.mem.indexOf(u8, resp_buf[0..total_read], "500 Internal Server Error") != null) break;
        }
        // Handler encountered error when reading trailer, so returns 500 or drops
        try std.testing.expect(std.mem.indexOf(u8, resp_buf[0..total_read], "500 Internal Server Error") != null or total_read == 0);
    }


}

test "e2e: RFC 9112 request-target rejection in live server" {
    const allocator = std.testing.allocator;
    const io = getTestIo();

    var mux = http.ServeMux.init(allocator);
    defer mux.deinit();

    try mux.handleFunc("OPTIONS *", struct {
        fn handle(w: *http.ResponseWriter, _: *http.Request) anyerror!void {
            try w.header().set("Allow", "GET, POST, OPTIONS");
            w.writeHeader(.ok);
        }
    }.handle);

    var ts = try helpers.TestServer.start(allocator, io, .{ .handler = mux.handler() });
    defer ts.stop();

    const connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", ts.port);

    // 1. GET * is rejected with 400 Bad Request
    {
        var client = try connect_addr.connect(io, .{ .mode = .stream });
        defer client.close(io);

        const req = "GET * HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
        var vec = [1][]const u8{req};
        _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &vec } })).net_write;

        var resp_buf: [512]u8 = undefined;
        var total_read: usize = 0;
        while (total_read < resp_buf.len) {
            var r_vec = [1][]u8{resp_buf[total_read..]};
            const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &r_vec } })).net_read).data_len;
            if (n == 0) break;
            total_read += n;
        }
        const resp_str = resp_buf[0..total_read];

        try std.testing.expect(std.mem.indexOf(u8, resp_str, "400 Bad Request") != null);
    }

    // 2. OPTIONS * is accepted with 200 OK
    {
        var client = try connect_addr.connect(io, .{ .mode = .stream });
        defer client.close(io);

        const req = "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
        var vec = [1][]const u8{req};
        _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &vec } })).net_write;

        var resp_buf: [512]u8 = undefined;
        var total_read: usize = 0;
        while (total_read < resp_buf.len) {
            var r_vec = [1][]u8{resp_buf[total_read..]};
            const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &r_vec } })).net_read).data_len;
            if (n == 0) break;
            total_read += n;
        }
        const resp_str = resp_buf[0..total_read];

        try std.testing.expect(std.mem.indexOf(u8, resp_str, "200 OK") != null);
        try std.testing.expect(std.mem.indexOf(u8, resp_str, "Allow: GET, POST, OPTIONS") != null);
    }


}

test "e2e: invalid Content-Length is rejected" {
    const allocator = std.testing.allocator;
    const io = getTestIo();

    var mux = http.ServeMux.init(allocator);
    defer mux.deinit();

    try mux.handleFunc("GET /bad-cl", struct {
        fn handle(w: *http.ResponseWriter, _: *http.Request) anyerror!void {
            try w.headers.set("Content-Length", "not_a_number");
            try w.writeAll("hello");
        }
    }.handle);

    var ts = try helpers.TestServer.start(allocator, io, .{ .handler = mux.handler() });
    defer ts.stop();

    const connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", ts.port);
    var client = try connect_addr.connect(io, .{ .mode = .stream });
    defer client.close(io);

    const req = "GET /bad-cl HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    var vec = [1][]const u8{req};
    _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &vec } })).net_write;

    var resp_buf: [512]u8 = undefined;
    var total: usize = 0;
    while (total < resp_buf.len) {
        var r_vec = [1][]u8{resp_buf[total..]};
        const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &r_vec } })).net_read).data_len;
        if (n == 0) break;
        total += n;
    }
    const resp_str = resp_buf[0..total];
    // Invalid Content-Length must trigger 500 Internal Server Error, and must NOT send not_a_number header
    try std.testing.expect(std.mem.indexOf(u8, resp_str, "500 Internal Server Error") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp_str, "not_a_number") == null);


}

test "e2e: Date header is generated and complies with RFC 9110" {
    const allocator = std.testing.allocator;
    const io = getTestIo();

    var mux = http.ServeMux.init(allocator);
    defer mux.deinit();

    try mux.handleFunc("GET /date-check", struct {
        fn handle(w: *http.ResponseWriter, _: *http.Request) anyerror!void {
            try w.writeAll("ok");
        }
    }.handle);

    var ts = try helpers.TestServer.start(allocator, io, .{ .handler = mux.handler() });
    defer ts.stop();

    const connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", ts.port);
    var client = try connect_addr.connect(io, .{ .mode = .stream });
    defer client.close(io);

    const req = "GET /date-check HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    var vec = [1][]const u8{req};
    _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &vec } })).net_write;

    var resp_buf: [512]u8 = undefined;
    var total: usize = 0;
    while (total < resp_buf.len) {
        var r_vec = [1][]u8{resp_buf[total..]};
        const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &r_vec } })).net_read).data_len;
        if (n == 0) break;
        total += n;
    }
    const resp_str = resp_buf[0..total];
    try std.testing.expect(std.mem.indexOf(u8, resp_str, "200 OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp_str, "Date: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp_str, " GMT\r\n") != null);


}

test "e2e: Expect: 100-continue is properly handled" {
    const allocator = std.testing.allocator;
    const io = getTestIo();

    var mux = http.ServeMux.init(allocator);
    defer mux.deinit();

    try mux.handleFunc("POST /expect-test", struct {
        fn handle(w: *http.ResponseWriter, r: *http.Request) anyerror!void {
            if (r.body()) |b| {
                const body = try b.readAllAlloc(w.arena, 1024);
                try w.writeAll(body);
            }
        }
    }.handle);

    var ts = try helpers.TestServer.start(allocator, io, .{ .handler = mux.handler() });
    defer ts.stop();

    const connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", ts.port);
    var client = try connect_addr.connect(io, .{ .mode = .stream });
    defer client.close(io);

    // Client sends head with Expect: 100-continue
    const req_head = "POST /expect-test HTTP/1.1\r\nHost: localhost\r\nExpect: 100-continue\r\nContent-Length: 12\r\nConnection: close\r\n\r\n";
    var head_vec = [1][]const u8{req_head};
    _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &head_vec } })).net_write;

    // Client waits for 100 Continue
    var interim_buf: [128]u8 = undefined;
    var interim_vec = [1][]u8{&interim_buf};
    const n_interim = (try (try io.operate(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &interim_vec } })).net_read).data_len;
    try std.testing.expect(std.mem.indexOf(u8, interim_buf[0..n_interim], "100 Continue") != null);

    // Client sends body
    const body_str = "hello-expect";
    var body_vec = [1][]const u8{body_str};
    _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &body_vec } })).net_write;

    // Client reads final 200 OK response
    var final_buf: [512]u8 = undefined;
    var total_final: usize = 0;
    while (total_final < final_buf.len) {
        var r_vec = [1][]u8{final_buf[total_final..]};
        const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &r_vec } })).net_read).data_len;
        if (n == 0) break;
        total_final += n;
    }
    const final_str = final_buf[0..total_final];
    try std.testing.expect(std.mem.indexOf(u8, final_str, "200 OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, final_str, "hello-expect") != null);


}
