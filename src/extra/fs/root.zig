//! Static file server, directory listing, MIME detection, and RFC 9110 HTTP Range handling.

const std = @import("std");
const server = @import("server.zig");
const mime = @import("mime.zig");
const range = @import("range.zig");
const dir = @import("dir.zig");

/// High-performance static file server supporting path traversal prevention, range requests, and ETag caching.
pub const FileServer = server.FileServer;

/// Configuration options for FileServer.
pub const FileServerOptions = server.FileServerOptions;

/// Detects standard MIME content-type string from a file extension.
pub const getMimeType = mime.getMimeType;

/// Parses standard RFC 9110 Range request header (e.g. "bytes=0-1023").
pub const parseRange = range.parseRange;

/// Represents a requested byte range interval [start, end].
pub const ByteRange = range.ByteRange;

/// Result of parsing an HTTP Range header.
pub const RangeResult = range.RangeResult;

/// Directory entry for HTML directory index rendering.
pub const DirEntry = dir.DirEntry;

/// Renders a directory listing HTML page.
pub const renderDirectory = dir.renderDirectory;

test {
    std.testing.refAllDecls(@This());
}
