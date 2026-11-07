const std = @import("std");
const helpers = @import("helpers.zig");
const http = helpers.http;
const getTestIo = helpers.getTestIo;

test "e2e: GET, POST echo, and Keep-Alive" {
    const allocator = std.testing.allocator;
    const io = getTestIo();

    var mux = http.ServeMux.init(allocator);
    defer mux.deinit();

    try mux.handleFunc("/ping", struct {
        fn handle(w: *http.ResponseWriter, _: *http.Request) anyerror!void {
            try w.header().set("Content-Type", "text/plain");
            try w.writeAll("pong");
        }
    }.handle);

    try mux.handleFunc("/echo", struct {
        fn handle(w: *http.ResponseWriter, req: *http.Request) anyerror!void {
            const body = try req.readBodyAlloc(1024);
            try w.header().set("Content-Type", "text/plain");
            try w.writeAll(body);
        }
    }.handle);

    var ts = try helpers.TestServer.start(allocator, io, .{ .handler = mux.handler() });
    defer ts.stop();

    var client_stream = try ts.connect(io);
    defer client_stream.close(io);

    // 1. Send first request: GET /ping (Keep-Alive)
    const req1 = "GET /ping HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n";
    var vec1 = [1][]const u8{req1};
    _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client_stream.socket.handle, .data = &vec1 } })).net_write;

    var resp_buf: [1024]u8 = undefined;
    var total_read: usize = 0;
    while (total_read < resp_buf.len) {
        var resp_vec = [1][]u8{resp_buf[total_read..]};
        const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client_stream.socket.handle, .data = &resp_vec } })).net_read).data_len;
        if (n == 0) break;
        total_read += n;
        if (std.mem.indexOf(u8, resp_buf[0..total_read], "pong") != null) break;
    }
    var resp_str = resp_buf[0..total_read];

    try std.testing.expect(std.ascii.findIgnoreCase(resp_str, "200 OK") != null);
    try std.testing.expect(std.ascii.findIgnoreCase(resp_str, "content-length: 4") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp_str, "pong") != null);

    // 2. Send second request on SAME connection (Keep-Alive): POST /echo
    const req2 = "POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 11\r\nConnection: close\r\n\r\nhello-zig17";
    var vec2 = [1][]const u8{req2};
    _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client_stream.socket.handle, .data = &vec2 } })).net_write;

    total_read = 0;
    while (total_read < resp_buf.len) {
        var resp_vec = [1][]u8{resp_buf[total_read..]};
        const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client_stream.socket.handle, .data = &resp_vec } })).net_read).data_len;
        if (n == 0) break;
        total_read += n;
        if (std.mem.indexOf(u8, resp_buf[0..total_read], "hello-zig17") != null) break;
    }
    resp_str = resp_buf[0..total_read];

    try std.testing.expect(std.ascii.findIgnoreCase(resp_str, "200 OK") != null);
    try std.testing.expect(std.ascii.findIgnoreCase(resp_str, "content-length: 11") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp_str, "hello-zig17") != null);
}

test "e2e: chunked transfer encoding" {
    const allocator = std.testing.allocator;
    const io = getTestIo();

    var mux = http.ServeMux.init(allocator);
    defer mux.deinit();

    try mux.handleFunc("/stream", struct {
        fn handle(w: *http.ResponseWriter, _: *http.Request) anyerror!void {
            try w.header().set("Content-Type", "text/plain");
            var block: [1024]u8 = undefined;
            @memset(&block, 'B');
            for (0..5) |_| {
                try w.writeAll(&block);
            }
        }
    }.handle);

    var ts = try helpers.TestServer.start(allocator, io, .{ .handler = mux.handler() });
    defer ts.stop();

    var client_stream = try ts.connect(io);
    defer client_stream.close(io);

    const req = "GET /stream HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    var vec = [1][]const u8{req};
    _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client_stream.socket.handle, .data = &vec } })).net_write;

    var resp_buf: [8192]u8 = undefined;
    var total_read: usize = 0;
    while (total_read < resp_buf.len) {
        var r_vec = [1][]u8{resp_buf[total_read..]};
        const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client_stream.socket.handle, .data = &r_vec } })).net_read).data_len;
        if (n == 0) break;
        total_read += n;
    }
    const resp_str = resp_buf[0..total_read];

    try std.testing.expect(std.ascii.findIgnoreCase(resp_str, "transfer-encoding: chunked") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp_str, "0\r\n\r\n") != null);
}

