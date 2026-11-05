const std = @import("std");
const ResponseWriter = @import("../../response_writer.zig").ResponseWriter;
const Request = @import("../../request.zig").Request;
const Handler = @import("../../handler.zig").Handler;
const URL = @import("../../request.zig").URL;
const mime = @import("mime.zig");
const range_mod = @import("range.zig");
const dir_mod = @import("dir.zig");

pub const FileServerOptions = struct {
    /// Filesystem directory to serve
    root_dir: []const u8,
    /// When request targets a directory without index_file, auto-generate HTML file list
    auto_index: bool = true,
    /// Default index file for directory requests
    index_file: []const u8 = "index.html",
    /// Whether to allow requests for hidden files/folders (starting with dot)
    show_hidden: bool = false,
    /// Stream read buffer size in bytes (default: 64KB)
    chunk_size: usize = 64 * 1024,
    /// Optional URL prefix to strip (e.g. "/static") before resolving in root_dir
    strip_prefix: ?[]const u8 = null,
};

pub const FileServer = struct {
    allocator: std.mem.Allocator,
    options: FileServerOptions,

    pub fn init(allocator: std.mem.Allocator, options: FileServerOptions) FileServer {
        return .{
            .allocator = allocator,
            .options = options,
        };
    }

    /// Converts this FileServer instance into a standard Lighting Handler interface
    pub fn handler(self: *FileServer) Handler {
        return Handler.from(self);
    }

    fn openRootDir(self: *const FileServer, io: std.Io) !std.Io.Dir {
        if (std.fs.path.isAbsolute(self.options.root_dir)) {
            return std.Io.Dir.openDirAbsolute(io, self.options.root_dir, .{ .iterate = true });
        } else {
            var cwd = std.Io.Dir.cwd();
            return cwd.openDir(io, self.options.root_dir, .{ .iterate = true });
        }
    }

    /// Sanitizes an input relative URL path to strictly prevent directory traversal (e.g. ../)
    /// Returns null if path attempts to escape the root directory or contains null bytes.
    pub fn sanitizePath(allocator: std.mem.Allocator, raw_path: []const u8) !?[]const u8 {
        if (std.mem.indexOfScalar(u8, raw_path, 0) != null) return null;

        var it = std.mem.tokenizeAny(u8, raw_path, "/\\");
        var parts = try std.ArrayList([]const u8).initCapacity(allocator, 8);
        defer parts.deinit(allocator);

        while (it.next()) |part| {
            if (std.mem.eql(u8, part, ".")) continue;
            if (std.mem.eql(u8, part, "..")) {
                if (parts.items.len == 0) {
                    // Attempting to traverse above root
                    return null;
                }
                _ = parts.pop();
            } else {
                try parts.append(allocator, part);
            }
        }

        if (parts.items.len == 0) return try allocator.dupe(u8, ".");
        return try std.mem.join(allocator, "/", parts.items);
    }

    pub fn serveHTTP(self: *FileServer, w: *ResponseWriter, req: *Request) anyerror!void {
        // 1. HTTP method validation: only GET and HEAD are allowed
        if (req.method != .GET and req.method != .HEAD) {
            w.setStatus(.method_not_allowed);
            try w.header().set("Allow", "GET, HEAD");
            try w.header().set("Content-Type", "text/plain; charset=utf-8");
            try w.writeAll("Method Not Allowed\n");
            return;
        }

        var req_path = req.url.path;

        // 2. Strip prefix if configured
        if (self.options.strip_prefix) |prefix| {
            const p = std.mem.trimEnd(u8, prefix, "/");
            if (p.len > 0) {
                if (std.mem.startsWith(u8, req_path, p)) {
                    const rest = req_path[p.len..];
                    if (rest.len == 0 or rest[0] == '/') {
                        req_path = if (rest.len == 0) "/" else rest;
                    } else {
                        // Non-segment match (e.g. prefix is "/static", req_path is "/staticfoo")
                        w.setStatus(.not_found);
                        try w.header().set("Content-Type", "text/plain; charset=utf-8");
                        try w.writeAll("Not Found\n");
                        return;
                    }
                } else {
                    w.setStatus(.not_found);
                    try w.header().set("Content-Type", "text/plain; charset=utf-8");
                    try w.writeAll("Not Found\n");
                    return;
                }
            }
        }

        // 3. URL unescape percent-encoded paths
        const unescaped = try URL.unescape(req.arena, req_path);

        // 4. Safe relative path normalization & traversal defense
        const safe_rel = (try sanitizePath(req.arena, unescaped)) orelse {
            w.setStatus(.forbidden);
            try w.header().set("Content-Type", "text/plain; charset=utf-8");
            try w.writeAll("Forbidden: Directory traversal attempt\n");
            return;
        };

        // 5. Hidden file check
        if (!self.options.show_hidden) {
            var seg_it = std.mem.tokenizeScalar(u8, safe_rel, '/');
            while (seg_it.next()) |seg| {
                if (seg.len > 0 and seg[0] == '.' and !std.mem.eql(u8, seg, ".")) {
                    w.setStatus(.not_found);
                    try w.header().set("Content-Type", "text/plain; charset=utf-8");
                    try w.writeAll("Not Found\n");
                    return;
                }
            }
        }

        // 6. Inspect target stat
        var root_dir = self.openRootDir(w.io) catch |err| {
            std.log.err("FileServer: failed to open root_dir '{s}': {any}", .{ self.options.root_dir, err });
            w.setStatus(.internal_server_error);
            try w.header().set("Content-Type", "text/plain; charset=utf-8");
            try w.writeAll("Internal Server Error\n");
            return;
        };
        defer root_dir.close(w.io);

        const stat = root_dir.statFile(w.io, safe_rel, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                w.setStatus(.not_found);
                try w.header().set("Content-Type", "text/plain; charset=utf-8");
                try w.writeAll("Not Found\n");
                return;
            },
            else => return err,
        };

        // 7. Directory handling
        if (stat.kind == .directory) {
            // Canonical directory URL must end with trailing slash (RFC 9110 standard practice)
            if (!std.mem.endsWith(u8, req.url.path, "/")) {
                const redir = if (req.url.raw_query) |q|
                    try std.fmt.allocPrint(req.arena, "{s}/?{s}", .{ req.url.path, q })
                else
                    try std.fmt.allocPrint(req.arena, "{s}/", .{req.url.path});
                w.setStatus(.moved_permanently);
                try w.header().set("Location", redir);
                return;
            }

            // Check if index_file exists
            var has_index = false;
            var index_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const index_subpath = if (std.mem.eql(u8, safe_rel, "."))
                self.options.index_file
            else
                try std.fmt.bufPrint(&index_path_buf, "{s}/{s}", .{ safe_rel, self.options.index_file });

            if (root_dir.statFile(w.io, index_subpath, .{})) |index_stat| {
                if (index_stat.kind == .file) {
                    has_index = true;
                }
            } else |_| {}

            if (has_index) {
                return self.serveFile(w, req, root_dir, index_subpath);
            }

            // Auto-index directory listing
            if (self.options.auto_index) {
                return self.serveDirectoryListing(w, req, root_dir, safe_rel, req.url.path);
            } else {
                w.setStatus(.forbidden);
                try w.header().set("Content-Type", "text/plain; charset=utf-8");
                try w.writeAll("Forbidden: Directory listing disabled\n");
                return;
            }
        }

        // 8. Regular file handling (reject special devices, FIFOs, and sockets)
        if (stat.kind != .file) {
            w.setStatus(.not_found);
            try w.header().set("Content-Type", "text/plain; charset=utf-8");
            try w.writeAll("Not Found\n");
            return;
        }

        return self.serveFile(w, req, root_dir, safe_rel);
    }

    fn serveFile(
        self: *FileServer,
        w: *ResponseWriter,
        req: *Request,
        dir: std.Io.Dir,
        subpath: []const u8,
    ) anyerror!void {
        const stat = try dir.statFile(w.io, subpath, .{});

        // Compute ETag: W/"<mtime_ns_hex>-<size_hex>"
        var etag_buf: [64]u8 = undefined;
        const etag = try std.fmt.bufPrint(&etag_buf, "W/\"{x}-{x}\"", .{ stat.mtime.nanoseconds, stat.size });
        const etag_dup = try req.arena.dupe(u8, etag);

        // Compute Last-Modified (RFC 9110 HTTP-date)
        var lm_buf: [29]u8 = undefined;
        const lm_str = ResponseWriter.formatHttpDate(&lm_buf, stat.mtime.toSeconds());
        const lm_dup = try req.arena.dupe(u8, lm_str);

        // Check conditional If-None-Match (RFC 9110 Section 8.8.3.2 / RFC 9111 Section 3.2: weak comparison & tag lists)
        if (req.headers.get("if-none-match")) |inm| {
            var it = std.mem.tokenizeScalar(u8, inm, ',');
            var matched = false;
            const norm_etag = if (std.mem.startsWith(u8, etag, "W/")) etag[2..] else etag;
            while (it.next()) |raw_tag| {
                const tag = std.mem.trim(u8, raw_tag, " \t");
                const norm_tag = if (std.mem.startsWith(u8, tag, "W/")) tag[2..] else tag;
                if (std.mem.eql(u8, tag, "*") or std.mem.eql(u8, norm_tag, norm_etag)) {
                    matched = true;
                    break;
                }
            }
            if (matched) {
                w.setStatus(.not_modified);
                try w.header().set("ETag", etag_dup);
                try w.header().set("Last-Modified", lm_dup);
                return;
            }
        }

        const mime_type = mime.getMimeType(subpath);

        // Parse Range request (RFC 9110 Section 14)
        const range_hdr = req.headers.get("range");
        const range_result = range_mod.parseRange(range_hdr, stat.size);

        switch (range_result) {
            .not_satisfiable => {
                w.setStatus(.range_not_satisfiable);
                var cr_buf: [48]u8 = undefined;
                const cr = try std.fmt.bufPrint(&cr_buf, "bytes */{d}", .{stat.size});
                const cr_dup = try req.arena.dupe(u8, cr);
                try w.header().set("Content-Range", cr_dup);
                try w.header().set("Content-Type", "text/plain; charset=utf-8");
                try w.writeAll("Range Not Satisfiable\n");
                return;
            },
            .single => |r| {
                // 206 Partial Content
                w.setStatus(.partial_content);
                try w.header().set("Accept-Ranges", "bytes");
                try w.header().set("Content-Type", mime_type);
                try w.header().set("ETag", etag_dup);
                try w.header().set("Last-Modified", lm_dup);

                var cr_buf: [64]u8 = undefined;
                const cr = try std.fmt.bufPrint(&cr_buf, "bytes {d}-{d}/{d}", .{ r.start, r.end, stat.size });
                const cr_dup = try req.arena.dupe(u8, cr);
                try w.header().set("Content-Range", cr_dup);

                var cl_buf: [32]u8 = undefined;
                const cl = try std.fmt.bufPrint(&cl_buf, "{d}", .{r.length()});
                const cl_dup = try req.arena.dupe(u8, cl);
                try w.header().set("Content-Length", cl_dup);

                try self.streamFileRange(w, dir, subpath, r.start, r.length());
            },
            .none, .ignore => {
                // 200 OK Full content
                w.setStatus(.ok);
                try w.header().set("Accept-Ranges", "bytes");
                try w.header().set("Content-Type", mime_type);
                try w.header().set("ETag", etag_dup);
                try w.header().set("Last-Modified", lm_dup);

                var cl_buf: [32]u8 = undefined;
                const cl = try std.fmt.bufPrint(&cl_buf, "{d}", .{stat.size});
                const cl_dup = try req.arena.dupe(u8, cl);
                try w.header().set("Content-Length", cl_dup);

                try self.streamFileRange(w, dir, subpath, 0, stat.size);
            },
        }
    }

    fn streamFileRange(
        self: *FileServer,
        w: *ResponseWriter,
        dir: std.Io.Dir,
        subpath: []const u8,
        start_offset: u64,
        total_len: u64,
    ) anyerror!void {
        if (total_len == 0 or w.is_head) return;

        const file = try dir.openFile(w.io, subpath, .{});
        defer file.close(w.io);

        const chunk_buf = try self.allocator.alloc(u8, self.options.chunk_size);
        defer self.allocator.free(chunk_buf);

        var remaining = total_len;
        var offset = start_offset;

        while (remaining > 0) {
            const to_read: usize = @intCast(@min(remaining, chunk_buf.len));
            const n = try file.readPositionalAll(w.io, chunk_buf[0..to_read], offset);
            if (n == 0) break; // Unexpected EOF
            try w.writeAll(chunk_buf[0..n]);
            offset += n;
            remaining -= n;
        }
    }

    fn serveDirectoryListing(
        self: *FileServer,
        w: *ResponseWriter,
        req: *Request,
        root_dir: std.Io.Dir,
        dir_subpath: []const u8,
        display_url: []const u8,
    ) anyerror!void {
        var target_dir = try root_dir.openDir(w.io, dir_subpath, .{ .iterate = true });
        defer target_dir.close(w.io);

        var entries = try std.ArrayList(dir_mod.DirEntry).initCapacity(req.arena, 16);

        var it = target_dir.iterate();
        while (try it.next(w.io)) |entry| {
            if (!self.options.show_hidden and entry.name.len > 0 and entry.name[0] == '.') {
                continue;
            }

            const name_dup = try req.arena.dupe(u8, entry.name);
            var size: u64 = 0;
            var mtime_secs: i64 = 0;

            if (target_dir.statFile(w.io, entry.name, .{})) |st| {
                size = st.size;
                mtime_secs = st.mtime.toSeconds();
            } else |_| {}

            try entries.append(req.arena, .{
                .name = name_dup,
                .is_dir = (entry.kind == .directory),
                .size = size,
                .mtime_secs = mtime_secs,
            });
        }

        // Sort: directories first, then alphabetically
        std.mem.sort(dir_mod.DirEntry, entries.items, {}, struct {
            fn lessThan(_: void, a: dir_mod.DirEntry, b: dir_mod.DirEntry) bool {
                if (a.is_dir != b.is_dir) return a.is_dir; // true (.is_dir) comes first
                return std.ascii.lessThanIgnoreCase(a.name, b.name);
            }
        }.lessThan);

        const is_root = std.mem.eql(u8, dir_subpath, ".");
        const html = try dir_mod.renderDirectory(req.arena, display_url, entries.items, is_root);

        w.setStatus(.ok);
        try w.header().set("Content-Type", "text/html; charset=utf-8");
        var cl_buf: [32]u8 = undefined;
        const cl = try std.fmt.bufPrint(&cl_buf, "{d}", .{html.len});
        const cl_dup = try req.arena.dupe(u8, cl);
        try w.header().set("Content-Length", cl_dup);

        try w.writeAll(html);
    }
};

test "FileServer.sanitizePath tests" {
    const alloc = std.testing.allocator;

    const p1 = (try FileServer.sanitizePath(alloc, "/")) orelse unreachable;
    defer alloc.free(p1);
    try std.testing.expectEqualStrings(".", p1);

    const p2 = (try FileServer.sanitizePath(alloc, "/foo/bar.txt")) orelse unreachable;
    defer alloc.free(p2);
    try std.testing.expectEqualStrings("foo/bar.txt", p2);

    const p3 = (try FileServer.sanitizePath(alloc, "/a/b/../c")) orelse unreachable;
    defer alloc.free(p3);
    try std.testing.expectEqualStrings("a/c", p3);

    // Traversal attempts
    try std.testing.expect((try FileServer.sanitizePath(alloc, "/../etc/passwd")) == null);
    try std.testing.expect((try FileServer.sanitizePath(alloc, "/a/../../b")) == null);
    try std.testing.expect((try FileServer.sanitizePath(alloc, "foo/bar\x00baz")) == null);
}
