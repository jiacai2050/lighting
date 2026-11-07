const std = @import("std");

/// HTTP request method enum (GET, POST, PUT, DELETE, etc.).
pub const Method = @import("proto/method.zig").Method;

/// Standard RFC 9110 HTTP response status codes.
pub const Status = @import("proto/status.zig").Status;

/// Supported HTTP protocol versions (HTTP/1.0 and HTTP/1.1).
pub const Version = @import("proto/parser.zig").Version;

/// Case-insensitive HTTP header map.
pub const HeaderMap = @import("header.zig").HeaderMap;

/// Single HTTP header name/value pair.
pub const HeaderEntry = @import("header.zig").HeaderEntry;

/// Incoming HTTP request representation.
pub const Request = @import("request.zig").Request;

/// Parsed request target URL breakdown.
pub const URL = @import("request.zig").URL;

/// Multi-value URL query parameter map paralleling Go's url.Values.
pub const QueryParams = @import("request.zig").QueryParams;

/// HTTP Cookie representation and Set-Cookie builder conforming to RFC 6265.
pub const Cookie = @import("cookie.zig").Cookie;

/// SameSite cookie attribute policy.
pub const SameSite = @import("cookie.zig").SameSite;

/// Parsed multipart/form-data container for form values and file uploads.
pub const MultipartForm = @import("multipart.zig").MultipartForm;

/// Uploaded file header within a multipart/form-data body.
pub const FileHeader = @import("multipart.zig").FileHeader;

/// HTTP response generator with dual-mode buffering and socket hijacking.
pub const ResponseWriter = @import("response_writer.zig").ResponseWriter;

/// Interface for handling incoming HTTP requests.
pub const Handler = @import("handler.zig").Handler;

/// Standard request logging middleware recording method, path, status, and duration.
pub const LoggingHandler = @import("handler.zig").LoggingHandler;

/// Middleware constructor function type `*const fn (Handler) Handler`.
pub const MiddlewareFn = @import("handler.zig").MiddlewareFn;

/// Route-level timeout middleware wrapping a Handler.
pub const TimeoutHandler = @import("timeout.zig").TimeoutHandler;

/// Constructs a TimeoutHandler wrapping next with a nanosecond duration limit.
pub const timeoutHandler = @import("timeout.zig").timeoutHandler;

/// HTTP request multiplexer matching incoming requests against URL patterns.
pub const ServeMux = @import("mux.zig").ServeMux;

/// High-performance HTTP server instance.
pub const Server = @import("server.zig").Server;

/// Configuration options for Server.
pub const ServerOptions = @import("server.zig").ServerOptions;

/// Zero-copy request line and headers parser.
pub const parseRequestHead = @import("proto/parser.zig").parseRequestHead;

/// HTTP request body stream reader supporting chunked encoding and Content-Length.
pub const BodyReader = @import("proto/chunk_reader.zig").BodyReader;

/// Extra extension modules: WebSocket, static file server, MIME types, and HTTP range support.
pub const extra = @import("extra/root.zig");

/// Legacy thread pool (deprecated; concurrency is handled natively via std.Io.Group).
pub const ThreadPool = @import("thread_pool.zig").ThreadPool;

test {
    std.testing.refAllDecls(@This());
}
