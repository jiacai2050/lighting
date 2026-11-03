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
    pub const ConnNode = struct {
        stream: std.Io.net.Stream,
        prev: ?*ConnNode = null,
        next: ?*ConnNode = null,
    };

    allocator: std.mem.Allocator,
    io: std.Io,
    options: ServerOptions,
    pool: ?*ThreadPool = null,
    running: std.atomic.Value(bool) = .init(false),
    listener: ?std.Io.net.Server = null,
    active_conns_head: ?*ConnNode = null,
    active_conns_mutex: std.Io.Mutex = .init,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, options: ServerOptions) Server {
        return .{
            .allocator = allocator,
            .io = io,
            .options = options,
            .active_conns_head = null,
            .active_conns_mutex = .init,
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
            // On Linux, closing a socket does not wake up a thread blocked in accept4().
            // Connect a loopback dummy probe to wake up the accept thread so it exits promptly.
            const port = l.socket.address.getPort();
            if (port != 0) {
                if (std.Io.net.IpAddress.parseIp4("127.0.0.1", port)) |addr| {
                    if (addr.connect(self.io, .{ .mode = .stream })) |dummy| {
                        dummy.close(self.io);
                    } else |_| {}
                } else |_| {}
            }
            l.socket.close(self.io);
            self.listener = null;
        }

        // Interrupt all active connections so workers in blocking read return immediately
        self.active_conns_mutex.lockUncancelable(self.io);
        var curr = self.active_conns_head;
        while (curr) |node| {
            node.stream.shutdown(self.io, .both) catch {};
            curr = node.next;
        }
        self.active_conns_mutex.unlock(self.io);
    }

    fn registerConnNode(self: *Server, node: *ConnNode) void {
        self.active_conns_mutex.lockUncancelable(self.io);
        defer self.active_conns_mutex.unlock(self.io);
        node.next = self.active_conns_head;
        node.prev = null;
        if (self.active_conns_head) |head| {
            head.prev = node;
        }
        self.active_conns_head = node;
    }

    fn unregisterConnNode(self: *Server, node: *ConnNode) void {
        self.active_conns_mutex.lockUncancelable(self.io);
        defer self.active_conns_mutex.unlock(self.io);
        if (node.prev) |prev| {
            prev.next = node.next;
        } else {
            self.active_conns_head = node.next;
        }
        if (node.next) |next| {
            next.prev = node.prev;
        }
        node.prev = null;
        node.next = null;
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
        var conn_node = ConnNode{ .stream = stream };
        self.registerConnNode(&conn_node);
        defer self.unregisterConnNode(&conn_node);

        // Allocate a dedicated connection read buffer (e.g. 8KB)
        const conn_buf = self.allocator.alloc(u8, self.options.max_header_bytes) catch return;
        defer self.allocator.free(conn_buf);

        var buf_len: usize = 0;
        var is_idle: bool = false;

        // Keep-Alive connection loop
        while (self.running.load(.acquire)) {
            // 1. First check if complete HTTP headers already reside in buffer (Pipelining support)
            var head_end: ?usize = std.mem.indexOf(u8, conn_buf[0..buf_len], "\r\n\r\n");
            var header_deadline: ?std.Io.Timeout = null;
            var idle_deadline: ?std.Io.Timeout = null;

            while (head_end == null) {
                if (!self.running.load(.acquire)) return;

                if (buf_len >= conn_buf.len) {
                    // Exceeded max_header_bytes -> 431 Request Header Fields Too Large
                    const msg = [1][]const u8{"HTTP/1.1 431 Request Header Fields Too Large\r\nConnection: close\r\n\r\n"};
                    _ = io_util.writeSocketAll(stream, self.io, &msg) catch {};
                    return;
                }

                // If connection is idle between requests, read in small time slices (100ms)
                // so we can promptly release worker if tasks are queued or server is shutting down
                if (is_idle and buf_len == 0) {
                    if (self.pool) |p| {
                        if (p.hasPendingTasks()) return;
                    }

                    if (idle_deadline == null) {
                        if (self.options.idle_timeout_ns orelse self.options.read_timeout_ns) |ns| {
                            const dur = std.Io.Timeout{ .duration = .{ .raw = .{ .nanoseconds = @intCast(ns) }, .clock = .boot } };
                            idle_deadline = dur.toDeadline(self.io);
                        } else {
                            idle_deadline = .none;
                        }
                    }

                    const slice_timeout: std.Io.Timeout = .{
                        .duration = .{ .raw = .{ .nanoseconds = 100 * std.time.ns_per_ms }, .clock = .boot },
                    };

                    const n = io_util.readSocketWithTimeout(stream, self.io, conn_buf[0..], slice_timeout) catch |err| {
                        if (err == error.Timeout) {
                            if (!self.running.load(.acquire)) return;
                            if (self.pool) |p| {
                                if (p.hasPendingTasks()) return;
                            }
                            if (idle_deadline.? != .none) {
                                if (idle_deadline.?.toDurationFromNow(self.io)) |d| {
                                    if (d.raw.nanoseconds <= 0) return;
                                } else {
                                    return;
                                }
                            }
                            continue;
                        }
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
                        const msg = [1][]const u8{"HTTP/1.1 408 Request Timeout\r\nConnection: close\r\n\r\n"};
                        _ = io_util.writeSocketAll(stream, self.io, &msg) catch {};
                        return;
                    }
                    return;
                };
                if (n == 0) return;
                buf_len += n;
                head_end = std.mem.indexOf(u8, conn_buf[0..buf_len], "\r\n\r\n");
            }

            // Create per-request Arena
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const req_allocator = arena.allocator();

            var head = parseRequestHead(req_allocator, conn_buf[0..buf_len]) catch |err| {
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

            // RFC 9110 Section 10.1.1: Expect header handling
            if (head.headers.get("expect")) |expect_hdr| {
                const trimmed = std.mem.trim(u8, expect_hdr, " \t");
                if (std.ascii.eqlIgnoreCase(trimmed, "100-continue")) {
                    if (head.version == .@"HTTP/1.1") {
                        const msg = [1][]const u8{"HTTP/1.1 100 Continue\r\n\r\n"};
                        _ = io_util.writeSocketAll(stream, self.io, &msg) catch {
                            return;
                        };
                    }
                } else {
                    // Unknown expectation: 417 Expectation Failed
                    const msg = [1][]const u8{"HTTP/1.1 417 Expectation Failed\r\nConnection: close\r\n\r\n"};
                    _ = io_util.writeSocketAll(stream, self.io, &msg) catch {};
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
            };

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