test "e2e: HTTP pipelining and RFC compliance (400 on missing Host, 204 No Content)" {
    const allocator = std.testing.allocator;
    const io = getTestIo();

    var mux = http.ServeMux.init(allocator);
    defer mux.deinit();

    try mux.handleFunc("/ping", struct {
        fn handle(w: *http.ResponseWriter, _: *http.Request) anyerror!void {
            try w.writeAll("pong");
        }
    }.handle);

    try mux.handleFunc("/nocontent", struct {
        fn handle(w: *http.ResponseWriter, _: *http.Request) anyerror!void {
            w.writeHeader(.no_content);
        }
    }.handle);

    var ts = try helpers.TestServer.start(allocator, io, .{ .handler = mux.handler() });
    defer ts.stop();

    const connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", ts.port);

    // 1. Pipelining test: Send two back-to-back requests in one TCP write
    {
        var client_stream = try connect_addr.connect(io, .{ .mode = .stream });
        defer client_stream.close(io);

        const pipelined_requests =
            "GET /ping HTTP/1.1\r\nHost: localhost\r\n\r\n" ++
            "GET /ping HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";

        var vec = [1][]const u8{pipelined_requests};
        _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client_stream.socket.handle, .data = &vec } })).net_write;

        var resp_buf: [2048]u8 = undefined;
        var total_read: usize = 0;
        while (total_read < resp_buf.len) {
            var r_vec = [1][]u8{resp_buf[total_read..]};
            const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client_stream.socket.handle, .data = &r_vec } })).net_read).data_len;
            if (n == 0) break;
            total_read += n;
        }
        const resp_str = resp_buf[0..total_read];

        // Should contain two 200 OK responses
        var count: usize = 0;
        var idx: usize = 0;
        while (std.mem.indexOfPos(u8, resp_str, idx, "HTTP/1.1 200 OK")) |found| {
            count += 1;
            idx = found + 15;
        }
        try std.testing.expectEqual(@as(usize, 2), count);
    }

    // 2. RFC Compliance: HTTP/1.1 missing Host header MUST return 400 Bad Request
    {
        var client_stream = try connect_addr.connect(io, .{ .mode = .stream });
        defer client_stream.close(io);

        const bad_req = "GET /ping HTTP/1.1\r\nConnection: close\r\n\r\n";
        var vec = [1][]const u8{bad_req};
        _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client_stream.socket.handle, .data = &vec } })).net_write;

        var resp_buf: [1024]u8 = undefined;
        var total_read: usize = 0;
        while (total_read < resp_buf.len) {
            var r_vec = [1][]u8{resp_buf[total_read..]};
            const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client_stream.socket.handle, .data = &r_vec } })).net_read).data_len;
            if (n == 0) break;
            total_read += n;
        }
        const resp_str = resp_buf[0..total_read];
        try std.testing.expect(std.mem.indexOf(u8, resp_str, "400 Bad Request") != null);
    }

    // 3. RFC Compliance: 204 No Content MUST NOT have Content-Length
    {
        var client_stream = try connect_addr.connect(io, .{ .mode = .stream });
        defer client_stream.close(io);

        const req = "GET /nocontent HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
        var vec = [1][]const u8{req};
        _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client_stream.socket.handle, .data = &vec } })).net_write;

        var resp_buf: [1024]u8 = undefined;
        var total_read: usize = 0;
        while (total_read < resp_buf.len) {
            var r_vec = [1][]u8{resp_buf[total_read..]};
            const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client_stream.socket.handle, .data = &r_vec } })).net_read).data_len;
            if (n == 0) break;
            total_read += n;
        }
        const resp_str = resp_buf[0..total_read];
        try std.testing.expect(std.mem.indexOf(u8, resp_str, "204 No Content") != null);
        try std.testing.expect(std.ascii.findIgnoreCase(resp_str, "content-length") == null);
    }

    // 4. Large unread body exceeding 256KB closes connection instead of draining indefinitely
    {
        var client_stream = try connect_addr.connect(io, .{ .mode = .stream });
        defer client_stream.close(io);

        // Handler doesn't read body; send 300KB declared body
        const req_head = "POST /nocontent HTTP/1.1\r\nHost: localhost\r\nContent-Length: 307200\r\n\r\n";
        var vec = [1][]const u8{req_head};
        _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client_stream.socket.handle, .data = &vec } })).net_write;

        // Send dummy chunk
        var dummy: [4096]u8 = undefined;
        @memset(&dummy, 'A');
        var dummy_vec = [1][]const u8{&dummy};
        _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client_stream.socket.handle, .data = &dummy_vec } })).net_write;

        var resp_buf: [1024]u8 = undefined;
        var total_read: usize = 0;
        while (total_read < resp_buf.len) {
            var r_vec = [1][]u8{resp_buf[total_read..]};
            const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client_stream.socket.handle, .data = &r_vec } })).net_read).data_len;
            if (n == 0) break;
            total_read += n;
            if (std.mem.indexOf(u8, resp_buf[0..total_read], "204 No Content") != null) break;
        }
        const resp_str = resp_buf[0..total_read];
        try std.testing.expect(std.mem.indexOf(u8, resp_str, "204 No Content") != null);
    }
}

