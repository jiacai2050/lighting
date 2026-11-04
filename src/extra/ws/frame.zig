const std = @import("std");

pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
    _,

    pub fn isControl(self: Opcode) bool {
        return @backingInt(self) >= 0x8;
    }
};

pub const FrameHeader = struct {
    fin: bool,
    rsv1: bool = false,
    rsv2: bool = false,
    rsv3: bool = false,
    opcode: Opcode,
    masked: bool,
    payload_len: u64,
    mask_key: [4]u8 = [_]u8{ 0, 0, 0, 0 },
};

pub const FrameError = error{
    InvalidOpcode,
    ReservedBitsSet,
    FragmentedControlFrame,
    ControlFrameTooLarge,
    UnmaskedClientFrame,
    InvalidPayloadLength,
    PayloadTooLarge,
};

/// Unmasks or masks in-place using the 4-byte masking key
pub fn applyMask(data: []u8, mask_key: [4]u8) void {
    for (data, 0..) |*b, i| {
        b.* ^= mask_key[i % 4];
    }
}

/// Formats a server-to-client frame header into out_buf (unmasked, per RFC 6455 §5.1).
/// Returns the slice of out_buf that contains the serialized header.
pub fn formatServerHeader(out_buf: *[10]u8, opcode: Opcode, payload_len: usize, fin: bool) []const u8 {
    out_buf[0] = (if (fin) @as(u8, 0x80) else 0) | @backingInt(opcode);

    if (payload_len <= 125) {
        out_buf[1] = @intCast(payload_len);
        return out_buf[0..2];
    } else if (payload_len <= 0xFFFF) {
        out_buf[1] = 126;
        std.mem.writeInt(u16, out_buf[2..4], @intCast(payload_len), .big);
        return out_buf[0..4];
    } else {
        out_buf[1] = 127;
        std.mem.writeInt(u64, out_buf[2..10], @intCast(payload_len), .big);
        return out_buf[0..10];
    }
}

test "applyMask in-place XOR unmasking" {
    var payload = [_]u8{ 0x7f, 0x9f, 0x4d, 0x51, 0x58 };
    const mask_key = [_]u8{ 0x37, 0xfa, 0x21, 0x3d };
    // "Hello" ^ mask:
    // 'H' (0x48) ^ 0x37 = 0x7f
    // 'e' (0x65) ^ 0xfa = 0x9f
    // 'l' (0x6c) ^ 0x21 = 0x4d
    // 'l' (0x6c) ^ 0x3d = 0x51
    // 'o' (0x6f) ^ 0x37 = 0x58
    applyMask(&payload, mask_key);
    try std.testing.expectEqualStrings("Hello", &payload);
}

test "formatServerHeader short payload" {
    var buf: [10]u8 = undefined;
    const hdr = formatServerHeader(&buf, .text, 5, true);
    try std.testing.expectEqual(@as(usize, 2), hdr.len);
    try std.testing.expectEqual(@as(u8, 0x81), hdr[0]); // FIN + text
    try std.testing.expectEqual(@as(u8, 5), hdr[1]); // unmasked, len 5
}

test "formatServerHeader medium payload" {
    var buf: [10]u8 = undefined;
    const hdr = formatServerHeader(&buf, .binary, 300, true);
    try std.testing.expectEqual(@as(usize, 4), hdr.len);
    try std.testing.expectEqual(@as(u8, 0x82), hdr[0]); // FIN + binary
    try std.testing.expectEqual(@as(u8, 126), hdr[1]); // 16-bit indicator
    const len = std.mem.readInt(u16, hdr[2..4], .big);
    try std.testing.expectEqual(@as(u16, 300), len);
}

test "formatServerHeader large payload" {
    var buf: [10]u8 = undefined;
    const hdr = formatServerHeader(&buf, .binary, 70000, false);
    try std.testing.expectEqual(@as(usize, 10), hdr.len);
    try std.testing.expectEqual(@as(u8, 0x02), hdr[0]); // non-FIN + binary
    try std.testing.expectEqual(@as(u8, 127), hdr[1]); // 64-bit indicator
    const len = std.mem.readInt(u64, hdr[2..10], .big);
    try std.testing.expectEqual(@as(u64, 70000), len);
}
