//! Reverse proxy HTTP handler conforming to Go's httputil.ReverseProxy.

const std = @import("std");
const assert = std.debug.assert;
const Handler = @import("../../handler.zig").Handler;
const ResponseWriter = @import("../../response_writer.zig").ResponseWriter;
const Request = @import("../../request.zig").Request;
const Status = @import("../../proto/status.zig").Status;
const io_util = @import("../../proto/io_util.zig");

/// ReverseProxyOptions configures a ReverseProxy handler.
pub const ReverseProxyOptions = struct {
    /// Upstream target IP address to forward requests to.
    target_addr: std.Io.net.IpAddress,
    /// Optional callback hook to rewrite the request line, target, or headers before upstream delivery.
    director: ?*const fn (req: *Request) void = null,
    /// Connection timeout to the upstream server in nanoseconds. Defaults to 5 seconds.
    connect_timeout_ns: ?u64 = 5 * std.time.ns_per_s,
};

/// ReverseProxy forwards incoming HTTP requests to an upstream server and proxies the response back.
///
/// It strips RFC 9110 hop-by-hop headers, injects standard X-Forwarded-* headers,
/// and streams request and response bodies.
pub const ReverseProxy = struct {
    options: ReverseProxyOptions,

    /// init constructs a ReverseProxy instance.
    pub fn init(options: ReverseProxyOptions) ReverseProxy {
        return .{ .options = options };
    }

    /// serveHTTP handles incoming client requests by forwarding them upstream.
    pub fn serveHTTP(self: *ReverseProxy, w: *ResponseWriter, req: *Request) anyerror!void {
        if (self.options.director) |dir| {
            dir(req);
        }

        // 1. Connect to upstream
        var upstream = self.options.target_addr.connect(w.io, .{ .mode = .stream }) catch |err| {
            std.log.warn("reverse proxy connect to upstream failed: {}", .{err});
            w.setStatus(.bad_gateway);
            try w.header().set("Content-Type", "text/plain; charset=utf-8");
            try w.writeAll("Bad Gateway: Unable to connect to upstream\n");
            return;
        };
        defer upstream.close(w.io);

        // 2. Build upstream request head
        var head_buf = std.ArrayListUnmanaged(u8).empty;
        defer head_buf.deinit(req.arena);

        const method = req.method.asString();
        const target = req.target;

        // Request line: METHOD TARGET HTTP/1.1\r\n
        try head_buf.appendSlice(req.arena, method);
        try head_buf.appendSlice(req.arena, " ");
        try head_buf.appendSlice(req.arena, target);
        try head_buf.appendSlice(req.arena, " HTTP/1.1\r\n");

        // Forward headers (excluding hop-by-hop)
        var has_x_forwarded_for = false;
        var has_x_forwarded_proto = false;

        for (req.headers.entries.items) |entry| {
            if (isHopByHop(entry.name)) continue;
            if (std.ascii.eqlIgnoreCase(entry.name, "x-forwarded-for")) has_x_forwarded_for = true;
            if (std.ascii.eqlIgnoreCase(entry.name, "x-forwarded-proto")) has_x_forwarded_proto = true;

            try head_buf.appendSlice(req.arena, entry.name);
            try head_buf.appendSlice(req.arena, ": ");
            try head_buf.appendSlice(req.arena, entry.value);
            try head_buf.appendSlice(req.arena, "\r\n");
        }

        if (!has_x_forwarded_proto) {
            try head_buf.appendSlice(req.arena, "X-Forwarded-Proto: http\r\n");
        }
        if (!has_x_forwarded_for) {
            try head_buf.appendSlice(req.arena, "X-Forwarded-For: 127.0.0.1\r\n");
        }

        // Use Connection: close with upstream for clean response streaming termination
        try head_buf.appendSlice(req.arena, "Connection: close\r\n\r\n");

        // Send request head to upstream
        var send_head_vec = [1][]const u8{head_buf.items};
        _ = try (try w.io.operate(.{ .net_write = .{ .socket_handle = upstream.socket.handle, .data = &send_head_vec } })).net_write;

        // Forward request body if present
        if (req.body()) |b| {
            var body_chunk: [4096]u8 = undefined;
            while (true) {
                const n = try b.read(&body_chunk);
                if (n == 0) break;
                var write_vec = [1][]const u8{body_chunk[0..n]};
                _ = try (try w.io.operate(.{ .net_write = .{ .socket_handle = upstream.socket.handle, .data = &write_vec } })).net_write;
            }
        }

        // 3. Read upstream response and stream back to client
        var resp_buf: [8192]u8 = undefined;
        var resp_len: usize = 0;
        var headers_parsed = false;
        var body_start: usize = 0;

        while (true) {
            var read_vec = [1][]u8{resp_buf[resp_len..]};
            const op_res = try w.io.operate(.{ .net_read = .{ .socket_handle = upstream.socket.handle, .data = &read_vec } });
            const n = (try op_res.net_read).data_len;
            if (n == 0) break;
            resp_len += n;

            if (!headers_parsed) {
                if (std.mem.indexOf(u8, resp_buf[0..resp_len], "\r\n\r\n")) |hdr_end| {
                    headers_parsed = true;
                    body_start = hdr_end + 4;
                    try parseAndForwardUpstreamHeaders(w, req.arena, resp_buf[0..hdr_end]);

                    // Write any body bytes already present in the initial buffer
                    if (body_start < resp_len) {
                        try w.writeAll(resp_buf[body_start..resp_len]);
                    }
                    resp_len = 0;
                }
            } else {
                try w.writeAll(resp_buf[0..resp_len]);
                resp_len = 0;
            }
        }
    }

    /// handler returns a Handler interface delegating to this ReverseProxy.
    pub fn handler(self: *ReverseProxy) Handler {
        return Handler.from(self);
    }
};

