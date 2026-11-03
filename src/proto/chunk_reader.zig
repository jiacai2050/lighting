const std = @import("std");
const io_util = @import("io_util.zig");
const isValidTokenChar = @import("../header.zig").isValidTokenChar;
const isValidHeaderValue = @import("../header.zig").isValidHeaderValue;

/// A stream body reader that supports fixed Content-Length reading
/// and handles reading out of the initial buffer first.
pub const BodyReader = struct {
    stream: std.Io.net.Stream,
    io: std.Io,
    unread_slice: []const u8,
    remaining_content_length: ?u64,
    is_chunked: bool,
    chunk_remaining: u64 = 0,
    chunk_done: bool = false,
    deadline: std.Io.Timeout = .none,

    pub fn init(
        stream: std.Io.net.Stream,
        io: std.Io,
        initial_unread: []const u8,
        content_length: ?u64,
        is_chunked: bool,
    ) BodyReader {
        return .{
            .stream = stream,
            .io = io,
            .unread_slice = initial_unread,
            .remaining_content_length = content_length,
            .is_chunked = is_chunked,
            .deadline = .none,
        };
    }

    pub fn setReadDeadline(self: *BodyReader, timeout_ns: ?u64) void {
        if (timeout_ns) |ns| {
            const dur = std.Io.Timeout{ .duration = .{ .raw = .{ .nanoseconds = @intCast(ns) }, .clock = .boot } };
            self.deadline = dur.toDeadline(self.io);
        } else {
            self.deadline = .none;
        }
    }

    pub fn setReadTimeout(self: *BodyReader, timeout_ns: ?u64) void {
        self.setReadDeadline(timeout_ns);
    }

    pub fn read(self: *BodyReader, dest: []u8) !usize {
        if (dest.len == 0) return 0;

        if (self.is_chunked) {
            return self.readChunked(dest);
        }

        if (self.remaining_content_length) |rem| {
            if (rem == 0) return 0; // EOF reached
            const to_read = @min(dest.len, @as(usize, @intCast(@min(rem, @as(u64, std.math.maxInt(usize))))));

            // First take from unread_slice if available
            if (self.unread_slice.len > 0) {
                const take = @min(self.unread_slice.len, to_read);
                @memcpy(dest[0..take], self.unread_slice[0..take]);
                self.unread_slice = self.unread_slice[take..];
                self.remaining_content_length.? -= take;
                return take;
            }

            // Otherwise read directly from socket with deadline
            const n = try io_util.readSocketWithTimeout(self.stream, self.io, dest[0..to_read], self.deadline);
            if (n == 0) return error.UnexpectedEOF; // premature EOF when expecting more content
            self.remaining_content_length.? -= n;
            return n;
        }

        // If no content length and not chunked, no body
        return 0;
    }

    fn readChunked(self: *BodyReader, dest: []u8) !usize {
        if (self.chunk_done) return 0;

        // If currently in a chunk, read from it
        if (self.chunk_remaining > 0) {
            const to_read = @min(dest.len, @as(usize, @intCast(@min(self.chunk_remaining, @as(u64, std.math.maxInt(usize))))));
            var n: usize = 0;
            if (self.unread_slice.len > 0) {
                n = @min(self.unread_slice.len, to_read);
                @memcpy(dest[0..n], self.unread_slice[0..n]);
                self.unread_slice = self.unread_slice[n..];
            } else {
                n = try io_util.readSocketWithTimeout(self.stream, self.io, dest[0..to_read], self.deadline);
                if (n == 0) return error.UnexpectedEOF;
            }
            self.chunk_remaining -= n;
            if (self.chunk_remaining == 0) {
                // Must consume trailing \r\n of the chunk
                try self.consumeExact("\r\n");
            }
            return n;
        }

        // Need to parse next chunk size: "<hex-len>\r\n"
        const chunk_sz = try self.readChunkSize();
        if (chunk_sz == 0) {
            self.chunk_done = true;
            var total_trailer_bytes: usize = 0;
            const max_trailer_bytes: usize = 16 * 1024;
            var trailer_buf: [1024]u8 = undefined;
            // Consume optional trailers until terminal empty line CRLF
            while (true) {
                const trailer_len = try self.readTrailerLine(&trailer_buf);
                if (trailer_len == 0) break;
                total_trailer_bytes += trailer_len + 2;
                if (total_trailer_bytes > max_trailer_bytes) return error.TrailerTooLarge;
            }
            return 0;
        }

        self.chunk_remaining = chunk_sz;
        return self.readChunked(dest);
    }

    fn readByte(self: *BodyReader) !u8 {
        if (self.unread_slice.len > 0) {
            const b = self.unread_slice[0];
            self.unread_slice = self.unread_slice[1..];
            return b;
        }
        var buf: [1]u8 = undefined;
        const n = try io_util.readSocketWithTimeout(self.stream, self.io, &buf, self.deadline);
        if (n == 0) return error.UnexpectedEOF;
        return buf[0];
    }

    fn readTrailerLine(self: *BodyReader, out_buf: []u8) !usize {
        var len: usize = 0;
        var cr_seen = false;
        while (len < out_buf.len) {
            const b = try self.readByte();
            if (b == '\n') {
                if (!cr_seen) return error.InvalidTrailerCRLF; // Bare LF is forbidden
                break;
            }
            if (b == '\r') {
                if (cr_seen) return error.InvalidTrailerCRLF; // Duplicate \r forbidden
                cr_seen = true;
                continue;
            }
            if (cr_seen) return error.InvalidTrailerCRLF;
            out_buf[len] = b;
            len += 1;
        }
        if (len == out_buf.len and !cr_seen) {
            // Buffer is full. Check if CRLF immediately follows (valid line of exactly out_buf.len bytes)
            const next_b = try self.readByte();
            if (next_b == '\r') {
                const next_lf = try self.readByte();
                if (next_lf != '\n') return error.InvalidTrailerCRLF;
            } else {
                return error.LineTooLong;
            }
        }

        if (len == 0) return 0; // Terminal empty line

        // Validate trailer field-line syntax (RFC 9112 Section 7.1.2)
        const colon_idx = std.mem.indexOfScalar(u8, out_buf[0..len], ':') orelse return error.InvalidTrailerHeader;
        const raw_name = out_buf[0..colon_idx];
        if (raw_name.len == 0) return error.InvalidTrailerHeader;
        if (raw_name[raw_name.len - 1] == ' ' or raw_name[raw_name.len - 1] == '\t') return error.InvalidTrailerHeader;
        for (raw_name) |c| {
            if (!isValidTokenChar(c)) return error.InvalidTrailerHeader;
        }

        // Validate trailer field-value characters (no control characters, obs-text and VCHAR only)
        const raw_val = out_buf[colon_idx + 1 .. len];
        if (!isValidHeaderValue(raw_val)) return error.InvalidTrailerHeader;

        // RFC 9110 Section 6.5.1: Forbidden trailer fields
        if (std.ascii.eqlIgnoreCase(raw_name, "transfer-encoding") or
            std.ascii.eqlIgnoreCase(raw_name, "content-length") or
            std.ascii.eqlIgnoreCase(raw_name, "host") or
            std.ascii.eqlIgnoreCase(raw_name, "trailer") or
            std.ascii.eqlIgnoreCase(raw_name, "authorization") or
            std.ascii.eqlIgnoreCase(raw_name, "set-cookie"))
        {
            return error.ForbiddenTrailerField;
        }

        return len;
    }

    fn consumeExact(self: *BodyReader, expected: []const u8) !void {
        for (expected) |exp_b| {
            const b = try self.readByte();
            if (b != exp_b) return error.InvalidChunk;
        }
    }

    fn readChunkSize(self: *BodyReader) !u64 {
        var line_buf: [64]u8 = undefined;
        var len: usize = 0;
        var cr_seen = false;
        while (len < line_buf.len) {
            const b = try self.readByte();
            if (b == '\n') {
                if (!cr_seen) return error.InvalidChunkCRLF; // Bare LF is forbidden
                break;
            }
            if (b == '\r') {
                if (cr_seen) return error.InvalidChunkCRLF; // Duplicate \r forbidden
                cr_seen = true;
                continue;
            }
            if (cr_seen) return error.InvalidChunkCRLF;
            line_buf[len] = b;
            len += 1;
        }
        if (len == line_buf.len and !cr_seen) {
            // Buffer is full. Check if CRLF immediately follows (valid line of exactly line_buf.len bytes)
            const next_b = try self.readByte();
            if (next_b == '\r') {
                const next_lf = try self.readByte();
                if (next_lf != '\n') return error.InvalidChunkCRLF;
            } else {
                return error.InvalidChunkSize;
            }
        }

        var hex_str = std.mem.trim(u8, line_buf[0..len], " \t");
        if (hex_str.len == 0) return error.InvalidChunkSize;
        // Support chunk extensions (e.g. "1a;extension=val")
        if (std.mem.indexOfScalar(u8, hex_str, ';')) |semi| {
            hex_str = std.mem.trim(u8, hex_str[0..semi], " \t");
        }
        return std.fmt.parseInt(u64, hex_str, 16) catch return error.InvalidChunkSize;
    }

    pub fn readAllAlloc(self: *BodyReader, allocator: std.mem.Allocator, max_size: usize) ![]u8 {
        if (self.remaining_content_length) |rem| {
            if (rem > max_size) return error.StreamTooLong;
        }

        var list = std.ArrayListUnmanaged(u8).empty;
        errdefer list.deinit(allocator);

        var buf: [4096]u8 = undefined;
        while (true) {
            const n = try self.read(&buf);
            if (n == 0) break;
            if (list.items.len + n > max_size) return error.StreamTooLong;
            try list.appendSlice(allocator, buf[0..n]);
        }
        return list.toOwnedSlice(allocator);
    }
};

