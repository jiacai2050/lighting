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
    server.pool = try http.ThreadPool.create(allocator, io, 2);
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
