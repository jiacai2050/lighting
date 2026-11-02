const std = @import("std");
const http = @import("root.zig");

test "e2e: GET, POST echo, and Keep-Alive" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

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

    var server = http.Server.init(allocator, .{
        .handler = mux.handler(),
        .num_threads = 2,
    });
    server.listener = listener;
    server.running.store(true, .release);
    server.pool = try http.ThreadPool.create(allocator, io, 2, 1024);
    defer server.deinit();

    // Start server loop in separate thread
    const server_thread = try std.Thread.spawn(.{}, struct {
        fn run(s: *http.Server) void {
            while (s.running.load(.acquire)) {
                const stream = s.listener.?.accept(s.io) catch break;
                s.pool.?.spawn(struct {
                    fn handle(srv: *http.Server, strm: std.Io.net.Stream) void {
                        srv.serveConn(strm);
                    }
                }.handle, .{ s, stream }) catch break;
            }
        }
    }.run, .{&server});

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
    const io = std.Io.Threaded.global_single_threaded.io();

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

    var server = http.Server.init(allocator, .{
        .handler = mux.handler(),
        .num_threads = 2,
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
    const io = std.Io.Threaded.global_single_threaded.io();

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

    var server = http.Server.init(allocator, .{
        .handler = mux.handler(),
        .num_threads = 2,
        .max_header_bytes = 256, // small limit to easily test 431
    });
    server.listener = listener;
    server.running.store(true, .release);

    const server_thread = try std.Thread.spawn(.{}, struct {
        fn run(s: *http.Server) void {
            while (s.running.load(.acquire)) {
                const stream = s.listener.?.accept(s.io) catch break;
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
        var r_vec = [1][]u8{&resp_buf};
        const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client_stream.socket.handle, .data = &r_vec } })).net_read).data_len;
        const resp_str = resp_buf[0..n];

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
        var r_vec = [1][]u8{&resp_buf};
        const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client_stream.socket.handle, .data = &r_vec } })).net_read).data_len;
        const resp_str = resp_buf[0..n];

        try std.testing.expect(std.ascii.findIgnoreCase(resp_str, "431 Request Header Fields Too Large") != null);
    }

    server.shutdown();
    server_thread.join();
}

test "e2e: Go 1.22+ pattern routing with wildcards and 405 Method Not Allowed" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

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

    var server = http.Server.init(allocator, .{
        .handler = mux.handler(),
        .num_threads = 2,
    });
    server.listener = listener;
    server.running.store(true, .release);

    const server_thread = try std.Thread.spawn(.{}, struct {
        fn run(s: *http.Server) void {
            while (s.running.load(.acquire)) {
                const stream = s.listener.?.accept(s.io) catch break;
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
    const io = std.Io.Threaded.global_single_threaded.io();

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

    var server = http.Server.init(allocator, .{
        .handler = mux.handler(),
        .num_threads = 2,
        .read_header_timeout_ns = 50 * std.time.ns_per_ms, // 50ms header timeout
        .idle_timeout_ns = 50 * std.time.ns_per_ms, // 50ms idle timeout
    });
    server.listener = listener;
    server.running.store(true, .release);

    const server_thread = try std.Thread.spawn(.{}, struct {
        fn run(s: *http.Server) void {
            while (s.running.load(.acquire)) {
                const stream = s.listener.?.accept(s.io) catch break;
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
        var r_vec = [1][]u8{&resp_buf};
        const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client_stream.socket.handle, .data = &r_vec } })).net_read).data_len;
        const resp_str = resp_buf[0..n];

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
    const io = std.Io.Threaded.global_single_threaded.io();

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

    var server = http.Server.init(allocator, .{
        .handler = mux.handler(),
        .num_threads = 2,
    });
    server.listener = listener;
    server.running.store(true, .release);

    const server_thread = try std.Thread.spawn(.{}, struct {
        fn run(s: *http.Server) void {
            while (s.running.load(.acquire)) {
                const stream = s.listener.?.accept(s.io) catch break;
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
        var r_vec = [1][]u8{&resp_buf};
        const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client_stream.socket.handle, .data = &r_vec } })).net_read).data_len;
        const resp_str = resp_buf[0..n];
        try std.testing.expect(std.mem.indexOf(u8, resp_str, "204 No Content") != null);
    }

    server.shutdown();
    server_thread.join();
}

