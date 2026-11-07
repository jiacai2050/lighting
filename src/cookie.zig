//! HTTP Cookie parsing and Set-Cookie serialization conforming to RFC 6265.

const std = @import("std");
const assert = std.debug.assert;
const isValidTokenChar = @import("header.zig").isValidTokenChar;
const formatHttpDate = @import("response_writer.zig").ResponseWriter.formatHttpDate;

/// SameSite defines the policy controlling whether cookies are sent with cross-site requests.
pub const SameSite = enum {
    default,
    lax,
    strict,
    none,

    /// asString returns the canonical attribute value for the SameSite policy.
    pub fn asString(self: SameSite) ?[]const u8 {
        return switch (self) {
            .default => null,
            .lax => "Lax",
            .strict => "Strict",
            .none => "None",
        };
    }
};

/// CookieEntry represents a single name-value pair parsed from a client Cookie header.
pub const CookieEntry = struct {
    name: []const u8,
    value: []const u8,
};

/// CookieIterator provides streaming, zero-copy iteration over cookie entries in a raw Cookie header line.
pub const CookieIterator = struct {
    raw: ?[]const u8,
    index: usize = 0,

    /// next parses and yields the next CookieEntry in the header, or null when iteration is complete.
    pub fn next(self: *CookieIterator) ?CookieEntry {
        const line = self.raw orelse return null;
        while (self.index < line.len) {
            const remaining = line[self.index..];
            const semi_rel = std.mem.indexOfScalar(u8, remaining, ';') orelse remaining.len;
            const part = std.mem.trim(u8, remaining[0..semi_rel], " \t");
            self.index += semi_rel + 1;

            if (part.len == 0) continue;

            const eq_idx = std.mem.indexOfScalar(u8, part, '=') orelse continue;
            const name = std.mem.trim(u8, part[0..eq_idx], " \t");
            if (name.len == 0 or !isValidCookieName(name)) continue;

            var val = std.mem.trim(u8, part[eq_idx + 1 ..], " \t");
            // Strip double quotes if the value is a quoted string
            if (val.len >= 2 and val[0] == '"' and val[val.len - 1] == '"') {
                val = val[1 .. val.len - 1];
            }

            return .{
                .name = name,
                .value = val,
            };
        }
        return null;
    }
};

/// Cookie represents an HTTP cookie as used in the Set-Cookie header of a server response.
pub const Cookie = struct {
    /// Name of the cookie. Must be a valid RFC 6265 token.
    name: []const u8,
    /// Value of the cookie.
    value: []const u8,

    /// Optional path scope for the cookie (e.g. "/").
    path: ?[]const u8 = null,
    /// Optional domain scope for the cookie (e.g. "example.com").
    domain: ?[]const u8 = null,
    /// Optional expiration timestamp (seconds since Unix epoch).
    expires: ?i64 = null,
    /// Optional max age in seconds. A value <= 0 indicates immediate deletion (`Max-Age=0`).
    max_age: ?i64 = null,
    /// If true, the cookie is only transmitted over HTTPS.
    secure: bool = false,
    /// If true, the cookie is inaccessible to client-side scripts.
    http_only: bool = false,
    /// Controls cross-site cookie transmission behavior.
    same_site: SameSite = .default,
    /// If true, partitions the cookie by top-level site (CHIPS specification).
    partitioned: bool = false,

    /// format serializes the cookie into an allocated RFC 6265 Set-Cookie header string using allocator.
    /// Caller owns the returned slice and must free it with allocator (or use an arena).
    pub fn format(self: Cookie, allocator: std.mem.Allocator) ![]u8 {
        if (!isValidCookieName(self.name)) return error.InvalidCookieName;
        if (!isValidCookieValue(self.value)) return error.InvalidCookieValue;

        var list = std.ArrayListUnmanaged(u8).empty;
        errdefer list.deinit(allocator);

        try list.appendSlice(allocator, self.name);
        try list.appendSlice(allocator, "=");
        try list.appendSlice(allocator, self.value);

        if (self.path) |p| {
            try list.appendSlice(allocator, "; Path=");
            try list.appendSlice(allocator, p);
        }

        if (self.domain) |d| {
            try list.appendSlice(allocator, "; Domain=");
            try list.appendSlice(allocator, d);
        }

        if (self.expires) |exp| {
            var date_buf: [29]u8 = undefined;
            const date_str = formatHttpDate(&date_buf, exp);
            try list.appendSlice(allocator, "; Expires=");
            try list.appendSlice(allocator, date_str);
        }

        if (self.max_age) |ma| {
            if (ma <= 0) {
                try list.appendSlice(allocator, "; Max-Age=0");
            } else {
                var ma_buf: [32]u8 = undefined;
                const ma_str = try std.fmt.bufPrint(&ma_buf, "; Max-Age={d}", .{ma});
                try list.appendSlice(allocator, ma_str);
            }
        }

        if (self.http_only) {
            try list.appendSlice(allocator, "; HttpOnly");
        }

        if (self.secure) {
            try list.appendSlice(allocator, "; Secure");
        }

        if (self.same_site.asString()) |ss| {
            try list.appendSlice(allocator, "; SameSite=");
            try list.appendSlice(allocator, ss);
        }

        if (self.partitioned) {
            try list.appendSlice(allocator, "; Partitioned");
        }

        return list.toOwnedSlice(allocator);
    }
};

