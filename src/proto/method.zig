const std = @import("std");

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

    pub fn asString(self: Method) []const u8 {
        return @tagName(self);
    }
};

test "Method parse" {
    try std.testing.expectEqual(Method.GET, Method.parse("GET").?);
    try std.testing.expectEqual(Method.POST, Method.parse("POST").?);
    try std.testing.expectEqual(null, Method.parse("INVALID"));
}
