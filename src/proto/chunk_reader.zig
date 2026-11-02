const std = @import("std");
const io_util = @import("io_util.zig");

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
    read_timeout_ns: ?u64 = null,

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
            .read_timeout_ns = null,
        };
    }

    pub fn setReadTimeout(self: *BodyReader, timeout_ns: ?u64) void {
        self.read_timeout_ns = timeout_ns;
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

            // Otherwise read directly from socket with optional timeout
            const n = try io_util.readSocketTimeout(self.stream, self.io, dest[0..to_read], self.read_timeout_ns);
            if (n == 0) return 0; // unexpected EOF
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
                n = try io_util.readSocketTimeout(self.stream, self.io, dest[0..to_read], self.read_timeout_ns);
                if (n == 0) return 0;
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
            // Consume optional trailers until terminal empty line CRLF
            while (true) {
                const trailer_len = try self.readLine();
                if (trailer_len == 0) break;
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
        const n = try io_util.readSocketTimeout(self.stream, self.io, &buf, self.read_timeout_ns);
        if (n == 0) return error.EndOfStream;
        return buf[0];
    }

    fn readLine(self: *BodyReader) !usize {
        var len: usize = 0;
        while (true) {
            const b = try self.readByte();
            if (b == '\n') {
                return len;
            }
            if (b != '\r') {
                len += 1;
            }
            if (len > 4096) return error.LineTooLong;
        }
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
        var newline_seen = false;
        while (len < line_buf.len) {
            const b = try self.readByte();
            if (b == '\n') {
                newline_seen = true;
                if (len > 0 and line_buf[len - 1] == '\r') {
                    len -= 1;
                }
                break;
            }
            line_buf[len] = b;
            len += 1;
        }
        if (!newline_seen) return error.InvalidChunkSize;

        var hex_str = std.mem.trim(u8, line_buf[0..len], " \t");
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
