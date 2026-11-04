const std = @import("std");

/// Returns the standard MIME content-type string for a given file path based on its extension.
/// Defaults to "application/octet-stream" if unrecognized.
pub fn getMimeType(file_path: []const u8) []const u8 {
    const ext = std.fs.path.extension(file_path);
    if (ext.len == 0) return "application/octet-stream";

    // Text & Web formats
    if (std.ascii.eqlIgnoreCase(ext, ".html") or std.ascii.eqlIgnoreCase(ext, ".htm")) {
        return "text/html; charset=utf-8";
    } else if (std.ascii.eqlIgnoreCase(ext, ".css")) {
        return "text/css; charset=utf-8";
    } else if (std.ascii.eqlIgnoreCase(ext, ".js") or std.ascii.eqlIgnoreCase(ext, ".mjs")) {
        return "text/javascript; charset=utf-8";
    } else if (std.ascii.eqlIgnoreCase(ext, ".json")) {
        return "application/json; charset=utf-8";
    } else if (std.ascii.eqlIgnoreCase(ext, ".xml")) {
        return "application/xml; charset=utf-8";
    } else if (std.ascii.eqlIgnoreCase(ext, ".wasm")) {
        return "application/wasm";
    } else if (std.ascii.eqlIgnoreCase(ext, ".txt") or std.ascii.eqlIgnoreCase(ext, ".zig") or
        std.ascii.eqlIgnoreCase(ext, ".c") or std.ascii.eqlIgnoreCase(ext, ".h") or
        std.ascii.eqlIgnoreCase(ext, ".log"))
    {
        return "text/plain; charset=utf-8";
    } else if (std.ascii.eqlIgnoreCase(ext, ".md")) {
        return "text/markdown; charset=utf-8";
    }

    // Images
    if (std.ascii.eqlIgnoreCase(ext, ".svg")) {
        return "image/svg+xml";
    } else if (std.ascii.eqlIgnoreCase(ext, ".png")) {
        return "image/png";
    } else if (std.ascii.eqlIgnoreCase(ext, ".jpg") or std.ascii.eqlIgnoreCase(ext, ".jpeg")) {
        return "image/jpeg";
    } else if (std.ascii.eqlIgnoreCase(ext, ".gif")) {
        return "image/gif";
    } else if (std.ascii.eqlIgnoreCase(ext, ".webp")) {
        return "image/webp";
    } else if (std.ascii.eqlIgnoreCase(ext, ".ico")) {
        return "image/x-icon";
    } else if (std.ascii.eqlIgnoreCase(ext, ".avif")) {
        return "image/avif";
    }

    // Audio & Video
    if (std.ascii.eqlIgnoreCase(ext, ".mp4")) {
        return "video/mp4";
    } else if (std.ascii.eqlIgnoreCase(ext, ".webm")) {
        return "video/webm";
    } else if (std.ascii.eqlIgnoreCase(ext, ".mp3")) {
        return "audio/mpeg";
    } else if (std.ascii.eqlIgnoreCase(ext, ".wav")) {
        return "audio/wav";
    } else if (std.ascii.eqlIgnoreCase(ext, ".ogg")) {
        return "audio/ogg";
    }

    // Archives & Documents
    if (std.ascii.eqlIgnoreCase(ext, ".pdf")) {
        return "application/pdf";
    } else if (std.ascii.eqlIgnoreCase(ext, ".zip")) {
        return "application/zip";
    } else if (std.ascii.eqlIgnoreCase(ext, ".gz") or std.ascii.eqlIgnoreCase(ext, ".tgz")) {
        return "application/gzip";
    } else if (std.ascii.eqlIgnoreCase(ext, ".tar")) {
        return "application/x-tar";
    }

    return "application/octet-stream";
}

test "getMimeType" {
    try std.testing.expectEqualStrings("text/html; charset=utf-8", getMimeType("index.html"));
    try std.testing.expectEqualStrings("text/javascript; charset=utf-8", getMimeType("app.mjs"));
    try std.testing.expectEqualStrings("video/mp4", getMimeType("movie.mp4"));
    try std.testing.expectEqualStrings("image/svg+xml", getMimeType("logo.svg"));
    try std.testing.expectEqualStrings("application/octet-stream", getMimeType("unknown.xyz"));
    try std.testing.expectEqualStrings("application/octet-stream", getMimeType("no_extension"));
}
