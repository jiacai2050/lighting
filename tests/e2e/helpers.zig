const std = @import("std");
pub const http = @import("lighting");

var test_threaded_runtime: ?std.Io.Threaded = null;

/// getTestIo returns a lazily-initialized threaded I/O runtime for tests.
pub fn getTestIo() std.Io {
    if (test_threaded_runtime == null) {
        test_threaded_runtime = std.Io.Threaded.init(std.heap.page_allocator, .{});
    }
    return test_threaded_runtime.?.io();
}

/// TestServer encapsulates a running server on an ephemeral port.
pub const TestServer = struct {
    server: *http.Server,
    thread: std.Thread,
    port: u16,
    allocator: std.mem.Allocator,

    pub fn start(allocator: std.mem.Allocator, io: std.Io, options: http.ServerOptions) !TestServer {
        const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        const listener = try addr.listen(io, .{ .reuse_address = true });
        const port = listener.socket.address.getPort();

        const server = try allocator.create(http.Server);
        server.* = http.Server.init(allocator, io, options);

        const Runner = struct {
            fn run(s: *http.Server, l: std.Io.net.Server) void {
                s.serve(l) catch {};
            }
        };

        const thread = try std.Thread.spawn(.{}, Runner.run, .{ server, listener });
        return .{
            .server = server,
            .thread = thread,
            .port = port,
            .allocator = allocator,
        };
    }

    pub fn stop(self: *TestServer) void {
        self.server.shutdown();
        self.thread.join();
        self.server.deinit();
        self.allocator.destroy(self.server);
    }

    pub fn connect(self: *TestServer, io: std.Io) !std.Io.net.Stream {
        const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", self.port);
        return addr.connect(io, .{ .mode = .stream });
    }
};
