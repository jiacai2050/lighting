const std = @import("std");
const http = @import("root.zig");

var test_threaded_runtime: ?std.Io.Threaded = null;

fn getTestIo() std.Io {
    if (test_threaded_runtime == null) {
        test_threaded_runtime = std.Io.Threaded.init(std.heap.page_allocator, .{});
    }
    return test_threaded_runtime.?.io();
}

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

    // Pick an ephemeral port
    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    const port = listener.socket.address.getPort();

    var server = http.Server.init(allocator, io, .{
        .handler = mux.handler(),
    });
    defer server.deinit();

    const ServerThread = struct {
        fn run(s: *http.Server, l: std.Io.net.Server) void {
            s.serve(l) catch {};
        }
    };
    const server_thread = try std.Thread.spawn(.{}, ServerThread.run, .{ &server, listener });

    // Run client tests
    const connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    var client_stream = try connect_addr.connect(io, .{ .mode = .stream });
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

    // Stop server and join
    server.shutdown();
    server_thread.join();
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

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    const port = listener.socket.address.getPort();

    var server = http.Server.init(allocator, io, .{
        .handler = mux.handler(),
    });
    server.listener = listener;
    server.running.store(true, .release);

    const server_thread = try std.Thread.spawn(.{}, struct {
        fn run(s: *http.Server) void {
            const stream = s.listener.?.accept(s.io) catch return;
            s.serveConn(stream);
        }
    }.run, .{&server});

    const connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    var client_stream = try connect_addr.connect(io, .{ .mode = .stream });
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

    server.shutdown();
    server_thread.join();
}

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

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    const port = listener.socket.address.getPort();

    var server = http.Server.init(allocator, io, .{
        .handler = mux.handler(),
        .header_bytes_max = 256, // small limit to easily test 431
    });
    server.listener = listener;
    server.running.store(true, .release);

    const server_thread = try std.Thread.spawn(.{}, struct {
        fn run(s: *http.Server) void {
            while (s.running.load(.acquire)) {
                const stream = s.listener.?.accept(s.io) catch break;
                if (!s.running.load(.acquire)) {
                    stream.close(s.io);
                    break;
                }
                s.serveConn(stream);
            }
        }
    }.run, .{&server});

    const connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);

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

    server.shutdown();
    server_thread.join();
}

test "e2e: Go 1.22+ pattern routing with wildcards and 405 Method Not Allowed" {
    const allocator = std.testing.allocator;
    const io = getTestIo();

    var mux = http.ServeMux.init(allocator);
    defer mux.deinit();

    // 1. Parameterized route
    try mux.handleFunc("GET /users/{id}", struct {
        fn handle(w: *http.ResponseWriter, req: *http.Request) anyerror!void {
            const id = req.pathValue("id") orelse "unknown";
            try w.header().set("Content-Type", "text/plain");
            try w.writer().print("User ID: {s}", .{id});
        }
    }.handle);

    // 2. Method-restricted route
    try mux.handleFunc("POST /users", struct {
        fn handle(w: *http.ResponseWriter, _: *http.Request) anyerror!void {
            try w.header().set("Content-Type", "text/plain");
            try w.writeAll("User created");
        }
    }.handle);

    // 3. Catch-all wildcard route
    try mux.handleFunc("GET /files/{filepath...}", struct {
        fn handle(w: *http.ResponseWriter, req: *http.Request) anyerror!void {
            const fp = req.pathValue("filepath") orelse "";
            try w.header().set("Content-Type", "text/plain");
            try w.writer().print("File: {s}", .{fp});
        }
    }.handle);

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    const port = listener.socket.address.getPort();

    var server = http.Server.init(allocator, io, .{
        .handler = mux.handler(),
    });
    server.listener = listener;
    server.running.store(true, .release);

    const server_thread = try std.Thread.spawn(.{}, struct {
        fn run(s: *http.Server) void {
            while (s.running.load(.acquire)) {
                const stream = s.listener.?.accept(s.io) catch break;
                if (!s.running.load(.acquire)) {
                    stream.close(s.io);
                    break;
                }
                s.serveConn(stream);
            }
        }
    }.run, .{&server});

    const connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);

    // Test A: Parameter extraction {id}
    {
        var client_stream = try connect_addr.connect(io, .{ .mode = .stream });
        defer client_stream.close(io);

        const req = "GET /users/alice HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
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
        try std.testing.expect(std.mem.indexOf(u8, resp_str, "User ID: alice") != null);
    }

    // Test B: 405 Method Not Allowed with Allow header
    {
        var client_stream = try connect_addr.connect(io, .{ .mode = .stream });
        defer client_stream.close(io);

        // Send GET to /users which only accepts POST
        const req = "GET /users HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
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

        try std.testing.expect(std.mem.indexOf(u8, resp_str, "405 Method Not Allowed") != null);
        try std.testing.expect(std.ascii.findIgnoreCase(resp_str, "allow: post") != null);
    }

    // Test C: Multi-segment catch-all wildcard {filepath...}
    {
        var client_stream = try connect_addr.connect(io, .{ .mode = .stream });
        defer client_stream.close(io);

        const req = "GET /files/docs/2026/report.pdf HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
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
        try std.testing.expect(std.mem.indexOf(u8, resp_str, "File: docs/2026/report.pdf") != null);
    }

    server.shutdown();
    server_thread.join();
}