test "e2e: HEAD suppression, 204 suppression, Content-Length guards" {
    const allocator = std.testing.allocator;
    const io = getTestIo();

    var mux = http.ServeMux.init(allocator);
    defer mux.deinit();

    // Endpoint for HEAD test (writes body, but HEAD must suppress it while keeping Content-Length)
    try mux.handleFunc("GET /head_test", struct {
        fn handle(w: *http.ResponseWriter, _: *http.Request) anyerror!void {
            try w.header().set("Content-Type", "text/plain");
            try w.writeAll("0123456789");
        }
    }.handle);

    // Endpoint for 204 test (tries to write body, but 204 must suppress it and omit Content-Length)
    try mux.handleFunc("GET /204_suppress", struct {
        fn handle(w: *http.ResponseWriter, _: *http.Request) anyerror!void {
            w.writeHeader(.no_content);
            try w.writeAll("this body must be suppressed");
        }
    }.handle);

    // Endpoint for Content-Length guard (declares 5, but writes 10 -> should fail)
    try mux.handleFunc("GET /cl_overflow", struct {
        fn handle(w: *http.ResponseWriter, _: *http.Request) anyerror!void {
            try w.header().set("Content-Length", "5");
            _ = try w.write("12345");
            _ = w.write("extra_bytes") catch |err| {
                if (err == error.ContentLengthExceeded) {
                    return;
                }
                return err;
            };
        }
    }.handle);

    var ts = try helpers.TestServer.start(allocator, io, .{ .handler = mux.handler() });
    defer ts.stop();

    const connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", ts.port);

    // 1. Verify HEAD suppresses body while emitting Content-Length
    {
        var client_stream = try connect_addr.connect(io, .{ .mode = .stream });
        defer client_stream.close(io);

        const req = "HEAD /head_test HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
        var vec = [1][]const u8{req};
        _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client_stream.socket.handle, .data = &vec } })).net_write;

        var resp_buf: [1024]u8 = undefined;
        var total_read: usize = 0;
        while (total_read < resp_buf.len) {
            var r_vec = [1][]u8{resp_buf[total_read..]};
            const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client_stream.socket.handle, .data = &r_vec } })).net_read).data_len;
            if (n == 0) break;
            total_read += n;
        }
        const resp_str = resp_buf[0..total_read];
        try std.testing.expect(std.mem.indexOf(u8, resp_str, "200 OK") != null);
        try std.testing.expect(std.mem.indexOf(u8, resp_str, "Content-Length: 10") != null);
        const header_end = std.mem.indexOf(u8, resp_str, "\r\n\r\n").?;
        const body_part = resp_str[header_end + 4 ..];
        try std.testing.expectEqual(@as(usize, 0), body_part.len);
    }

    // 2. Verify 204 suppresses body even if handler attempted to write it
    {
        var client_stream = try connect_addr.connect(io, .{ .mode = .stream });
        defer client_stream.close(io);

        const req = "GET /204_suppress HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
        var vec = [1][]const u8{req};
        _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client_stream.socket.handle, .data = &vec } })).net_write;

        var resp_buf: [1024]u8 = undefined;
        var total_read: usize = 0;
        while (total_read < resp_buf.len) {
            var r_vec = [1][]u8{resp_buf[total_read..]};
            const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client_stream.socket.handle, .data = &r_vec } })).net_read).data_len;
            if (n == 0) break;
            total_read += n;
        }
        const resp_str = resp_buf[0..total_read];
        try std.testing.expect(std.mem.indexOf(u8, resp_str, "204 No Content") != null);
        try std.testing.expect(std.ascii.findIgnoreCase(resp_str, "content-length") == null);
        const header_end = std.mem.indexOf(u8, resp_str, "\r\n\r\n").?;
        const body_part = resp_str[header_end + 4 ..];
        try std.testing.expectEqual(@as(usize, 0), body_part.len);
    }

    // 3. Verify Content-Length overflow guard
    {
        var client_stream = try connect_addr.connect(io, .{ .mode = .stream });
        defer client_stream.close(io);

        const req = "GET /cl_overflow HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
        var vec = [1][]const u8{req};
        _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client_stream.socket.handle, .data = &vec } })).net_write;

        var resp_buf: [1024]u8 = undefined;
        var total_read: usize = 0;
        while (total_read < resp_buf.len) {
            var r_vec = [1][]u8{resp_buf[total_read..]};
            const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client_stream.socket.handle, .data = &r_vec } })).net_read).data_len;
            if (n == 0) break;
            total_read += n;
        }
        const resp_str = resp_buf[0..total_read];
        try std.testing.expect(std.mem.indexOf(u8, resp_str, "200 OK") != null);
        try std.testing.expect(std.mem.indexOf(u8, resp_str, "Content-Length: 5") != null);
    }


}