/// isValidCookieName reports whether name is a valid RFC 6265 token.
pub fn isValidCookieName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        if (!isValidTokenChar(c)) return false;
    }
    return true;
}

/// isValidCookieValue reports whether value conforms to RFC 6265 cookie-octet rules
/// (rejects semicolons, whitespace, and control characters to prevent header injection).
pub fn isValidCookieValue(val: []const u8) bool {
    for (val) |c| {
        if (c <= 0x20 or c == 0x7f or c == ';') return false;
    }
    return true;
}

test "Cookie format and attributes" {
    const allocator = std.testing.allocator;

    const c = Cookie{
        .name = "session_id",
        .value = "abc123xyz",
        .path = "/",
        .domain = "example.com",
        .expires = 784111777, // Sun, 06 Nov 1994 08:49:37 GMT
        .max_age = 3600,
        .http_only = true,
        .secure = true,
        .same_site = .strict,
        .partitioned = true,
    };

    const s = try c.format(allocator);
    defer allocator.free(s);
    try std.testing.expectEqualStrings("session_id=abc123xyz; Path=/; Domain=example.com; Expires=Sun, 06 Nov 1994 08:49:37 GMT; Max-Age=3600; HttpOnly; Secure; SameSite=Strict; Partitioned", s);
}

test "Cookie delete via max_age <= 0" {
    const allocator = std.testing.allocator;

    const c = Cookie{
        .name = "auth",
        .value = "",
        .max_age = -1,
    };

    const s = try c.format(allocator);
    defer allocator.free(s);
    try std.testing.expectEqualStrings("auth=; Max-Age=0", s);
}

test "CookieIterator parsing quoted and multiple entries" {
    const raw = "  id=12345; user=\"alice smith\"; token=abc_def; empty=; invalid ";
    var it = CookieIterator{ .raw = raw };

    const c1 = it.next().?;
    try std.testing.expectEqualStrings("id", c1.name);
    try std.testing.expectEqualStrings("12345", c1.value);

    const c2 = it.next().?;
    try std.testing.expectEqualStrings("user", c2.name);
    try std.testing.expectEqualStrings("alice smith", c2.value);

    const c3 = it.next().?;
    try std.testing.expectEqualStrings("token", c3.name);
    try std.testing.expectEqualStrings("abc_def", c3.value);

    const c4 = it.next().?;
    try std.testing.expectEqualStrings("empty", c4.name);
    try std.testing.expectEqualStrings("", c4.value);

    try std.testing.expectEqual(null, it.next());
}