test "e2e: Server header and idle timeout handling" {
    const allocator = std.testing.allocator;
    const io = getTestIo();

    var mux = http.ServeMux.init(allocator);
    defer mux.deinit();

    try mux.handleFunc("/ping", struct {
        fn handle(w: *http.ResponseWriter, _: *http.Request) anyerror!void {
            try w.writeAll("pong");
        }
    }.handle);

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    const port = listener.socket.address.getPort();

    var server = http.Server.init(allocator, io, .{
        .handler = mux.handler(),
        .read_header_timeout_ns = 50 * std.time.ns_per_ms, // 50ms header timeout
        .idle_timeout_ns = 50 * std.time.ns_per_ms, // 50ms idle timeout
    });
    server.listener = listener;
    server.running.store(true, .release);

    const server_thread = try std.Thread.spawn(.{}, struct {
        fn run(s: *http.Server) void {
            while (s.running.load(.acquire)) {
                const stream = s.listener.?.accept(s.io) catch break;
                if (!s.running.load(.acquire)) {
                    stream.close(s.io);
                    break;
                }
                s.serveConn(stream);
            }
        }
    }.run, .{&server});

    const connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);

    // 1. Test header timeout -> Slowloris defense triggers 408 Request Timeout
    {
        var client_stream = try connect_addr.connect(io, .{ .mode = .stream });
        defer client_stream.close(io);

        // Send partial request without terminating CRLF CRLF
        const partial = "GET /ping HTTP/1.1\r\nHost: localhost\r\n";
        var vec = [1][]const u8{partial};
        _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client_stream.socket.handle, .data = &vec } })).net_write;

        // Wait longer than 50ms timeout
        try std.Io.sleep(io, .{ .nanoseconds = 100 * std.time.ns_per_ms }, .boot);

        var resp_buf: [1024]u8 = undefined;
        var total_read: usize = 0;
        while (total_read < resp_buf.len) {
            var r_vec = [1][]u8{resp_buf[total_read..]};
            const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client_stream.socket.handle, .data = &r_vec } })).net_read).data_len;
            if (n == 0) break;
            total_read += n;
            if (std.mem.indexOf(u8, resp_buf[0..total_read], "408 Request Timeout") != null) break;
        }
        const resp_str = resp_buf[0..total_read];

        try std.testing.expect(std.mem.indexOf(u8, resp_str, "408 Request Timeout") != null);
    }

    // 2. Test idle timeout on Keep-Alive connection
    {
        var client_stream = try connect_addr.connect(io, .{ .mode = .stream });
        defer client_stream.close(io);

        // Send a complete Keep-Alive request
        const req = "GET /ping HTTP/1.1\r\nHost: localhost\r\n\r\n";
        var vec = [1][]const u8{req};
        _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client_stream.socket.handle, .data = &vec } })).net_write;

        var resp_buf: [1024]u8 = undefined;
        var total_read: usize = 0;
        while (total_read < resp_buf.len) {
            var r_vec = [1][]u8{resp_buf[total_read..]};
            const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client_stream.socket.handle, .data = &r_vec } })).net_read).data_len;
            if (n == 0) break;
            total_read += n;
            if (std.mem.indexOf(u8, resp_buf[0..total_read], "pong") != null) break;
        }
        const resp_str = resp_buf[0..total_read];
        try std.testing.expect(std.mem.indexOf(u8, resp_str, "200 OK") != null);

        // Now stay idle for >50ms
        try std.Io.sleep(io, .{ .nanoseconds = 100 * std.time.ns_per_ms }, .boot);

        // Server should have cleanly closed the connection (EOF, read returns 0)
        var r_vec2 = [1][]u8{&resp_buf};
        const n2 = (try (try io.operate(.{ .net_read = .{ .socket_handle = client_stream.socket.handle, .data = &r_vec2 } })).net_read).data_len;
        try std.testing.expectEqual(@as(usize, 0), n2);
    }

    server.shutdown();
    server_thread.join();
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

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    const port = listener.socket.address.getPort();

    var server = http.Server.init(allocator, io, .{
        .handler = mux.handler(),
    });
    server.listener = listener;
    server.running.store(true, .release);

    const server_thread = try std.Thread.spawn(.{}, struct {
        fn run(s: *http.Server) void {
            while (s.running.load(.acquire)) {
                const stream = s.listener.?.accept(s.io) catch break;
                if (!s.running.load(.acquire)) {
                    stream.close(s.io);
                    break;
                }
                s.serveConn(stream);
            }
        }
    }.run, .{&server});

    const connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);

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

    server.shutdown();
    server_thread.join();
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

    const listen_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try listen_addr.listen(io, .{ .reuse_address = true });
    const port = listener.socket.address.getPort();

    var server = http.Server.init(allocator, io, .{
        .handler = mux.handler(),
    });
    defer server.deinit();

    const ServerThread = struct {
        fn run(s: *http.Server, l: std.Io.net.Server) void {
            s.serve(l) catch {};
        }
    };
    const server_thread = try std.Thread.spawn(.{}, ServerThread.run, .{ &server, listener });

    const connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);

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

    server.shutdown();
    server_thread.join();
}

