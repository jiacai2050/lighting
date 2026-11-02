const std = @import("std");
const Method = @import("method.zig").Method;
const HeaderMap = @import("../header.zig").HeaderMap;

pub const Version = enum {
    @"HTTP/1.0",
    @"HTTP/1.1",

    pub fn parse(s: []const u8) ?Version {
        if (std.mem.eql(u8, s, "HTTP/1.1")) return .@"HTTP/1.1";
        if (std.mem.eql(u8, s, "HTTP/1.0")) return .@"HTTP/1.0";
        return null;
    }

    pub fn asString(self: Version) []const u8 {
        return switch (self) {
            .@"HTTP/1.0" => "HTTP/1.0",
            .@"HTTP/1.1" => "HTTP/1.1",
        };
    }
};

pub const RequestHead = struct {
    method: Method,
    target: []const u8,
    version: Version,
    headers: HeaderMap,
    content_length: ?u64 = null,
    is_chunked: bool = false,
    keep_alive: bool = true,
    bytes_consumed: usize, // length of request head including final \r\n\r\n
};

pub const ParseError = error{
    Incomplete,
    InvalidMethod,
    InvalidTarget,
    InvalidVersion,
    InvalidHeader,
    InvalidContentLength,
    MissingHostHeader,
    OutOfMemory,
};

/// Parses HTTP/1.x request header from a raw buffer in a zero-copy manner.
/// Strings point directly into `buffer` whenever possible.
pub fn parseRequestHead(allocator: std.mem.Allocator, buffer: []const u8) ParseError!RequestHead {
    const end_idx = std.mem.indexOf(u8, buffer, "\r\n\r\n") orelse return error.Incomplete;
    const head_part = buffer[0..end_idx];

    var line_it = std.mem.splitSequence(u8, head_part, "\r\n");
    const request_line = line_it.next() orelse return error.InvalidMethod;

    // Parse request line: METHOD TARGET VERSION
    var req_line_it = std.mem.splitScalar(u8, request_line, ' ');
    const method_str = req_line_it.next() orelse return error.InvalidMethod;
    const target = req_line_it.next() orelse return error.InvalidTarget;
    const version_str = req_line_it.next() orelse return error.InvalidVersion;

    const method = Method.parse(method_str) orelse return error.InvalidMethod;
    const version = Version.parse(version_str) orelse return error.InvalidVersion;

    var headers = HeaderMap.init(allocator);
    errdefer headers.deinit();

    var content_length: ?u64 = null;
    var is_chunked = false;
    var connection_hdr: ?[]const u8 = null;

    while (line_it.next()) |line| {
        if (line.len == 0) continue;
        const colon_idx = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidHeader;
        const key = std.mem.trim(u8, line[0..colon_idx], " \t");
        const val = std.mem.trim(u8, line[colon_idx + 1 ..], " \t");

        try headers.add(key, val);

        if (std.ascii.eqlIgnoreCase(key, "content-length")) {
            const parsed_cl = std.fmt.parseInt(u64, val, 10) catch return error.InvalidContentLength;
            if (content_length) |existing| {
                // RFC 9112 Section 6.3: Reject conflicting multiple Content-Lengths (Request Smuggling defense)
                if (existing != parsed_cl) return error.InvalidContentLength;
            } else {
                content_length = parsed_cl;
            }
        } else if (std.ascii.eqlIgnoreCase(key, "transfer-encoding")) {
            if (std.ascii.findIgnoreCase(val, "chunked") != null) {
                is_chunked = true;
            }
        } else if (std.ascii.eqlIgnoreCase(key, "connection")) {
            connection_hdr = val;
        }
    }

    // RFC 9112 Section 6.1: Transfer-Encoding overrides Content-Length
    if (is_chunked) {
        content_length = null;
    }

    // RFC 9112 Section 7.1: Host header mandatory for HTTP/1.1
    if (version == .@"HTTP/1.1" and headers.get("host") == null) {
        return error.MissingHostHeader;
    }

    // Determine keep-alive policy
    var keep_alive: bool = switch (version) {
        .@"HTTP/1.1" => true,
        .@"HTTP/1.0" => false,
    };
    if (connection_hdr) |conn| {
        if (std.ascii.findIgnoreCase(conn, "close") != null) {
            keep_alive = false;
        } else if (std.ascii.findIgnoreCase(conn, "keep-alive") != null) {
            keep_alive = true;
        }
    }

    return RequestHead{
        .method = method,
        .target = target,
        .version = version,
        .headers = headers,
        .content_length = content_length,
        .is_chunked = is_chunked,
        .keep_alive = keep_alive,
        .bytes_consumed = end_idx + 4,
    };
}

test "parseRequestHead simple GET" {
    const raw = "GET /index.html HTTP/1.1\r\nHost: example.com\r\nUser-Agent: curl\r\n\r\n";
    const head = try parseRequestHead(std.testing.allocator, raw);
    var h = head.headers;
    defer h.deinit();

    try std.testing.expectEqual(Method.GET, head.method);
    try std.testing.expectEqualStrings("/index.html", head.target);
    try std.testing.expectEqual(Version.@"HTTP/1.1", head.version);
    try std.testing.expectEqual(true, head.keep_alive);
    try std.testing.expectEqualStrings("example.com", head.headers.get("host").?);
    try std.testing.expectEqual(raw.len, head.bytes_consumed);
}

test "parseRequestHead POST with content length and connection close" {
    const raw = "POST /api/data HTTP/1.1\r\nHost: localhost\r\nContent-Length: 42\r\nConnection: close\r\n\r\nrest-of-body";
    const head = try parseRequestHead(std.testing.allocator, raw);
    var h = head.headers;
    defer h.deinit();

    try std.testing.expectEqual(Method.POST, head.method);
    try std.testing.expectEqualStrings("/api/data", head.target);
    try std.testing.expectEqual(@as(?u64, 42), head.content_length);
    try std.testing.expectEqual(false, head.keep_alive);
    try std.testing.expectEqual(@as(usize, 83), head.bytes_consumed);
}

test "parseRequestHead RFC compliance: reject missing host in HTTP/1.1" {
    const raw = "GET / HTTP/1.1\r\nUser-Agent: bad-client\r\n\r\n";
    try std.testing.expectError(error.MissingHostHeader, parseRequestHead(std.testing.allocator, raw));
}

test "parseRequestHead RFC compliance: reject conflicting Content-Lengths" {
    const raw = "POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 10\r\nContent-Length: 20\r\n\r\n";
    try std.testing.expectError(error.InvalidContentLength, parseRequestHead(std.testing.allocator, raw));
}
