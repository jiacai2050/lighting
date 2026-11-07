//! Extra protocol extensions and server utilities for lighting.

const std = @import("std");

/// WebSocket protocol upgrade and connection framing conforming to RFC 6455.
pub const ws = @import("ws/root.zig");

/// High-performance static file server with RFC 9110 HTTP Range and automatic MIME detection.
pub const fs = @import("fs/root.zig");

/// Reverse proxy HTTP handler conforming to Go's httputil.ReverseProxy.
pub const proxy = @import("proxy/root.zig");

test {
    std.testing.refAllDecls(@This());
}
