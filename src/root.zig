const std = @import("std");

pub const Method = @import("proto/method.zig").Method;
pub const Status = @import("proto/status.zig").Status;
pub const Version = @import("proto/parser.zig").Version;

pub const HeaderMap = @import("header.zig").HeaderMap;
pub const HeaderEntry = @import("header.zig").HeaderEntry;

pub const Request = @import("request.zig").Request;
pub const URL = @import("request.zig").URL;

pub const ResponseWriter = @import("response_writer.zig").ResponseWriter;

pub const Handler = @import("handler.zig").Handler;
pub const LoggingHandler = @import("handler.zig").LoggingHandler;
pub const MiddlewareFn = @import("handler.zig").MiddlewareFn;

pub const ServeMux = @import("mux.zig").ServeMux;

pub const Server = @import("server.zig").Server;
pub const ServerOptions = @import("server.zig").ServerOptions;

pub const parseRequestHead = @import("proto/parser.zig").parseRequestHead;
pub const BodyReader = @import("proto/chunk_reader.zig").BodyReader;

pub const extra = @import("extra/root.zig");

test {
    std.testing.refAllDecls(@This());
    _ = @import("proto/method.zig");
    _ = @import("proto/status.zig");
    _ = @import("proto/parser.zig");
    _ = @import("proto/chunk_reader.zig");
    _ = @import("header.zig");
    _ = @import("request.zig");
    _ = @import("response_writer.zig");
    _ = @import("handler.zig");
    _ = @import("mux.zig");
    _ = @import("thread_pool.zig");
    _ = @import("server.zig");
    _ = @import("extra/root.zig");
}
