# Static File Server CLI

This recipe demonstrates using `lighting.extra.fs` to build a full-featured static file server CLI with RFC 9110 Range seeking, ETag caching, and an adaptive dark-mode directory browser.

Source code: [`examples/fs/`](https://github.com/jiacai2050/lighting/tree/main/examples/fs)

---

## Server Implementation

```zig
const std = @import("std");
const http = @import("lighting");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Default to current directory if not specified
    const target_dir = if (args.len > 1) args[1] else ".";

    var fs = http.extra.fs.FileServer.init(allocator, .{
        .root_dir = target_dir,
        .auto_index = true,
        .index_file = "index.html",
        .show_hidden = false,
    });

    var mux = http.ServeMux.init(allocator);
    defer mux.deinit();

    try mux.handle("GET /{path...}", fs.handler());
    try mux.handle("HEAD /{path...}", fs.handler());

    var logging = http.LoggingHandler{ .next = mux.handler() };

    var server = http.Server.init(allocator, io, .{
        .handler = logging.handler(),
    });
    defer server.deinit();

    std.log.info("Serving directory '{s}' at http://127.0.0.1:7000...", .{target_dir});
    try server.listenAndServe("127.0.0.1", 7000);
}
```

---

## Running the Example

Run in the project directory:

```bash
make run-fs
```

Or pass a custom directory:

```bash
cd examples/fs && zig build run -- /path/to/my/docs
```

Features included:
* **Video/Audio Streaming**: Supports HTML5 `<video>` scrubbing via HTTP 206 Partial Content.
* **Bandwidth Optimization**: HTTP 304 Not Modified caching via strong ETags.
* **Security**: Traversal attacks like `/../../etc/passwd` are sanitized and safely rejected.
