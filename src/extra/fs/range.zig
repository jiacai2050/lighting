const std = @import("std");

/// Inclusive byte range [start, end]
pub const ByteRange = struct {
    start: u64,
    end: u64,

    /// Number of bytes represented by this range
    pub fn length(self: ByteRange) u64 {
        std.debug.assert(self.end >= self.start);
        return self.end - self.start + 1;
    }
};

pub const RangeResult = union(enum) {
    /// No Range header was provided
    none,
    /// Valid single range parsed according to RFC 9110
    single: ByteRange,
    /// Syntax error in Range header; RFC 9110 section 14.1.2 recommends ignoring and serving full 200 OK
    ignore,
    /// Range header could not be satisfied (e.g. start >= file_size or file_size == 0) -> 416
    not_satisfiable,
};

/// Parses an HTTP Range header per RFC 9110 Section 14.1.2.
/// Supported formats:
/// - "bytes=start-end"
/// - "bytes=start-"
/// - "bytes=-suffix"
pub fn parseRange(range_hdr: ?[]const u8, file_size: u64) RangeResult {
    const raw = range_hdr orelse return .none;
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len == 0) return .none;

    const prefix = "bytes=";
    if (!std.ascii.startsWithIgnoreCase(trimmed, prefix)) {
        return .ignore;
    }

    const spec = std.mem.trim(u8, trimmed[prefix.len..], " \t");
    // If multipart/multiple ranges are given (e.g. "bytes=0-10, 20-30"), we ignore and serve 200 OK
    if (std.mem.indexOfScalar(u8, spec, ',') != null) {
        return .ignore;
    }

    const dash_idx = std.mem.indexOfScalar(u8, spec, '-') orelse return .ignore;
    const first_part = std.mem.trim(u8, spec[0..dash_idx], " \t");
    const second_part = std.mem.trim(u8, spec[dash_idx + 1 ..], " \t");

    if (first_part.len == 0) {
        // Suffix range: "-suffix"
        if (second_part.len == 0) return .ignore;
        const suffix_len = std.fmt.parseInt(u64, second_part, 10) catch return .ignore;
        if (suffix_len == 0) return .not_satisfiable;

        if (file_size == 0) return .not_satisfiable;

        if (suffix_len >= file_size) {
            return .{ .single = .{ .start = 0, .end = file_size - 1 } };
        } else {
            return .{ .single = .{ .start = file_size - suffix_len, .end = file_size - 1 } };
        }
    }

    const start = std.fmt.parseInt(u64, first_part, 10) catch return .ignore;

    if (second_part.len == 0) {
        // Prefix range: "start-"
        if (file_size == 0 or start >= file_size) {
            return .not_satisfiable;
        }
        return .{ .single = .{ .start = start, .end = file_size - 1 } };
    }

    // Closed range: "start-end"
    var end = std.fmt.parseInt(u64, second_part, 10) catch return .ignore;
    // RFC 9110 Section 14.1.2: if start > end, the range is syntactically invalid and MUST be ignored
    if (start > end) {
        return .ignore;
    }

    if (file_size == 0 or start >= file_size) {
        return .not_satisfiable;
    }

    // Clamp end to file_size - 1 per RFC 9110
    if (end >= file_size) {
        end = file_size - 1;
    }

    return .{ .single = .{ .start = start, .end = end } };
}

test "parseRange tests" {
    // 1. None
    try std.testing.expect(parseRange(null, 1000) == .none);
    try std.testing.expect(parseRange("", 1000) == .none);

    // 2. Closed range "bytes=0-499"
    const r1 = parseRange("bytes=0-499", 1000);
    try std.testing.expect(r1 == .single);
    try std.testing.expectEqual(@as(u64, 0), r1.single.start);
    try std.testing.expectEqual(@as(u64, 499), r1.single.end);
    try std.testing.expectEqual(@as(u64, 500), r1.single.length());

    // 3. Prefix range "bytes=500-"
    const r2 = parseRange("bytes=500-", 1000);
    try std.testing.expect(r2 == .single);
    try std.testing.expectEqual(@as(u64, 500), r2.single.start);
    try std.testing.expectEqual(@as(u64, 999), r2.single.end);
    try std.testing.expectEqual(@as(u64, 500), r2.single.length());

    // 4. Suffix range "bytes=-200"
    const r3 = parseRange("bytes=-200", 1000);
    try std.testing.expect(r3 == .single);
    try std.testing.expectEqual(@as(u64, 800), r3.single.start);
    try std.testing.expectEqual(@as(u64, 999), r3.single.end);
    try std.testing.expectEqual(@as(u64, 200), r3.single.length());

    // 5. Clamped end "bytes=900-2000"
    const r4 = parseRange("bytes=900-2000", 1000);
    try std.testing.expect(r4 == .single);
    try std.testing.expectEqual(@as(u64, 900), r4.single.start);
    try std.testing.expectEqual(@as(u64, 999), r4.single.end);

    // 6. Unsatisfiable: start >= size
    try std.testing.expect(parseRange("bytes=1000-", 1000) == .not_satisfiable);
    try std.testing.expect(parseRange("bytes=0-10", 0) == .not_satisfiable);
    try std.testing.expect(parseRange("bytes=-10", 0) == .not_satisfiable);

    // 7. Non-bytes unit, start > end, or invalid syntax -> ignore
    try std.testing.expect(parseRange("items=0-10", 1000) == .ignore);
    try std.testing.expect(parseRange("bytes=abc-def", 1000) == .ignore);
    try std.testing.expect(parseRange("bytes=500-400", 1000) == .ignore); // start > end MUST be ignored per RFC 9110
    try std.testing.expect(parseRange("bytes=500-400", 0) == .ignore);
    try std.testing.expect(parseRange("bytes=0-99999999999999999999999999999", 1000) == .ignore);
}
