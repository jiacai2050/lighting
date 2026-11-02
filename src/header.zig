const std = @import("std");

pub fn isValidTokenChar(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}

pub fn isValidHeaderName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        if (!isValidTokenChar(c)) return false;
    }
    return true;
}

pub fn isValidHeaderValue(value: []const u8) bool {
    for (value) |c| {
        if (c == '\r' or c == '\n') return false;
        if (c < 0x20 and c != '\t') return false;
        if (c == 0x7f) return false;
    }
    return true;
}

/// HTTP Header entry
pub const HeaderEntry = struct {
    name: []const u8,
    value: []const u8,
};

/// Case-insensitive HTTP Header map
pub const HeaderMap = struct {
    entries: std.ArrayListUnmanaged(HeaderEntry),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) HeaderMap {
        return .{
            .entries = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *HeaderMap) void {
        self.entries.deinit(self.allocator);
    }

    pub fn get(self: *const HeaderMap, name: []const u8) ?[]const u8 {
        for (self.entries.items) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.name, name)) {
                return entry.value;
            }
        }
        return null;
    }

    pub fn set(self: *HeaderMap, name: []const u8, value: []const u8) !void {
        if (!isValidHeaderName(name) or !isValidHeaderValue(value)) {
            return error.InvalidHeaderCharacter;
        }
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

    pub fn add(self: *HeaderMap, name: []const u8, value: []const u8) !void {
        if (!isValidHeaderName(name) or !isValidHeaderValue(value)) {
            return error.InvalidHeaderCharacter;
        }
        try self.entries.append(self.allocator, .{
            .name = name,
            .value = value,
        });
    }

    pub fn has(self: *const HeaderMap, name: []const u8) bool {
        return self.get(name) != null;
    }

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

    pub fn clone(self: *const HeaderMap, allocator: std.mem.Allocator) !HeaderMap {
        var new_map = HeaderMap.init(allocator);
        for (self.entries.items) |item| {
            const name_dup = try allocator.dupe(u8, item.name);
            const val_dup = try allocator.dupe(u8, item.value);
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
