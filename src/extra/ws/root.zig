//! RFC 6455 compliant WebSocket implementation for lighting.

const std = @import("std");
const ResponseWriter = @import("../../response_writer.zig").ResponseWriter;
const Request = @import("../../request.zig").Request;
const handshake = @import("handshake.zig");
const conn = @import("conn.zig");
const frame = @import("frame.zig");

/// Active WebSocket connection wrapping a hijacked TCP socket stream.
pub const Conn = conn.Conn;

/// Configuration options for a WebSocket connection.
pub const Options = conn.Options;

/// Decoded incoming WebSocket message.
pub const Message = conn.Message;

/// Message payload type: Text (UTF-8) or Binary.
pub const MessageType = conn.MessageType;

/// WebSocket frame opcode.
pub const Opcode = frame.Opcode;

/// Parsed WebSocket frame header.
pub const FrameHeader = frame.FrameHeader;

/// Errors that can occur during the WebSocket handshake.
pub const HandshakeError = handshake.HandshakeError;

/// Errors that can occur during frame serialization or deserialization.
pub const FrameError = frame.FrameError;

/// upgrade upgrades an incoming HTTP request to a WebSocket connection per RFC 6455.
/// Validates handshake headers, sends 101 Switching Protocols, hijacks the underlying socket,
/// and returns an initialized WebSocket Conn.
pub fn upgrade(w: *ResponseWriter, req: *Request, options: Options) !Conn {
    const key = try handshake.validateRequest(req);

    var accept_buf: [handshake.ACCEPT_LEN]u8 = undefined;
    const accept = handshake.computeAccept(key, &accept_buf);
    const accept_dup = try req.arena.dupe(u8, accept);

    w.setStatus(.switching_protocols);
    try w.header().set("Upgrade", "websocket");
    try w.header().set("Connection", "Upgrade");
    try w.header().set("Sec-WebSocket-Accept", accept_dup);

    // Send the 101 Switching Protocols response headers before hijacking the socket
    try w.flushHeaders();

    const stream = try w.hijack();
    return Conn.init(stream, w.io, options);
}

test {
    std.testing.refAllDecls(@This());
}