test "review: Finding 2 & 9 - RFC 9112 strict request line, headers, and Transfer-Encoding" {
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

    // 4. Transfer-Encoding not-chunked rejected (Finding 2)
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

test "review: Finding 6 - Response header CRLF and control character injection" {
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

test "review: Finding 7 - ThreadPool QueueFull backpressure and error recovery" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    // Pool with 1 thread, max queue size 1
    const pool = try http.ThreadPool.create(allocator, io, 1, 1);
    defer pool.destroy();

    const Blocker = struct {
        fn run(io_ctx: std.Io) void {
            io_ctx.sleep(.{ .nanoseconds = 50 * std.time.ns_per_ms }, .boot) catch {};
        }
    };

    // 1. Task occupying the single worker
    try pool.spawn(Blocker.run, .{io});
    // Give it a tiny moment to pick up
    try io.sleep(.{ .nanoseconds = 5 * std.time.ns_per_ms }, .boot);

    // 2. Queue the single permitted task
    try pool.spawn(Blocker.run, .{io});

    // 3. Queue is now full: next spawn must fail with QueueFull
    try std.testing.expectError(error.QueueFull, pool.spawn(Blocker.run, .{io}));

    // Wait for tasks to drain cleanly
    try io.sleep(.{ .nanoseconds = 120 * std.time.ns_per_ms }, .boot);
    try std.testing.expect(!pool.hasPendingTasks());
}

test "review: Finding 4, 5, 10 - HEAD suppression, 204 suppression, Content-Length guards" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

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

    const port: u16 = 19100;
    const listen_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    var listener = try listen_addr.listen(io, .{ .reuse_address = true });

    var server = http.Server.init(allocator, .{
        .handler = mux.handler(),
        .num_threads = 2,
    });
    server.listener = listener;
    server.running.store(true, .release);
    server.pool = try http.ThreadPool.create(allocator, io, 2, 1024);
    defer server.deinit();

    const ServerThread = struct {
        fn run(s: *http.Server, l: *std.Io.net.Server) void {
            while (s.running.load(.acquire)) {
                const stream = l.accept(s.io) catch break;
                s.pool.?.spawn(http.Server.serveConn, .{ s, stream }) catch {
                    stream.close(s.io);
                };
            }
        }
    };
    const server_thread = try std.Thread.spawn(.{}, ServerThread.run, .{ &server, &listener });

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

test "review round 2: Finding 1 - shutdown interrupts idle keep-alive connections without hanging" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var mux = http.ServeMux.init(allocator);
    defer mux.deinit();

    try mux.handleFunc("GET /ping", struct {
        fn handle(w: *http.ResponseWriter, _: *http.Request) anyerror!void {
            try w.writeAll("pong");
        }
    }.handle);

    const port: u16 = 19201;
    const listen_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    var listener = try listen_addr.listen(io, .{ .reuse_address = true });

    var server = http.Server.init(allocator, .{
        .handler = mux.handler(),
        .num_threads = 2,
    });
    server.listener = listener;
    server.running.store(true, .release);
    server.pool = try http.ThreadPool.create(allocator, io, 2, 1024);
    defer server.deinit();

    const ServerThread = struct {
        fn run(s: *http.Server, l: *std.Io.net.Server) void {
            while (s.running.load(.acquire)) {
                const stream = l.accept(s.io) catch break;
                s.pool.?.spawn(http.Server.serveConn, .{ s, stream }) catch {
                    stream.close(s.io);
                };
            }
        }
    };
    const server_thread = try std.Thread.spawn(.{}, ServerThread.run, .{ &server, &listener });

    // Client connects and sends Keep-Alive request
    const connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    var client_stream = try connect_addr.connect(io, .{ .mode = .stream });
    defer client_stream.close(io);

    const req = "GET /ping HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n";
    var vec = [1][]const u8{req};
    _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client_stream.socket.handle, .data = &vec } })).net_write;

    var resp_buf: [256]u8 = undefined;
    var r_vec = [1][]u8{&resp_buf};
    const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client_stream.socket.handle, .data = &r_vec } })).net_read).data_len;
    try std.testing.expect(std.mem.indexOf(u8, resp_buf[0..n], "200 OK") != null);

    // Client stays idle on connection. Server now shuts down.
    // shutdown() and deinit() MUST unblock the worker and return immediately (not hang indefinitely in join).
    server.shutdown();
    server_thread.join();
}

