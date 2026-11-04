const std = @import("std");
const io_util = @import("../../proto/io_util.zig");
const frame = @import("frame.zig");
const Opcode = frame.Opcode;

pub const MessageType = enum {
    text,
    binary,
    close,
};

/// WebSocket application message.
/// The caller is responsible for freeing `payload` using the allocator passed to `readMessage()`.
pub const Message = struct {
    type: MessageType,
    payload: []const u8,
};

pub const Options = struct {
    max_message_size: usize = 16 * 1024 * 1024, // 16 MB default limit
    read_timeout_ns: ?u64 = null,
    write_timeout_ns: ?u64 = null,
};

pub const Conn = struct {
    stream: std.Io.net.Stream,
    io: std.Io,
    options: Options,
    closed: bool = false,

    pub fn init(stream: std.Io.net.Stream, io: std.Io, options: Options) Conn {
        return .{
            .stream = stream,
            .io = io,
            .options = options,
        };
    }

    /// Reads exactly dest.len bytes from the socket or errors.
    fn readExact(self: *Conn, dest: []u8) !void {
        var total: usize = 0;
        while (total < dest.len) {
            const n = try io_util.readSocketTimeout(self.stream, self.io, dest[total..], self.options.read_timeout_ns);
            if (n == 0) return error.ConnectionClosed;
            total += n;
        }
    }

    /// Reads the next full application message from the client.
    /// Handles Ping/Pong automatically.
    /// The caller is responsible for freeing `Message.payload` using `allocator`.
    /// Returns null when the connection is closed.
    pub fn readMessage(self: *Conn, allocator: std.mem.Allocator) !?Message {
        var message_type: ?MessageType = null;
        var accumulated: std.ArrayList(u8) = std.ArrayList(u8).empty;
        defer accumulated.deinit(allocator);

        while (!self.closed) {
            var hdr_buf: [2]u8 = undefined;
            self.readExact(&hdr_buf) catch |err| switch (err) {
                error.ConnectionClosed => return null,
                else => return err,
            };

            const b0 = hdr_buf[0];
            const b1 = hdr_buf[1];

            const fin = (b0 & 0x80) != 0;
            const rsv = (b0 & 0x70) != 0;
            if (rsv) return error.ReservedBitsSet;

            const opcode_raw = @as(u4, @truncate(b0 & 0x0F));
            const opcode: Opcode = @fromBackingInt(@intCast(opcode_raw));
            switch (opcode) {
                .continuation, .text, .binary, .close, .ping, .pong => {},
                _ => return error.InvalidOpcode,
            }

            const masked = (b1 & 0x80) != 0;
            if (!masked) return error.UnmaskedClientFrame;

            const len7 = @as(u7, @truncate(b1 & 0x7F));
            var payload_len: u64 = len7;
            if (len7 == 126) {
                var len_buf: [2]u8 = undefined;
                try self.readExact(&len_buf);
                payload_len = std.mem.readInt(u16, &len_buf, .big);
                if (payload_len < 126) return error.NonMinimalPayloadLength;
            } else if (len7 == 127) {
                var len_buf: [8]u8 = undefined;
                try self.readExact(&len_buf);
                payload_len = std.mem.readInt(u64, &len_buf, .big);
                if ((payload_len & 0x8000000000000000) != 0) return error.InvalidPayloadLength;
                if (payload_len < 0x10000) return error.NonMinimalPayloadLength;
            }

            // Enforce cumulative message size limit across fragmented data frames (N1)
            if (!opcode.isControl() and accumulated.items.len + payload_len > self.options.max_message_size) return error.MessageTooLarge;

            if (opcode.isControl()) {
                if (!fin) return error.FragmentedControlFrame;
                if (payload_len > 125) return error.ControlFrameTooLarge;
            }

            // Read 4-byte mask key
            var mask_key: [4]u8 = undefined;
            try self.readExact(&mask_key);

            // Read payload
            const payload = try allocator.alloc(u8, @intCast(payload_len));
            defer allocator.free(payload);
            try self.readExact(payload);

            // Unmask payload in-place
            frame.applyMask(payload, mask_key);

            // Handle control frames
            switch (opcode) {
                .ping => {
                    // RFC 6455 Section 5.5.3: MUST send a Pong in response to a Ping
                    try self.writeFrame(.pong, payload);
                    continue;
                },
                .pong => {
                    // RFC 6455 Section 5.5.3: Unsolicited or solicited Pong, drop silently
                    continue;
                },
                .close => {
                    // RFC 6455 Section 5.5.1: 1-byte payload is illegal
                    if (payload.len == 1) return error.InvalidClosePayload;
                    var echo_code: ?u16 = null;
                    if (payload.len >= 2) {
                        const code = std.mem.readInt(u16, payload[0..2], .big);
                        // RFC 6455 Section 7.4.1: Reserved codes must not appear on wire
                        if (code < 1000 or (code >= 1004 and code <= 1006) or (code >= 1014 and code <= 2999) or code >= 5000) {
                            return error.InvalidCloseCode;
                        }
                        if (!std.unicode.utf8ValidateSlice(payload[2..])) {
                            return error.InvalidCloseReason;
                        }
                        echo_code = code;
                    }
                    // Echo back close frame if not already closed
                    self.writeClose(echo_code, null) catch {};
                    self.closed = true;
                    return Message{
                        .type = .close,
                        .payload = try allocator.dupe(u8, payload),
                    };
                },
                .text => {
                    if (message_type != null) return error.UnexpectedTextFrame;
                    message_type = .text;
                    try accumulated.appendSlice(allocator, payload);
                    if (fin) {
                        if (!std.unicode.utf8ValidateSlice(accumulated.items)) return error.InvalidUtf8;
                        return Message{
                            .type = .text,
                            .payload = try accumulated.toOwnedSlice(allocator),
                        };
                    }
                },
                .binary => {
                    if (message_type != null) return error.UnexpectedBinaryFrame;
                    message_type = .binary;
                    try accumulated.appendSlice(allocator, payload);
                    if (fin) {
                        return Message{
                            .type = .binary,
                            .payload = try accumulated.toOwnedSlice(allocator),
                        };
                    }
                },
                .continuation => {
                    if (message_type == null) return error.UnexpectedContinuationFrame;
                    try accumulated.appendSlice(allocator, payload);
                    if (fin) {
                        if (message_type.? == .text and !std.unicode.utf8ValidateSlice(accumulated.items)) {
                            return error.InvalidUtf8;
                        }
                        return Message{
                            .type = message_type.?,
                            .payload = try accumulated.toOwnedSlice(allocator),
                        };
                    }
                },
                _ => return error.InvalidOpcode,
            }
        }

        return null;
    }

    /// Writes a single unfragmented WebSocket frame to the client.
    pub fn writeFrame(self: *Conn, opcode: Opcode, payload: []const u8) !void {
        if (self.closed) return error.ConnectionClosed;
        if (opcode.isControl() and payload.len > 125) return error.ControlFrameTooLarge;
        var hdr_buf: [10]u8 = undefined;
        const hdr = frame.formatServerHeader(&hdr_buf, opcode, payload.len, true);
        var vecs = [2][]const u8{ hdr, payload };
        try io_util.writeSocketAllTimeout(self.stream, self.io, &vecs, self.options.write_timeout_ns);
    }

    /// Sends a UTF-8 text message.
    pub fn writeText(self: *Conn, text: []const u8) !void {
        return self.writeFrame(.text, text);
    }

    /// Sends a binary message.
    pub fn writeBinary(self: *Conn, data: []const u8) !void {
        return self.writeFrame(.binary, data);
    }

    /// Sends a Ping control frame.
    pub fn writePing(self: *Conn, data: []const u8) !void {
        if (data.len > 125) return error.ControlFrameTooLarge;
        return self.writeFrame(.ping, data);
    }

    /// Sends a Pong control frame.
    pub fn writePong(self: *Conn, data: []const u8) !void {
        if (data.len > 125) return error.ControlFrameTooLarge;
        return self.writeFrame(.pong, data);
    }

    /// Sends a Close control frame with optional status code and reason string.
    pub fn writeClose(self: *Conn, code: ?u16, reason: ?[]const u8) !void {
        if (self.closed) return;
        var close_buf: [127]u8 = undefined;
        var payload_len: usize = 0;
        if (code) |c| {
            std.mem.writeInt(u16, close_buf[0..2], c, .big);
            payload_len = 2;
            if (reason) |r| {
                var copy_len = @min(r.len, close_buf.len - 2);
                while (copy_len > 0 and (r[copy_len - 1] & 0xC0) == 0x80) {
                    copy_len -= 1;
                }
                @memcpy(close_buf[2 .. 2 + copy_len], r[0..copy_len]);
                payload_len += copy_len;
            }
        }
        self.writeFrame(.close, close_buf[0..payload_len]) catch {};
    }

    /// Closes the underlying network stream.
    pub fn close(self: *Conn) void {
        if (self.closed) return;
        self.closed = true;
        self.stream.close(self.io);
    }
};