test "e2e: status 205 and header stripping on bodyless responses" {
    const allocator = std.testing.allocator;
    const io = getTestIo();

    var mux = http.ServeMux.init(allocator);
    defer mux.deinit();

    // 205 Reset Content: user tries to set Content-Length: 50 and write body
    try mux.handleFunc("GET /reset_content", struct {
        fn handle(w: *http.ResponseWriter, _: *http.Request) anyerror!void {
            w.writeHeader(.reset_content);
            try w.header().set("Content-Length", "50");
            try w.header().set("Transfer-Encoding", "chunked");
            _ = try w.write("discarded body");
        }
    }.handle);

    // 204 No Content: user tries to set Content-Length and Transfer-Encoding
    try mux.handleFunc("GET /no_content_strip", struct {
        fn handle(w: *http.ResponseWriter, _: *http.Request) anyerror!void {
            w.writeHeader(.no_content);
            try w.header().set("Content-Length", "99");
            try w.header().set("Transfer-Encoding", "chunked");
        }
    }.handle);

    var ts = try helpers.TestServer.start(allocator, io, .{ .handler = mux.handler() });
    defer ts.stop();

    const connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", ts.port);

    // 1. Verify 205 response
    {
        var client = try connect_addr.connect(io, .{ .mode = .stream });
        defer client.close(io);

        const req = "GET /reset_content HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
        var vec = [1][]const u8{req};
        _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &vec } })).net_write;

        var resp_buf: [512]u8 = undefined;
        var total_read: usize = 0;
        while (total_read < resp_buf.len) {
            var r_vec = [1][]u8{resp_buf[total_read..]};
            const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &r_vec } })).net_read).data_len;
            if (n == 0) break;
            total_read += n;
            if (std.mem.indexOf(u8, resp_buf[0..total_read], "\r\n\r\n") != null) break;
        }
        const resp_str = resp_buf[0..total_read];

        try std.testing.expect(std.mem.indexOf(u8, resp_str, "205 Reset Content") != null);
        try std.testing.expect(std.mem.indexOf(u8, resp_str, "Content-Length: 0") != null);
        try std.testing.expect(std.ascii.findIgnoreCase(resp_str, "transfer-encoding") == null);
        const header_end = std.mem.indexOf(u8, resp_str, "\r\n\r\n").?;
        try std.testing.expectEqual(@as(usize, 0), resp_str[header_end + 4 ..].len);
    }

    // 2. Verify 204 stripped both Content-Length and Transfer-Encoding
    {
        var client = try connect_addr.connect(io, .{ .mode = .stream });
        defer client.close(io);

        const req = "GET /no_content_strip HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
        var vec = [1][]const u8{req};
        _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &vec } })).net_write;

        var resp_buf: [512]u8 = undefined;
        var total_read: usize = 0;
        while (total_read < resp_buf.len) {
            var r_vec = [1][]u8{resp_buf[total_read..]};
            const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &r_vec } })).net_read).data_len;
            if (n == 0) break;
            total_read += n;
            if (std.mem.indexOf(u8, resp_buf[0..total_read], "\r\n\r\n") != null) break;
        }
        const resp_str = resp_buf[0..total_read];

        try std.testing.expect(std.mem.indexOf(u8, resp_str, "204 No Content") != null);
        try std.testing.expect(std.ascii.findIgnoreCase(resp_str, "content-length") == null);
        try std.testing.expect(std.ascii.findIgnoreCase(resp_str, "transfer-encoding") == null);
    }


}

