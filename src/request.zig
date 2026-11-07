//! HTTP request representations, URI/URL parsing, and multi-value query parameter management.

const std = @import("std");
const Method = @import("proto/method.zig").Method;
const Version = @import("proto/parser.zig").Version;
const HeaderMap = @import("header.zig").HeaderMap;
const BodyReader = @import("proto/chunk_reader.zig").BodyReader;
const CookieIterator = @import("cookie.zig").CookieIterator;
const multipart = @import("multipart.zig");
const MultipartForm = multipart.MultipartForm;

/// URL represents a parsed uniform resource locator (or request URI).
///
/// It isolates components such as host, path, raw query string, and fragment.
/// Slices within URL borrow from the original input string.
pub const URL = struct {
    /// Full original raw URI string.
    raw: []const u8,
    /// Host component (e.g. "example.com:8080"), if an absolute URI was supplied.
    host: ?[]const u8 = null,
    /// Absolute or relative path component (defaults to "/" for root URIs).
    path: []const u8,
    /// Raw query string without the leading '?' or trailing '#', if present.
    raw_query: ?[]const u8 = null,
    /// URL fragment identifier without the leading '#', if present.
    fragment: ?[]const u8 = null,

    /// QueryEntry represents a single key-value query parameter slice.
    pub const QueryEntry = struct {
        key: []const u8,
        value: []const u8,
    };

    /// QueryIterator provides zero-copy streaming iteration over all raw query parameters.
    pub const QueryIterator = struct {
        raw_query: ?[]const u8,
        index: usize = 0,

        /// next returns the next QueryEntry in the query string, or null when iteration is complete.
        pub fn next(self: *QueryIterator) ?QueryEntry {
            const raw_q = self.raw_query orelse return null;
            if (self.index >= raw_q.len) return null;

            const remaining = raw_q[self.index..];
            const end_rel = std.mem.indexOfScalar(u8, remaining, '&') orelse remaining.len;
            const pair = remaining[0..end_rel];
            self.index += end_rel + 1;

            if (pair.len == 0) return self.next();

            if (std.mem.indexOfScalar(u8, pair, '=')) |eq| {
                return .{
                    .key = pair[0..eq],
                    .value = pair[eq + 1 ..],
                };
            } else {
                return .{
                    .key = pair,
                    .value = "",
                };
            }
        }
    };

    /// QueryValueIterator provides zero-copy iteration over all values matching a specific query key.
    pub const QueryValueIterator = struct {
        iter: QueryIterator,
        target_key: []const u8,

        /// next returns the next raw value matching target_key, or null when no more values match.
        pub fn next(self: *QueryValueIterator) ?[]const u8 {
            while (self.iter.next()) |entry| {
                if (std.mem.eql(u8, entry.key, self.target_key)) {
                    return entry.value;
                }
            }
            return null;
        }
    };

    /// parse parses a raw request target URI into its URL components.
    /// Automatically strips fragments ('#') and separates path from query string ('?').
    pub fn parse(target: []const u8) URL {
        // Strip fragment (#) per RFC 3986
        var clean_target = target;
        var fragment: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, target, '#')) |hash_idx| {
            clean_target = target[0..hash_idx];
            fragment = target[hash_idx + 1 ..];
        }

        var raw_path = clean_target;
        var raw_query: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, clean_target, '?')) |q_idx| {
            raw_path = clean_target[0..q_idx];
            raw_query = clean_target[q_idx + 1 ..];
        }

        var host: ?[]const u8 = null;
        var path = raw_path;

        if (std.ascii.startsWithIgnoreCase(raw_path, "http://")) {
            const rest = raw_path["http://".len..];
            if (std.mem.indexOfScalar(u8, rest, '/')) |slash_idx| {
                host = rest[0..slash_idx];
                path = rest[slash_idx..];
            } else {
                host = rest;
                path = "/";
            }
        } else if (std.ascii.startsWithIgnoreCase(raw_path, "https://")) {
            const rest = raw_path["https://".len..];
            if (std.mem.indexOfScalar(u8, rest, '/')) |slash_idx| {
                host = rest[0..slash_idx];
                path = rest[slash_idx..];
            } else {
                host = rest;
                path = "/";
            }
        }

        return .{
            .raw = target,
            .host = host,
            .path = path,
            .raw_query = raw_query,
            .fragment = fragment,
        };
    }

    /// Fast, zero-copy query parameter lookup returning the first match.
    pub fn queryParam(self: URL, key: []const u8) ?[]const u8 {
        var it = self.queryParamIterator(key);
        return it.next();
    }

    /// Checks whether a query parameter key is present (even if value is empty).
    pub fn queryHas(self: URL, key: []const u8) bool {
        var it = self.queryParamIterator(key);
        return it.next() != null;
    }

    /// Returns an iterator yielding all occurrences of the given query parameter key.
    pub fn queryParamIterator(self: URL, key: []const u8) QueryValueIterator {
        return .{
            .iter = self.queryIterator(),
            .target_key = key,
        };
    }

    /// Returns an iterator yielding all key-value pairs in the query string.
    pub fn queryIterator(self: URL) QueryIterator {
        return .{
            .raw_query = self.raw_query,
            .index = 0,
        };
    }

    /// URL unescapes query component: decodes '%XX' hex and '+' to ' ' (space).
    pub fn queryUnescape(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
        // Fast path: if no '%' and no '+', return duplicate slice
        if (std.mem.indexOfAny(u8, s, "%+") == null) {
            return try allocator.dupe(u8, s);
        }

        var out = std.ArrayListUnmanaged(u8).empty;
        errdefer out.deinit(allocator);

        var i: usize = 0;
        while (i < s.len) {
            switch (s[i]) {
                '+' => {
                    try out.append(allocator, ' ');
                    i += 1;
                },
                '%' => {
                    if (i + 2 >= s.len) return error.InvalidPercentEncoding;
                    const hex = s[i + 1 .. i + 3];
                    const byte = std.fmt.parseInt(u8, hex, 16) catch {
                        return error.InvalidPercentEncoding;
                    };
                    try out.append(allocator, byte);
                    i += 3;
                },
                else => {
                    try out.append(allocator, s[i]);
                    i += 1;
                },
            }
        }
        return out.toOwnedSlice(allocator);
    }

    /// URL unescape percent-encoded string per RFC 3986 (leaves '+' literal).
    pub fn unescape(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
        var out = std.ArrayListUnmanaged(u8).empty;
        errdefer out.deinit(allocator);

        var i: usize = 0;
        while (i < s.len) {
            if (s[i] == '%' and i + 2 < s.len) {
                const hex = s[i + 1 .. i + 3];
                if (std.fmt.parseInt(u8, hex, 16)) |byte| {
                    try out.append(allocator, byte);
                    i += 3;
                    continue;
                } else |_| {}
            }
            try out.append(allocator, s[i]);
            i += 1;
        }
        return out.toOwnedSlice(allocator);
    }

    /// Fully decodes the raw query string into a multi-value QueryParams map.
    pub fn query(self: URL, allocator: std.mem.Allocator) !QueryParams {
        return QueryParams.parse(allocator, self.raw_query);
    }
};

