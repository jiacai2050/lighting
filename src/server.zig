//! HTTP server implementation powered by Zig structured concurrency (`std.Io.Group`).

const std = @import("std");
const assert = std.debug.assert;
const Handler = @import("handler.zig").Handler;
const Request = @import("request.zig").Request;
const ResponseWriter = @import("response_writer.zig").ResponseWriter;
const parseRequestHead = @import("proto/parser.zig").parseRequestHead;
const BodyReader = @import("proto/chunk_reader.zig").BodyReader;
const io_util = @import("proto/io_util.zig");

/// ServerOptions configures an HTTP Server instance.
pub const ServerOptions = struct {
    /// Root request handler or multiplexer.
    handler: Handler,
    /// Maximum allowed request header size in bytes (default 8KB). Requests exceeding this limit return 431.
    header_bytes_max: usize = 8 * 1024,
    /// Maximum capacity (in bytes) to retain in the per-connection request arena.
    /// Memory exceeding this high-water mark is freed back to the child allocator on reset.
    request_arena_retain_limit: usize = 64 * 1024,
    /// Maximum duration (in nanoseconds) allowed for reading the entire request (including body).
    read_timeout_ns: ?u64 = null,
    /// Maximum duration (in nanoseconds) allowed for reading the request line and headers.
    read_header_timeout_ns: ?u64 = null,
    /// Maximum duration (in nanoseconds) allowed for writing the response.
    write_timeout_ns: ?u64 = null,
    /// Maximum idle duration (in nanoseconds) between requests on a keep-alive connection.
    idle_timeout_ns: ?u64 = null,
};

