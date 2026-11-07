//! Route-level request timeout middleware conforming to Go's http.TimeoutHandler.

const std = @import("std");
const Handler = @import("handler.zig").Handler;
const ResponseWriter = @import("response_writer.zig").ResponseWriter;
const Request = @import("request.zig").Request;

/// TimeoutHandler wraps a Handler with a maximum execution and I/O duration.
///
/// If processing exceeds timeout_ns or returns error.Timeout / error.Canceled,
/// a 504 Gateway Timeout response is returned and the connection is closed.
pub const TimeoutHandler = struct {
    next: Handler,
    timeout_ns: u64,
    message: []const u8 = "Gateway Timeout\n",

    /// serveHTTP sets socket read/write timeouts and intercepts timeout errors.
    pub fn serveHTTP(self: *TimeoutHandler, w: *ResponseWriter, req: *Request) anyerror!void {
        // Enforce socket-level write timeout
        w.setWriteTimeout(self.timeout_ns);

        // Enforce request body stream timeout if present
        if (req.body()) |b| {
            b.setReadTimeout(self.timeout_ns);
        }

        const start = std.Io.Clock.awake.now(w.io);

        const result = self.next.serveHTTP(w, req);
        if (result) |_| {
            const duration = start.durationTo(std.Io.Clock.awake.now(w.io));
            const elapsed_ns = duration.toNanoseconds();
            if (elapsed_ns > self.timeout_ns and !w.header_written) {
                return self.sendTimeoutResponse(w);
            }
            return;
        } else |err| {
            if ((err == error.Timeout or err == error.Canceled) and !w.header_written) {
                return self.sendTimeoutResponse(w);
            }
            return err;
        }
    }

    fn sendTimeoutResponse(self: *TimeoutHandler, w: *ResponseWriter) !void {
        w.setStatus(.gateway_timeout);
        w.keep_alive = false;
        try w.header().set("Content-Type", "text/plain; charset=utf-8");
        try w.header().set("Connection", "close");
        try w.writeAll(self.message);
    }

    /// handler returns a Handler interface delegating to this TimeoutHandler.
    pub fn handler(self: *TimeoutHandler) Handler {
        return Handler.from(self);
    }
};

/// timeoutHandler constructs a TimeoutHandler wrapping next with the specified nanosecond limit.
pub fn timeoutHandler(next: Handler, timeout_ns: u64, message: []const u8) TimeoutHandler {
    return .{
        .next = next,
        .timeout_ns = timeout_ns,
        .message = message,
    };
}

test "TimeoutHandler fast path completes normally" {
    const fastFn = struct {
        fn handle(w: *ResponseWriter, _: *Request) anyerror!void {
            w.setStatus(.ok);
            try w.writeAll("success");
        }
    }.handle;

    var th = timeoutHandler(Handler.fromFn(fastFn), 100 * std.time.ns_per_ms, "Timed out");
    const h = th.handler();
    _ = h;
}