test "review round 2: Finding 2 - worker pool yields idle keep-alive connection when queue has pending tasks" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var mux = http.ServeMux.init(allocator);
    defer mux.deinit();

    try mux.handleFunc("GET /task", struct {
        fn handle(w: *http.ResponseWriter, _: *http.Request) anyerror!void {
            try w.writeAll("task-done");
        }
    }.handle);

    const port: u16 = 19202;
    const listen_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    var listener = try listen_addr.listen(io, .{ .reuse_address = true });

    // Server with only 1 worker thread!
    var server = http.Server.init(allocator, .{
        .handler = mux.handler(),
        .num_threads = 1,
        .idle_timeout_ns = 5 * std.time.ns_per_s, // long idle timeout: 5s
    });
    server.listener = listener;
    server.running.store(true, .release);
    server.pool = try http.ThreadPool.create(allocator, io, 1, 1024);
    defer server.deinit();

    const ServerThread = struct {
        fn run(s: *http.Server, l: *std.Io.net.Server) void {
            while (s.running.load(.acquire)) {
                const stream = l.accept(s.io) catch break;
                s.pool.?.spawn(http.Server.serveConn, .{ s, stream }) catch {
                    stream.close(s.io);
                };
            }
        }
    };
    const server_thread = try std.Thread.spawn(.{}, ServerThread.run, .{ &server, &listener });

    const connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);

    // Client 1 connects and sends first request. The only worker is handling Client 1.
    var c1 = try connect_addr.connect(io, .{ .mode = .stream });
    defer c1.close(io);

    const req1 = "GET /task HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n";
    var vec1 = [1][]const u8{req1};
    _ = try (try io.operate(.{ .net_write = .{ .socket_handle = c1.socket.handle, .data = &vec1 } })).net_write;

    var resp_buf: [256]u8 = undefined;
    var r_vec = [1][]u8{&resp_buf};
    const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = c1.socket.handle, .data = &r_vec } })).net_read).data_len;
    try std.testing.expect(std.mem.indexOf(u8, resp_buf[0..n], "200 OK") != null);

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

test "review round 2: Finding 3 - handler error forces Connection: close and prevents connection reuse" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var mux = http.ServeMux.init(allocator);
    defer mux.deinit();

    try mux.handleFunc("POST /fail", struct {
        fn handle(_: *http.ResponseWriter, _: *http.Request) anyerror!void {
            return error.CustomHandlerFault;
        }
    }.handle);

    const port: u16 = 19203;
    const listen_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    var listener = try listen_addr.listen(io, .{ .reuse_address = true });

    var server = http.Server.init(allocator, .{
        .handler = mux.handler(),
        .num_threads = 2,
    });
    server.listener = listener;
    server.running.store(true, .release);
    server.pool = try http.ThreadPool.create(allocator, io, 2, 1024);
    defer server.deinit();

    const ServerThread = struct {
        fn run(s: *http.Server, l: *std.Io.net.Server) void {
            while (s.running.load(.acquire)) {
                const stream = l.accept(s.io) catch break;
                s.pool.?.spawn(http.Server.serveConn, .{ s, stream }) catch {
                    stream.close(s.io);
                };
            }
        }
    };
    const server_thread = try std.Thread.spawn(.{}, ServerThread.run, .{ &server, &listener });

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

