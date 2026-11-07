//! RFC 7578 multipart/form-data parser with memory limits and file upload support.

const std = @import("std");
const assert = std.debug.assert;
const HeaderMap = @import("header.zig").HeaderMap;

/// FileHeader represents an uploaded file within a multipart/form-data payload.
pub const FileHeader = struct {
    /// Field name from the form (e.g. "avatar" or "file").
    name: []const u8,
    /// Submitted filename of the uploaded file (e.g. "photo.png").
    filename: []const u8,
    /// MIME Content-Type of the file (e.g. "image/png"), or null if omitted.
    content_type: ?[]const u8 = null,
    /// File size in bytes.
    size: usize,
    /// File payload data. Slices are allocated within the MultipartForm's arena.
    data: []const u8,
};

/// FormValueEntry stores a single form text field name and value.
pub const FormValueEntry = struct {
    name: []const u8,
    value: []const u8,
};

/// MultipartForm represents a fully parsed multipart/form-data submission.
///
/// It encapsulates both text fields and uploaded files. All allocated memory
/// is managed by an internal ArenaAllocator, released via a single call to `deinit()`.
pub const MultipartForm = struct {
    arena: std.heap.ArenaAllocator,
    values: std.ArrayListUnmanaged(FormValueEntry) = .empty,
    files: std.ArrayListUnmanaged(FileHeader) = .empty,

    /// init initializes an empty MultipartForm using the backing allocator.
    pub fn init(allocator: std.mem.Allocator) MultipartForm {
        return .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .values = .empty,
            .files = .empty,
        };
    }

    /// deinit releases all memory allocated for text values and uploaded file buffers.
    pub fn deinit(self: *MultipartForm) void {
        self.arena.deinit();
    }

    /// getValue returns the first text value matching name, or null if not found.
    pub fn getValue(self: MultipartForm, name: []const u8) ?[]const u8 {
        for (self.values.items) |entry| {
            if (std.mem.eql(u8, entry.name, name)) {
                return entry.value;
            }
        }
        return null;
    }

    /// getAllValues returns an allocated slice of all text values matching name.
    /// Caller owns the returned slice and must free it with allocator.
    pub fn getAllValues(self: MultipartForm, allocator: std.mem.Allocator, name: []const u8) ![][]const u8 {
        var list = std.ArrayListUnmanaged([]const u8).empty;
        errdefer list.deinit(allocator);
        for (self.values.items) |entry| {
            if (std.mem.eql(u8, entry.name, name)) {
                try list.append(allocator, entry.value);
            }
        }
        return list.toOwnedSlice(allocator);
    }

    /// getFile returns the first uploaded file matching field name, or null if not found.
    pub fn getFile(self: MultipartForm, name: []const u8) ?FileHeader {
        for (self.files.items) |file| {
            if (std.mem.eql(u8, file.name, name)) {
                return file;
            }
        }
        return null;
    }

    /// getAllFiles returns an allocated slice of all uploaded files matching field name.
    /// Caller owns the returned slice and must free it with allocator.
    pub fn getAllFiles(self: MultipartForm, allocator: std.mem.Allocator, name: []const u8) ![]FileHeader {
        var list = std.ArrayListUnmanaged(FileHeader).empty;
        errdefer list.deinit(allocator);
        for (self.files.items) |file| {
            if (std.mem.eql(u8, file.name, name)) {
                try list.append(allocator, file);
            }
        }
        return list.toOwnedSlice(allocator);
    }
};

/// parseBoundary extracts the boundary parameter from a Content-Type header.
/// Example: "multipart/form-data; boundary=----WebKitFormBoundaryXYZ" -> "----WebKitFormBoundaryXYZ"
pub fn parseBoundary(content_type: []const u8) ?[]const u8 {
    const marker = "boundary=";
    var idx: usize = 0;
    while (idx < content_type.len) {
        const found = std.mem.indexOf(u8, content_type[idx..], marker) orelse return null;
        const start = idx + found + marker.len;

        // Ensure boundary was preceded by ';' or whitespace
        if (found > 0) {
            const prev = content_type[idx + found - 1];
            if (prev != ';' and prev != ' ' and prev != '\t') {
                idx = start;
                continue;
            }
        }

        var boundary = content_type[start..];
        // Strip quotes if present
        if (boundary.len >= 2 and boundary[0] == '"') {
            const closing = std.mem.indexOfScalarPos(u8, boundary, 1, '"') orelse return null;
            return boundary[1..closing];
        }

        // Delimited by semicolon or whitespace or end of string
        if (std.mem.indexOfAny(u8, boundary, "; \t")) |end_pos| {
            boundary = boundary[0..end_pos];
        }

        if (boundary.len > 0) return boundary;
        return null;
    }
    return null;
}