test "e2e: HTTP/1.0 request receives HTTP/1.0 status line and no chunked encoding" {
    const allocator = std.testing.allocator;
    const io = getTestIo();

    var mux = http.ServeMux.init(allocator);
    defer mux.deinit();

    try mux.handleFunc("GET /version_test", struct {
        fn handle(w: *http.ResponseWriter, _: *http.Request) anyerror!void {
            try w.writeAll("hello-http10");
        }
    }.handle);

    // Large response: in HTTP/1.1 would trigger chunked, but in HTTP/1.0 must NOT be chunked
    try mux.handleFunc("GET /large_http10", struct {
        fn handle(w: *http.ResponseWriter, _: *http.Request) anyerror!void {
            var block: [8192]u8 = undefined;
            @memset(&block, 'Z');
            try w.writeAll(&block);
        }
    }.handle);

    var ts = try helpers.TestServer.start(allocator, io, .{ .handler = mux.handler() });
    defer ts.stop();

    const connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", ts.port);

    // 1. Basic HTTP/1.0 request gets HTTP/1.0 status line
    {
        var client = try connect_addr.connect(io, .{ .mode = .stream });
        defer client.close(io);

        const req = "GET /version_test HTTP/1.0\r\n\r\n";
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

        try std.testing.expect(std.mem.startsWith(u8, resp_str, "HTTP/1.0 200 OK\r\n"));
    }

    // 2. Large HTTP/1.0 response must NOT use Transfer-Encoding: chunked
    {
        var client = try connect_addr.connect(io, .{ .mode = .stream });
        defer client.close(io);

        const req = "GET /large_http10 HTTP/1.0\r\n\r\n";
        var vec = [1][]const u8{req};
        _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &vec } })).net_write;

        var resp_buf: [1024]u8 = undefined;
        var r_vec = [1][]u8{&resp_buf};
        const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &r_vec } })).net_read).data_len;
        const resp_str = resp_buf[0..n];

        try std.testing.expect(std.mem.startsWith(u8, resp_str, "HTTP/1.0 200 OK\r\n"));
        try std.testing.expect(std.ascii.findIgnoreCase(resp_str, "transfer-encoding") == null);
    }


}

