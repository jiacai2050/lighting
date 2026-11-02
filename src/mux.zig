const std = @import("std");
const Handler = @import("handler.zig").Handler;
const ResponseWriter = @import("response_writer.zig").ResponseWriter;
const Request = @import("request.zig").Request;

pub const Segment = struct {
    s: []const u8,
    wild: bool,
    multi: bool,
};

pub const Pattern = struct {
    str: []const u8,
    method: ?[]const u8 = null,
    host: ?[]const u8 = null,
    segments: []const Segment,
};

pub const MatchResult = struct {
    handler: Handler,
    pattern: Pattern,
    matches: []const []const u8,
};

pub const RoutingNode = struct {
    pattern: ?Pattern = null,
    handler: ?Handler = null,
    children: std.StringHashMapUnmanaged(*RoutingNode) = .empty,
    wild_child: ?*RoutingNode = null,
    multi_child: ?*RoutingNode = null,
    empty_child: ?*RoutingNode = null,

    pub fn addChild(self: *RoutingNode, allocator: std.mem.Allocator, key: []const u8) !*RoutingNode {
        if (key.len == 0) {
            if (self.empty_child == null) {
                const node = try allocator.create(RoutingNode);
                node.* = .{};
                self.empty_child = node;
            }
            return self.empty_child.?;
        }
        if (self.children.get(key)) |existing| {
            return existing;
        }
        const node = try allocator.create(RoutingNode);
        node.* = .{};
        try self.children.put(allocator, key, node);
        return node;
    }

    pub fn addSegments(
        self: *RoutingNode,
        allocator: std.mem.Allocator,
        segs: []const Segment,
        pat: Pattern,
        h: Handler,
    ) !void {
        if (segs.len == 0) {
            self.pattern = pat;
            self.handler = h;
            return;
        }

        const seg = segs[0];
        if (seg.multi) {
            std.debug.assert(segs.len == 1);
            if (self.multi_child == null) {
                const node = try allocator.create(RoutingNode);
                node.* = .{};
                self.multi_child = node;
            }
            self.multi_child.?.pattern = pat;
            self.multi_child.?.handler = h;
        } else if (seg.wild) {
            if (self.wild_child == null) {
                const node = try allocator.create(RoutingNode);
                node.* = .{};
                self.wild_child = node;
            }
            try self.wild_child.?.addSegments(allocator, segs[1..], pat, h);
        } else {
            const child = try self.addChild(allocator, seg.s);
            try child.addSegments(allocator, segs[1..], pat, h);
        }
    }

    pub fn matchPath(
        self: *const RoutingNode,
        allocator: std.mem.Allocator,
        path: []const u8,
        matches: *std.ArrayListUnmanaged([]const u8),
    ) ?*const RoutingNode {
        if (path.len == 0) {
            if (self.pattern != null) {
                return self;
            }
            return null;
        }

        const s = firstSegment(path);
        const seg = s.seg;
        const rest = s.rest;

        // 1. Literal match (most specific)
        if (self.children.get(seg)) |child| {
            if (child.matchPath(allocator, rest, matches)) |leaf| {
                return leaf;
            }
        }

        // 2. Single wildcard match (next most specific)
        // Single wildcards do not match trailing slashes (where seg == "/")
        if (!std.mem.eql(u8, seg, "/") and self.wild_child != null) {
            const save_len = matches.items.len;
            matches.append(allocator, seg) catch return null;
            if (self.wild_child.?.matchPath(allocator, rest, matches)) |leaf| {
                return leaf;
            }
            matches.shrinkRetainingCapacity(save_len);
        }

        // 3. Multi wildcard match (least specific)
        if (self.multi_child) |multi| {
            const pat = multi.pattern.?;
            const last_seg = pat.segments[pat.segments.len - 1];
            if (last_seg.s.len > 0) {
                const val = if (std.mem.startsWith(u8, path, "/")) path[1..] else path;
                matches.append(allocator, val) catch return null;
            }
            return multi;
        }

        return null;
    }
};

pub fn firstSegment(path: []const u8) struct { seg: []const u8, rest: []const u8 } {
    if (std.mem.eql(u8, path, "/")) {
        return .{ .seg = "/", .rest = "" };
    }
    var p = path;
    if (std.mem.startsWith(u8, p, "/")) {
        p = p[1..];
    }
    if (std.mem.indexOfScalar(u8, p, '/')) |idx| {
        return .{ .seg = p[0..idx], .rest = p[idx..] };
    } else {
        return .{ .seg = p, .rest = "" };
    }
}