/// Helper to parse a quoted or unquoted parameter in header attributes like name="foo"
fn extractParam(header_val: []const u8, param_key: []const u8) ?[]const u8 {
    var search_idx: usize = 0;
    while (search_idx < header_val.len) {
        const found = std.mem.indexOf(u8, header_val[search_idx..], param_key) orelse return null;
        const key_start = search_idx + found;
        const val_start = key_start + param_key.len;

        // Check character immediately before key (must be whitespace or ';')
        if (found > 0) {
            const prev = header_val[key_start - 1];
            if (prev != ';' and prev != ' ' and prev != '\t') {
                search_idx = val_start;
                continue;
            }
        }

        // Must be immediately followed by '='
        if (val_start >= header_val.len or header_val[val_start] != '=') {
            search_idx = val_start;
            continue;
        }

        var rest = std.mem.trimStart(u8, header_val[val_start + 1 ..], " \t");
        if (rest.len == 0) return null;

        if (rest[0] == '"') {
            const closing = std.mem.indexOfScalarPos(u8, rest, 1, '"') orelse return null;
            return rest[1..closing];
        } else {
            const end = std.mem.indexOfAny(u8, rest, "; \t") orelse rest.len;
            return rest[0..end];
        }
    }
    return null;
}

/// parseMultipart parses a raw body slice formatted as multipart/form-data.
pub fn parseMultipart(
    allocator: std.mem.Allocator,
    body: []const u8,
    boundary: []const u8,
    max_memory: usize,
) !MultipartForm {
    if (body.len > max_memory) return error.PayloadTooLarge;

    var result = MultipartForm.init(allocator);
    errdefer result.deinit();
    const arena = result.arena.allocator();

    // The delimiter starts with "--" + boundary
    var delim_buf: [128]u8 = undefined;
    if (boundary.len + 2 > delim_buf.len) return error.BoundaryTooLong;
    const delimiter = try std.fmt.bufPrint(&delim_buf, "--{s}", .{boundary});

    // Find the first boundary
    const first_bound = std.mem.indexOf(u8, body, delimiter) orelse return error.InvalidMultipart;
    var cursor = first_bound + delimiter.len;

    while (cursor < body.len) {
        // If followed by "--", it's the terminal boundary: "--boundary--"
        if (std.mem.startsWith(u8, body[cursor..], "--")) {
            break;
        }

        // Expect CRLF after boundary line
        if (std.mem.startsWith(u8, body[cursor..], "\r\n")) {
            cursor += 2;
        } else if (std.mem.startsWith(u8, body[cursor..], "\n")) {
            cursor += 1;
        } else {
            return error.InvalidMultipart;
        }

        // Parse Part Headers up to "\r\n\r\n"
        const header_end_rel = std.mem.indexOf(u8, body[cursor..], "\r\n\r\n") orelse return error.InvalidMultipart;
        const part_headers_raw = body[cursor .. cursor + header_end_rel];
        cursor += header_end_rel + 4; // Move past \r\n\r\n to the payload data

        var part_name: ?[]const u8 = null;
        var part_filename: ?[]const u8 = null;
        var part_content_type: ?[]const u8 = null;

        var header_lines = std.mem.splitSequence(u8, part_headers_raw, "\r\n");
        while (header_lines.next()) |line| {
            if (line.len == 0) continue;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const h_name = std.mem.trim(u8, line[0..colon], " \t");
            const h_val = std.mem.trim(u8, line[colon + 1 ..], " \t");

            if (std.ascii.eqlIgnoreCase(h_name, "content-disposition")) {
                part_name = extractParam(h_val, "name");
                part_filename = extractParam(h_val, "filename");
            } else if (std.ascii.eqlIgnoreCase(h_name, "content-type")) {
                part_content_type = h_val;
            }
        }

        const name = part_name orelse return error.MissingPartName;

        // Find the next boundary marking the end of this part payload
        // We look for "\r\n--" + boundary
        var next_delim_buf: [132]u8 = undefined;
        const next_delim = try std.fmt.bufPrint(&next_delim_buf, "\r\n--{s}", .{boundary});
        const part_end_rel = std.mem.indexOf(u8, body[cursor..], next_delim) orelse return error.InvalidMultipart;
        const part_data = body[cursor .. cursor + part_end_rel];

        cursor += part_end_rel + 2; // Position cursor at "--{boundary}" for the next iteration
        cursor += delimiter.len;

        const name_dup = try arena.dupe(u8, name);
        const data_dup = try arena.dupe(u8, part_data);

        if (part_filename) |fname| {
            const fname_dup = try arena.dupe(u8, fname);
            const ct_dup = if (part_content_type) |ct| try arena.dupe(u8, ct) else null;

            try result.files.append(arena, .{
                .name = name_dup,
                .filename = fname_dup,
                .content_type = ct_dup,
                .size = data_dup.len,
                .data = data_dup,
            });
        } else {
            try result.values.append(arena, .{
                .name = name_dup,
                .value = data_dup,
            });
        }
    }

    return result;
}