/// reverseProxy creates a new ReverseProxy with options.
pub fn reverseProxy(options: ReverseProxyOptions) ReverseProxy {
    return ReverseProxy.init(options);
}

/// isHopByHop reports whether the header field is an RFC 9110 hop-by-hop header.
pub fn isHopByHop(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "connection") or
        std.ascii.eqlIgnoreCase(name, "keep-alive") or
        std.ascii.eqlIgnoreCase(name, "proxy-authenticate") or
        std.ascii.eqlIgnoreCase(name, "proxy-authorization") or
        std.ascii.eqlIgnoreCase(name, "te") or
        std.ascii.eqlIgnoreCase(name, "trailer") or
        std.ascii.eqlIgnoreCase(name, "upgrade");
}

fn parseAndForwardUpstreamHeaders(w: *ResponseWriter, arena: std.mem.Allocator, header_bytes: []const u8) !void {
    var lines = std.mem.splitSequence(u8, header_bytes, "\r\n");
    // Status line: HTTP/1.1 200 OK
    const status_line = lines.next() orelse return error.InvalidUpstreamResponse;
    var status_parts = std.mem.splitScalar(u8, status_line, ' ');
    _ = status_parts.next(); // Skip HTTP/1.1
    if (status_parts.next()) |code_str| {
        const code = std.fmt.parseInt(u16, code_str, 10) catch 502;
        w.writeHeader(@fromBackingInt(@intCast(code)));
    }

    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const val = std.mem.trim(u8, line[colon + 1 ..], " \t");

        if (isHopByHop(name)) continue;

        const name_dup = try arena.dupe(u8, name);
        const val_dup = try arena.dupe(u8, val);
        try w.header().add(name_dup, val_dup);
    }
}

test "isHopByHop detection" {
    try std.testing.expect(isHopByHop("Connection"));
    try std.testing.expect(isHopByHop("Keep-Alive"));
    try std.testing.expect(isHopByHop("upgrade"));
    try std.testing.expect(!isHopByHop("Content-Type"));
    try std.testing.expect(!isHopByHop("X-Custom-Header"));
}