test "BodyReader: rejects chunk size with bare LF" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const dummy_stream: std.Io.net.Stream = undefined;

    const raw = "5\nhello\r\n0\r\n\r\n";
    var reader = BodyReader.init(dummy_stream, io, raw, null, true);
    var buf: [16]u8 = undefined;
    try std.testing.expectError(error.InvalidChunkCRLF, reader.read(&buf));
}

test "BodyReader: parses valid chunked payload from initial buffer" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const dummy_stream: std.Io.net.Stream = undefined;

    const raw = "5\r\nhello\r\n0\r\n\r\n";
    var reader = BodyReader.init(dummy_stream, io, raw, null, true);
    var buf: [16]u8 = undefined;
    const n = try reader.read(&buf);
    try std.testing.expectEqual(@as(usize, 5), n);
    try std.testing.expectEqualStrings("hello", buf[0..n]);

    const eof = try reader.read(&buf);
    try std.testing.expectEqual(@as(usize, 0), eof);
}

test "BodyReader: returns UnexpectedEOF when content-length not satisfied" {
    const io = std.Io.Threaded.global_single_threaded.io();

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.socket.close(io);
    const listen_port = listener.socket.address.getPort();
    const connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", listen_port);

    const ClientThread = struct {
        fn run(target_addr: std.Io.net.IpAddress, io_ctx: std.Io) void {
            var client = target_addr.connect(io_ctx, .{ .mode = .stream }) catch return;
            defer client.close(io_ctx);
            // Declared 50 bytes, but send only 5 bytes then close
            var vec = [1][]const u8{"12345"};
            _ = io_ctx.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &vec } }) catch return;
        }
    };
    const t = try std.Thread.spawn(.{}, ClientThread.run, .{ connect_addr, io });
    defer t.join();

    var server_stream = try listener.accept(io);
    defer server_stream.close(io);

    // Initial unread is empty, expected content length is 50
    var reader = BodyReader.init(server_stream, io, "", 50, false);
    var buf: [100]u8 = undefined;

    // First read gets 5 bytes
    const n = try reader.read(&buf);
    try std.testing.expectEqual(@as(usize, 5), n);

    // Second read encounters client closed connection before 50 bytes satisfied -> MUST return error.UnexpectedEOF
    try std.testing.expectError(error.UnexpectedEOF, reader.read(&buf));
}