test "e2e: shutdown interrupts idle keep-alive connections without hanging" {
    const allocator = std.testing.allocator;
    const io = getTestIo();

    var mux = http.ServeMux.init(allocator);
    defer mux.deinit();

    try mux.handleFunc("GET /ping", struct {
        fn handle(w: *http.ResponseWriter, _: *http.Request) anyerror!void {
            try w.writeAll("pong");
        }
    }.handle);

    const listen_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try listen_addr.listen(io, .{ .reuse_address = true });
    const port = listener.socket.address.getPort();

    var server = http.Server.init(allocator, io, .{
        .handler = mux.handler(),
    });
    defer server.deinit();

    const ServerThread = struct {
        fn run(s: *http.Server, l: std.Io.net.Server) void {
            s.serve(l) catch {};
        }
    };
    const server_thread = try std.Thread.spawn(.{}, ServerThread.run, .{ &server, listener });

    // Client connects and sends Keep-Alive request
    const connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    var client_stream = try connect_addr.connect(io, .{ .mode = .stream });
    defer client_stream.close(io);

    const req = "GET /ping HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n";
    var vec = [1][]const u8{req};
    _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client_stream.socket.handle, .data = &vec } })).net_write;

    var resp_buf: [256]u8 = undefined;
    var total_read: usize = 0;
    while (total_read < resp_buf.len) {
        var r_vec = [1][]u8{resp_buf[total_read..]};
        const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client_stream.socket.handle, .data = &r_vec } })).net_read).data_len;
        if (n == 0) break;
        total_read += n;
        if (std.mem.indexOf(u8, resp_buf[0..total_read], "200 OK") != null) break;
    }
    try std.testing.expect(std.mem.indexOf(u8, resp_buf[0..total_read], "200 OK") != null);

    // Client stays idle on connection. Server now shuts down.
    // shutdown() and deinit() MUST unblock the worker and return immediately (not hang indefinitely in join).
    server.shutdown();
    server_thread.join();
}