test "parseBoundary extraction" {
    const ct1 = "multipart/form-data; boundary=---------------------------974767299852498929531610575";
    try std.testing.expectEqualStrings("---------------------------974767299852498929531610575", parseBoundary(ct1).?);

    const ct2 = "multipart/form-data; boundary=\"my_custom_boundary\"; charset=utf-8";
    try std.testing.expectEqualStrings("my_custom_boundary", parseBoundary(ct2).?);

    const ct3 = "application/json";
    try std.testing.expectEqual(null, parseBoundary(ct3));
}

test "parseMultipart form with text fields and file upload" {
    const allocator = std.testing.allocator;
    const boundary = "----WebKitFormBoundary7MA4YWxkTrZu0gW";
    const body =
        "------WebKitFormBoundary7MA4YWxkTrZu0gW\r\n" ++
        "Content-Disposition: form-data; name=\"title\"\r\n" ++
        "\r\n" ++
        "My First Upload\r\n" ++
        "------WebKitFormBoundary7MA4YWxkTrZu0gW\r\n" ++
        "Content-Disposition: form-data; name=\"avatar\"; filename=\"avatar.png\"\r\n" ++
        "Content-Type: image/png\r\n" ++
        "\r\n" ++
        "\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\r\n" ++
        "------WebKitFormBoundary7MA4YWxkTrZu0gW\r\n" ++
        "Content-Disposition: form-data; name=\"tags\"\r\n" ++
        "\r\n" ++
        "zig\r\n" ++
        "------WebKitFormBoundary7MA4YWxkTrZu0gW\r\n" ++
        "Content-Disposition: form-data; name=\"tags\"\r\n" ++
        "\r\n" ++
        "fast\r\n" ++
        "------WebKitFormBoundary7MA4YWxkTrZu0gW--\r\n";

    var form = try parseMultipart(allocator, body, boundary, 1024 * 1024);
    defer form.deinit();

    // 1. Check text fields
    try std.testing.expectEqualStrings("My First Upload", form.getValue("title").?);

    const tags = try form.getAllValues(allocator, "tags");
    defer allocator.free(tags);
    try std.testing.expectEqual(@as(usize, 2), tags.len);
    try std.testing.expectEqualStrings("zig", tags[0]);
    try std.testing.expectEqualStrings("fast", tags[1]);

    // 2. Check file upload
    const file = form.getFile("avatar").?;
    try std.testing.expectEqualStrings("avatar.png", file.filename);
    try std.testing.expectEqualStrings("image/png", file.content_type.?);
    try std.testing.expectEqualStrings("\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR", file.data);
    try std.testing.expectEqual(@as(usize, 16), file.size);
}

test "parseMultipart memory limit enforcement" {
    const allocator = std.testing.allocator;
    const boundary = "boundary123";
    const body = "--boundary123\r\nContent-Disposition: form-data; name=\"f\"\r\n\r\n1234567890\r\n--boundary123--\r\n";

    // Max memory 10 bytes -> body is > 10 bytes -> error.PayloadTooLarge
    try std.testing.expectError(error.PayloadTooLarge, parseMultipart(allocator, body, boundary, 10));
}