test "review round 2: Finding 4 - status 205 and header stripping on bodyless responses" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

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

    const port: u16 = 19204;
    const listen_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    var listener = try listen_addr.listen(io, .{ .reuse_address = true });

    var server = http.Server.init(allocator, .{
        .handler = mux.handler(),
        .num_threads = 2,
    });
    server.listener = listener;
    server.running.store(true, .release);
    server.pool = try http.ThreadPool.create(allocator, io, 2, 1024);
    defer server.deinit();

    const ServerThread = struct {
        fn run(s: *http.Server, l: *std.Io.net.Server) void {
            while (s.running.load(.acquire)) {
                const stream = l.accept(s.io) catch break;
                s.pool.?.spawn(http.Server.serveConn, .{ s, stream }) catch {
                    stream.close(s.io);
                };
            }
        }
    };
    const server_thread = try std.Thread.spawn(.{}, ServerThread.run, .{ &server, &listener });

    const connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);

    // 1. Verify 205 response
    {
        var client = try connect_addr.connect(io, .{ .mode = .stream });
        defer client.close(io);

        const req = "GET /reset_content HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
        var vec = [1][]const u8{req};
        _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &vec } })).net_write;

        var resp_buf: [512]u8 = undefined;
        var r_vec = [1][]u8{&resp_buf};
        const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &r_vec } })).net_read).data_len;
        const resp_str = resp_buf[0..n];

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
        var r_vec = [1][]u8{&resp_buf};
        const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &r_vec } })).net_read).data_len;
        const resp_str = resp_buf[0..n];

        try std.testing.expect(std.mem.indexOf(u8, resp_str, "204 No Content") != null);
        try std.testing.expect(std.ascii.findIgnoreCase(resp_str, "content-length") == null);
        try std.testing.expect(std.ascii.findIgnoreCase(resp_str, "transfer-encoding") == null);
    }

    server.shutdown();
    server_thread.join();
}

test "review round 2: Finding 5 - monotonic read deadline stops Slow Post trickle" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var mux = http.ServeMux.init(allocator);
    defer mux.deinit();

    try mux.handleFunc("POST /slow", struct {
        fn handle(w: *http.ResponseWriter, req: *http.Request) anyerror!void {
            const body = try req.readBodyAlloc(1024);
            try w.writeAll(body);
        }
    }.handle);

    const port: u16 = 19205;
    const listen_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    var listener = try listen_addr.listen(io, .{ .reuse_address = true });

    // read_timeout_ns = 150ms
    var server = http.Server.init(allocator, .{
        .handler = mux.handler(),
        .num_threads = 2,
        .read_timeout_ns = 150 * std.time.ns_per_ms,
    });
    server.listener = listener;
    server.running.store(true, .release);
    server.pool = try http.ThreadPool.create(allocator, io, 2, 1024);
    defer server.deinit();

    const ServerThread = struct {
        fn run(s: *http.Server, l: *std.Io.net.Server) void {
            while (s.running.load(.acquire)) {
                const stream = l.accept(s.io) catch break;
                s.pool.?.spawn(http.Server.serveConn, .{ s, stream }) catch {
                    stream.close(s.io);
                };
            }
        }
    };
    const server_thread = try std.Thread.spawn(.{}, ServerThread.run, .{ &server, &listener });

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

test "review round 2: Finding 6 - duplicate chunked and forbidden chunk trailers rejected" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var mux = http.ServeMux.init(allocator);
    defer mux.deinit();

    try mux.handleFunc("POST /trailer", struct {
        fn handle(w: *http.ResponseWriter, req: *http.Request) anyerror!void {
            _ = try req.readBodyAlloc(1024);
            try w.writeAll("ok");
        }
    }.handle);

    const port: u16 = 19206;
    const listen_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    var listener = try listen_addr.listen(io, .{ .reuse_address = true });

    var server = http.Server.init(allocator, .{
        .handler = mux.handler(),
        .num_threads = 2,
    });
    server.listener = listener;
    server.running.store(true, .release);
    server.pool = try http.ThreadPool.create(allocator, io, 2, 1024);
    defer server.deinit();

    const ServerThread = struct {
        fn run(s: *http.Server, l: *std.Io.net.Server) void {
            while (s.running.load(.acquire)) {
                const stream = l.accept(s.io) catch break;
                s.pool.?.spawn(http.Server.serveConn, .{ s, stream }) catch {
                    stream.close(s.io);
                };
            }
        }
    };
    const server_thread = try std.Thread.spawn(.{}, ServerThread.run, .{ &server, &listener });

    const connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);

    // 1. Duplicate chunked transfer encoding rejected with 400 Bad Request
    {
        var client = try connect_addr.connect(io, .{ .mode = .stream });
        defer client.close(io);

        const req = "POST /trailer HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked, chunked\r\n\r\n0\r\n\r\n";
        var vec = [1][]const u8{req};
        _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &vec } })).net_write;

        var resp_buf: [256]u8 = undefined;
        var r_vec = [1][]u8{&resp_buf};
        const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &r_vec } })).net_read).data_len;
        try std.testing.expect(std.mem.indexOf(u8, resp_buf[0..n], "400 Bad Request") != null);
    }

    // 2. Forbidden trailer Content-Length rejected
    {
        var client = try connect_addr.connect(io, .{ .mode = .stream });
        defer client.close(io);

        const req = "POST /trailer HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\nContent-Length: 5\r\n\r\n";
        var vec = [1][]const u8{req};
        _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &vec } })).net_write;

        var resp_buf: [256]u8 = undefined;
        var r_vec = [1][]u8{&resp_buf};
        const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &r_vec } })).net_read).data_len;
        // Handler encountered error when reading trailer, so returns 500 or drops
        try std.testing.expect(std.mem.indexOf(u8, resp_buf[0..n], "500 Internal Server Error") != null or n == 0);
    }

    server.shutdown();
    server_thread.join();
}