test "BodyReader: chunk trailer parsing and validation" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const dummy_stream: std.Io.net.Stream = undefined;

    // 1. Valid trailer succeeds
    {
        const raw = "5\r\nhello\r\n0\r\nX-Checksum: abc123\r\n\r\n";
        var reader = BodyReader.init(dummy_stream, io, raw, null, true);
        var buf: [16]u8 = undefined;
        const n = try reader.read(&buf);
        try std.testing.expectEqual(@as(usize, 5), n);
        const eof = try reader.read(&buf);
        try std.testing.expectEqual(@as(usize, 0), eof);
    }

    // 2. Bare LF in trailer is rejected
    {
        const raw = "5\r\nhello\r\n0\r\nX-Checksum: abc123\n\r\n";
        var reader = BodyReader.init(dummy_stream, io, raw, null, true);
        var buf: [16]u8 = undefined;
        _ = try reader.read(&buf);
        try std.testing.expectError(error.InvalidTrailerCRLF, reader.read(&buf));
    }

    // 3. Forbidden trailer Transfer-Encoding is rejected
    {
        const raw = "5\r\nhello\r\n0\r\nTransfer-Encoding: chunked\r\n\r\n";
        var reader = BodyReader.init(dummy_stream, io, raw, null, true);
        var buf: [16]u8 = undefined;
        _ = try reader.read(&buf);
        try std.testing.expectError(error.ForbiddenTrailerField, reader.read(&buf));
    }

    // 4. Forbidden trailer Content-Length is rejected
    {
        const raw = "5\r\nhello\r\n0\r\nContent-Length: 5\r\n\r\n";
        var reader = BodyReader.init(dummy_stream, io, raw, null, true);
        var buf: [16]u8 = undefined;
        _ = try reader.read(&buf);
        try std.testing.expectError(error.ForbiddenTrailerField, reader.read(&buf));
    }

    // 5. Space before colon is rejected (RFC 9112 Section 7.1.2 / 5.1)
    {
        const raw = "5\r\nhello\r\n0\r\nX-Header : bad\r\n\r\n";
        var reader = BodyReader.init(dummy_stream, io, raw, null, true);
        var buf: [16]u8 = undefined;
        _ = try reader.read(&buf);
        try std.testing.expectError(error.InvalidTrailerHeader, reader.read(&buf));
    }

    // 6. Duplicate \r in trailer line is rejected
    {
        const raw = "5\r\nhello\r\n0\r\nX-Checksum: abc123\r\r\n\r\n";
        var reader = BodyReader.init(dummy_stream, io, raw, null, true);
        var buf: [16]u8 = undefined;
        _ = try reader.read(&buf);
        try std.testing.expectError(error.InvalidTrailerCRLF, reader.read(&buf));
    }

    // 7. Control character in trailer value is rejected
    {
        const raw = "5\r\nhello\r\n0\r\nX-Checksum: bad\x01value\r\n\r\n";
        var reader = BodyReader.init(dummy_stream, io, raw, null, true);
        var buf: [16]u8 = undefined;
        _ = try reader.read(&buf);
        try std.testing.expectError(error.InvalidTrailerHeader, reader.read(&buf));
    }

    // 8. Duplicate \r in chunk size line is rejected
    {
        const raw = "5\r\r\nhello\r\n0\r\n\r\n";
        var reader = BodyReader.init(dummy_stream, io, raw, null, true);
        var buf: [16]u8 = undefined;
        try std.testing.expectError(error.InvalidChunkCRLF, reader.read(&buf));
    }
}
