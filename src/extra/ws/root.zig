const std = @import("std");
const ResponseWriter = @import("../../response_writer.zig").ResponseWriter;
const Request = @import("../../request.zig").Request;
const handshake = @import("handshake.zig");
const conn = @import("conn.zig");
const frame = @import("frame.zig");

pub const Conn = conn.Conn;
pub const Options = conn.Options;
pub const Message = conn.Message;
pub const MessageType = conn.MessageType;
pub const Opcode = frame.Opcode;
pub const FrameHeader = frame.FrameHeader;
pub const HandshakeError = handshake.HandshakeError;
pub const FrameError = frame.FrameError;

/// Upgrades an incoming HTTP request to a WebSocket connection per RFC 6455.
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