pub fn parsePattern(allocator: std.mem.Allocator, raw: []const u8) !Pattern {
    const s = std.mem.trim(u8, raw, " \t\r\n");
    if (s.len == 0) return error.EmptyPattern;

    var method: ?[]const u8 = null;
    var rest = s;

    if (std.mem.indexOfAny(u8, s, " \t")) |space_idx| {
        const m = s[0..space_idx];
        method = try allocator.dupe(u8, m);
        rest = std.mem.trimStart(u8, s[space_idx + 1 ..], " \t");
    }

    const slash_idx = std.mem.indexOfScalar(u8, rest, '/') orelse return error.MissingSlash;
    const host_part = rest[0..slash_idx];
    const host: ?[]const u8 = if (host_part.len > 0) try allocator.dupe(u8, host_part) else null;
    var path_part = rest[slash_idx..];

    var seg_list = std.ArrayListUnmanaged(Segment).empty;
    while (path_part.len > 0) {
        std.debug.assert(path_part[0] == '/');
        path_part = path_part[1..];
        if (path_part.len == 0) {
            // Trailing slash -> anonymous multi wildcard
            try seg_list.append(allocator, .{ .s = "", .wild = true, .multi = true });
            break;
        }
        const next_slash = std.mem.indexOfScalar(u8, path_part, '/');
        const seg_str = if (next_slash) |idx| path_part[0..idx] else path_part;
        path_part = if (next_slash) |idx| path_part[idx..] else "";

        if (std.mem.startsWith(u8, seg_str, "{") and std.mem.endsWith(u8, seg_str, "}")) {
            const inner = seg_str[1 .. seg_str.len - 1];
            if (std.mem.eql(u8, inner, "$")) {
                if (path_part.len != 0) return error.DollarNotAtEnd;
                try seg_list.append(allocator, .{ .s = "/", .wild = false, .multi = false });
                break;
            } else if (std.mem.endsWith(u8, inner, "...")) {
                if (path_part.len != 0) return error.MultiWildcardNotAtEnd;
                const name = inner[0 .. inner.len - 3];
                if (name.len == 0) return error.EmptyWildcardName;
                const name_dup = try allocator.dupe(u8, name);
                try seg_list.append(allocator, .{ .s = name_dup, .wild = true, .multi = true });
                break;
            } else {
                if (inner.len == 0) return error.EmptyWildcardName;
                const name_dup = try allocator.dupe(u8, inner);
                try seg_list.append(allocator, .{ .s = name_dup, .wild = true, .multi = false });
            }
        } else {
            const seg_dup = try allocator.dupe(u8, seg_str);
            try seg_list.append(allocator, .{ .s = seg_dup, .wild = false, .multi = false });
        }
    }

    return Pattern{
        .str = try allocator.dupe(u8, s),
        .method = method,
        .host = host,
        .segments = try seg_list.toOwnedSlice(allocator),
    };
}

