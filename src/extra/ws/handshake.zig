const std = @import("std");
const ResponseWriter = @import("../../response_writer.zig").ResponseWriter;
const Request = @import("../../request.zig").Request;

pub const MAGIC_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
pub const ACCEPT_LEN = std.base64.standard.Encoder.calcSize(std.crypto.hash.Sha1.digest_length);

pub const HandshakeError = error{
    InvalidMethod,
    MissingUpgradeHeader,
    InvalidUpgradeHeader,
    MissingConnectionHeader,
    InvalidConnectionHeader,
    MissingSecWebSocketKey,
    InvalidSecWebSocketKey,
    InvalidSecWebSocketVersion,
};

/// Computes the Sec-WebSocket-Accept value from client's Sec-WebSocket-Key
/// according to RFC 6455 Section 4.2.2.
pub fn computeAccept(key: []const u8, out: *[ACCEPT_LEN]u8) []const u8 {
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(key);
    hasher.update(MAGIC_GUID);
    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    hasher.final(&digest);
    return std.base64.standard.Encoder.encode(out, &digest);
}

/// Checks if a comma-separated header value contains a specific token (case-insensitive)
pub fn headerContainsToken(header_val: []const u8, token: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, header_val, ',');
    while (it.next()) |item| {
        const trimmed = std.mem.trim(u8, item, " \t");
        if (std.ascii.eqlIgnoreCase(trimmed, token)) return true;
    }
    return false;
}

/// Validates WebSocket upgrade request headers according to RFC 6455 Section 4.2.1.
/// Returns the client's Sec-WebSocket-Key string.
pub fn validateRequest(req: *Request) HandshakeError![]const u8 {
    if (req.method != .GET) return error.InvalidMethod;

    const upgrade = req.header("upgrade") orelse return error.MissingUpgradeHeader;
    if (!headerContainsToken(upgrade, "websocket")) {
        return error.InvalidUpgradeHeader;
    }

    const conn = req.header("connection") orelse return error.MissingConnectionHeader;
    if (!headerContainsToken(conn, "upgrade")) {
        return error.InvalidConnectionHeader;
    }

    if (req.header("sec-websocket-version")) |ver| {
        if (!std.mem.eql(u8, std.mem.trim(u8, ver, " \t"), "13")) {
            return error.InvalidSecWebSocketVersion;
        }
    } else {
        return error.InvalidSecWebSocketVersion;
    }

    const key = req.header("sec-websocket-key") orelse return error.MissingSecWebSocketKey;
    const trimmed_key = std.mem.trim(u8, key, " \t");
    if (trimmed_key.len == 0) return error.MissingSecWebSocketKey;

    // RFC 6455 Section 4.2.1: Key must be a base64-encoded 16-byte nonce (24 chars)
    if (trimmed_key.len != 24) return error.InvalidSecWebSocketKey;
    var decoded_buf: [16]u8 = undefined;
    std.base64.standard.Decoder.decode(&decoded_buf, trimmed_key) catch return error.InvalidSecWebSocketKey;

    return trimmed_key;
}

test "computeAccept matches RFC 6455 Section 1.3 test vector" {
    // RFC 6455 Section 1.3 canonical example:
    // Key: dGhlIHNhbXBsZSBub25jZQ==
    // Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=
    const key = "dGhlIHNhbXBsZSBub25jZQ==";
    var accept_buf: [ACCEPT_LEN]u8 = undefined;
    const accept = computeAccept(key, &accept_buf);
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", accept);
}