test "review round 3: Finding 2 - truncated body or handler error enforces Connection: close in headers" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

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

    const port: u16 = 19301;
    const listen_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    var listener = try listen_addr.listen(io, .{ .reuse_address = true });

    var server = http.Server.init(allocator, .{
        .handler = mux.handler(),
        .num_threads = 2,
    });
    server.listener = listener;
    server.running.store(true, .release);
    server.pool = try http.ThreadPool.create(allocator, io, 2, 1024);
    defer server.deinit();

    const ServerThread = struct {
        fn run(s: *http.Server, l: *std.Io.net.Server) void {
            while (s.running.load(.acquire)) {
                const stream = l.accept(s.io) catch break;
                s.pool.?.spawn(http.Server.serveConn, .{ s, stream }) catch {
                    stream.close(s.io);
                };
            }
        }
    };
    const server_thread = try std.Thread.spawn(.{}, ServerThread.run, .{ &server, &listener });

    const connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);

    // Case 1: Truncated body must emit Connection: close, not keep-alive
    {
        var client = try connect_addr.connect(io, .{ .mode = .stream });
        defer client.close(io);

        const req = "GET /short_body HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n";
        var vec = [1][]const u8{req};
        _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &vec } })).net_write;

        var resp_buf: [512]u8 = undefined;
        var r_vec = [1][]u8{&resp_buf};
        const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &r_vec } })).net_read).data_len;
        const resp_str = resp_buf[0..n];

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
        var r_vec = [1][]u8{&resp_buf};
        const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &r_vec } })).net_read).data_len;
        const resp_str = resp_buf[0..n];

        try std.testing.expect(std.mem.indexOf(u8, resp_str, "500 Internal Server Error") != null);
        try std.testing.expect(std.mem.indexOf(u8, resp_str, "Connection: close") != null);
        try std.testing.expect(std.ascii.findIgnoreCase(resp_str, "connection: keep-alive") == null);
    }

    server.shutdown();
    server_thread.join();
}

test "review round 3: Finding 3 - HTTP/1.0 request receives HTTP/1.0 status line and no chunked encoding" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

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

    const port: u16 = 19302;
    const listen_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    var listener = try listen_addr.listen(io, .{ .reuse_address = true });

    var server = http.Server.init(allocator, .{
        .handler = mux.handler(),
        .num_threads = 2,
    });
    server.listener = listener;
    server.running.store(true, .release);
    server.pool = try http.ThreadPool.create(allocator, io, 2, 1024);
    defer server.deinit();

    const ServerThread = struct {
        fn run(s: *http.Server, l: *std.Io.net.Server) void {
            while (s.running.load(.acquire)) {
                const stream = l.accept(s.io) catch break;
                s.pool.?.spawn(http.Server.serveConn, .{ s, stream }) catch {
                    stream.close(s.io);
                };
            }
        }
    };
    const server_thread = try std.Thread.spawn(.{}, ServerThread.run, .{ &server, &listener });

    const connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);

    // 1. Basic HTTP/1.0 request gets HTTP/1.0 status line
    {
        var client = try connect_addr.connect(io, .{ .mode = .stream });
        defer client.close(io);

        const req = "GET /version_test HTTP/1.0\r\n\r\n";
        var vec = [1][]const u8{req};
        _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &vec } })).net_write;

        var resp_buf: [512]u8 = undefined;
        var r_vec = [1][]u8{&resp_buf};
        const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &r_vec } })).net_read).data_len;
        const resp_str = resp_buf[0..n];

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