test "e2e: Transfer-Encoding chunked synchronization" {
    const allocator = std.testing.allocator;
    const io = getTestIo();

    var mux = http.ServeMux.init(allocator);
    defer mux.deinit();

    try mux.handleFunc("GET /manual-te", struct {
        fn handle(w: *http.ResponseWriter, _: *http.Request) anyerror!void {
            try w.headers.set("Transfer-Encoding", "chunked");
            try w.writeAll("chunk-body");
        }
    }.handle);

    var ts = try helpers.TestServer.start(allocator, io, .{ .handler = mux.handler() });
    defer ts.stop();

    const connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", ts.port);
    var client = try connect_addr.connect(io, .{ .mode = .stream });
    defer client.close(io);

    const req = "GET /manual-te HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
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
    // Must be properly chunked and must NOT have Content-Length header
    try std.testing.expect(std.ascii.findIgnoreCase(resp_str, "Transfer-Encoding: chunked") != null);
    try std.testing.expect(std.ascii.findIgnoreCase(resp_str, "Content-Length:") == null);
    try std.testing.expect(std.mem.indexOf(u8, resp_str, "0\r\n\r\n") != null);


}

test "e2e: body of exactly 256KB is cleanly drained and retains keep-alive" {
    const allocator = std.testing.allocator;
    const io = getTestIo();

    var mux = http.ServeMux.init(allocator);
    defer mux.deinit();

    try mux.handleFunc("POST /drain256", struct {
        fn handle(w: *http.ResponseWriter, _: *http.Request) anyerror!void {
            // Handler ignores body completely, leaving server to drain
            try w.writeAll("drained-ok");
        }
    }.handle);

    try mux.handleFunc("GET /second", struct {
        fn handle(w: *http.ResponseWriter, _: *http.Request) anyerror!void {
            try w.writeAll("second-ok");
        }
    }.handle);

    var ts = try helpers.TestServer.start(allocator, io, .{ .handler = mux.handler() });
    defer ts.stop();

    const connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", ts.port);
    var client = try connect_addr.connect(io, .{ .mode = .stream });
    defer client.close(io);

    // Request 1: POST with exactly 256KB (262144 bytes) body
    const body_len = 256 * 1024;
    const body_buf = try allocator.alloc(u8, body_len);
    defer allocator.free(body_buf);
    @memset(body_buf, 'X');

    var head_buf: [128]u8 = undefined;
    const head_str = std.fmt.bufPrint(&head_buf, "POST /drain256 HTTP/1.1\r\nHost: localhost\r\nContent-Length: {d}\r\nConnection: keep-alive\r\n\r\n", .{body_len}) catch unreachable;
    var head_vec = [1][]const u8{head_str};
    _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &head_vec } })).net_write;

    var body_vec = [1][]const u8{body_buf};
    _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &body_vec } })).net_write;

    var resp_buf: [512]u8 = undefined;
    var total1: usize = 0;
    while (total1 < resp_buf.len) {
        var r_vec = [1][]u8{resp_buf[total1..]};
        const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &r_vec } })).net_read).data_len;
        if (n == 0) break;
        total1 += n;
        if (std.mem.indexOf(u8, resp_buf[0..total1], "drained-ok") != null) break;
    }
    const resp_str = resp_buf[0..total1];
    try std.testing.expect(std.mem.indexOf(u8, resp_str, "200 OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp_str, "drained-ok") != null);

    // Request 2: Must succeed on the same Keep-Alive connection
    const req2 = "GET /second HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    var vec2 = [1][]const u8{req2};
    _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &vec2 } })).net_write;

    var resp2_buf: [512]u8 = undefined;
    var total2: usize = 0;
    while (total2 < resp2_buf.len) {
        var r2_vec = [1][]u8{resp2_buf[total2..]};
        const n2 = (try (try io.operate(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &r2_vec } })).net_read).data_len;
        if (n2 == 0) break;
        total2 += n2;
    }
    const resp2_str = resp2_buf[0..total2];
    try std.testing.expect(std.mem.indexOf(u8, resp2_str, "200 OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp2_str, "second-ok") != null);


}

test "e2e: chunk reader line boundary exact capacity acceptance" {
    const allocator = std.testing.allocator;
    const io = getTestIo();

    // Construct raw chunked stream with a trailer line of exactly 1024 bytes (e.g. "X-Custom: " + 994 bytes of 'a' + "\r\n")
    // Total trailer line without CRLF = 10 + 1014 = 1024 bytes!
    const prefix = "5\r\nhello\r\n0\r\n";
    const key = "X-Trailer: ";
    const val_len = 1024 - key.len;
    var raw_buf: [2048]u8 = undefined;
    var pos: usize = 0;
    @memcpy(raw_buf[pos .. pos + prefix.len], prefix);
    pos += prefix.len;
    @memcpy(raw_buf[pos .. pos + key.len], key);
    pos += key.len;
    @memset(raw_buf[pos .. pos + val_len], 'a');
    pos += val_len;
    @memcpy(raw_buf[pos .. pos + 4], "\r\n\r\n");
    pos += 4;

    const payload = raw_buf[0..pos];
    const dummy_stream: std.Io.net.Stream = undefined;
    var reader = http.BodyReader.init(dummy_stream, io, payload, null, true);

    const body = try reader.readAllAlloc(allocator, 1024);
    defer allocator.free(body);
    try std.testing.expectEqualStrings("hello", body);
}

test "e2e: Transfer-Encoding chunked with zero body emits terminal chunk and keeps connection alive" {
    const allocator = std.testing.allocator;
    const io = getTestIo();

    var mux = http.ServeMux.init(allocator);
    defer mux.deinit();

    try mux.handleFunc("GET /empty-chunked", struct {
        fn handle(w: *http.ResponseWriter, _: *http.Request) anyerror!void {
            // Handler sets Transfer-Encoding: chunked without writing any body
            try w.headers.set("Transfer-Encoding", "chunked");
        }
    }.handle);

    try mux.handleFunc("GET /second-ping", struct {
        fn handle(w: *http.ResponseWriter, _: *http.Request) anyerror!void {
            try w.writeAll("pong-second");
        }
    }.handle);

    var ts = try helpers.TestServer.start(allocator, io, .{ .handler = mux.handler() });
    defer ts.stop();

    const connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", ts.port);
    var client = try connect_addr.connect(io, .{ .mode = .stream });
    defer client.close(io);

    // Request 1: keep-alive request to /empty-chunked
    const req1 = "GET /empty-chunked HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n";
    var vec1 = [1][]const u8{req1};
    _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &vec1 } })).net_write;

    var resp_buf: [512]u8 = undefined;
    var total1: usize = 0;
    while (total1 < resp_buf.len) {
        var r_vec = [1][]u8{resp_buf[total1..]};
        const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &r_vec } })).net_read).data_len;
        if (n == 0) break;
        total1 += n;
        if (std.mem.indexOf(u8, resp_buf[0..total1], "0\r\n\r\n") != null) break;
    }
    const resp1_str = resp_buf[0..total1];
    try std.testing.expect(std.mem.indexOf(u8, resp1_str, "200 OK") != null);
    try std.testing.expect(std.ascii.findIgnoreCase(resp1_str, "transfer-encoding: chunked") != null);
    // Must include terminal 0\r\n\r\n chunk
    try std.testing.expect(std.mem.indexOf(u8, resp1_str, "0\r\n\r\n") != null);

    // Request 2: Send second request on the same Keep-Alive connection
    const req2 = "GET /second-ping HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    var vec2 = [1][]const u8{req2};
    _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &vec2 } })).net_write;

    var resp2_buf: [512]u8 = undefined;
    var total2: usize = 0;
    while (total2 < resp2_buf.len) {
        var r_vec2 = [1][]u8{resp2_buf[total2..]};
        const n2 = (try (try io.operate(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &r_vec2 } })).net_read).data_len;
        if (n2 == 0) break;
        total2 += n2;
    }
    const resp2_str = resp2_buf[0..total2];
    try std.testing.expect(std.mem.indexOf(u8, resp2_str, "200 OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp2_str, "pong-second") != null);


}