/// Server represents an HTTP server instance.
/// It uses a concurrent execution model backed by std.Io.Group.
///
/// Thread Safety and Performance:
/// - True Zero-Lock Architecture: No global mutexes on accept, connection handling, or request routing.
/// - Self-Contained Scope: All resources and concurrent workers are fully reclaimed upon `serve()` return.
/// - Graceful Stop & Shutdown: Call `server.close()` for non-blocking exit or `server.shutdown()` to block until drained.
pub const Server = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    options: ServerOptions,
    group: std.Io.Group = .init,
    listener: ?std.Io.net.Server = null,
    stopped: std.atomic.Value(bool) = .init(false),
    stop_event: std.Io.Event = .unset,
    done_event: std.Io.Event = .unset,

    /// init initializes a new Server instance.
    pub fn init(gpa: std.mem.Allocator, io: std.Io, options: ServerOptions) Server {
        assert(options.header_bytes_max > 0);
        return .{
            .allocator = gpa,
            .io = io,
            .options = options,
            .group = .init,
            .listener = null,
            .stopped = .init(false),
            .stop_event = .unset,
            .done_event = .unset,
        };
    }

    /// close triggers non-blocking termination of the server (matching Go's srv.Close()).
    /// Safe to call concurrently from any thread or handler.
    pub fn close(self: *Server) void {
        self.stop_event.set(self.io);
    }

    /// shutdown gracefully terminates the server and blocks until all in-flight connections
    /// have completed and serve() has returned (matching Go's srv.Shutdown()).
    /// Safe to call concurrently from any thread.
    pub fn shutdown(self: *Server) void {
        if (!self.isRunning()) return;
        self.close();
        self.done_event.waitUncancelable(self.io);
    }

    /// isRunning reports whether the server is actively accepting connections.
    pub fn isRunning(self: *const Server) bool {
        return self.listener != null and !self.stopped.load(.acquire);
    }

    fn closeListener(self: *Server) void {
        if (self.listener) |*l| {
            l.socket.close(self.io);
            self.listener = null;
        }
    }

    fn writeErrorResponse(stream: std.Io.net.Stream, io: std.Io, comptime response: []const u8) void {
        const msg = [1][]const u8{response};
        _ = io_util.writeSocketAll(stream, io, &msg) catch |err| {
            std.log.debug("writeErrorResponse failed: {}", .{err});
        };
    }

    /// stopWatcher runs as a background task inside self.group.
    /// It waits for self.stop_event or group cancellation.
    ///
    /// NOTE: We use cancellation-aware `wait(io) catch return;` instead of `waitUncancelable(io)`.
    /// If serve() exits prematurely due to an unexpected terminal listener error (e.g.
    /// SocketNotListening or ConnectionAborted), `group.cancel(io)` propagates cancellation.
    /// A cancellation-aware wait ensures stopWatcher exits immediately rather than hanging
    /// `group.cancel()` indefinitely.
    fn stopWatcher(self: *Server) void {
        self.stop_event.wait(self.io) catch return;
        self.stopped.store(true, .release);

        // Wake up accept thread by connecting a dummy loopback probe
        if (self.listener) |l| {
            const port = l.socket.address.getPort();
            if (port != 0) {
                if (std.Io.net.IpAddress.parseIp4("127.0.0.1", port)) |addr| {
                    if (addr.connect(self.io, .{ .mode = .stream })) |dummy| {
                        dummy.close(self.io);
                    } else |_| {}
                } else |_| {}
            }
        }
    }

    /// serve accepts incoming connections on the provided listener, creating a concurrent worker
    /// for each connection. Blocks until close() or shutdown() is called or an unrecoverable listener error occurs.
    pub fn serve(self: *Server, listener: std.Io.net.Server) !void {
        self.listener = listener;
        self.stopped.store(false, .release);
        self.done_event = .unset;

        defer {
            // Cancel and wait for all active connection workers and the stopWatcher.
            self.group.cancel(self.io);
            // Close the listener socket so the TCP port is freed.
            self.closeListener();
            // Signal callers of shutdown() that the server has fully stopped and drained.
            self.done_event.set(self.io);
        }

        try self.group.concurrent(self.io, stopWatcher, .{self});

        while (self.isRunning()) {
            var active_listener = self.listener orelse break;

            const stream = active_listener.accept(self.io) catch |err| {
                if (!self.isRunning()) break;
                // If listener was closed or interrupted, stop
                switch (err) {
                    error.ConnectionAborted, error.SocketNotListening, error.Canceled => break,
                    else => {
                        std.log.warn("accept error: {}", .{err});
                        continue;
                    },
                }
            };

            if (!self.isRunning()) {
                stream.close(self.io);
                break;
            }

            // Dispatch connection concurrently via std.Io.Group
            self.group.concurrent(self.io, serveConnWorker, .{ self, stream }) catch |err| {
                if (err == error.ConcurrencyUnavailable) {
                    writeErrorResponse(stream, self.io, "HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\n\r\n");
                } else {
                    std.log.warn("spawn concurrent worker error (dropping connection): {}", .{err});
                }
                stream.close(self.io);
            };
        }
    }

    /// listenAndServe binds to the specified host and TCP port, then begins accepting connections.
    /// Blocks until close() is called or an unrecoverable error occurs.
    pub fn listenAndServe(self: *Server, host: []const u8, port: u16) !void {
        const addr = try std.Io.net.IpAddress.parseIp4(host, port);
        const listener = try addr.listen(self.io, .{ .reuse_address = true });
        return self.serve(listener);
    }

    fn serveConnWorker(server: *Server, stream: std.Io.net.Stream) void {
        server.serveConn(stream);
    }

    /// serveConn processes HTTP/1.x requests on an accepted TCP connection, supporting keep-alive pipelining.
    pub fn serveConn(self: *Server, stream: std.Io.net.Stream) void {
        var close_stream = true;
        defer if (close_stream) stream.close(self.io);

        // Allocate a dedicated connection read buffer (e.g. 8KB)
        const conn_buf = self.allocator.alloc(u8, self.options.header_bytes_max) catch return;
        defer self.allocator.free(conn_buf);

        // Connection-scoped request arena with retained capacity across requests
        var conn_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer conn_arena.deinit();

        var buf_len: usize = 0;
        var is_idle: bool = false;

        // Keep-Alive connection loop
        while (self.isRunning()) {
            assert(buf_len <= conn_buf.len);

            // Reset arena capacity for each request with high-water mark protection
            _ = conn_arena.reset(.{ .retain_with_limit = self.options.request_arena_retain_limit });
            const req_allocator = conn_arena.allocator();

            // 1. First check if complete HTTP headers already reside in buffer (Pipelining support)
            var head_end: ?usize = std.mem.indexOf(u8, conn_buf[0..buf_len], "\r\n\r\n");
            var header_deadline: ?std.Io.Timeout = null;
            var idle_deadline: ?std.Io.Timeout = null;

            while (head_end == null) {
                if (!self.isRunning()) return;

                if (buf_len >= conn_buf.len) {
                    // Exceeded header_bytes_max -> 431 Request Header Fields Too Large
                    writeErrorResponse(stream, self.io, "HTTP/1.1 431 Request Header Fields Too Large\r\nConnection: close\r\n\r\n");
                    return;
                }

                // If connection is idle between requests, wait until next request or idle timeout
                if (is_idle and buf_len == 0) {
                    if (idle_deadline == null) {
                        if (self.options.idle_timeout_ns orelse self.options.read_timeout_ns) |ns| {
                            const dur = std.Io.Timeout{ .duration = .{ .raw = .{ .nanoseconds = @intCast(ns) }, .clock = .boot } };
                            idle_deadline = dur.toDeadline(self.io);
                        } else {
                            idle_deadline = .none;
                        }
                    }

                    const n = io_util.readSocketWithTimeout(stream, self.io, conn_buf[0..], idle_deadline.?) catch |err| {
                        if (err == error.Timeout) return;
                        return;
                    };
                    if (n == 0) return;
                    buf_len += n;
                    head_end = std.mem.indexOf(u8, conn_buf[0..buf_len], "\r\n\r\n");
                    continue;
                }

                // Active reading of request headers uses fixed header_deadline (Slowloris defense)
                if (header_deadline == null) {
                    if (self.options.read_header_timeout_ns orelse self.options.read_timeout_ns) |ns| {
                        const dur = std.Io.Timeout{ .duration = .{ .raw = .{ .nanoseconds = @intCast(ns) }, .clock = .boot } };
                        header_deadline = dur.toDeadline(self.io);
                    } else {
                        header_deadline = .none;
                    }
                }

                const n = io_util.readSocketWithTimeout(stream, self.io, conn_buf[buf_len..], header_deadline.?) catch |err| {
                    if (err == error.Timeout) {
                        writeErrorResponse(stream, self.io, "HTTP/1.1 408 Request Timeout\r\nConnection: close\r\n\r\n");
                        return;
                    }
                    return;
                };
                if (n == 0) return;
                buf_len += n;
                head_end = std.mem.indexOf(u8, conn_buf[0..buf_len], "\r\n\r\n");
            }

            var head = parseRequestHead(req_allocator, conn_buf[0..buf_len]) catch |err| {
                if (err == error.UnsupportedTransferEncoding) {
                    writeErrorResponse(stream, self.io, "HTTP/1.1 501 Not Implemented\r\nConnection: close\r\n\r\n");
                } else {
                    writeErrorResponse(stream, self.io, "HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n");
                }
                return;
            };

            const header_bytes = head.bytes_consumed;
            const extra_in_buf = conn_buf[header_bytes..buf_len];

            // RFC 9110 Section 10.1.1: Expect header handling
            if (head.headers.get("expect")) |expect_hdr| {
                const trimmed = std.mem.trim(u8, expect_hdr, " \t");
                if (std.ascii.eqlIgnoreCase(trimmed, "100-continue")) {
                    if (head.version == .@"HTTP/1.1") {
                        const msg = [1][]const u8{"HTTP/1.1 100 Continue\r\n\r\n"};
                        _ = io_util.writeSocketAll(stream, self.io, &msg) catch |err| {
                            std.log.debug("write 100 Continue error: {}", .{err});
                            return;
                        };
                    }
                } else {
                    // Unknown expectation: 417 Expectation Failed
                    writeErrorResponse(stream, self.io, "HTTP/1.1 417 Expectation Failed\r\nConnection: close\r\n\r\n");
                    return;
                }
            }

            // Build BodyReader with absolute deadline
            var body_reader = BodyReader.init(
                stream,
                self.io,
                extra_in_buf,
                head.content_length,
                head.is_chunked,
            );
            body_reader.setReadDeadline(self.options.read_timeout_ns);

            // Construct Request and ResponseWriter
            var req = Request.init(
                head.method,
                head.target,
                head.version,
                head.headers,
                body_reader,
                head.content_length,
                head.keep_alive,
                req_allocator,
            );

            var res = ResponseWriter.init(
                stream,
                self.io,
                req_allocator,
                head.version,
                head.keep_alive,
                head.method == .HEAD,
            );
            res.setWriteTimeout(self.options.write_timeout_ns);

            // Invoke Handler (Catch error to avoid crash and isolate 500)
            self.options.handler.serveHTTP(&res, &req) catch |err| {
                if (@errorReturnTrace()) |trace| {
                    std.debug.dumpErrorReturnTrace(trace);
                }
                if (res.hijacked) {
                    std.log.warn("Handler error on hijacked connection: {}", .{err});
                } else {
                    std.log.warn("Handler error (handled as 500): {}", .{err});
                    // Any error during handler terminates connection to prevent framing desync
                    head.keep_alive = false;
                    res.keep_alive = false;
                    if (!res.header_written) {
                        res.setStatus(.internal_server_error);
                        res.headers.delete("Content-Length");
                        res.headers.delete("Transfer-Encoding");
                        res.headers.delete("Connection");
                        res.headers.set("Connection", "close") catch |set_err| {
                            std.log.warn("Failed to set Connection: close on 500 error: {}", .{set_err});
                        };
                        res.buffer_len = 0;
                        // Attempt best-effort 500 error response; client might already have disconnected
                        res.writeAll("500 Internal Server Error\n") catch |write_err| {
                            std.log.debug("Failed to write 500 error response body: {}", .{write_err});
                        };
                    }
                }
            };

            // If connection was hijacked, socket ownership was transferred and
            // connection was already unregistered on hijack; exit immediately
            if (res.hijacked) {
                close_stream = false;
                return;
            }

            // Finalize response
            res.finish() catch return;

            // If keep-alive is false (or disabled due to body mismatch / error), close connection
            if (!head.keep_alive or !res.keep_alive) {
                return;
            }

            // If there's an unread body and keep-alive is active, discard up to 256KB to keep conn alive
            if (req.body()) |b| {
                const max_discard: usize = 256 * 1024;
                var total_discarded: usize = 0;
                var discard_buf: [1024]u8 = undefined;
                var too_large = false;
                var drain_failed = false;

                while (total_discarded < max_discard) {
                    const to_read = @min(discard_buf.len, max_discard - total_discarded);
                    const n = b.read(discard_buf[0..to_read]) catch {
                        drain_failed = true;
                        break;
                    };
                    if (n == 0) break;
                    total_discarded += n;
                }

                // If exactly max_discard bytes were read, probe 1 byte to check if stream has reached EOF
                if (!drain_failed and total_discarded == max_discard) {
                    var probe: [1]u8 = undefined;
                    const n = b.read(&probe) catch blk: {
                        drain_failed = true;
                        break :blk 0;
                    };
                    if (n > 0) {
                        too_large = true;
                    }
                }

                if (too_large or drain_failed) {
                    // Body error during drain must not reuse connection
                    return;
                }

                if (b.unread_slice.len > 0) {
                    const leftover = b.unread_slice.len;
                    assert(leftover <= conn_buf.len);
                    std.mem.copyForwards(u8, conn_buf[0..leftover], b.unread_slice);
                    buf_len = leftover;
                    is_idle = false;
                    continue;
                }
            }

            // Reset buffer pointers for next request on the same connection
            buf_len = 0;
            is_idle = true;
        }
    }
};

test "Server request arena high-water mark protection" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const limit: usize = 64 * 1024;
    const alloc = arena.allocator();

    // Allocate 256 KB (exceeding the 64 KB limit)
    const big_buf = try alloc.alloc(u8, 256 * 1024);
    @memset(big_buf, 0xAA);
    try testing.expect(arena.queryCapacity() >= 256 * 1024);

    // Reset with limit
    _ = arena.reset(.{ .retain_with_limit = limit });
    try testing.expect(arena.queryCapacity() <= limit);
}
