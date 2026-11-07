const std = @import("std");
const helpers = @import("helpers.zig");
const http = helpers.http;
const getTestIo = helpers.getTestIo;

test "e2e: Cookie request parsing and Set-Cookie response" {
    const io = getTestIo();
    const gpa = std.testing.allocator;

    const cookieHandler = struct {
        fn handle(w: *http.ResponseWriter, req: *http.Request) anyerror!void {
            const token = req.cookie("auth_token") orelse "anonymous";

            // Set response cookies
            try w.setCookie(.{
                .name = "session_id",
                .value = "sess_abc123",
                .path = "/",
                .http_only = true,
                .same_site = .lax,
            });

            try w.setCookie(.{
                .name = "remember_me",
                .value = "1",
                .max_age = 86400,
                .secure = true,
            });

            w.setStatus(.ok);
            try w.writer().print("Welcome: {s}", .{token});
        }
    }.handle;

    var mux = http.ServeMux.init(gpa);
    defer mux.deinit();
    try mux.handleFunc("/login", cookieHandler);

    var ts = try helpers.TestServer.start(gpa, io, .{ .handler = mux.handler() });
    defer ts.stop();

    var client = try ts.connect(io);
    defer client.close(io);

    const req = "GET /login HTTP/1.1\r\nHost: localhost\r\nCookie: auth_token=secret_jwt_payload; theme=dark\r\nConnection: close\r\n\r\n";
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
    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, resp, "Set-Cookie: session_id=sess_abc123; Path=/; HttpOnly; SameSite=Lax") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "Set-Cookie: remember_me=1; Max-Age=86400; Secure") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "Welcome: secret_jwt_payload") != null);
}

test "e2e: multipart/form-data upload with text and file" {
    const io = getTestIo();
    const gpa = std.testing.allocator;

    const uploadHandler = struct {
        fn handle(w: *http.ResponseWriter, req: *http.Request) anyerror!void {
            var form = try req.multipartForm(1024 * 1024);
            defer form.deinit();

            const title = form.getValue("title") orelse "untitled";
            const file = form.getFile("upload") orelse return error.MissingFile;

            w.setStatus(.ok);
            try w.writer().print("Uploaded: {s}, File: {s}, Size: {d}, Content: {s}", .{
                title,
                file.filename,
                file.size,
                file.data,
            });
        }
    }.handle;

    var mux = http.ServeMux.init(gpa);
    defer mux.deinit();
    try mux.handleFunc("POST /upload", uploadHandler);

    var ts = try helpers.TestServer.start(gpa, io, .{ .handler = mux.handler() });
    defer ts.stop();

    var client = try ts.connect(io);
    defer client.close(io);

    const boundary = "---------------------------974767299852498929531610575";
    const body =
        "--" ++ boundary ++ "\r\n" ++
        "Content-Disposition: form-data; name=\"title\"\r\n" ++
        "\r\n" ++
        "Report 2026\r\n" ++
        "--" ++ boundary ++ "\r\n" ++
        "Content-Disposition: form-data; name=\"upload\"; filename=\"notes.txt\"\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "\r\n" ++
        "Lighting is fast\r\n" ++
        "--" ++ boundary ++ "--\r\n";

    var head_buf: [256]u8 = undefined;
    const req_head = try std.fmt.bufPrint(&head_buf, "POST /upload HTTP/1.1\r\nHost: localhost\r\nContent-Type: multipart/form-data; boundary={s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ boundary, body.len });

    var write_vecs = [2][]const u8{ req_head, body };
    _ = try (try io.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &write_vecs } })).net_write;

    var buf: [2048]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        var r_vec = [1][]u8{buf[total..]};
        const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &r_vec } })).net_read).data_len;
        if (n == 0) break;
        total += n;
    }

    const resp = buf[0..total];
    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, resp, "Uploaded: Report 2026, File: notes.txt, Size: 16, Content: Lighting is fast") != null);
}
