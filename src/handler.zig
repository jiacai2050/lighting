//! HTTP Handler interface and middleware abstractions conforming to Go's http.Handler model.

const std = @import("std");
const ResponseWriter = @import("response_writer.zig").ResponseWriter;
const Request = @import("request.zig").Request;

/// Handler responds to an HTTP request.
///
/// Handler is implemented via a type-erased fat pointer (VTable) providing zero runtime
/// memory overhead and zero allocation cost. It can wrap standalone functions, stateful structs,
/// or struct methods.
pub const Handler = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    /// VTable defines the virtual function dispatch table for Handler implementations.
    pub const VTable = struct {
        serveHTTP: *const fn (ctx: *anyopaque, w: *ResponseWriter, req: *Request) anyerror!void,
    };

    /// serveHTTP handles the incoming HTTP request by writing headers and body data to w.
    pub fn serveHTTP(self: Handler, w: *ResponseWriter, req: *Request) anyerror!void {
        return self.vtable.serveHTTP(self.ptr, w, req);
    }

    /// fromFn wraps a stateless function pointer as a Handler.
    pub fn fromFn(comptime func: *const fn (*ResponseWriter, *Request) anyerror!void) Handler {
        const Gen = struct {
            fn call(_: *anyopaque, w: *ResponseWriter, req: *Request) anyerror!void {
                return func(w, req);
            }
            const vt = VTable{ .serveHTTP = call };
        };
        return .{
            .ptr = undefined,
            .vtable = &Gen.vt,
        };
    }

    /// from wraps any struct pointer that implements `serveHTTP(*@This(), *ResponseWriter, *Request) anyerror!void`.
    pub fn from(pointer: anytype) Handler {
        const PtrType = @TypeOf(pointer);
        const Pointee = std.meta.Child(PtrType);

        const Gen = struct {
            fn call(ctx: *anyopaque, w: *ResponseWriter, req: *Request) anyerror!void {
                const self: *Pointee = @ptrCast(@alignCast(ctx));
                return self.serveHTTP(w, req);
            }
            const vt = VTable{ .serveHTTP = call };
        };

        return .{
            .ptr = @ptrCast(pointer),
            .vtable = &Gen.vt,
        };
    }

    /// bind binds any struct pointer with any member method `fn (*T, *ResponseWriter, *Request) anyerror!void`.
    pub fn bind(pointer: anytype, comptime method: anytype) Handler {
        const PtrType = @TypeOf(pointer);
        const Pointee = std.meta.Child(PtrType);

        const Gen = struct {
            fn call(ctx: *anyopaque, w: *ResponseWriter, req: *Request) anyerror!void {
                const self: *Pointee = @ptrCast(@alignCast(ctx));
                return @call(.auto, method, .{ self, w, req });
            }
            const vt = VTable{ .serveHTTP = call };
        };

        return .{
            .ptr = @ptrCast(pointer),
            .vtable = &Gen.vt,
        };
    }
};

/// LoggingHandler is a standard request logging middleware that records method, path, HTTP status, and latency.
pub const LoggingHandler = struct {
    next: Handler,

    /// serveHTTP records request start time, delegates to next handler, and logs the execution outcome.
    pub fn serveHTTP(self: *LoggingHandler, w: *ResponseWriter, req: *Request) anyerror!void {
        const start = std.Io.Clock.awake.now(w.io);
        const method = req.method.asString();
        const path = req.url.path;

        const result = self.next.serveHTTP(w, req);

        const duration = start.durationTo(std.Io.Clock.awake.now(w.io));
        const us = duration.toMicroseconds();
        const code = w.status_code.code();

        if (us < 1000) {
            std.log.info("{s} {s} {d} ({d}µs)", .{ method, path, code, us });
        } else {
            const ms = @as(f64, @floatFromInt(us)) / 1000.0;
            std.log.info("{s} {s} {d} ({d:.2}ms)", .{ method, path, code, ms });
        }

        return result;
    }

    /// handler returns a Handler interface pointing to this LoggingHandler.
    pub fn handler(self: *LoggingHandler) Handler {
        return Handler.from(self);
    }
};

/// MiddlewareFn represents a middleware constructor that wraps a Handler and returns an augmented Handler.
pub const MiddlewareFn = *const fn (next: Handler) Handler;

test "Handler fromFn and from struct" {
    const dummyFn = struct {
        fn handle(w: *ResponseWriter, req: *Request) anyerror!void {
            _ = w;
            _ = req;
        }
    }.handle;

    const h = Handler.fromFn(dummyFn);
    _ = h;

    const Counter = struct {
        count: usize = 0,
        pub fn serveHTTP(self: *@This(), w: *ResponseWriter, req: *Request) anyerror!void {
            _ = w;
            _ = req;
            self.count += 1;
        }
    };
    var c = Counter{};
    const h2 = Handler.from(&c);
    _ = h2;

    const App = struct {
        hits: usize = 0,
        fn getHits(self: *@This(), _: *ResponseWriter, _: *Request) anyerror!void {
            self.hits += 1;
        }
    };
    var app = App{};
    const h3 = Handler.bind(&app, App.getHits);
    _ = h3;
}

test "inline for batch route binding" {
    const App = struct {
        fn h1(_: *@This(), _: *ResponseWriter, _: *Request) anyerror!void {}
        fn h2(_: *@This(), _: *ResponseWriter, _: *Request) anyerror!void {}
    };
    var app = App{};
    const routes = .{
        .{ "GET /a", App.h1 },
        .{ "GET /b", App.h2 },
    };
    inline for (routes) |r| {
        const pattern, const method = r;
        const h = Handler.bind(&app, method);
        _ = pattern;
        _ = h;
    }
}
