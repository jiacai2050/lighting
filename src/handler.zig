const std = @import("std");
const ResponseWriter = @import("response_writer.zig").ResponseWriter;
const Request = @import("request.zig").Request;

pub const Handler = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        serveHTTP: *const fn (ctx: *anyopaque, w: *ResponseWriter, req: *Request) anyerror!void,
    };

    pub fn serveHTTP(self: Handler, w: *ResponseWriter, req: *Request) anyerror!void {
        return self.vtable.serveHTTP(self.ptr, w, req);
    }

    /// Wraps a stateless function pointer as a Handler
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

    /// Wraps any struct pointer that implements `serveHTTP(*@This(), *ResponseWriter, *Request) anyerror!void`
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
};

/// Middleware function type: wraps a Handler and returns an augmented Handler
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
}
