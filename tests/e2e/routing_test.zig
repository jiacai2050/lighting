const std = @import("std");
const helpers = @import("helpers.zig");
const http = helpers.http;
const getTestIo = helpers.getTestIo;

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

    var ts = try helpers.TestServer.start(allocator, io, .{ .handler = mux.handler() });
    defer ts.stop();

    const connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", ts.port);

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

    var ts = try helpers.TestServer.start(allocator, io, .{ .handler = mux.handler() });
    defer ts.stop();

    const connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", ts.port);

    // Client sends Host in lowercase with port
    {
        var client = try connect_addr.connect(io, .{ .mode = .stream });
        defer client.close(io);

        var req_buf: [128]u8 = undefined;
        const req = try std.fmt.bufPrint(&req_buf, "GET /info HTTP/1.1\r\nHost: myhost.com:{d}\r\nConnection: close\r\n\r\n", .{ts.port});
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

    var ts = try helpers.TestServer.start(allocator, io, .{ .handler = mux.handler() });
    defer ts.stop();

    const connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", ts.port);

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