/// QueryParams maps query parameter keys to a list of values, paralleling Go's url.Values.
///
/// QueryParams manages its own internal ArenaAllocator so that all decoded strings
/// and entry lists are freed in a single call to `deinit()`.
pub const QueryParams = struct {
    /// Entry represents a query key with one or more associated values.
    pub const Entry = struct {
        key: []const u8,
        values: std.ArrayListUnmanaged([]const u8) = .empty,
    };

    /// default_max_query_params is the default threshold for query parameter counts to prevent DoS attacks.
    pub const default_max_query_params: usize = 10000;

    arena: std.heap.ArenaAllocator,
    entries: std.ArrayListUnmanaged(Entry) = .empty,

    /// init initializes an empty QueryParams map using the provided backing allocator.
    pub fn init(allocator: std.mem.Allocator) QueryParams {
        return .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .entries = .empty,
        };
    }

    /// deinit releases all memory allocated for keys, values, and entry lists.
    pub fn deinit(self: *QueryParams) void {
        self.arena.deinit();
    }

    /// parse parses a raw query string into QueryParams with automatic percent-decoding and safety limits.
    pub fn parse(allocator: std.mem.Allocator, raw_query: ?[]const u8) !QueryParams {
        return parseWithLimit(allocator, raw_query, default_max_query_params);
    }

    /// parseWithLimit parses raw_query enforcing max_params count and disallowing bare semicolons.
    pub fn parseWithLimit(allocator: std.mem.Allocator, raw_query: ?[]const u8, max_params: usize) !QueryParams {
        var result = QueryParams.init(allocator);
        errdefer result.deinit();

        const q = raw_query orelse return result;
        if (q.len == 0) return result;

        // Security check: limit maximum query parameter count against DoS
        const amp_count = std.mem.count(u8, q, "&");
        if (amp_count + 1 > max_params) {
            return error.TooManyQueryParams;
        }

        const arena_alloc = result.arena.allocator();
        var it = std.mem.splitScalar(u8, q, '&');
        while (it.next()) |pair| {
            if (pair.len == 0) continue;

            // Security check: disallow unencoded semicolons to prevent parameter smuggling (aligned with Go)
            if (std.mem.indexOfScalar(u8, pair, ';') != null) {
                return error.InvalidSemicolonSeparator;
            }

            var raw_k = pair;
            var raw_v: []const u8 = "";
            if (std.mem.indexOfScalar(u8, pair, '=')) |eq| {
                raw_k = pair[0..eq];
                raw_v = pair[eq + 1 ..];
            }

            const decoded_k = try URL.queryUnescape(arena_alloc, raw_k);
            const decoded_v = try URL.queryUnescape(arena_alloc, raw_v);

            try result.add(decoded_k, decoded_v);
        }

        return result;
    }

    /// Gets the first value associated with the given key.
    pub fn get(self: QueryParams, key: []const u8) ?[]const u8 {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.key, key)) {
                if (entry.values.items.len > 0) {
                    return entry.values.items[0];
                }
                return "";
            }
        }
        return null;
    }

    /// Gets all values associated with the given key.
    pub fn getAll(self: QueryParams, key: []const u8) ?[]const []const u8 {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.key, key)) {
                return entry.values.items;
            }
        }
        return null;
    }

    /// Checks whether the given key is present.
    pub fn has(self: QueryParams, key: []const u8) bool {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.key, key)) {
                return true;
            }
        }
        return false;
    }

    /// Appends a key-value pair, preserving multiple values for the same key.
    pub fn add(self: *QueryParams, key: []const u8, value: []const u8) !void {
        const arena_alloc = self.arena.allocator();
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.key, key)) {
                try entry.values.append(arena_alloc, value);
                return;
            }
        }
        var new_entry = Entry{
            .key = key,
            .values = .empty,
        };
        try new_entry.values.append(arena_alloc, value);
        try self.entries.append(arena_alloc, new_entry);
    }

    /// Sets the key to value, replacing any existing values.
    pub fn set(self: *QueryParams, key: []const u8, value: []const u8) !void {
        const arena_alloc = self.arena.allocator();
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.key, key)) {
                entry.values.clearRetainingCapacity();
                try entry.values.append(arena_alloc, value);
                return;
            }
        }
        try self.add(key, value);
    }

    /// Deletes all values associated with the key.
    pub fn del(self: *QueryParams, key: []const u8) void {
        var i: usize = 0;
        while (i < self.entries.items.len) {
            if (std.mem.eql(u8, self.entries.items[i].key, key)) {
                _ = self.entries.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }
};

/// PathValueEntry stores a single URL path parameter extracted by route pattern matching.
pub const PathValueEntry = struct {
    name: []const u8,
    value: []const u8,
};

/// Request represents an incoming HTTP request received by the server.
///
/// It encapsulates the method, raw target, parsed URL, protocol version, headers,
/// body reader, and route path parameters. The request's `arena` allocator is automatically
/// reset between requests on a keep-alive connection.
pub const Request = struct {
    /// HTTP method of the request.
    method: Method,
    /// Raw unparsed target URI from the request line.
    target: []const u8,
    /// Parsed URL component breakdown.
    url: URL,
    /// HTTP protocol version.
    proto: Version,
    /// Parsed headers of the request.
    headers: HeaderMap,
    /// Optional reader for streaming the request body.
    body_reader: ?BodyReader,
    /// Per-request arena allocator. Automatically recycled after the handler returns.
    arena: std.mem.Allocator,
    /// Explicit Content-Length in bytes, if supplied by the client.
    content_length: ?u64,
    /// True if the connection should remain open after handling this request.
    keep_alive: bool,
    /// Dynamic path parameters matched by ServeMux patterns (e.g. {id} or {path...}).
    path_values: std.ArrayListUnmanaged(PathValueEntry) = .empty,

    /// init constructs a new Request instance.
    pub fn init(
        method: Method,
        target: []const u8,
        proto: Version,
        headers: HeaderMap,
        body_reader: ?BodyReader,
        content_length: ?u64,
        keep_alive: bool,
        arena: std.mem.Allocator,
    ) Request {
        return .{
            .method = method,
            .target = target,
            .url = URL.parse(target),
            .proto = proto,
            .headers = headers,
            .body_reader = body_reader,
            .arena = arena,
            .content_length = content_length,
            .keep_alive = keep_alive,
            .path_values = .empty,
        };
    }

    /// body returns a pointer to the BodyReader if a body stream is available.
    pub fn body(self: *Request) ?*BodyReader {
        if (self.body_reader != null) {
            return &self.body_reader.?;
        }
        return null;
    }

    /// readBodyAlloc reads the entire request body up to max_size bytes using the request's arena allocator.
    /// Memory is automatically freed when the request cycle completes.
    pub fn readBodyAlloc(self: *Request, max_size: usize) ![]u8 {
        if (self.body()) |b| {
            return b.readAllAlloc(self.arena, max_size);
        }
        return &[_]u8{};
    }

    /// pathValue returns the matched wildcard or placeholder value from the route pattern,
    /// equivalent to Go's req.PathValue(name).
    pub fn pathValue(self: *const Request, name: []const u8) ?[]const u8 {
        for (self.path_values.items) |entry| {
            if (std.mem.eql(u8, entry.name, name)) {
                return entry.value;
            }
        }
        return null;
    }

    /// setPathValue sets a path value parameter (called by router or middlewares).
    pub fn setPathValue(self: *Request, name: []const u8, value: []const u8) !void {
        for (self.path_values.items) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) {
                entry.value = value;
                return;
            }
        }
        try self.path_values.append(self.arena, .{
            .name = name,
            .value = value,
        });
    }

    /// header returns the first header value matching name (case-insensitive).
    pub fn header(self: *const Request, name: []const u8) ?[]const u8 {
        return self.headers.get(name);
    }

    /// queryParam returns the first raw matching query parameter value without decoding (zero-copy).
    pub fn queryParam(self: *const Request, key: []const u8) ?[]const u8 {
        return self.url.queryParam(key);
    }

    /// queryHas reports whether the query parameter key is present.
    pub fn queryHas(self: *const Request, key: []const u8) bool {
        return self.url.queryHas(key);
    }

    /// query parses and unescapes the query string into a multi-value QueryParams map allocated in req.arena.
    pub fn query(self: *const Request) !QueryParams {
        return self.url.query(self.arena);
    }

    /// cookie returns the value of the named cookie provided in the request, or null if not found.
    pub fn cookie(self: *const Request, name: []const u8) ?[]const u8 {
        var it = self.cookies();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.name, name)) {
                return entry.value;
            }
        }
        return null;
    }

    /// cookies returns an iterator yielding all name-value pairs from the request's Cookie header.
    pub fn cookies(self: *const Request) CookieIterator {
        return .{
            .raw = self.headers.get("cookie"),
            .index = 0,
        };
    }

    /// multipartForm parses the request body as multipart/form-data with a maximum memory threshold.
    /// Returns the parsed MultipartForm containing form fields and uploaded files.
    pub fn multipartForm(self: *Request, max_memory: usize) !MultipartForm {
        const ct = self.headers.get("content-type") orelse return error.MissingContentType;
        const boundary = multipart.parseBoundary(ct) orelse return error.MissingBoundary;
        const body_bytes = try self.readBodyAlloc(max_memory);
        return multipart.parseMultipart(self.arena, body_bytes, boundary, max_memory);
    }
};

