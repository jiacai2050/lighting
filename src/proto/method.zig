//! HTTP request method definitions conforming to RFC 9110 Section 9.

const std = @import("std");

/// Method represents standard HTTP request methods.
pub const Method = enum {
    GET,
    HEAD,
    POST,
    PUT,
    PATCH,
    DELETE,
    CONNECT,
    OPTIONS,
    TRACE,

    /// parse parses a byte slice into a standard HTTP Method.
    /// Returns null if the method string is unrecognized or not supported.
    pub fn parse(s: []const u8) ?Method {
        if (std.mem.eql(u8, s, "GET")) return .GET;
        if (std.mem.eql(u8, s, "POST")) return .POST;
        if (std.mem.eql(u8, s, "PUT")) return .PUT;
        if (std.mem.eql(u8, s, "DELETE")) return .DELETE;
        if (std.mem.eql(u8, s, "HEAD")) return .HEAD;
        if (std.mem.eql(u8, s, "OPTIONS")) return .OPTIONS;
        if (std.mem.eql(u8, s, "PATCH")) return .PATCH;
        if (std.mem.eql(u8, s, "CONNECT")) return .CONNECT;
        if (std.mem.eql(u8, s, "TRACE")) return .TRACE;
        return null;
    }

    /// asString returns the uppercase string slice representation of the Method.
    pub fn asString(self: Method) []const u8 {
        return @tagName(self);
    }
};

test "Method parse" {
    try std.testing.expectEqual(Method.GET, Method.parse("GET").?);
    try std.testing.expectEqual(Method.POST, Method.parse("POST").?);
    try std.testing.expectEqual(null, Method.parse("INVALID"));
}
