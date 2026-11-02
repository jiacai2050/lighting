const std = @import("std");
const Status = @import("proto/status.zig").Status;
const HeaderMap = @import("header.zig").HeaderMap;
const io_util = @import("proto/io_util.zig");

pub const ResponseWriter = struct {
    stream: std.Io.net.Stream,
    io: std.Io,
    arena: std.mem.Allocator,
    headers: HeaderMap,
    status_code: Status = .ok,
    header_written: bool = false,
    keep_alive: bool = true,
    is_head: bool = false,
    bytes_written: u64 = 0,
    write_timeout_ns: ?u64 = null,

    // Dual-mode buffering
    buffer: [4096]u8 = undefined,
    buffer_len: usize = 0,
    chunked_mode: bool = false,

    pub fn init(
        stream: std.Io.net.Stream,
        io: std.Io,
        arena: std.mem.Allocator,
        keep_alive: bool,
        is_head: bool,
    ) ResponseWriter {
        return .{
            .stream = stream,
            .io = io,
            .arena = arena,
            .headers = HeaderMap.init(arena),
            .keep_alive = keep_alive,
            .is_head = is_head,
            .bytes_written = 0,
            .write_timeout_ns = null,
        };
    }

    pub fn allowsBody(status: Status) bool {
        const code = status.code();
        if (code >= 100 and code < 200) return false;
        if (code == 204 or code == 304) return false;
        return true;
    }

    pub fn setWriteTimeout(self: *ResponseWriter, timeout_ns: ?u64) void {
        self.write_timeout_ns = timeout_ns;
    }

    pub fn header(self: *ResponseWriter) *HeaderMap {
        return &self.headers;
    }

    pub fn writeHeader(self: *ResponseWriter, status: Status) void {
        if (!self.header_written) {
            self.status_code = status;
        }
    }

    pub fn setStatus(self: *ResponseWriter, status: Status) void {
        self.writeHeader(status);
    }

    /// Appends data to internal buffer or flushes chunked
    pub fn write(self: *ResponseWriter, data: []const u8) !usize {
        if (data.len == 0) return 0;

        // 1. If status does not allow a body (204, 304, 1xx), suppress body completely (RFC 9110)
        if (!allowsBody(self.status_code)) {
            return data.len;
        }

        // 2. If HEAD request, suppress body completely, but count bytes for Content-Length (RFC 9110)
        if (self.is_head) {
            self.bytes_written += data.len;
            return data.len;
        }

        // 3. Finding 10: Check against explicit user-specified Content-Length
        if (self.headers.get("content-length")) |cl_str| {
            if (std.fmt.parseInt(u64, cl_str, 10)) |cl| {
                if (self.bytes_written + self.buffer_len + data.len > cl) {
                    return error.ContentLengthExceeded;
                }
            } else |_| {}
        }

        // If headers not yet written and data fits in buffer: buffer it!
        if (!self.header_written and (self.buffer_len + data.len <= self.buffer.len)) {
            @memcpy(self.buffer[self.buffer_len .. self.buffer_len + data.len], data);
            self.buffer_len += data.len;
            return data.len;
        }

        // Buffer full or headers already written
        if (!self.header_written) {
            // Need to flush headers. Since data didn't fit, check if user provided Content-Length
            if (self.headers.get("content-length") == null) {
                // Fallback to Chunked mode!
                self.chunked_mode = true;
                try self.headers.set("Transfer-Encoding", "chunked");
            }
            try self.flushHeaders();
        }

        if (self.chunked_mode) {
            // First flush any buffered data as a chunk
            if (self.buffer_len > 0) {
                try self.writeChunk(self.buffer[0..self.buffer_len]);
                self.bytes_written += self.buffer_len;
                self.buffer_len = 0;
            }
            // Then write this data as a chunk
            try self.writeChunk(data);
            self.bytes_written += data.len;
        } else {
            // Direct write
            if (self.buffer_len > 0) {
                var vec = [1][]const u8{self.buffer[0..self.buffer_len]};
                try io_util.writeSocketAllTimeout(self.stream, self.io, &vec, self.write_timeout_ns);
                self.bytes_written += self.buffer_len;
                self.buffer_len = 0;
            }
            var vec = [1][]const u8{data};
            try io_util.writeSocketAllTimeout(self.stream, self.io, &vec, self.write_timeout_ns);
            self.bytes_written += data.len;
        }

        return data.len;
    }

    pub fn writeAll(self: *ResponseWriter, data: []const u8) !void {
        _ = try self.write(data);
    }

    /// Internal helper to write a chunk: <hex_size>\r\n<data>\r\n
    fn writeChunk(self: *ResponseWriter, data: []const u8) !void {
        if (data.len == 0) return;
        var size_buf: [32]u8 = undefined;
        const size_str = std.fmt.bufPrint(&size_buf, "{x}\r\n", .{data.len}) catch unreachable;

        var vecs = [3][]const u8{ size_str, data, "\r\n" };
        try io_util.writeSocketAllTimeout(self.stream, self.io, &vecs, self.write_timeout_ns);
    }

    fn flushHeaders(self: *ResponseWriter) !void {
        if (self.header_written) return;
        self.header_written = true;

        // Ensure Date header or Connection header
        if (!self.keep_alive and self.headers.get("connection") == null) {
            try self.headers.set("Connection", "close");
        } else if (self.keep_alive and self.headers.get("connection") == null) {
            try self.headers.set("Connection", "keep-alive");
        }

        // If status or method forbids a body, ensure no buffer is emitted
        if (!allowsBody(self.status_code) or self.is_head) {
            self.buffer_len = 0;
        }

        // Format Status Line: "HTTP/1.1 200 OK\r\n"
        var line_buf: [64]u8 = undefined;
        const status_line = std.fmt.bufPrint(&line_buf, "HTTP/1.1 {d} {s}\r\n", .{
            self.status_code.code(),
            self.status_code.phrase(),
        }) catch unreachable;

        // Optimization: Zero-allocation stack buffer for response slices
        var stack_vecs: [64][]const u8 = undefined;
        var vec_count: usize = 0;

        const max_required = 1 + (self.headers.entries.items.len * 4) + 1 + 1;
        if (max_required <= stack_vecs.len) {
            stack_vecs[vec_count] = status_line;
            vec_count += 1;

            for (self.headers.entries.items) |entry| {
                stack_vecs[vec_count] = entry.name;
                stack_vecs[vec_count + 1] = ": ";
                stack_vecs[vec_count + 2] = entry.value;
                stack_vecs[vec_count + 3] = "\r\n";
                vec_count += 4;
            }
            stack_vecs[vec_count] = "\r\n";
            vec_count += 1;

            if (self.buffer_len > 0) {
                stack_vecs[vec_count] = self.buffer[0..self.buffer_len];
                vec_count += 1;
                self.bytes_written += self.buffer_len;
                self.buffer_len = 0;
            }

            try io_util.writeSocketAllTimeout(self.stream, self.io, stack_vecs[0..vec_count], self.write_timeout_ns);
        } else {
            // Fallback for unusually large header lists
            var vecs = std.ArrayListUnmanaged([]const u8).empty;
            defer vecs.deinit(self.arena);

            try vecs.append(self.arena, status_line);
            for (self.headers.entries.items) |entry| {
                try vecs.append(self.arena, entry.name);
                try vecs.append(self.arena, ": ");
                try vecs.append(self.arena, entry.value);
                try vecs.append(self.arena, "\r\n");
            }
            try vecs.append(self.arena, "\r\n");

            if (self.buffer_len > 0) {
                try vecs.append(self.arena, self.buffer[0..self.buffer_len]);
                self.bytes_written += self.buffer_len;
                self.buffer_len = 0;
            }

            try io_util.writeSocketAllTimeout(self.stream, self.io, vecs.items, self.write_timeout_ns);
        }
    }

    /// Called at the end of the request handler execution
    pub fn finish(self: *ResponseWriter) !void {
        const body_allowed = allowsBody(self.status_code);

        if (!self.header_written) {
            // Response fit completely inside buffer or is HEAD / 204
            if (!body_allowed) {
                self.buffer_len = 0;
            } else if (self.is_head) {
                if (self.headers.get("content-length") == null) {
                    var len_buf: [32]u8 = undefined;
                    const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{self.bytes_written}) catch unreachable;
                    const len_dup = try self.arena.dupe(u8, len_str);
                    try self.headers.set("Content-Length", len_dup);
                }
                self.buffer_len = 0;
            } else {
                if (self.headers.get("content-length") == null) {
                    var len_buf: [32]u8 = undefined;
                    const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{self.buffer_len}) catch unreachable;
                    const len_dup = try self.arena.dupe(u8, len_str);
                    try self.headers.set("Content-Length", len_dup);
                }
            }
            try self.flushHeaders();
        } else {
            // Headers were already flushed
            if (!body_allowed or self.is_head) {
                self.buffer_len = 0;
                return;
            }

            if (self.chunked_mode) {
                // If there is residual data in buffer
                if (self.buffer_len > 0) {
                    try self.writeChunk(self.buffer[0..self.buffer_len]);
                    self.bytes_written += self.buffer_len;
                    self.buffer_len = 0;
                }
                // Send terminal 0\r\n\r\n chunk
                var final_vec = [1][]const u8{"0\r\n\r\n"};
                try io_util.writeSocketAllTimeout(self.stream, self.io, &final_vec, self.write_timeout_ns);
            } else {
                if (self.buffer_len > 0) {
                    var vec = [1][]const u8{self.buffer[0..self.buffer_len]};
                    try io_util.writeSocketAllTimeout(self.stream, self.io, &vec, self.write_timeout_ns);
                    self.bytes_written += self.buffer_len;
                    self.buffer_len = 0;
                }
            }
        }

        // Finding 10: Check if actual written was less than user-specified Content-Length
        if (body_allowed and !self.is_head and !self.chunked_mode) {
            if (self.headers.get("content-length")) |cl_str| {
                if (std.fmt.parseInt(u64, cl_str, 10)) |cl| {
                    if (self.bytes_written < cl) {
                        // Body truncated by handler; close connection to prevent desynchronization
                        self.keep_alive = false;
                    }
                } else |_| {}
            }
        }
    }

    /// Provides std.io.AnyWriter interface
    pub fn writer(self: *ResponseWriter) Writer {
        return .{ .context = self };
    }

    pub const Writer = struct {
        context: *ResponseWriter,

        pub const Error = anyerror;

        pub fn write(w: Writer, bytes: []const u8) Error!usize {
            return w.context.write(bytes);
        }

        pub fn writeAll(w: Writer, bytes: []const u8) Error!void {
            return w.context.writeAll(bytes);
        }

        pub fn print(w: Writer, comptime format: []const u8, args: anytype) Error!void {
            var buf: [2048]u8 = undefined;
            const s = try std.fmt.bufPrint(&buf, format, args);
            try w.context.writeAll(s);
        }
    };
};