test "URL parse and queryParam" {
    const allocator = std.testing.allocator;
    const u = URL.parse("/search?q=zig&page=2");
    try std.testing.expectEqualStrings("/search", u.path);
    try std.testing.expectEqualStrings("zig", u.queryParam("q").?);
    try std.testing.expectEqualStrings("2", u.queryParam("page").?);
    try std.testing.expect(u.queryParam("other") == null);
    try std.testing.expect(u.queryHas("q"));
    try std.testing.expect(!u.queryHas("other"));

    const unescaped = try URL.unescape(allocator, "hello+world%21%20%2F");
    defer allocator.free(unescaped);
    try std.testing.expectEqualStrings("hello+world! /", unescaped);
}

test "URL fragment stripping" {
    // 1. Path with query and fragment
    const url_with_frag = URL.parse("/search?q=zig#section-1");
    try std.testing.expectEqualStrings("/search", url_with_frag.path);
    try std.testing.expectEqualStrings("q=zig", url_with_frag.raw_query.?);
    try std.testing.expectEqualStrings("section-1", url_with_frag.fragment.?);
    try std.testing.expectEqualStrings("zig", url_with_frag.queryParam("q").?);

    // 2. Path with fragment only
    const url_frag_only = URL.parse("/docs/intro#top");
    try std.testing.expectEqualStrings("/docs/intro", url_frag_only.path);
    try std.testing.expect(url_frag_only.raw_query == null);
    try std.testing.expectEqualStrings("top", url_frag_only.fragment.?);
}

