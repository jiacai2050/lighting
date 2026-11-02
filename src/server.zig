const std = @import("std");
const Handler = @import("handler.zig").Handler;
const Request = @import("request.zig").Request;
const ResponseWriter = @import("response_writer.zig").ResponseWriter;
const ThreadPool = @import("thread_pool.zig").ThreadPool;
const parseRequestHead = @import("proto/parser.zig").parseRequestHead;
const BodyReader = @import("proto/chunk_reader.zig").BodyReader;
const io_util = @import("proto/io_util.zig");

pub const ServerOptions = struct {
    handler: Handler,
    num_threads: usize = 64,
    max_queue_size: usize = 1024,
    max_header_bytes: usize = 8 * 1024,
    read_timeout_ns: ?u64 = null,
    read_header_timeout_ns: ?u64 = null,
    write_timeout_ns: ?u64 = null,
    idle_timeout_ns: ?u64 = null,
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    options: ServerOptions,
    pool: ?*ThreadPool = null,
    running: std.atomic.Value(bool) = .init(false),
    listener: ?std.Io.net.Server = null,

    pub fn init(allocator: std.mem.Allocator, options: ServerOptions) Server {
        const io = std.Io.Threaded.global_single_threaded.io();
        return .{
            .allocator = allocator,
            .io = io,
            .options = options,
        };
    }

    pub fn deinit(self: *Server) void {
        self.shutdown();
        if (self.pool) |p| {
            p.destroy();
            self.pool = null;
        }
    }

    pub fn shutdown(self: *Server) void {
        if (!self.running.swap(false, .acq_rel)) return;
        if (self.listener) |*l| {
            l.socket.close(self.io);
            self.listener = null;
        }
    }

    pub fn listenAndServe(self: *Server, host: []const u8, port: u16) !void {
        const addr = try std.Io.net.IpAddress.parseIp4(host, port);
        var listener = try addr.listen(self.io, .{ .reuse_address = true });
        self.listener = listener;
        self.running.store(true, .release);

        self.pool = try ThreadPool.create(self.allocator, self.io, self.options.num_threads, self.options.max_queue_size);

        while (self.running.load(.acquire)) {
            const stream = listener.accept(self.io) catch |err| {
                if (!self.running.load(.acquire)) break;
                // If listener was closed or interrupted, stop
                switch (err) {
                    error.ConnectionAborted, error.SocketNotListening, error.Canceled => break,
                    else => {
                        std.log.warn("accept error: {}", .{err});
                        continue;
                    },
                }
            };

            // Dispatch connection to worker pool
            self.pool.?.spawn(serveConnWorker, .{ self, stream }) catch |err| {
                if (err == error.QueueFull) {
                    const msg = [1][]const u8{"HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\n\r\n"};
                    _ = io_util.writeSocketAll(stream, self.io, &msg) catch {};
                } else {
                    std.log.warn("spawn worker error (dropping connection): {}", .{err});
                }
                stream.close(self.io);
            };
        }
    }

    fn serveConnWorker(server: *Server, stream: std.Io.net.Stream) void {
        server.serveConn(stream);
    }

    pub fn serveConn(self: *Server, stream: std.Io.net.Stream) void {
        defer stream.close(self.io);

        // Allocate a dedicated connection read buffer (e.g. 8KB)
        const conn_buf = self.allocator.alloc(u8, self.options.max_header_bytes) catch return;
        defer self.allocator.free(conn_buf);

        var buf_len: usize = 0;
        var is_idle: bool = false;

        // Keep-Alive connection loop
        while (self.running.load(.acquire)) {
            // If connection is idle between requests and queue has pending tasks,
            // don't hog the worker thread: close connection gracefully and yield thread to pending tasks
            if (is_idle and buf_len == 0) {
                if (self.pool) |p| {
                    if (p.hasPendingTasks()) {
                        return;
                    }
                }
            }

            // 1. First check if complete HTTP headers already reside in buffer (Pipelining support)
            var head_end: ?usize = std.mem.indexOf(u8, conn_buf[0..buf_len], "\r\n\r\n");
            var header_deadline: ?std.Io.Timeout = null;

            while (head_end == null) {
                if (buf_len >= conn_buf.len) {
                    // Exceeded max_header_bytes -> 431 Request Header Fields Too Large
                    const msg = [1][]const u8{"HTTP/1.1 431 Request Header Fields Too Large\r\nConnection: close\r\n\r\n"};
                    _ = io_util.writeSocketAll(stream, self.io, &msg) catch {};
                    return;
                }

                // Determine timeout:
                // Idle keep-alive connection waiting for first byte uses idle_timeout_ns
                // Active reading of request headers uses fixed header_deadline (Slowloris defense)
                const current_timeout: std.Io.Timeout = if (is_idle and buf_len == 0) blk: {
                    if (self.options.idle_timeout_ns orelse self.options.read_timeout_ns) |ns| {
                        break :blk .{ .duration = .{ .raw = .{ .nanoseconds = @intCast(ns) }, .clock = .boot } };
                    }
                    break :blk .none;
                } else blk: {
                    if (header_deadline == null) {
                        if (self.options.read_header_timeout_ns orelse self.options.read_timeout_ns) |ns| {
                            const dur = std.Io.Timeout{ .duration = .{ .raw = .{ .nanoseconds = @intCast(ns) }, .clock = .boot } };
                            header_deadline = dur.toDeadline(self.io);
                        } else {
                            header_deadline = .none;
                        }
                    }
                    break :blk header_deadline.?;
                };

                const n = io_util.readSocketWithTimeout(stream, self.io, conn_buf[buf_len..], current_timeout) catch |err| {
                    if (err == error.Timeout) {
                        if (is_idle and buf_len == 0) {
                            // Idle keep-alive connection timed out cleanly
                            return;
                        } else {
                            // Slowloris or slow client during headers: 408 Request Timeout
                            const msg = [1][]const u8{"HTTP/1.1 408 Request Timeout\r\nConnection: close\r\n\r\n"};
                            _ = io_util.writeSocketAll(stream, self.io, &msg) catch {};
                            return;
                        }
                    }
                    if (err == error.EndOfStream or buf_len == 0) return;
                    return;
                };
                if (n == 0) return; // Client closed connection
                buf_len += n;

                head_end = std.mem.indexOf(u8, conn_buf[0..buf_len], "\r\n\r\n");
            }

            // Create per-request Arena
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const req_allocator = arena.allocator();

            const head = parseRequestHead(req_allocator, conn_buf[0..buf_len]) catch |err| {
                if (err == error.UnsupportedTransferEncoding) {
                    const msg = [1][]const u8{"HTTP/1.1 501 Not Implemented\r\nConnection: close\r\n\r\n"};
                    _ = io_util.writeSocketAll(stream, self.io, &msg) catch {};
                } else {
                    const msg = [1][]const u8{"HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n"};
                    _ = io_util.writeSocketAll(stream, self.io, &msg) catch {};
                }
                return;
            };

            const header_bytes = head.bytes_consumed;
            const extra_in_buf = conn_buf[header_bytes..buf_len];

            // Build BodyReader
            var body_reader = BodyReader.init(
                stream,
                self.io,
                extra_in_buf,
                head.content_length,
                head.is_chunked,
            );
            body_reader.setReadTimeout(self.options.read_timeout_ns);

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
                head.keep_alive,
                head.method == .HEAD,
            );
            res.setWriteTimeout(self.options.write_timeout_ns);

            // Invoke Handler (Catch error to avoid crash and isolate 500)
            self.options.handler.serveHTTP(&res, &req) catch |err| {
                std.log.warn("Handler error (handled as 500): {}", .{err});
                if (!res.header_written) {
                    res.setStatus(.internal_server_error);
                    res.writeAll("500 Internal Server Error\n") catch {};
                }
            };

            // Finalize response
            res.finish() catch return;

            // If keep-alive is false (or disabled due to body mismatch), close connection
            if (!head.keep_alive or !res.keep_alive) {
                return;
            }

            // If there's an unread body and keep-alive is active, discard up to 256KB to keep conn alive
            if (req.body()) |b| {
                const max_discard: usize = 256 * 1024;
                var total_discarded: usize = 0;
                var discard_buf: [1024]u8 = undefined;
                var too_large = false;

                while (true) {
                    const to_read = @min(discard_buf.len, max_discard - total_discarded);
                    if (to_read == 0) {
                        too_large = true;
                        break;
                    }
                    const n = b.read(discard_buf[0..to_read]) catch break;
                    if (n == 0) break;
                    total_discarded += n;
                }

                if (too_large) {
                    // Unread body exceeded 256KB, close connection to prevent DoS (mimicking Go net/http)
                    return;
                }

                if (b.unread_slice.len > 0) {
                    const leftover = b.unread_slice.len;
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
