const std = @import("std");
const helpers = @import("helpers.zig");
const http = helpers.http;
const getTestIo = helpers.getTestIo;

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

    const server_thread = try std.Thread.spawn(.{}, struct {
        fn run(s: *http.Server, l: std.Io.net.Server) void {
            s.serve(l) catch {};
        }
    }.run, .{ &server, listener });

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

    server.close();
    server_thread.join();
}

test "e2e: stop signal interrupts idle keep-alive connections without hanging" {
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

    // Client stays idle on connection. Server now receives stop signal.
    // Signaling stop_event MUST unblock the worker and return promptly without hanging.
    server.close();
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

    var ts = try helpers.TestServer.start(allocator, io, .{
        .handler = mux.handler(),
        .idle_timeout_ns = 5 * std.time.ns_per_s, // long idle timeout: 5s
    });
    defer ts.stop();

    const connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", ts.port);

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

    var ts = try helpers.TestServer.start(allocator, io, .{ .handler = mux.handler() });
    defer ts.stop();

    var client = try ts.connect(io);
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

    var ts = try helpers.TestServer.start(allocator, io, .{ .handler = mux.handler() });
    defer ts.stop();

    const connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", ts.port);

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
}

test "e2e: Server graceful exit with slow request prevents use-after-free" {
    const allocator = std.testing.allocator;
    const io = getTestIo();

    var mux = http.ServeMux.init(allocator);
    defer mux.deinit();

    try mux.handleFunc("/slow", struct {
        fn handle(w: *http.ResponseWriter, _: *http.Request) anyerror!void {
            try w.io.sleep(.{ .nanoseconds = 20 * std.time.ns_per_ms }, .boot);
            try w.writeAll("done slow");
        }
    }.handle);

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    const listener = try addr.listen(io, .{ .reuse_address = true });
    const port = listener.socket.address.getPort();

    const server = try allocator.create(http.Server);
    server.* = http.Server.init(allocator, io, .{
        .handler = mux.handler(),
    });

    const server_thread = try std.Thread.spawn(.{}, struct {
        fn run(s: *http.Server, l: std.Io.net.Server) void {
            s.serve(l) catch {};
        }
    }.run, .{ server, listener });

    // Connect a client and initiate a slow request
    const connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    var client = try connect_addr.connect(io, .{ .mode = .stream });
    defer client.close(io);

    const req = "GET /slow HTTP/1.1\r\nHost: localhost\r\n\r\n";
    var vec = [1][]const u8{req};
    _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &vec } })).net_write;

    // Give worker time to accept and enter handler
    try io.sleep(.{ .nanoseconds = 5 * std.time.ns_per_ms }, .boot);

    // server.shutdown() blocks until serve() completely exits and all workers complete
    server.shutdown();

    try std.testing.expect(!server.isRunning());

    // Wait for thread to exit
    server_thread.join();

    // Resources released on serve() return
    allocator.destroy(server);
}

test "e2e: Server.serve exits cleanly when server.close is called" {
    const allocator = std.testing.allocator;
    const io = getTestIo();

    var mux = http.ServeMux.init(allocator);
    defer mux.deinit();

    var server = http.Server.init(allocator, io, .{
        .handler = mux.handler(),
    });

    const addr1 = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    const listener1 = try addr1.listen(io, .{ .reuse_address = true });

    const server_thread = try std.Thread.spawn(.{}, struct {
        fn run(s: *http.Server, l: std.Io.net.Server) void {
            s.serve(l) catch {};
        }
    }.run, .{ &server, listener1 });

    try io.sleep(.{ .nanoseconds = 5 * std.time.ns_per_ms }, .boot);
    server.close();
    server_thread.join();

    try std.testing.expect(!server.isRunning());
}

test "e2e: concurrent serve and stop signal does not cause use-after-free" {
    const allocator = std.testing.allocator;
    const io = getTestIo();

    var mux = http.ServeMux.init(allocator);
    defer mux.deinit();

    // Run multiple iterations of rapid concurrent serve vs server.close()
    var iter: usize = 0;
    while (iter < 30) : (iter += 1) {
        const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        const listener = try addr.listen(io, .{ .reuse_address = true });

        const server = try allocator.create(http.Server);
        server.* = http.Server.init(allocator, io, .{
            .handler = mux.handler(),
        });

        const ServeTask = struct {
            fn run(s: *http.Server, l: std.Io.net.Server) void {
                s.serve(l) catch {};
            }
        };

        const StopTask = struct {
            fn run(s: *http.Server) void {
                s.close();
            }
        };

        const t_serve = try std.Thread.spawn(.{}, ServeTask.run, .{ server, listener });
        const t_stop = try std.Thread.spawn(.{}, StopTask.run, .{server});

        t_serve.join();
        t_stop.join();

        allocator.destroy(server);
    }
}