test "URL query iterators" {
    const u = URL.parse("/items?tag=zig&tag=backend&tag=web&sort=asc&flag");

    // Test queryParamIterator (multi-value)
    var val_it = u.queryParamIterator("tag");
    try std.testing.expectEqualStrings("zig", val_it.next().?);
    try std.testing.expectEqualStrings("backend", val_it.next().?);
    try std.testing.expectEqualStrings("web", val_it.next().?);
    try std.testing.expect(val_it.next() == null);

    // Test flag (no equals)
    try std.testing.expect(u.queryHas("flag"));
    try std.testing.expectEqualStrings("", u.queryParam("flag").?);

    // Test queryIterator (all entries)
    var all_it = u.queryIterator();
    const e1 = all_it.next().?;
    try std.testing.expectEqualStrings("tag", e1.key);
    try std.testing.expectEqualStrings("zig", e1.value);

    const e2 = all_it.next().?;
    try std.testing.expectEqualStrings("tag", e2.key);
    try std.testing.expectEqualStrings("backend", e2.value);

    const e3 = all_it.next().?;
    try std.testing.expectEqualStrings("tag", e3.key);
    try std.testing.expectEqualStrings("web", e3.value);

    const e4 = all_it.next().?;
    try std.testing.expectEqualStrings("sort", e4.key);
    try std.testing.expectEqualStrings("asc", e4.value);

    const e5 = all_it.next().?;
    try std.testing.expectEqualStrings("flag", e5.key);
    try std.testing.expectEqualStrings("", e5.value);

    try std.testing.expect(all_it.next() == null);
}

