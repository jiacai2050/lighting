//! HTTP header structures and RFC 9110 compliant field validation.

const std = @import("std");
const assert = std.debug.assert;

/// isValidTokenChar reports whether c is a valid RFC 9110 Section 5.6.2 token character.
pub fn isValidTokenChar(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}

/// isValidHeaderName reports whether name is a valid RFC 9110 HTTP header field name.
pub fn isValidHeaderName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        if (!isValidTokenChar(c)) return false;
    }
    return true;
}

/// isValidHeaderValue reports whether value conforms to RFC 9110 field value rules
/// (rejects bare control characters and CR/LF characters to prevent HTTP response splitting).
pub fn isValidHeaderValue(value: []const u8) bool {
    for (value) |c| {
        if (c == '\r' or c == '\n') return false;
        if (c < 0x20 and c != '\t') return false;
        if (c == 0x7f) return false;
    }
    return true;
}

/// HeaderEntry represents a single HTTP header name/value pair.
pub const HeaderEntry = struct {
    /// Field name of the header (e.g. "Content-Type").
    name: []const u8,
    /// Field value of the header (e.g. "application/json").
    value: []const u8,
};

/// HeaderMap represents a collection of HTTP header fields with case-insensitive name matching.
///
/// It preserves insertion order while allowing standard HTTP header manipulations
/// (get, set, add, delete, and duplicate retrieval).
pub const HeaderMap = struct {
    entries: std.ArrayListUnmanaged(HeaderEntry),
    allocator: std.mem.Allocator,

    /// init creates an empty HeaderMap using the specified allocator for internal entry slice storage.
    pub fn init(allocator: std.mem.Allocator) HeaderMap {
        return .{
            .entries = .empty,
            .allocator = allocator,
        };
    }

    /// deinit frees the internal list of header entries.
    /// Does not free the underlying header name/value strings unless cloned via clone().
    pub fn deinit(self: *HeaderMap) void {
        self.entries.deinit(self.allocator);
    }

    /// get returns the first value associated with the given key (case-insensitive).
    /// If no entry matches, returns null.
    pub fn get(self: *const HeaderMap, name: []const u8) ?[]const u8 {
        assert(name.len > 0);
        for (self.entries.items) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.name, name)) {
                return entry.value;
            }
        }
        return null;
    }

    /// set sets the header field associated with name to value.
    /// It replaces any existing values associated with name (case-insensitive).
    /// Returns error.InvalidHeaderCharacter if name or value contains forbidden characters.
    pub fn set(self: *HeaderMap, name: []const u8, value: []const u8) !void {
        if (!isValidHeaderName(name)) return error.InvalidHeaderCharacter;
        if (!isValidHeaderValue(value)) return error.InvalidHeaderCharacter;
        for (self.entries.items) |*entry| {
            if (std.ascii.eqlIgnoreCase(entry.name, name)) {
                entry.value = value;
                return;
            }
        }
        try self.entries.append(self.allocator, .{
            .name = name,
            .value = value,
        });
    }

    /// add appends a key/value pair to the headers.
    /// It does not replace existing values associated with name.
    /// Returns error.InvalidHeaderCharacter if name or value contains forbidden characters.
    pub fn add(self: *HeaderMap, name: []const u8, value: []const u8) !void {
        if (!isValidHeaderName(name)) return error.InvalidHeaderCharacter;
        if (!isValidHeaderValue(value)) return error.InvalidHeaderCharacter;
        try self.entries.append(self.allocator, .{
            .name = name,
            .value = value,
        });
    }

    /// has reports whether any header with the given name exists (case-insensitive).
    pub fn has(self: *const HeaderMap, name: []const u8) bool {
        return self.get(name) != null;
    }

    /// getAll returns an allocated slice of all values associated with the given name (case-insensitive).
    /// Caller owns the returned slice and must free it with allocator.
    pub fn getAll(self: *const HeaderMap, allocator: std.mem.Allocator, name: []const u8) ![][]const u8 {
        var list = std.ArrayListUnmanaged([]const u8).empty;
        errdefer list.deinit(allocator);
        for (self.entries.items) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.name, name)) {
                try list.append(allocator, entry.value);
            }
        }
        return list.toOwnedSlice(allocator);
    }

    /// delete removes all header fields matching name (case-insensitive).
    pub fn delete(self: *HeaderMap, name: []const u8) void {
        var i: usize = 0;
        while (i < self.entries.items.len) {
            if (std.ascii.eqlIgnoreCase(self.entries.items[i].name, name)) {
                _ = self.entries.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// deinitCloned frees duplicated header name/value strings as well as the entry list.
    /// Only use this if the HeaderMap was produced by clone().
    pub fn deinitCloned(self: *HeaderMap) void {
        for (self.entries.items) |item| {
            self.allocator.free(item.name);
            self.allocator.free(item.value);
        }
        self.deinit();
    }

    /// clone creates a deep copy of the HeaderMap, duplicating all name and value strings using allocator.
    /// The caller must call deinitCloned() to free all allocated memory.
    pub fn clone(self: *const HeaderMap, allocator: std.mem.Allocator) !HeaderMap {
        var new_map = HeaderMap.init(allocator);
        errdefer new_map.deinitCloned();

        for (self.entries.items) |item| {
            const name_dup = try allocator.dupe(u8, item.name);
            errdefer allocator.free(name_dup);
            const val_dup = try allocator.dupe(u8, item.value);
            errdefer allocator.free(val_dup);
            try new_map.add(name_dup, val_dup);
        }
        return new_map;
    }
};

test "HeaderMap basic operations" {
    const allocator = std.testing.allocator;
    var headers = HeaderMap.init(allocator);
    defer headers.deinit();

    try headers.set("Content-Type", "application/json");
    try headers.set("content-type", "text/plain");

    try std.testing.expectEqualStrings("text/plain", headers.get("CONTENT-TYPE").?);
    try std.testing.expectEqual(@as(usize, 1), headers.entries.items.len);

    try headers.add("X-Custom", "val1");
    try headers.add("X-Custom", "val2");
    try std.testing.expectEqual(@as(usize, 3), headers.entries.items.len);
    try std.testing.expect(headers.has("x-custom"));

    const all = try headers.getAll(allocator, "x-custom");
    defer allocator.free(all);
    try std.testing.expectEqual(@as(usize, 2), all.len);
    try std.testing.expectEqualStrings("val1", all[0]);
    try std.testing.expectEqualStrings("val2", all[1]);

    headers.delete("x-custom");
    try std.testing.expectEqual(@as(usize, 1), headers.entries.items.len);
    try std.testing.expect(headers.get("X-Custom") == null);
    try std.testing.expect(!headers.has("x-custom"));
}

test "HeaderMap clone and error cleanup" {
    const allocator = std.testing.allocator;
    var headers = HeaderMap.init(allocator);
    defer headers.deinit();

    try headers.set("Host", "example.com");
    try headers.add("Accept", "text/html");
    try headers.add("Accept", "application/xhtml+xml");

    var cloned = try headers.clone(allocator);
    defer cloned.deinitCloned();

    try std.testing.expectEqual(@as(usize, 3), cloned.entries.items.len);
    try std.testing.expectEqualStrings("example.com", cloned.get("host").?);

    // Test failing allocator error handling to ensure no leaks
    var failing_alloc = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 2 });
    try std.testing.expectError(error.OutOfMemory, headers.clone(failing_alloc.allocator()));
}
