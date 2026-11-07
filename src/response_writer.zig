//! HTTP response generation implementing dual-mode buffering, RFC 9110/9112 framing, and socket hijacking.

const std = @import("std");
const assert = std.debug.assert;
const Status = @import("proto/status.zig").Status;
const HeaderMap = @import("header.zig").HeaderMap;
const io_util = @import("proto/io_util.zig");
const Version = @import("proto/parser.zig").Version;
const Cookie = @import("cookie.zig").Cookie;

/// ResponseWriter coordinates writing an HTTP response back to the client.
///
/// It features dual-mode buffering: small responses (< 4KB) are buffered in memory to automatically
/// determine and emit a `Content-Length` header without chunking. Larger responses or explicit calls to `flush()`
/// automatically transition to RFC 9112 `Transfer-Encoding: chunked` streaming.
///
/// It also supports full socket hijacking (e.g. for WebSockets and SSE).
pub const ResponseWriter = struct {
    stream: std.Io.net.Stream,
    io: std.Io,
    arena: std.mem.Allocator,
    headers: HeaderMap,
    status_code: Status = .ok,
    header_written: bool = false,
    version: Version = .@"HTTP/1.1",
    keep_alive: bool = true,
    is_head: bool = false,
    bytes_written: u64 = 0,
    write_timeout_ns: ?u64 = null,
    hijacked: bool = false,

    // Dual-mode buffering
    buffer: [4096]u8 = undefined,
    buffer_len: usize = 0,
    chunked_mode: bool = false,

    // Lifecycle hook triggered immediately when socket is hijacked
    on_hijack: ?*const fn (*anyopaque) void = null,
    on_hijack_ctx: ?*anyopaque = null,

    comptime {
        assert(@sizeOf(ResponseWriter) <= 8192);
    }

    /// init initializes a ResponseWriter for an incoming connection cycle.
    pub fn init(
        stream: std.Io.net.Stream,
        io: std.Io,
        arena: std.mem.Allocator,
        version: Version,
        keep_alive: bool,
        is_head: bool,
    ) ResponseWriter {
        return .{
            .stream = stream,
            .io = io,
            .arena = arena,
            .headers = HeaderMap.init(arena),
            .version = version,
            .keep_alive = keep_alive,
            .is_head = is_head,
            .bytes_written = 0,
            .write_timeout_ns = null,
        };
    }

    /// allowsBody reports whether the given HTTP status allows a message body per RFC 9110 Section 6.4.1.
    pub fn allowsBody(status: Status) bool {
        const code = status.code();
        if (code >= 100 and code < 200) return false;
        if (code == 204 or code == 205 or code == 304) return false;
        return true;
    }

    /// formatHttpDate formats a Unix epoch timestamp (seconds) into standard RFC 9110 IMF-fixdate format:
    /// "Sun, 06 Nov 1994 08:49:37 GMT" (exactly 29 bytes).
    pub fn formatHttpDate(buf: *[29]u8, ts: i64) []const u8 {
        const epoch_sec = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(0, ts)) };
        const day_secs = epoch_sec.getDaySeconds();
        const epoch_day = epoch_sec.getEpochDay();
        const year_day = epoch_day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();

        // 1970-01-01 was Thursday (index 4 with 0=Sun)
        const day_of_week = @mod(epoch_day.day + 4, 7);
        const day_names = [7][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
        const month_names = [12][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

        const dow = day_names[day_of_week];
        const mon = month_names[month_day.month.numeric() - 1];
        const day = month_day.day_index + 1;
        const year = year_day.year;
        const hour = day_secs.getHoursIntoDay();
        const min = day_secs.getMinutesIntoHour();
        const sec = day_secs.getSecondsIntoMinute();

        return std.fmt.bufPrint(buf, "{s}, {:0>2} {s} {:0>4} {:0>2}:{:0>2}:{:0>2} GMT", .{
            dow, day, mon, year, hour, min, sec,
        }) catch unreachable;
    }

    /// setWriteTimeout sets the nanosecond timeout duration for socket write operations.
    pub fn setWriteTimeout(self: *ResponseWriter, timeout_ns: ?u64) void {
        self.write_timeout_ns = timeout_ns;
    }

    /// header returns the HeaderMap of response headers to be sent to the client.
    pub fn header(self: *ResponseWriter) *HeaderMap {
        return &self.headers;
    }

    /// writeHeader sets the HTTP response status code.
    /// Subsequent calls to writeHeader or setStatus have no effect if headers have already been sent.
    pub fn writeHeader(self: *ResponseWriter, status: Status) void {
        if (!self.header_written) {
            self.status_code = status;
        }
    }

    /// setStatus is an alias for writeHeader.
    pub fn setStatus(self: *ResponseWriter, status: Status) void {
        self.writeHeader(status);
    }

    /// setCookie serializes cookie into RFC 6265 Set-Cookie format and appends it to the response headers.
    pub fn setCookie(self: *ResponseWriter, cookie: Cookie) !void {
        const cookie_str = try cookie.format(self.arena);
        try self.headers.add("Set-Cookie", cookie_str);
    }

    /// write writes a slice of data into the HTTP response body.
    ///
    /// Data is buffered in memory up to 4KB; once exceeded or flushed,
    /// headers are emitted and subsequent writes are streamed via chunked transfer coding.
    pub fn write(self: *ResponseWriter, data: []const u8) !usize {
        assert(self.buffer_len <= self.buffer.len);
        if (self.hijacked) return error.AlreadyHijacked;
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

        // Check against explicit user-specified Content-Length
        if (self.headers.get("content-length")) |cl_str| {
            const cl = std.fmt.parseInt(u64, cl_str, 10) catch {
                return error.InvalidContentLength;
            };
            if (self.bytes_written + self.buffer_len + data.len > cl) {
                return error.ContentLengthExceeded;
            }
        }

        // Check if user requested Transfer-Encoding: chunked
        if (self.headers.get("transfer-encoding")) |te| {
            if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, te, " \t"), "chunked")) {
                if (self.version == .@"HTTP/1.1") {
                    self.chunked_mode = true;
                }
            } else {
                return error.UnsupportedTransferEncoding;
            }
        }

        // If headers not yet written and data fits in buffer: buffer it! (unless chunked_mode explicitly forced)
        if (!self.chunked_mode and !self.header_written and (self.buffer_len + data.len <= self.buffer.len)) {
            @memcpy(self.buffer[self.buffer_len .. self.buffer_len + data.len], data);
            self.buffer_len += data.len;
            return data.len;
        }

        // Buffer full or headers already written
        try self.ensureHeadersWritten();
        try self.flushBuffer();

        if (self.chunked_mode) {
            try self.writeChunk(data);
            self.bytes_written += data.len;
        } else {
            var vec = [1][]const u8{data};
            try io_util.writeSocketAllTimeout(self.stream, self.io, &vec, self.write_timeout_ns);
            self.bytes_written += data.len;
        }

        return data.len;
    }

    /// writeAll writes the entire data slice into the response body.
    pub fn writeAll(self: *ResponseWriter, data: []const u8) !void {
        _ = try self.write(data);
    }

    /// Ensures status line and headers are written to the socket.
    /// If Transfer-Encoding or Content-Length are not explicitly established, defaults to chunked for HTTP/1.1.
    fn ensureHeadersWritten(self: *ResponseWriter) !void {
        if (self.header_written) return;

        // Check if user requested Transfer-Encoding
        if (self.headers.get("transfer-encoding")) |te| {
            if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, te, " \t"), "chunked")) {
                if (self.version == .@"HTTP/1.1") {
                    self.chunked_mode = true;
                }
            } else {
                return error.UnsupportedTransferEncoding;
            }
        }

        // If user did not provide explicit Content-Length, transition to chunked mode in HTTP/1.1
        if (self.headers.get("content-length") == null) {
            if (self.version == .@"HTTP/1.1") {
                self.chunked_mode = true;
                try self.headers.set("Transfer-Encoding", "chunked");
            } else {
                self.chunked_mode = false;
                self.keep_alive = false;
            }
        }

        try self.flushHeaders();
    }

    /// Flushes any pending buffered data in `self.buffer` out to the socket.
    fn flushBuffer(self: *ResponseWriter) !void {
        if (self.buffer_len == 0) return;
        if (self.chunked_mode) {
            try self.writeChunk(self.buffer[0..self.buffer_len]);
        } else {
            var vec = [1][]const u8{self.buffer[0..self.buffer_len]};
            try io_util.writeSocketAllTimeout(self.stream, self.io, &vec, self.write_timeout_ns);
        }
        self.bytes_written += self.buffer_len;
        self.buffer_len = 0;
    }

    /// Flushes buffered data to the client immediately.
    /// If headers have not been written yet, they are flushed now.
    /// If Content-Length was not set, this transitions to chunked transfer encoding (in HTTP/1.1).
    pub fn flush(self: *ResponseWriter) !void {
        if (self.hijacked) return error.AlreadyHijacked;
        if (!allowsBody(self.status_code) or self.is_head) return;

        try self.ensureHeadersWritten();
        try self.flushBuffer();
    }

    /// Hijacks the underlying connection, transferring ownership of the stream to the caller.
    /// Any response data previously buffered in memory is flushed before returning the stream.
    /// If an error occurs during flushing, the stream is not hijacked but partial bytes may have
    /// already been written to the wire.
    ///
    /// Framing: If `Content-Length` was not set, the flushed prefix is framed as `Transfer-Encoding: chunked`
    /// without a terminal chunk (`0\r\n\r\n`). Handlers should set `Content-Length` first, or hijack before
    /// writing, for clean protocol framing.
    ///
    /// Lifecycle: On hijack the server unregisters the connection from shutdown
    /// tracking; `Server.shutdown()` will no longer close or reset the socket directly.
    ///
    /// NOTE: Any trailing request bytes already read ahead by the server's connection buffer
    /// (e.g. client early data or pipelined frames sent prior to the upgrade response) are not
    /// forwarded. Callers should ensure protocols use request-response handshakes where the client
    /// waits for the upgrade acknowledgement before sending frames.
    pub fn hijack(self: *ResponseWriter) !std.Io.net.Stream {
        if (self.hijacked) return error.AlreadyHijacked;
        // If data was buffered in memory prior to hijacking, flush it out now so the client
        // receives any handshake bytes sent via ResponseWriter before socket takeover.
        if (self.buffer_len > 0) {
            try self.flush();
            if (self.buffer_len > 0) return error.CannotFlushBuffer;
        }
        if (self.on_hijack) |cb| {
            if (self.on_hijack_ctx) |ctx| {
                cb(ctx);
            }
            self.on_hijack = null;
        }
        self.hijacked = true;
        return self.stream;
    }

    /// Internal helper to write a chunk: <hex_size>\r\n<data>\r\n
    fn writeChunk(self: *ResponseWriter, data: []const u8) !void {
        if (data.len == 0) return;
        var size_buf: [32]u8 = undefined;
        const size_str = std.fmt.bufPrint(&size_buf, "{x}\r\n", .{data.len}) catch unreachable;

        var vecs = [3][]const u8{ size_str, data, "\r\n" };
        try io_util.writeSocketAllTimeout(self.stream, self.io, &vecs, self.write_timeout_ns);
    }

    /// Flushes the HTTP response status line and headers out to the wire immediately.
    ///
    /// NOTE: This method writes raw headers without computing Content-Length or transitioning
    /// to chunked transfer encoding. It is intended for status codes that forbid bodies
    /// (e.g. 101 Switching Protocols, 204 No Content) or custom upgrade handshakes before hijack.
    /// For responses with body data, use write()/writeAll() or flush().
    pub fn flushHeaders(self: *ResponseWriter) !void {
        if (self.header_written) return;

        // RFC 9110 Section 6.6.1: Date header MUST be sent by origin server
        if (self.headers.get("date") == null) {
            var date_buf: [29]u8 = undefined;
            const now_ts = std.Io.Clock.real.now(self.io).toSeconds();
            const date_str = formatHttpDate(&date_buf, now_ts);
            const date_dup = try self.arena.dupe(u8, date_str);
            try self.headers.set("Date", date_dup);
        }

        // Ensure Connection header
        if (!self.keep_alive and self.headers.get("connection") == null) {
            try self.headers.set("Connection", "close");
        } else if (self.keep_alive and self.headers.get("connection") == null) {
            try self.headers.set("Connection", "keep-alive");
        }

        // If status or method forbids a body, ensure no buffer is emitted
        if (!allowsBody(self.status_code) or self.is_head) {
            self.buffer_len = 0;
        }

        // Validate user-specified Content-Length
        if (self.headers.get("content-length")) |cl_str| {
            _ = std.fmt.parseInt(u64, cl_str, 10) catch {
                return error.InvalidContentLength;
            };
        }

        // RFC 9110 Section 8.6 & 6.4.1 & RFC 9112 Section 6.1:
        // 1xx, 204, 304 must NOT include Content-Length or Transfer-Encoding (strip even if user set them)
        // 205 MUST NOT include a body; Content-Length if present must be 0, no chunked
        const code = self.status_code.code();
        if ((code >= 100 and code < 200) or code == 204 or code == 304) {
            self.headers.delete("Content-Length");
            self.headers.delete("Transfer-Encoding");
            self.chunked_mode = false;
        } else if (code == 205) {
            self.headers.delete("Transfer-Encoding");
            self.chunked_mode = false;
            if (self.headers.get("content-length") != null) {
                try self.headers.set("Content-Length", "0");
            }
        } else if (self.version == .@"HTTP/1.0") {
            // RFC 9112 Section 6.1: HTTP/1.0 does not support chunked
            self.headers.delete("Transfer-Encoding");
            self.chunked_mode = false;
        } else if (self.chunked_mode) {
            self.headers.delete("Content-Length");
            self.headers.delete("Transfer-Encoding");
            try self.headers.set("Transfer-Encoding", "chunked");
        } else {
            // Non-chunked mode must never send Transfer-Encoding
            self.headers.delete("Transfer-Encoding");
        }

        // Format Status Line: e.g. "HTTP/1.1 200 OK\r\n" or "HTTP/1.0 200 OK\r\n"
        var line_buf: [64]u8 = undefined;
        const status_line = std.fmt.bufPrint(&line_buf, "{s} {d} {s}\r\n", .{
            self.version.asString(),
            self.status_code.code(),
            self.status_code.phrase(),
        }) catch unreachable;

        // Fast Path: serialize status line and headers into a contiguous 1KB stack buffer
        // to issue a single atomic socket write (1-2 iovecs: [headers, body]) instead of
        // scattering across 10-20 tiny iovecs which causes multi-syscall amplification.
        var header_buf: [1024]u8 = undefined;
        var h_len: usize = status_line.len;
        var fits = h_len <= header_buf.len;
        if (fits) {
            @memcpy(header_buf[0..status_line.len], status_line);
            for (self.headers.entries.items) |entry| {
                const needed = entry.name.len + 2 + entry.value.len + 2;
                if (h_len + needed > header_buf.len) {
                    fits = false;
                    break;
                }
                @memcpy(header_buf[h_len .. h_len + entry.name.len], entry.name);
                h_len += entry.name.len;
                @memcpy(header_buf[h_len .. h_len + 2], ": ");
                h_len += 2;
                @memcpy(header_buf[h_len .. h_len + entry.value.len], entry.value);
                h_len += entry.value.len;
                @memcpy(header_buf[h_len .. h_len + 2], "\r\n");
                h_len += 2;
            }
            if (fits) {
                if (h_len + 2 <= header_buf.len) {
                    @memcpy(header_buf[h_len .. h_len + 2], "\r\n");
                    h_len += 2;
                } else {
                    fits = false;
                }
            }
        }

        if (fits) {
            var vecs: [2][]const u8 = undefined;
            vecs[0] = header_buf[0..h_len];
            var v_count: usize = 1;

            if (!self.chunked_mode and self.buffer_len > 0) {
                vecs[1] = self.buffer[0..self.buffer_len];
                v_count = 2;
                self.bytes_written += self.buffer_len;
                self.buffer_len = 0;
            }

            self.header_written = true;
            try io_util.writeSocketAllTimeout(self.stream, self.io, vecs[0..v_count], self.write_timeout_ns);
            return;
        }

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

            if (!self.chunked_mode and self.buffer_len > 0) {
                stack_vecs[vec_count] = self.buffer[0..self.buffer_len];
                vec_count += 1;
                self.bytes_written += self.buffer_len;
                self.buffer_len = 0;
            }

            self.header_written = true;
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

            if (!self.chunked_mode and self.buffer_len > 0) {
                try vecs.append(self.arena, self.buffer[0..self.buffer_len]);
                self.bytes_written += self.buffer_len;
                self.buffer_len = 0;
            }

            self.header_written = true;
            try io_util.writeSocketAllTimeout(self.stream, self.io, vecs.items, self.write_timeout_ns);
        }
    }

    /// Called at the end of the request handler execution
    pub fn finish(self: *ResponseWriter) !void {
        if (self.hijacked) return;
        const body_allowed = allowsBody(self.status_code);

        // Check if actual written + buffered is less than user-specified Content-Length
        // MUST check before flushHeaders() so we don't advertise Connection: keep-alive
        if (body_allowed and !self.is_head and !self.chunked_mode) {
            if (self.headers.get("content-length")) |cl_str| {
                const cl = std.fmt.parseInt(u64, cl_str, 10) catch {
                    return error.InvalidContentLength;
                };
                if (self.bytes_written + self.buffer_len < cl) {
                    // Body truncated by handler; force Connection: close
                    self.keep_alive = false;
                    self.headers.delete("Connection");
                    try self.headers.set("Connection", "close");
                }
            }
        }

        if (!self.header_written) {
            // Activate chunked_mode if user requested it
            if (self.headers.get("transfer-encoding")) |te| {
                if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, te, " \t"), "chunked") and self.version == .@"HTTP/1.1") {
                    self.chunked_mode = true;
                }
            }

            // Response fit completely inside buffer or is HEAD / 204
            if (!body_allowed) {
                self.buffer_len = 0;
                if (self.status_code.code() == 205) {
                    try self.headers.set("Content-Length", "0");
                }
            } else if (self.is_head) {
                if (self.headers.get("content-length") == null) {
                    var len_buf: [32]u8 = undefined;
                    const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{self.bytes_written}) catch unreachable;
                    const len_dup = try self.arena.dupe(u8, len_str);
                    try self.headers.set("Content-Length", len_dup);
                }
                self.buffer_len = 0;
            } else {
                if (!self.chunked_mode and self.headers.get("content-length") == null) {
                    var len_buf: [32]u8 = undefined;
                    const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{self.buffer_len}) catch unreachable;
                    const len_dup = try self.arena.dupe(u8, len_str);
                    try self.headers.set("Content-Length", len_dup);
                }
            }
            try self.flushHeaders();
        }

        // Headers are now guaranteed to be flushed.
        if (!body_allowed or self.is_head) {
            self.buffer_len = 0;
            return;
        }

        try self.flushBuffer();

        if (self.chunked_mode) {
            // Send terminal 0\r\n\r\n chunk
            var final_vec = [1][]const u8{"0\r\n\r\n"};
            try io_util.writeSocketAllTimeout(self.stream, self.io, &final_vec, self.write_timeout_ns);
        }

        // Check if actual written was less than user-specified Content-Length
        if (body_allowed and !self.is_head and !self.chunked_mode) {
            if (self.headers.get("content-length")) |cl_str| {
                const cl = std.fmt.parseInt(u64, cl_str, 10) catch {
                    return error.InvalidContentLength;
                };
                if (self.bytes_written < cl) {
                    // Body truncated by handler; close connection to prevent desynchronization
                    self.keep_alive = false;
                }
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

test "formatHttpDate compliance with RFC 9110 IMF-fixdate format" {
    var buf: [29]u8 = undefined;

    // 1. Epoch zero: 1970-01-01 00:00:00 GMT (Thursday)
    const epoch_zero = ResponseWriter.formatHttpDate(&buf, 0);
    try std.testing.expectEqualStrings("Thu, 01 Jan 1970 00:00:00 GMT", epoch_zero);

    // 2. RFC 9110 Section 5.6.7 canonical example: Sun, 06 Nov 1994 08:49:37 GMT
    const rfc_example = ResponseWriter.formatHttpDate(&buf, 784111777);
    try std.testing.expectEqualStrings("Sun, 06 Nov 1994 08:49:37 GMT", rfc_example);

    // 3. Leap year: 2000-02-29 23:59:59 GMT (Tuesday)
    const leap_year = ResponseWriter.formatHttpDate(&buf, 951868799);
    try std.testing.expectEqualStrings("Tue, 29 Feb 2000 23:59:59 GMT", leap_year);

    // 4. Leap day rollover: 2000-03-01 00:00:00 GMT (Wednesday)
    const leap_next = ResponseWriter.formatHttpDate(&buf, 951868800);
    try std.testing.expectEqualStrings("Wed, 01 Mar 2000 00:00:00 GMT", leap_next);
}