test "e2e: worker pool yields idle keep-alive connection when queue has pending tasks" {
    const allocator = std.testing.allocator;
    const io = getTestIo();

    var mux = http.ServeMux.init(allocator);
    defer mux.deinit();

    try mux.handleFunc("GET /task", struct {
        fn handle(w: *http.ResponseWriter, _: *http.Request) anyerror!void {
            try w.writeAll("task-done");
        }
    }.handle);

    const listen_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try listen_addr.listen(io, .{ .reuse_address = true });
    const port = listener.socket.address.getPort();

    // Server with only 1 worker thread!
    var server = http.Server.init(allocator, io, .{
        .handler = mux.handler(),
        .idle_timeout_ns = 5 * std.time.ns_per_s, // long idle timeout: 5s
    });
    defer server.deinit();

    const ServerThread = struct {
        fn run(s: *http.Server, l: std.Io.net.Server) void {
            s.serve(l) catch {};
        }
    };
    const server_thread = try std.Thread.spawn(.{}, ServerThread.run, .{ &server, listener });

    const connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);

    // Client 1 connects and sends first request. The only worker is handling Client 1.
    var c1 = try connect_addr.connect(io, .{ .mode = .stream });
    defer c1.close(io);

    const req1 = "GET /task HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n";
    var vec1 = [1][]const u8{req1};
    _ = try (try io.operate(.{ .net_write = .{ .socket_handle = c1.socket.handle, .data = &vec1 } })).net_write;

    var resp_buf: [256]u8 = undefined;
    var total_read: usize = 0;
    while (total_read < resp_buf.len) {
        var r_vec = [1][]u8{resp_buf[total_read..]};
        const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = c1.socket.handle, .data = &r_vec } })).net_read).data_len;
        if (n == 0) break;
        total_read += n;
        if (std.mem.indexOf(u8, resp_buf[0..total_read], "200 OK") != null) break;
    }
    try std.testing.expect(std.mem.indexOf(u8, resp_buf[0..total_read], "200 OK") != null);

    // Client 1 remains idle without sending anything more.
    // Now Client 2 connects and sends a request. Client 2's task is queued because worker 1 is busy waiting for C1.
    // Thanks to the 100ms sliced check for hasPendingTasks(), worker 1 quickly yields C1 and serves C2!
    var c2 = try connect_addr.connect(io, .{ .mode = .stream });
    defer c2.close(io);

    const req2 = "GET /task HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    var vec2 = [1][]const u8{req2};
    _ = try (try io.operate(.{ .net_write = .{ .socket_handle = c2.socket.handle, .data = &vec2 } })).net_write;

    var resp_buf2: [256]u8 = undefined;
    var total_read2: usize = 0;
    while (total_read2 < resp_buf2.len) {
        var r_vec2 = [1][]u8{resp_buf2[total_read2..]};
        const res = io.operate(.{ .net_read = .{ .socket_handle = c2.socket.handle, .data = &r_vec2 } }) catch break;
        const nr = res.net_read catch break;
        if (nr.data_len == 0) break;
        total_read2 += nr.data_len;
        if (std.mem.indexOf(u8, resp_buf2[0..total_read2], "task-done") != null) break;
    }
    try std.testing.expect(std.mem.indexOf(u8, resp_buf2[0..total_read2], "task-done") != null);

    server.shutdown();
    server_thread.join();
}

test "e2e: handler error forces Connection: close and prevents connection reuse" {
    const allocator = std.testing.allocator;
    const io = getTestIo();

    var mux = http.ServeMux.init(allocator);
    defer mux.deinit();

    try mux.handleFunc("POST /fail", struct {
        fn handle(_: *http.ResponseWriter, _: *http.Request) anyerror!void {
            return error.CustomHandlerFault;
        }
    }.handle);

    const listen_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try listen_addr.listen(io, .{ .reuse_address = true });
    const port = listener.socket.address.getPort();

    var server = http.Server.init(allocator, io, .{
        .handler = mux.handler(),
    });
    defer server.deinit();

    const ServerThread = struct {
        fn run(s: *http.Server, l: std.Io.net.Server) void {
            s.serve(l) catch {};
        }
    };
    const server_thread = try std.Thread.spawn(.{}, ServerThread.run, .{ &server, listener });

    const connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    var client = try connect_addr.connect(io, .{ .mode = .stream });
    defer client.close(io);

    // Send request with Keep-Alive header to failing handler
    const req = "POST /fail HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\nContent-Length: 5\r\n\r\nhello";
    var vec = [1][]const u8{req};
    _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &vec } })).net_write;

    var resp_buf: [512]u8 = undefined;
    var total_read: usize = 0;
    while (total_read < resp_buf.len) {
        var r_vec = [1][]u8{resp_buf[total_read..]};
        const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &r_vec } })).net_read).data_len;
        if (n == 0) break;
        total_read += n;
        if (std.mem.indexOf(u8, resp_buf[0..total_read], "500 Internal Server Error\n") != null) break;
    }
    const resp_str = resp_buf[0..total_read];

    try std.testing.expect(std.mem.indexOf(u8, resp_str, "500 Internal Server Error") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp_str, "Connection: close") != null);

    // Subsequent read should observe EOF because server closed the connection
    var eof_buf: [64]u8 = undefined;
    var eof_vec = [1][]u8{&eof_buf};
    const n2 = (try (try io.operate(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &eof_vec } })).net_read).data_len;
    try std.testing.expectEqual(@as(usize, 0), n2);

    server.shutdown();
    server_thread.join();
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

    const listen_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try listen_addr.listen(io, .{ .reuse_address = true });
    const port = listener.socket.address.getPort();

    var server = http.Server.init(allocator, io, .{
        .handler = mux.handler(),
    });
    defer server.deinit();

    const ServerThread = struct {
        fn run(s: *http.Server, l: std.Io.net.Server) void {
            s.serve(l) catch {};
        }
    };
    const server_thread = try std.Thread.spawn(.{}, ServerThread.run, .{ &server, listener });

    const connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);

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

    server.shutdown();
    server_thread.join();
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

    const listen_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try listen_addr.listen(io, .{ .reuse_address = true });
    const port = listener.socket.address.getPort();

    // read_timeout_ns = 150ms
    var server = http.Server.init(allocator, io, .{
        .handler = mux.handler(),
        .read_timeout_ns = 150 * std.time.ns_per_ms,
    });
    defer server.deinit();

    const ServerThread = struct {
        fn run(s: *http.Server, l: std.Io.net.Server) void {
            s.serve(l) catch {};
        }
    };
    const server_thread = try std.Thread.spawn(.{}, ServerThread.run, .{ &server, listener });

    const connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    var client = try connect_addr.connect(io, .{ .mode = .stream });
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

    server.shutdown();
    server_thread.join();
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

    const listen_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try listen_addr.listen(io, .{ .reuse_address = true });
    const port = listener.socket.address.getPort();

    var server = http.Server.init(allocator, io, .{
        .handler = mux.handler(),
    });
    defer server.deinit();

    const ServerThread = struct {
        fn run(s: *http.Server, l: std.Io.net.Server) void {
            s.serve(l) catch {};
        }
    };
    const server_thread = try std.Thread.spawn(.{}, ServerThread.run, .{ &server, listener });

    const connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);

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

    server.shutdown();
    server_thread.join();
}

