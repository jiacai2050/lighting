const std = @import("std");
const Method = @import("proto/method.zig").Method;
const Version = @import("proto/parser.zig").Version;
const HeaderMap = @import("header.zig").HeaderMap;
const BodyReader = @import("proto/chunk_reader.zig").BodyReader;

pub const URL = struct {
    raw: []const u8,
    path: []const u8,
    raw_query: ?[]const u8,

    pub fn parse(target: []const u8) URL {
        if (std.mem.indexOfScalar(u8, target, '?')) |q_idx| {
            return .{
                .raw = target,
                .path = target[0..q_idx],
                .raw_query = target[q_idx + 1 ..],
            };
        } else {
            return .{
                .raw = target,
                .path = target,
                .raw_query = null,
            };
        }
    }

    pub fn queryParam(self: URL, key: []const u8) ?[]const u8 {
        const query = self.raw_query orelse return null;
        var it = std.mem.splitScalar(u8, query, '&');
        while (it.next()) |pair| {
            if (std.mem.indexOfScalar(u8, pair, '=')) |eq| {
                const k = pair[0..eq];
                const v = pair[eq + 1 ..];
                if (std.mem.eql(u8, k, key)) {
                    return v;
                }
            } else {
                if (std.mem.eql(u8, pair, key)) {
                    return "";
                }
            }
        }
        return null;
    }

    /// URL unescape percent-encoded string and '+' to spaces
    pub fn unescape(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
        var out = std.ArrayListUnmanaged(u8).empty;
        errdefer out.deinit(allocator);

        var i: usize = 0;
        while (i < s.len) {
            if (s[i] == '%' and i + 2 < s.len) {
                const hex = s[i + 1 .. i + 3];
                if (std.fmt.parseInt(u8, hex, 16)) |byte| {
                    try out.append(allocator, byte);
                    i += 3;
                    continue;
                } else |_| {}
            } else if (s[i] == '+') {
                try out.append(allocator, ' ');
                i += 1;
                continue;
            }
            try out.append(allocator, s[i]);
            i += 1;
        }
        return out.toOwnedSlice(allocator);
    }
};

pub const PathValueEntry = struct {
    name: []const u8,
    value: []const u8,
};

pub const Request = struct {
    method: Method,
    target: []const u8,
    url: URL,
    proto: Version,
    headers: HeaderMap,
    body_reader: ?BodyReader,
    arena: std.mem.Allocator,
    content_length: ?u64,
    keep_alive: bool,
    path_values: std.ArrayListUnmanaged(PathValueEntry) = .empty,

    pub fn init(
        method: Method,
        target: []const u8,
        proto: Version,
        headers: HeaderMap,
        body_reader: ?BodyReader,
        content_length: ?u64,
        keep_alive: bool,
        arena: std.mem.Allocator,
    ) Request {
        return .{
            .method = method,
            .target = target,
            .url = URL.parse(target),
            .proto = proto,
            .headers = headers,
            .body_reader = body_reader,
            .arena = arena,
            .content_length = content_length,
            .keep_alive = keep_alive,
            .path_values = .empty,
        };
    }

    pub fn body(self: *Request) ?*BodyReader {
        if (self.body_reader != null) {
            return &self.body_reader.?;
        }
        return null;
    }

    pub fn readBodyAlloc(self: *Request, max_size: usize) ![]u8 {
        if (self.body()) |b| {
            return b.readAllAlloc(self.arena, max_size);
        }
        return &[_]u8{};
    }

    /// Returns the matched wildcard or placeholder value from the route pattern
    /// equivalent to Go's req.PathValue(name)
    pub fn pathValue(self: *const Request, name: []const u8) ?[]const u8 {
        for (self.path_values.items) |entry| {
            if (std.mem.eql(u8, entry.name, name)) {
                return entry.value;
            }
        }
        return null;
    }

    /// Sets a path value parameter (called by router or middlewares)
    pub fn setPathValue(self: *Request, name: []const u8, value: []const u8) !void {
        for (self.path_values.items) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) {
                entry.value = value;
                return;
            }
        }
        try self.path_values.append(self.arena, .{
            .name = name,
            .value = value,
        });
    }
    /// Shortcut helper to access header value case-insensitively
    pub fn header(self: *const Request, name: []const u8) ?[]const u8 {
        return self.headers.get(name);
    }
};

test "URL parse and queryParam" {
    const allocator = std.testing.allocator;
    const u = URL.parse("/search?q=zig&page=2");
    try std.testing.expectEqualStrings("/search", u.path);
    try std.testing.expectEqualStrings("zig", u.queryParam("q").?);
    try std.testing.expectEqualStrings("2", u.queryParam("page").?);
    try std.testing.expect(u.queryParam("other") == null);

    const unescaped = try URL.unescape(allocator, "hello+world%21%20%2F");
    defer allocator.free(unescaped);
    try std.testing.expectEqualStrings("hello world! /", unescaped);
}
