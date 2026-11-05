# Middleware

Middleware functions intercept and wrap HTTP request processing. They are ideal for cross-cutting concerns like logging, timing, CORS headers, rate limiting, and panic/error recovery.

---

## 1. The Middleware Signature

A middleware in Lighting is a function or struct that wraps an inner `Handler` and returns an augmented `Handler`:

```zig
pub const MiddlewareFn = *const fn (next: Handler) Handler;
```

---

## 2. Built-in `LoggingHandler`

Lighting comes with an out-of-the-box `LoggingHandler` that records the HTTP method, request path, status code, and latency in microseconds or milliseconds:

```zig
const http = @import("lighting");

var mux = http.ServeMux.init(allocator);
// ... register routes ...

// Wrap mux with the logging middleware:
var logging = http.LoggingHandler{
    .next = mux.handler(),
};

var server = http.Server.init(allocator, io, .{
    .handler = logging.handler(),
});
```

Sample output:
```text
info: GET /ping 200 (42µs)
info: GET /users/123 200 (1.45ms)
info: GET /missing 404 (28µs)
```

---

## 3. Writing Custom Middleware

You can write custom middleware either using a struct or with closures.

### Struct-Based Middleware (Recommended)

Struct-based middleware provides the cleanest memory safety and state retention in Zig:

```zig
pub const HeaderMiddleware = struct {
    next: http.Handler,
    server_tag: []const u8,

    pub fn serveHTTP(self: *HeaderMiddleware, w: *http.ResponseWriter, req: *http.Request) anyerror!void {
        // Pre-processing: inject response header
        try w.header().set("X-Framework", self.server_tag);

        // Call the downstream handler
        return self.next.serveHTTP(w, req);
    }

    pub fn handler(self: *HeaderMiddleware) http.Handler {
        return http.Handler.from(self);
    }
};
```

Usage:
```zig
var headers_mw = HeaderMiddleware{
    .next = mux.handler(),
    .server_tag = "Lighting 0.1.0",
};

var logging_mw = http.LoggingHandler{
    .next = headers_mw.handler(),
};

var server = http.Server.init(allocator, io, .{
    .handler = logging_mw.handler(),
});
```

---

## 4. Middleware Chaining Pattern

To combine multiple middleware cleanly without nested initializations, define a chain helper:

```zig
pub fn chain(inner: http.Handler, middlewares: anytype) http.Handler {
    var current = inner;
    inline for (middlewares) |mw| {
        current = mw(current);
    }
    return current;
}
```

Or nest struct wrappers:
```text
Client Request
      │
      ▼
[Logging Middleware] (Starts clock)
      │
      ▼
[Security Headers Middleware] (Injects headers)
      │
      ▼
[Router (ServeMux)] (Matches route pattern)
      │
      ▼
[Endpoint Handler] (Processes business logic)
```