test "e2e: truncated body or handler error enforces Connection: close in headers" {
    const allocator = std.testing.allocator;
    const io = getTestIo();

    var mux = http.ServeMux.init(allocator);
    defer mux.deinit();

    // 1. Handler claims Content-Length: 50, but only writes 10 bytes and finishes
    try mux.handleFunc("GET /short_body", struct {
        fn handle(w: *http.ResponseWriter, _: *http.Request) anyerror!void {
            try w.header().set("Content-Length", "50");
            try w.writeAll("0123456789");
        }
    }.handle);

    // 2. Handler buffers data, then returns an error before headers flushed
    try mux.handleFunc("GET /err_buffered", struct {
        fn handle(w: *http.ResponseWriter, _: *http.Request) anyerror!void {
            try w.header().set("Content-Length", "100");
            try w.writeAll("partial");
            return error.CustomHandlerFault;
        }
    }.handle);

    const listen_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try listen_addr.listen(io, .{ .reuse_address = true });
    const port = listener.socket.address.getPort();

    var server = http.Server.init(allocator, io, .{
        .handler = mux.handler(),
    });
    defer server.deinit();

    const ServerThread = struct {
        fn run(s: *http.Server, l: std.Io.net.Server) void {
            s.serve(l) catch {};
        }
    };
    const server_thread = try std.Thread.spawn(.{}, ServerThread.run, .{ &server, listener });

    const connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);

    // Case 1: Truncated body must emit Connection: close, not keep-alive
    {
        var client = try connect_addr.connect(io, .{ .mode = .stream });
        defer client.close(io);

        const req = "GET /short_body HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n";
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
        try std.testing.expect(std.mem.indexOf(u8, resp_str, "Connection: close") != null);
        try std.testing.expect(std.ascii.findIgnoreCase(resp_str, "connection: keep-alive") == null);
    }

    // Case 2: Handler error must clear Content-Length and emit Connection: close
    {
        var client = try connect_addr.connect(io, .{ .mode = .stream });
        defer client.close(io);

        const req = "GET /err_buffered HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n";
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

        try std.testing.expect(std.mem.indexOf(u8, resp_str, "500 Internal Server Error") != null);
        try std.testing.expect(std.mem.indexOf(u8, resp_str, "Connection: close") != null);
        try std.testing.expect(std.ascii.findIgnoreCase(resp_str, "connection: keep-alive") == null);
    }

    server.shutdown();
    server_thread.join();
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

    const listen_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try listen_addr.listen(io, .{ .reuse_address = true });
    const port = listener.socket.address.getPort();

    var server = http.Server.init(allocator, io, .{
        .handler = mux.handler(),
    });
    defer server.deinit();

    const ServerThread = struct {
        fn run(s: *http.Server, l: std.Io.net.Server) void {
            s.serve(l) catch {};
        }
    };
    const server_thread = try std.Thread.spawn(.{}, ServerThread.run, .{ &server, listener });

    const connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);

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

    server.shutdown();
    server_thread.join();
}