test "URL queryUnescape" {
    const allocator = std.testing.allocator;

    // Fast path: no % and no +
    const s1 = try URL.queryUnescape(allocator, "simple_text");
    defer allocator.free(s1);
    try std.testing.expectEqualStrings("simple_text", s1);

    // Decodes + to space and %21 to !
    const s2 = try URL.queryUnescape(allocator, "hello+world%21%20%2F%26%3D");
    defer allocator.free(s2);
    try std.testing.expectEqualStrings("hello world! /&=", s2);

    // Invalid percent encodings
    try std.testing.expectError(error.InvalidPercentEncoding, URL.queryUnescape(allocator, "incomplete%2"));
    try std.testing.expectError(error.InvalidPercentEncoding, URL.queryUnescape(allocator, "bad_hex%2G"));
}

test "QueryParams multi-value map" {
    const allocator = std.testing.allocator;

    // 1. Parsing query string
    var qp = try QueryParams.parse(allocator, "tag=zig&tag=systems+lang&filter=new&mode");
    defer qp.deinit();

    try std.testing.expect(qp.has("tag"));
    try std.testing.expect(qp.has("filter"));
    try std.testing.expect(qp.has("mode"));
    try std.testing.expect(!qp.has("not_found"));

    // First value
    try std.testing.expectEqualStrings("zig", qp.get("tag").?);
    try std.testing.expectEqualStrings("new", qp.get("filter").?);
    try std.testing.expectEqualStrings("", qp.get("mode").?);

    // All values
    const tags = qp.getAll("tag").?;
    try std.testing.expectEqual(@as(usize, 2), tags.len);
    try std.testing.expectEqualStrings("zig", tags[0]);
    try std.testing.expectEqualStrings("systems lang", tags[1]);

    // 2. Mutation: add, set, del
    try qp.add("tag", "fast");
    try std.testing.expectEqual(@as(usize, 3), qp.getAll("tag").?.len);

    try qp.set("filter", "popular");
    try std.testing.expectEqualStrings("popular", qp.get("filter").?);

    qp.del("mode");
    try std.testing.expect(!qp.has("mode"));

    // 3. Security checks
    // Semicolon disallowance (aligned with Go against parameter smuggling)
    try std.testing.expectError(error.InvalidSemicolonSeparator, QueryParams.parse(allocator, "a=1;b=2"));

    // Max query params DoS limit
    try std.testing.expectError(error.TooManyQueryParams, QueryParams.parseWithLimit(allocator, "a=1&b=2&c=3", 2));
}