pub const ServeMux = struct {
    arena: std.heap.ArenaAllocator,
    root: *RoutingNode,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ServeMux {
        var arena = std.heap.ArenaAllocator.init(allocator);
        const root = arena.allocator().create(RoutingNode) catch unreachable;
        root.* = .{};
        return .{
            .arena = arena,
            .root = root,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ServeMux) void {
        self.arena.deinit();
    }

    /// Register a Go 1.22+ pattern route.
    /// Syntax: [METHOD ] [HOST]/[PATH]
    /// Wildcards: {id}, {path...}, {$}, trailing '/'
    pub fn handle(self: *ServeMux, pattern: []const u8, h: Handler) !void {
        const parsed = try parsePattern(self.arena.allocator(), pattern);
        const arena_allocator = self.arena.allocator();

        // 1. Host level
        const host_node = try self.root.addChild(arena_allocator, parsed.host orelse "");
        // 2. Method level
        const method_node = try host_node.addChild(arena_allocator, parsed.method orelse "");
        // 3. Path segments
        try method_node.addSegments(arena_allocator, parsed.segments, parsed, h);
    }

    /// Convenience helper to register a function pointer
    pub fn handleFunc(self: *ServeMux, pattern: []const u8, comptime func: *const fn (*ResponseWriter, *Request) anyerror!void) !void {
        try self.handle(pattern, Handler.fromFn(func));
    }

    /// Match a request to a handler with wildcards extracted.
    pub fn matchTree(
        self: *const ServeMux,
        allocator: std.mem.Allocator,
        host: ?[]const u8,
        method: []const u8,
        path: []const u8,
        matches: *std.ArrayListUnmanaged([]const u8),
    ) ?MatchResult {
        // 1. Host match
        if (host) |h| {
            const h_name = if (std.mem.indexOfScalar(u8, h, ':')) |colon| h[0..colon] else h;
            if (self.root.children.get(h_name)) |hn| {
                if (matchMethodAndPath(hn, allocator, method, path, matches)) |res| {
                    return res;
                }
            }
        }

        // Fall back to patterns with no host
        if (self.root.empty_child) |hn| {
            if (matchMethodAndPath(hn, allocator, method, path, matches)) |res| {
                return res;
            }
        }

        return null;
    }

    fn matchMethodAndPath(
        host_node: *const RoutingNode,
        allocator: std.mem.Allocator,
        method: []const u8,
        path: []const u8,
        matches: *std.ArrayListUnmanaged([]const u8),
    ) ?MatchResult {
        // Exact method match
        if (host_node.children.get(method)) |mn| {
            if (mn.matchPath(allocator, path, matches)) |leaf| {
                return .{
                    .handler = leaf.handler.?,
                    .pattern = leaf.pattern.?,
                    .matches = matches.items,
                };
            }
        }

        // If method is HEAD, also try GET
        if (std.mem.eql(u8, method, "HEAD")) {
            if (host_node.children.get("GET")) |mn| {
                if (mn.matchPath(allocator, path, matches)) |leaf| {
                    return .{
                        .handler = leaf.handler.?,
                        .pattern = leaf.pattern.?,
                        .matches = matches.items,
                    };
                }
            }
        }

        // Try patterns with no method (matches any method)
        if (host_node.empty_child) |mn| {
            if (mn.matchPath(allocator, path, matches)) |leaf| {
                return .{
                    .handler = leaf.handler.?,
                    .pattern = leaf.pattern.?,
                    .matches = matches.items,
                };
            }
        }

        return null;
    }

    pub fn collectAllowedMethods(
        self: *const ServeMux,
        allocator: std.mem.Allocator,
        host: ?[]const u8,
        path: []const u8,
        out: *std.ArrayListUnmanaged([]const u8),
    ) !void {
        if (host) |h| {
            const h_name = if (std.mem.indexOfScalar(u8, h, ':')) |colon| h[0..colon] else h;
            if (self.root.children.get(h_name)) |hn| {
                try collectFromHostNode(hn, allocator, path, out);
            }
        }
        if (self.root.empty_child) |hn| {
            try collectFromHostNode(hn, allocator, path, out);
        }
    }

    fn collectFromHostNode(
        hn: *const RoutingNode,
        allocator: std.mem.Allocator,
        path: []const u8,
        out: *std.ArrayListUnmanaged([]const u8),
    ) !void {
        var it = hn.children.iterator();
        while (it.next()) |entry| {
            const method_name = entry.key_ptr.*;
            const child = entry.value_ptr.*;
            var dummy_matches = std.ArrayListUnmanaged([]const u8).empty;
            defer dummy_matches.deinit(allocator);

            if (child.matchPath(allocator, path, &dummy_matches)) |_| {
                var exists = false;
                for (out.items) |m| {
                    if (std.mem.eql(u8, m, method_name)) {
                        exists = true;
                        break;
                    }
                }
                if (!exists) {
                    try out.append(allocator, method_name);
                }
            }
        }

        var has_get = false;
        var has_head = false;
        for (out.items) |m| {
            if (std.mem.eql(u8, m, "GET")) has_get = true;
            if (std.mem.eql(u8, m, "HEAD")) has_head = true;
        }
        if (has_get and !has_head) {
            try out.append(allocator, "HEAD");
        }
    }

    /// Backward compatibility helper
    pub fn match(self: *const ServeMux, path: []const u8) ?Handler {
        var dummy_matches = std.ArrayListUnmanaged([]const u8).empty;
        const res = self.matchTree(self.allocator, null, "GET", path, &dummy_matches);
        dummy_matches.deinit(self.allocator);
        if (res) |r| return r.handler;
        return null;
    }

    pub fn serveHTTP(self: *ServeMux, w: *ResponseWriter, req: *Request) anyerror!void {
        const host = req.headers.get("host");
        const method = req.method.asString();
        const path = req.url.path;

        var matches = std.ArrayListUnmanaged([]const u8).empty;
        if (self.matchTree(req.arena, host, method, path, &matches)) |result| {
            // Populate path values into req
            var match_idx: usize = 0;
            for (result.pattern.segments) |seg| {
                if (seg.wild) {
                    if (match_idx < matches.items.len) {
                        const val = matches.items[match_idx];
                        match_idx += 1;
                        if (seg.s.len > 0) {
                            try req.setPathValue(seg.s, val);
                        }
                    }
                }
            }
            try result.handler.serveHTTP(w, req);
            return;
        }

        // Check if method not allowed (405)
        var allowed = std.ArrayListUnmanaged([]const u8).empty;
        try self.collectAllowedMethods(req.arena, host, path, &allowed);

        if (allowed.items.len > 0) {
            w.writeHeader(.method_not_allowed);
            try w.header().set("Content-Type", "text/plain; charset=utf-8");
            var allow_buf = std.ArrayListUnmanaged(u8).empty;
            for (allowed.items, 0..) |m, i| {
                if (i > 0) try allow_buf.appendSlice(req.arena, ", ");
                try allow_buf.appendSlice(req.arena, m);
            }
            try w.header().set("Allow", allow_buf.items);
            try w.writeAll("Method Not Allowed\n");
            return;
        }

        // 404 Not Found
        w.writeHeader(.not_found);
        try w.header().set("Content-Type", "text/plain; charset=utf-8");
        try w.writeAll("404 page not found\n");
    }

    pub fn handler(self: *ServeMux) Handler {
        return Handler.from(self);
    }
};

test "ServeMux routing: exact and prefix" {
    const allocator = std.testing.allocator;
    var mux = ServeMux.init(allocator);
    defer mux.deinit();

    const dummy = struct {
        fn handle(w: *ResponseWriter, req: *Request) anyerror!void {
            _ = w;
            _ = req;
        }
    }.handle;

    try mux.handleFunc("/ping", dummy);
    try mux.handleFunc("/api/", dummy);

    try std.testing.expect(mux.match("/ping") != null);
    try std.testing.expect(mux.match("/ping/extra") == null);
    try std.testing.expect(mux.match("/api/v1/users") != null);
    try std.testing.expect(mux.match("/api/") != null);
    try std.testing.expect(mux.match("/notfound") == null);
}

test "ServeMux routing: method matching and wildcards" {
    const allocator = std.testing.allocator;
    var mux = ServeMux.init(allocator);
    defer mux.deinit();

    const dummy = struct {
        fn handle(w: *ResponseWriter, req: *Request) anyerror!void {
            _ = w;
            _ = req;
        }
    }.handle;

    try mux.handleFunc("GET /users/{id}", dummy);
    try mux.handleFunc("POST /users", dummy);
    try mux.handleFunc("GET /files/{path...}", dummy);
    try mux.handleFunc("/exact/{$}", dummy);

    // Test GET /users/{id}
    var matches1 = std.ArrayListUnmanaged([]const u8).empty;
    defer matches1.deinit(allocator);
    const res1 = mux.matchTree(allocator, null, "GET", "/users/alice", &matches1);
    try std.testing.expect(res1 != null);
    try std.testing.expectEqualStrings("GET /users/{id}", res1.?.pattern.str);
    try std.testing.expectEqual(@as(usize, 1), matches1.items.len);
    try std.testing.expectEqualStrings("alice", matches1.items[0]);

    // Test POST /users
    var matches2 = std.ArrayListUnmanaged([]const u8).empty;
    defer matches2.deinit(allocator);
    const res2 = mux.matchTree(allocator, null, "POST", "/users", &matches2);
    try std.testing.expect(res2 != null);
    try std.testing.expectEqualStrings("POST /users", res2.?.pattern.str);

    // Test 405 check for GET /users
    var allowed = std.ArrayListUnmanaged([]const u8).empty;
    defer allowed.deinit(allocator);
    try mux.collectAllowedMethods(allocator, null, "/users", &allowed);
    try std.testing.expectEqual(@as(usize, 1), allowed.items.len);
    try std.testing.expectEqualStrings("POST", allowed.items[0]);

    // Test GET /files/{path...}
    var matches3 = std.ArrayListUnmanaged([]const u8).empty;
    defer matches3.deinit(allocator);
    const res3 = mux.matchTree(allocator, null, "GET", "/files/docs/readme.txt", &matches3);
    try std.testing.expect(res3 != null);
    try std.testing.expectEqual(@as(usize, 1), matches3.items.len);
    try std.testing.expectEqualStrings("docs/readme.txt", matches3.items[0]);

    // Test /exact/{$}
    var matches4 = std.ArrayListUnmanaged([]const u8).empty;
    defer matches4.deinit(allocator);
    const res4 = mux.matchTree(allocator, null, "GET", "/exact/", &matches4);
    try std.testing.expect(res4 != null);

    var matches5 = std.ArrayListUnmanaged([]const u8).empty;
    defer matches5.deinit(allocator);
    const res5 = mux.matchTree(allocator, null, "GET", "/exact/extra", &matches5);
    try std.testing.expect(res5 == null);
}