test "e2e: Host case-insensitivity and IPv6 routing in live server" {
    const allocator = std.testing.allocator;
    const io = getTestIo();

    var mux = http.ServeMux.init(allocator);
    defer mux.deinit();

    try mux.handleFunc("MYHOST.COM/info", struct {
        fn handle(w: *http.ResponseWriter, _: *http.Request) anyerror!void {
            try w.writeAll("myhost-info");
        }
    }.handle);

    const listen_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try listen_addr.listen(io, .{ .reuse_address = true });
    const port = listener.socket.address.getPort();

    var server = http.Server.init(allocator, io, .{
        .handler = mux.handler(),
    });
    defer server.deinit();

    const ServerThread = struct {
        fn run(s: *http.Server, l: std.Io.net.Server) void {
            s.serve(l) catch {};
        }
    };
    const server_thread = try std.Thread.spawn(.{}, ServerThread.run, .{ &server, listener });

    const connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);

    // Client sends Host in lowercase with port
    {
        var client = try connect_addr.connect(io, .{ .mode = .stream });
        defer client.close(io);

        var req_buf: [128]u8 = undefined;
        const req = try std.fmt.bufPrint(&req_buf, "GET /info HTTP/1.1\r\nHost: myhost.com:{d}\r\nConnection: close\r\n\r\n", .{port});
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
        try std.testing.expect(std.mem.indexOf(u8, resp_str, "myhost-info") != null);
    }

    server.shutdown();
    server_thread.join();
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

    const listen_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try listen_addr.listen(io, .{ .reuse_address = true });
    const port = listener.socket.address.getPort();

    var server = http.Server.init(allocator, io, .{
        .handler = mux.handler(),
    });
    defer server.deinit();

    const ServerThread = struct {
        fn run(s: *http.Server, l: std.Io.net.Server) void {
            s.serve(l) catch {};
        }
    };
    const server_thread = try std.Thread.spawn(.{}, ServerThread.run, .{ &server, listener });

    const connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);

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

    server.shutdown();
    server_thread.join();
}

test "e2e: absolute-form request targets and routing" {
    const allocator = std.testing.allocator;
    const io = getTestIo();

    var mux = http.ServeMux.init(allocator);
    defer mux.deinit();

    const Handlers = struct {
        fn proxyTest(w: *http.ResponseWriter, req: *http.Request) anyerror!void {
            _ = req;
            try w.writeAll("proxy-ok");
        }

        fn queryTest(w: *http.ResponseWriter, req: *http.Request) anyerror!void {
            const val = req.url.queryParam("name") orelse "none";
            try w.writeAll(val);
        }

        fn rootTest(w: *http.ResponseWriter, req: *http.Request) anyerror!void {
            _ = req;
            try w.writeAll("root-ok");
        }
    };

    try mux.handleFunc("example.com/proxy_test", Handlers.proxyTest);
    try mux.handleFunc("/query", Handlers.queryTest);
    try mux.handleFunc("/", Handlers.rootTest);

    const listen_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try listen_addr.listen(io, .{ .reuse_address = true });
    const port = listener.socket.address.getPort();

    var server = http.Server.init(allocator, io, .{
        .handler = mux.handler(),
    });
    defer server.deinit();

    const ServerThread = struct {
        fn run(s: *http.Server, l: std.Io.net.Server) void {
            s.serve(l) catch {};
        }
    };
    const server_thread = try std.Thread.spawn(.{}, ServerThread.run, .{ &server, listener });

    const connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);

    // 1. Absolute-form target matches host-qualified pattern, ignoring different Host header
    {
        var client = try connect_addr.connect(io, .{ .mode = .stream });
        defer client.close(io);

        const req = "GET http://example.com/proxy_test HTTP/1.1\r\nHost: other.com\r\nConnection: close\r\n\r\n";
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
        try std.testing.expect(std.mem.indexOf(u8, resp_str, "proxy-ok") != null);
    }

    // 2. Absolute-form target with query matches generic path and parses query
    {
        var client = try connect_addr.connect(io, .{ .mode = .stream });
        defer client.close(io);

        const req = "GET http://myserver.org:8080/query?name=alice HTTP/1.1\r\nHost: myserver.org:8080\r\nConnection: close\r\n\r\n";
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
        try std.testing.expect(std.mem.indexOf(u8, resp_str, "alice") != null);
    }

    // 3. Absolute-form target without path defaults to "/" (RFC 9112 Section 3.2.2)
    {
        var client = try connect_addr.connect(io, .{ .mode = .stream });
        defer client.close(io);

        const req = "GET http://example.com HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n";
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
        try std.testing.expect(std.mem.indexOf(u8, resp_str, "root-ok") != null);
    }

    server.shutdown();
    server_thread.join();
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

    const listen_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try listen_addr.listen(io, .{ .reuse_address = true });
    const port = listener.socket.address.getPort();

    var server = http.Server.init(allocator, io, .{
        .handler = mux.handler(),
    });
    defer server.deinit();

    const ServerThread = struct {
        fn run(s: *http.Server, l: std.Io.net.Server) void {
            s.serve(l) catch {};
        }
    };
    const server_thread = try std.Thread.spawn(.{}, ServerThread.run, .{ &server, listener });

    const connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
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

    server.shutdown();
    server_thread.join();
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

    const listen_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try listen_addr.listen(io, .{ .reuse_address = true });
    const port = listener.socket.address.getPort();

    var server = http.Server.init(allocator, io, .{
        .handler = mux.handler(),
    });
    defer server.deinit();

    const ServerThread = struct {
        fn run(s: *http.Server, l: std.Io.net.Server) void {
            s.serve(l) catch {};
        }
    };
    const server_thread = try std.Thread.spawn(.{}, ServerThread.run, .{ &server, listener });

    const connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
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

    server.shutdown();
    server_thread.join();
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

    const listen_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try listen_addr.listen(io, .{ .reuse_address = true });
    const port = listener.socket.address.getPort();

    var server = http.Server.init(allocator, io, .{
        .handler = mux.handler(),
    });
    defer server.deinit();

    const ServerThread = struct {
        fn run(s: *http.Server, l: std.Io.net.Server) void {
            s.serve(l) catch {};
        }
    };
    const server_thread = try std.Thread.spawn(.{}, ServerThread.run, .{ &server, listener });

    const connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
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

    server.shutdown();
    server_thread.join();
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