test "URL parse absolute-form targets" {
    // 1. With path and query
    const url1 = URL.parse("http://example.com:8080/path/sub?foo=bar");
    try std.testing.expectEqualStrings("example.com:8080", url1.host.?);
    try std.testing.expectEqualStrings("/path/sub", url1.path);
    try std.testing.expectEqualStrings("foo=bar", url1.raw_query.?);
    try std.testing.expectEqualStrings("bar", url1.queryParam("foo").?);

    // 2. HTTPS with path and no query
    const url2 = URL.parse("https://myhost.org/api/v1");
    try std.testing.expectEqualStrings("myhost.org", url2.host.?);
    try std.testing.expectEqualStrings("/api/v1", url2.path);
    try std.testing.expect(url2.raw_query == null);

    // 3. No path (RFC 9112: path defaults to "/")
    const url3 = URL.parse("http://example.com");
    try std.testing.expectEqualStrings("example.com", url3.host.?);
    try std.testing.expectEqualStrings("/", url3.path);
    try std.testing.expect(url3.raw_query == null);

    // 4. No path, with query
    const url4 = URL.parse("http://example.com?key=val");
    try std.testing.expectEqualStrings("example.com", url4.host.?);
    try std.testing.expectEqualStrings("/", url4.path);
    try std.testing.expectEqualStrings("key=val", url4.raw_query.?);
    try std.testing.expectEqualStrings("val", url4.queryParam("key").?);

    // 5. Trailing slash
    const url5 = URL.parse("http://example.com/");
    try std.testing.expectEqualStrings("example.com", url5.host.?);
    try std.testing.expectEqualStrings("/", url5.path);
}

test "Request cookie and cookies methods" {
    const allocator = std.testing.allocator;
    var headers = HeaderMap.init(allocator);
    defer headers.deinit();

    try headers.set("Cookie", "session_token=xyz123; user_pref=\"dark_mode\"; tracking=on");

    var req = Request.init(
        .GET,
        "/dashboard",
        .@"HTTP/1.1",
        headers,
        null,
        null,
        true,
        allocator,
    );
    defer req.path_values.deinit(allocator);

    try std.testing.expectEqualStrings("xyz123", req.cookie("session_token").?);
    try std.testing.expectEqualStrings("dark_mode", req.cookie("user_pref").?);
    try std.testing.expectEqualStrings("on", req.cookie("tracking").?);
    try std.testing.expect(req.cookie("missing") == null);
}