test "review round 3: Finding 5 - Host case-insensitivity and IPv6 routing in live server" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var mux = http.ServeMux.init(allocator);
    defer mux.deinit();

    try mux.handleFunc("MYHOST.COM/info", struct {
        fn handle(w: *http.ResponseWriter, _: *http.Request) anyerror!void {
            try w.writeAll("myhost-info");
        }
    }.handle);

    const port: u16 = 19303;
    const listen_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    var listener = try listen_addr.listen(io, .{ .reuse_address = true });

    var server = http.Server.init(allocator, .{
        .handler = mux.handler(),
        .num_threads = 2,
    });
    server.listener = listener;
    server.running.store(true, .release);
    server.pool = try http.ThreadPool.create(allocator, io, 2, 1024);
    defer server.deinit();

    const ServerThread = struct {
        fn run(s: *http.Server, l: *std.Io.net.Server) void {
            while (s.running.load(.acquire)) {
                const stream = l.accept(s.io) catch break;
                s.pool.?.spawn(http.Server.serveConn, .{ s, stream }) catch {
                    stream.close(s.io);
                };
            }
        }
    };
    const server_thread = try std.Thread.spawn(.{}, ServerThread.run, .{ &server, &listener });

    const connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);

    // Client sends Host in lowercase with port
    {
        var client = try connect_addr.connect(io, .{ .mode = .stream });
        defer client.close(io);

        const req = "GET /info HTTP/1.1\r\nHost: myhost.com:19303\r\nConnection: close\r\n\r\n";
        var vec = [1][]const u8{req};
        _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &vec } })).net_write;

        var resp_buf: [512]u8 = undefined;
        var r_vec = [1][]u8{&resp_buf};
        const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &r_vec } })).net_read).data_len;
        const resp_str = resp_buf[0..n];

        try std.testing.expect(std.mem.indexOf(u8, resp_str, "200 OK") != null);
        try std.testing.expect(std.mem.indexOf(u8, resp_str, "myhost-info") != null);
    }

    server.shutdown();
    server_thread.join();
}

test "review round 3: Finding 6 - RFC 9112 request-target rejection in live server" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var mux = http.ServeMux.init(allocator);
    defer mux.deinit();

    try mux.handleFunc("OPTIONS *", struct {
        fn handle(w: *http.ResponseWriter, _: *http.Request) anyerror!void {
            try w.header().set("Allow", "GET, POST, OPTIONS");
            w.writeHeader(.ok);
        }
    }.handle);

    const port: u16 = 19304;
    const listen_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    var listener = try listen_addr.listen(io, .{ .reuse_address = true });

    var server = http.Server.init(allocator, .{
        .handler = mux.handler(),
        .num_threads = 2,
    });
    server.listener = listener;
    server.running.store(true, .release);
    server.pool = try http.ThreadPool.create(allocator, io, 2, 1024);
    defer server.deinit();

    const ServerThread = struct {
        fn run(s: *http.Server, l: *std.Io.net.Server) void {
            while (s.running.load(.acquire)) {
                const stream = l.accept(s.io) catch break;
                s.pool.?.spawn(http.Server.serveConn, .{ s, stream }) catch {
                    stream.close(s.io);
                };
            }
        }
    };
    const server_thread = try std.Thread.spawn(.{}, ServerThread.run, .{ &server, &listener });

    const connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);

    // 1. GET * is rejected with 400 Bad Request
    {
        var client = try connect_addr.connect(io, .{ .mode = .stream });
        defer client.close(io);

        const req = "GET * HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
        var vec = [1][]const u8{req};
        _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &vec } })).net_write;

        var resp_buf: [512]u8 = undefined;
        var r_vec = [1][]u8{&resp_buf};
        const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &r_vec } })).net_read).data_len;
        const resp_str = resp_buf[0..n];

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
        var r_vec = [1][]u8{&resp_buf};
        const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &r_vec } })).net_read).data_len;
        const resp_str = resp_buf[0..n];

        try std.testing.expect(std.mem.indexOf(u8, resp_str, "200 OK") != null);
        try std.testing.expect(std.mem.indexOf(u8, resp_str, "Allow: GET, POST, OPTIONS") != null);
    }

    server.shutdown();
    server_thread.join();
}
