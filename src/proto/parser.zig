const std = @import("std");
const Method = @import("method.zig").Method;
const HeaderMap = @import("../header.zig").HeaderMap;
const isValidTokenChar = @import("../header.zig").isValidTokenChar;

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
    InvalidRequestLine,
    InvalidHeader,
    InvalidHeaderColonWhitespace,
    DuplicateHostHeader,
    InvalidContentLength,
    MissingHostHeader,
    UnsupportedTransferEncoding,
    ChunkedNotFinalTransferEncoding,
    DuplicateChunkedTransferEncoding,
    InvalidTransferEncoding,
    OutOfMemory,
};

/// Parses HTTP/1.x request header from a raw buffer in a zero-copy manner.
/// Strings point directly into `buffer` whenever possible.
pub fn parseRequestHead(allocator: std.mem.Allocator, buffer: []const u8) ParseError!RequestHead {
    const end_idx = std.mem.indexOf(u8, buffer, "\r\n\r\n") orelse return error.Incomplete;
    const head_part = buffer[0..end_idx];

    var line_it = std.mem.splitSequence(u8, head_part, "\r\n");
    const request_line = line_it.next() orelse return error.InvalidMethod;

    // Parse request line: METHOD TARGET VERSION (strictly 3 space-separated non-empty tokens)
    var req_line_it = std.mem.splitScalar(u8, request_line, ' ');
    const method_str = req_line_it.next() orelse return error.InvalidMethod;
    const target = req_line_it.next() orelse return error.InvalidTarget;
    const version_str = req_line_it.next() orelse return error.InvalidVersion;
    if (req_line_it.next() != null) return error.InvalidRequestLine;
    if (method_str.len == 0 or target.len == 0 or version_str.len == 0) return error.InvalidRequestLine;

    const method = Method.parse(method_str) orelse return error.InvalidMethod;
    const version = Version.parse(version_str) orelse return error.InvalidVersion;

    // RFC 9112 Section 3.2: Validate request-target
    for (target) |c| {
        if (c <= 0x20 or c == 0x7f) return error.InvalidTarget;
    }

    if (std.mem.eql(u8, target, "*")) {
        if (method != .OPTIONS) return error.InvalidTarget;
    } else if (method == .CONNECT) {
        // CONNECT requires authority-form (e.g. "example.com:443", must not start with '/')
        if (target[0] == '/' or std.ascii.startsWithIgnoreCase(target, "http://") or std.ascii.startsWithIgnoreCase(target, "https://")) {
            return error.InvalidTarget;
        }
    } else if (target[0] == '/') {
        // origin-form: valid for all methods except CONNECT
    } else if (std.ascii.startsWithIgnoreCase(target, "http://") or std.ascii.startsWithIgnoreCase(target, "https://")) {
        // absolute-form: valid
    } else {
        // Non-standard or disallowed form
        return error.InvalidTarget;
    }

    var headers = HeaderMap.init(allocator);
    errdefer headers.deinit();

    var content_length: ?u64 = null;
    var is_chunked = false;
    var connection_hdr: ?[]const u8 = null;
    var host_count: usize = 0;

    while (line_it.next()) |line| {
        if (line.len == 0) continue;
        const colon_idx = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidHeader;
        const raw_key = line[0..colon_idx];
        if (raw_key.len == 0) return error.InvalidHeader;

        // RFC 9112 Section 5.1: No whitespace allowed between field name and colon
        if (raw_key[raw_key.len - 1] == ' ' or raw_key[raw_key.len - 1] == '\t') {
            return error.InvalidHeaderColonWhitespace;
        }
        for (raw_key) |c| {
            if (!isValidTokenChar(c)) return error.InvalidHeader;
        }

        const key = raw_key;
        const val = std.mem.trim(u8, line[colon_idx + 1 ..], " \t");
        for (val) |c| {
            if (c < 0x20 and c != '\t') return error.InvalidHeader;
        }

        headers.add(key, val) catch |err| {
            if (err == error.InvalidHeaderCharacter) return error.InvalidHeader;
            return error.OutOfMemory;
        };

        if (std.ascii.eqlIgnoreCase(key, "host")) {
            host_count += 1;
            if (host_count > 1) return error.DuplicateHostHeader;
        } else if (std.ascii.eqlIgnoreCase(key, "content-length")) {
            const parsed_cl = std.fmt.parseInt(u64, val, 10) catch return error.InvalidContentLength;
            if (content_length) |existing| {
                // RFC 9112 Section 6.3: Reject conflicting multiple Content-Lengths (Request Smuggling defense)
                if (existing != parsed_cl) return error.InvalidContentLength;
            } else {
                content_length = parsed_cl;
            }
        } else if (std.ascii.eqlIgnoreCase(key, "transfer-encoding")) {
            // RFC 9112 Section 6.1: Parse comma-separated list of transfer codings
            var te_it = std.mem.splitScalar(u8, val, ',');
            var last_token: ?[]const u8 = null;
            var chunked_count: usize = 0;
            var token_count: usize = 0;
            while (te_it.next()) |raw_tok| {
                const tok = std.mem.trim(u8, raw_tok, " \t");
                if (tok.len == 0) {
                    // Empty token between commas (e.g. "chunked, , chunked") is invalid syntax
                    return error.InvalidTransferEncoding;
                }
                token_count += 1;
                last_token = tok;
                if (std.ascii.eqlIgnoreCase(tok, "chunked")) {
                    chunked_count += 1;
                } else {
                    return error.UnsupportedTransferEncoding;
                }
            }
            // RFC 9112 Section 6.1: Chunked must not be applied more than once
            if (chunked_count > 1) {
                return error.DuplicateChunkedTransferEncoding;
            }
            if (last_token) |last| {
                if (!std.ascii.eqlIgnoreCase(last, "chunked")) {
                    return error.ChunkedNotFinalTransferEncoding;
                }
                is_chunked = true;
            } else {
                return error.InvalidTransferEncoding;
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

test "parseRequestHead RFC compliance: Transfer-Encoding chunked validation" {
    const allocator = std.testing.allocator;

    // Reject duplicate chunked tokens
    const dup_raw = "POST / HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked, chunked\r\n\r\n";
    try std.testing.expectError(error.DuplicateChunkedTransferEncoding, parseRequestHead(allocator, dup_raw));

    // Reject empty tokens like "chunked, , chunked"
    const empty_raw = "POST / HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked, , chunked\r\n\r\n";
    try std.testing.expectError(error.InvalidTransferEncoding, parseRequestHead(allocator, empty_raw));

    // Reject non-chunked transfer coding as unsupported (RFC 9112 Section 6.1 -> 501 Not Implemented)
    const not_final = "POST / HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked, gzip\r\n\r\n";
    try std.testing.expectError(error.UnsupportedTransferEncoding, parseRequestHead(allocator, not_final));

    // Accept valid chunked encoding
    const valid_raw = "POST / HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n";
    const head = try parseRequestHead(allocator, valid_raw);
    var h = head.headers;
    defer h.deinit();
    try std.testing.expectEqual(true, head.is_chunked);
}

test "parseRequestHead RFC compliance: request-target forms validation" {
    const allocator = std.testing.allocator;

    // 1. origin-form is valid
    {
        const raw = "GET /path/to/resource?query=1 HTTP/1.1\r\nHost: localhost\r\n\r\n";
        const head = try parseRequestHead(allocator, raw);
        var h = head.headers;
        defer h.deinit();
        try std.testing.expectEqualStrings("/path/to/resource?query=1", head.target);
    }

    // 2. absolute-form is valid
    {
        const raw = "GET http://example.com/index.html HTTP/1.1\r\nHost: example.com\r\n\r\n";
        const head = try parseRequestHead(allocator, raw);
        var h = head.headers;
        defer h.deinit();
        try std.testing.expectEqualStrings("http://example.com/index.html", head.target);
    }

    // 3. asterisk-form is valid ONLY for OPTIONS
    {
        const opt_raw = "OPTIONS * HTTP/1.1\r\nHost: localhost\r\n\r\n";
        const head = try parseRequestHead(allocator, opt_raw);
        var h = head.headers;
        defer h.deinit();
        try std.testing.expectEqualStrings("*", head.target);

        const get_raw = "GET * HTTP/1.1\r\nHost: localhost\r\n\r\n";
        try std.testing.expectError(error.InvalidTarget, parseRequestHead(allocator, get_raw));
    }

    // 4. authority-form is valid ONLY for CONNECT
    {
        const conn_raw = "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n";
        const head = try parseRequestHead(allocator, conn_raw);
        var h = head.headers;
        defer h.deinit();
        try std.testing.expectEqualStrings("example.com:443", head.target);

        // CONNECT with origin-form is invalid
        const conn_bad = "CONNECT /path HTTP/1.1\r\nHost: localhost\r\n\r\n";
        try std.testing.expectError(error.InvalidTarget, parseRequestHead(allocator, conn_bad));

        // GET with authority-form is invalid
        const get_auth = "GET example.com:80 HTTP/1.1\r\nHost: example.com\r\n\r\n";
        try std.testing.expectError(error.InvalidTarget, parseRequestHead(allocator, get_auth));
    }

    // 5. Control character in target is rejected
    {
        const bad_char = "GET /bad\x01path HTTP/1.1\r\nHost: localhost\r\n\r\n";
        try std.testing.expectError(error.InvalidTarget, parseRequestHead(allocator, bad_char));
    }
}