test "e2e: ServeMux route registration conflict returns error.PatternConflict" {
    const allocator = std.testing.allocator;
    var mux = http.ServeMux.init(allocator);
    defer mux.deinit();

    const dummy_fn = struct {
        fn handle(_: *http.ResponseWriter, _: *http.Request) anyerror!void {}
    }.handle;

    // 1. Literal duplicate conflict
    try mux.handleFunc("GET /items", dummy_fn);
    try std.testing.expectError(error.PatternConflict, mux.handleFunc("GET /items", dummy_fn));

    // 2. Multi wildcard collision: /files/ and /files/{rest...}
    try mux.handleFunc("GET /files/", dummy_fn);
    try std.testing.expectError(error.PatternConflict, mux.handleFunc("GET /files/{rest...}", dummy_fn));

    // 3. Single wildcard collision: /user/{id} and /user/{name}
    try mux.handleFunc("GET /user/{id}", dummy_fn);
    try std.testing.expectError(error.PatternConflict, mux.handleFunc("GET /user/{name}", dummy_fn));
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

    const listen_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try listen_addr.listen(io, .{ .reuse_address = true });
    const port = listener.socket.address.getPort();

    var server = http.Server.init(allocator, io, .{
        .handler = mux.handler(),
    });
    defer server.deinit();

    const ServerThread = struct {
        fn run(s: *http.Server, l: std.Io.net.Server) void {
            s.serve(l) catch {};
        }
    };
    const server_thread = try std.Thread.spawn(.{}, ServerThread.run, .{ &server, listener });

    const connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
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

    server.shutdown();
    server_thread.join();
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

    const listen_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try listen_addr.listen(io, .{ .reuse_address = true });
    const port = listener.socket.address.getPort();

    var server = http.Server.init(allocator, io, .{
        .handler = mux.handler(),
    });
    defer server.deinit();

    const ServerThread = struct {
        fn run(s: *http.Server, l: std.Io.net.Server) void {
            s.serve(l) catch {};
        }
    };
    const server_thread = try std.Thread.spawn(.{}, ServerThread.run, .{ &server, listener });

    const connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
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

    server.shutdown();
    server_thread.join();
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

    const listen_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try listen_addr.listen(io, .{ .reuse_address = true });
    const port = listener.socket.address.getPort();

    var server = http.Server.init(allocator, io, .{
        .handler = mux.handler(),
    });
    defer server.deinit();

    const ServerThread = struct {
        fn run(s: *http.Server, l: std.Io.net.Server) void {
            s.serve(l) catch {};
        }
    };
    const server_thread = try std.Thread.spawn(.{}, ServerThread.run, .{ &server, listener });

    const connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
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

    server.shutdown();
    server_thread.join();
}

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

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    const listener = try addr.listen(io, .{ .reuse_address = true });
    const port = listener.socket.address.getPort();

    var server = http.Server.init(allocator, io, .{
        .handler = mux.handler(),
    });
    defer server.deinit();

    const ServerThread = struct {
        fn run(s: *http.Server, l: std.Io.net.Server) void {
            s.serve(l) catch {};
        }
    };
    const server_thread = try std.Thread.spawn(.{}, ServerThread.run, .{ &server, listener });
    defer {
        server.shutdown();
        server_thread.join();
    }

    const connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    var client = try connect_addr.connect(io, .{ .mode = .stream });
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

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    const listener = try addr.listen(io, .{ .reuse_address = true });
    const port = listener.socket.address.getPort();

    var server = http.Server.init(allocator, io, .{
        .handler = mux.handler(),
    });
    defer server.deinit();

    const ServerThread = struct {
        fn run(s: *http.Server, l: std.Io.net.Server) void {
            s.serve(l) catch {};
        }
    };
    const server_thread = try std.Thread.spawn(.{}, ServerThread.run, .{ &server, listener });
    defer {
        server.shutdown();
        server_thread.join();
    }

    const connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    var client = try connect_addr.connect(io, .{ .mode = .stream });
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

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    const listener = try addr.listen(io, .{ .reuse_address = true });
    const port = listener.socket.address.getPort();

    var server = http.Server.init(allocator, io, .{
        .handler = mux.handler(),
    });
    defer server.deinit();

    const ServerThread = struct {
        fn run(s: *http.Server, l: std.Io.net.Server) void {
            s.serve(l) catch {};
        }
    };
    const server_thread = try std.Thread.spawn(.{}, ServerThread.run, .{ &server, listener });
    defer {
        server.shutdown();
        server_thread.join();
    }

    const connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    var client = try connect_addr.connect(io, .{ .mode = .stream });
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

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    const listener = try addr.listen(io, .{ .reuse_address = true });
    const port = listener.socket.address.getPort();

    var server = http.Server.init(allocator, io, .{
        .handler = mux.handler(),
    });
    defer server.deinit();

    const ServerThread = struct {
        fn run(s: *http.Server, l: std.Io.net.Server) void {
            s.serve(l) catch {};
        }
    };
    const server_thread = try std.Thread.spawn(.{}, ServerThread.run, .{ &server, listener });
    defer {
        server.shutdown();
        server_thread.join();
    }

    const connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    var client = try connect_addr.connect(io, .{ .mode = .stream });
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

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    const listener = try addr.listen(io, .{ .reuse_address = true });
    const port = listener.socket.address.getPort();

    var server = http.Server.init(allocator, io, .{
        .handler = mux.handler(),
    });
    defer server.deinit();

    const ServerThread = struct {
        fn run(s: *http.Server, l: std.Io.net.Server) void {
            s.serve(l) catch {};
        }
    };
    const server_thread = try std.Thread.spawn(.{}, ServerThread.run, .{ &server, listener });
    defer {
        server.shutdown();
        server_thread.join();
    }

    const connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    var client = try connect_addr.connect(io, .{ .mode = .stream });
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

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    const listener = try addr.listen(io, .{ .reuse_address = true });
    const port = listener.socket.address.getPort();

    var server = http.Server.init(allocator, io, .{
        .handler = mux.handler(),
    });
    defer server.deinit();

    const ServerThread = struct {
        fn run(s: *http.Server, l: std.Io.net.Server) void {
            s.serve(l) catch {};
        }
    };
    const server_thread = try std.Thread.spawn(.{}, ServerThread.run, .{ &server, listener });
    defer {
        server.shutdown();
        server_thread.join();
    }

    const connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    var client = try connect_addr.connect(io, .{ .mode = .stream });
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

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    const listener = try addr.listen(io, .{ .reuse_address = true });
    const port = listener.socket.address.getPort();

    var server = http.Server.init(allocator, io, .{
        .handler = mux.handler(),
    });
    defer server.deinit();

    const ServerThread = struct {
        fn run(s: *http.Server, l: std.Io.net.Server) void {
            s.serve(l) catch {};
        }
    };
    const server_thread = try std.Thread.spawn(.{}, ServerThread.run, .{ &server, listener });
    defer {
        server.shutdown();
        server_thread.join();
    }

    const connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    var client = try connect_addr.connect(io, .{ .mode = .stream });
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

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    const listener = try addr.listen(io, .{ .reuse_address = true });
    const port = listener.socket.address.getPort();

    var server = http.Server.init(allocator, io, .{
        .handler = mux.handler(),
    });
    defer server.deinit();

    const ServerThread = struct {
        fn run(s: *http.Server, l: std.Io.net.Server) void {
            s.serve(l) catch {};
        }
    };
    const server_thread = try std.Thread.spawn(.{}, ServerThread.run, .{ &server, listener });
    defer {
        server.shutdown();
        server_thread.join();
    }

    const connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);

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

        const addr_p = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        const listener_p = try addr_p.listen(io, .{ .reuse_address = true });
        const port_p = listener_p.socket.address.getPort();

        var server_p = http.Server.init(allocator, io, .{
            .handler = mux_prefix.handler(),
        });
        defer server_p.deinit();

        const ServerThreadP = struct {
            fn run(s: *http.Server, l: std.Io.net.Server) void {
                s.serve(l) catch {};
            }
        };
        const st_p = try std.Thread.spawn(.{}, ServerThreadP.run, .{ &server_p, listener_p });
        defer {
            server_p.shutdown();
            st_p.join();
        }

        const connect_p = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port_p);

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
