const std = @import("std");

pub const DirEntry = struct {
    name: []const u8,
    is_dir: bool,
    size: u64,
    mtime_secs: i64,
};

pub fn formatSize(buf: []u8, bytes: u64) []const u8 {
    if (bytes < 1024) {
        return std.fmt.bufPrint(buf, "{d} B", .{bytes}) catch "0 B";
    } else if (bytes < 1024 * 1024) {
        const kb: f64 = @as(f64, @floatFromInt(bytes)) / 1024.0;
        return std.fmt.bufPrint(buf, "{d:.1} KB", .{kb}) catch "0 KB";
    } else if (bytes < 1024 * 1024 * 1024) {
        const mb: f64 = @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0);
        return std.fmt.bufPrint(buf, "{d:.1} MB", .{mb}) catch "0 MB";
    } else {
        const gb: f64 = @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0 * 1024.0);
        return std.fmt.bufPrint(buf, "{d:.2} GB", .{gb}) catch "0 GB";
    }
}

pub fn formatMtime(buf: []u8, epoch_secs: i64) []const u8 {
    if (epoch_secs <= 0) return "-";
    const SECS_PER_DAY = 86400;
    const epoch_days = @divFloor(epoch_secs, SECS_PER_DAY);
    var day_secs = @mod(epoch_secs, SECS_PER_DAY);
    if (day_secs < 0) day_secs += SECS_PER_DAY;

    const hour = @divFloor(day_secs, 3600);
    const minute = @divFloor(@mod(day_secs, 3600), 60);
    const second = @mod(day_secs, 60);

    // Compute Y-M-D from epoch days (Civil calendar calculation)
    const z = epoch_days + 719468;
    const era = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe: u64 = @intCast(z - era * 146097);
    const yoe = (doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096)) / 365;
    const y: i64 = @as(i64, @intCast(yoe)) + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = (5 * doy + 2) / 153;
    const d = doy - (153 * mp + 2) / 5 + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    const year = if (m <= 2) y + 1 else y;

    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        year,
        m,
        d,
        hour,
        minute,
        second,
    }) catch "-";
}

fn escapeHtml(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(allocator);

    for (input) |c| {
        switch (c) {
            '&' => try out.appendSlice(allocator, "&amp;"),
            '<' => try out.appendSlice(allocator, "&lt;"),
            '>' => try out.appendSlice(allocator, "&gt;"),
            '"' => try out.appendSlice(allocator, "&quot;"),
            '\'' => try out.appendSlice(allocator, "&#39;"),
            else => try out.append(allocator, c),
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Percent-encodes characters in a single path segment per RFC 3986 (only unreserved chars remain unencoded).
pub fn percentEncodePathSegment(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(allocator);

    const hex_chars = "0123456789ABCDEF";
    for (input) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => {
                try out.append(allocator, c);
            },
            else => {
                try out.append(allocator, '%');
                try out.append(allocator, hex_chars[(c >> 4) & 0x0F]);
                try out.append(allocator, hex_chars[c & 0x0F]);
            },
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Generates an adaptive Dark Mode HTML directory listing.
pub fn renderDirectory(
    allocator: std.mem.Allocator,
    display_path: []const u8,
    entries: []const DirEntry,
    is_root: bool,
) ![]u8 {
    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(allocator);

    const escaped_path = try escapeHtml(allocator, display_path);
    defer allocator.free(escaped_path);

    try out.appendSlice(allocator,
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\  <meta charset="UTF-8">
        \\  <meta name="viewport" content="width=device-width, initial-scale=1.0">
        \\  <title>Index of 
    );
    try out.appendSlice(allocator, escaped_path);
    try out.appendSlice(allocator,
        \\</title>
        \\  <style>
        \\    :root {
        \\      color-scheme: light;
        \\      --bg: #f8fafc;
        \\      --card: #ffffff;
        \\      --border: #e2e8f0;
        \\      --text: #0f172a;
        \\      --text-muted: #64748b;
        \\      --primary: #0284c7;
        \\      --primary-hover: #0369a1;
        \\      --badge-bg: #f1f5f9;
        \\      --hover-row: #f8fafc;
        \\      --shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.05);
        \\    }
        \\    @media (prefers-color-scheme: dark) {
        \\      :root:not([data-theme="light"]) {
        \\        color-scheme: dark;
        \\        --bg: #0f172a;
        \\        --card: #1e293b;
        \\        --border: #334155;
        \\        --text: #f8fafc;
        \\        --text-muted: #94a3b8;
        \\        --primary: #38bdf8;
        \\        --primary-hover: #0284c7;
        \\        --badge-bg: #334155;
        \\        --hover-row: #243248;
        \\        --shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.3);
        \\      }
        \\    }
        \\    :root[data-theme="dark"] {
        \\      color-scheme: dark;
        \\      --bg: #0f172a;
        \\      --card: #1e293b;
        \\      --border: #334155;
        \\      --text: #f8fafc;
        \\      --text-muted: #94a3b8;
        \\      --primary: #38bdf8;
        \\      --primary-hover: #0284c7;
        \\      --badge-bg: #334155;
        \\      --hover-row: #243248;
        \\      --shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.3);
        \\    }
        \\    :root[data-theme="light"] {
        \\      color-scheme: light;
        \\      --bg: #f8fafc;
        \\      --card: #ffffff;
        \\      --border: #e2e8f0;
        \\      --text: #0f172a;
        \\      --text-muted: #64748b;
        \\      --primary: #0284c7;
        \\      --primary-hover: #0369a1;
        \\      --badge-bg: #f1f5f9;
        \\      --hover-row: #f8fafc;
        \\      --shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.05);
        \\    }
        \\    * { box-sizing: border-box; margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
        \\    body { background-color: var(--bg); color: var(--text); min-height: 100vh; padding: 2rem 1rem; display: flex; justify-content: center; }
        \\    .container { width: 100%; max-width: 900px; display: flex; flex-direction: column; gap: 1.25rem; }
        \\    header { display: flex; align-items: center; justify-content: space-between; flex-wrap: wrap; gap: 1rem; border-bottom: 1px solid var(--border); padding-bottom: 1rem; }
        \\    .title-box { display: flex; align-items: center; gap: 0.5rem; font-size: 1.25rem; font-weight: 700; word-break: break-all; }
        \\    .theme-toggle-btn { background: var(--badge-bg); color: var(--text); border: 1px solid var(--border); padding: 0.35rem 0.75rem; border-radius: 9999px; font-size: 0.85rem; font-weight: 500; cursor: pointer; }
        \\    .theme-toggle-btn:hover { border-color: var(--primary); }
        \\    .search-input { width: 100%; background: var(--card); border: 1px solid var(--border); border-radius: 0.5rem; padding: 0.6rem 0.85rem; color: var(--text); font-size: 0.9rem; outline: none; }
        \\    .search-input:focus { border-color: var(--primary); }
        \\    .card { background: var(--card); border: 1px solid var(--border); border-radius: 0.75rem; overflow: hidden; box-shadow: var(--shadow); }
        \\    table { width: 100%; border-collapse: collapse; text-align: left; font-size: 0.9rem; }
        \\    th { background: var(--badge-bg); padding: 0.75rem 1rem; font-weight: 600; color: var(--text-muted); border-bottom: 1px solid var(--border); }
        \\    td { padding: 0.75rem 1rem; border-bottom: 1px solid var(--border); }
        \\    tr:last-child td { border-bottom: none; }
        \\    tr.entry-row:hover { background-color: var(--hover-row); }
        \\    a.entry-link { color: var(--text); text-decoration: none; display: flex; align-items: center; gap: 0.5rem; font-weight: 500; }
        \\    a.entry-link:hover { color: var(--primary); }
        \\    .size, .mtime { color: var(--text-muted); font-size: 0.85rem; }
        \\    .mtime { white-space: nowrap; }
        \\    .footer-bar { display: flex; justify-content: space-between; font-size: 0.8rem; color: var(--text-muted); padding: 0.25rem 0.5rem; }
        \\  </style>
        \\</head>
        \\<body>
        \\  <div class="container">
        \\    <header>
        \\      <div class="title-box">
        \\        <span>⚡️</span>
        \\        <span>Index of </span>
        \\        <span>
    );
    try out.appendSlice(allocator, escaped_path);
    try out.appendSlice(allocator,
        \\</span>
        \\      </div>
        \\      <button id="theme-btn" class="theme-toggle-btn" onclick="cycleTheme()" title="Toggle Theme">🌓 Auto</button>
        \\    </header>
        \\
        \\    <input type="text" id="filter" class="search-input" placeholder="Search files and folders..." oninput="filterEntries()" autocomplete="off">
        \\
        \\    <div class="card">
        \\      <table>
        \\        <thead>
        \\          <tr>
        \\            <th>Name</th>
        \\            <th style="width: 120px; text-align: right;">Size</th>
        \\            <th style="width: 180px; text-align: right;">Modified</th>
        \\          </tr>
        \\        </thead>
        \\        <tbody id="entries-body">
    );

    // Parent directory row if not root
    if (!is_root) {
        try out.appendSlice(allocator,
            \\<tr class="entry-row">
            \\  <td><a class="entry-link" href="../">📁 ..</a></td>
            \\  <td style="text-align: right;" class="size">-</td>
            \\  <td style="text-align: right;" class="mtime">-</td>
            \\</tr>
        );
    }

    var size_buf: [32]u8 = undefined;
    var mtime_buf: [32]u8 = undefined;

    for (entries) |entry| {
        const escaped_name = try escapeHtml(allocator, entry.name);
        defer allocator.free(escaped_name);

        const encoded_name = try percentEncodePathSegment(allocator, entry.name);
        defer allocator.free(encoded_name);

        const icon = if (entry.is_dir) "📁" else "📄";
        const suffix = if (entry.is_dir) "/" else "";
        const size_str = if (entry.is_dir) "-" else formatSize(&size_buf, entry.size);
        const mtime_str = formatMtime(&mtime_buf, entry.mtime_secs);

        try out.appendSlice(allocator, "<tr class=\"entry-row\" data-name=\"");
        try out.appendSlice(allocator, escaped_name);
        try out.appendSlice(allocator, "\"><td><a class=\"entry-link\" href=\"./");
        try out.appendSlice(allocator, encoded_name);
        try out.appendSlice(allocator, suffix);
        try out.appendSlice(allocator, "\">");
        try out.appendSlice(allocator, icon);
        try out.appendSlice(allocator, " ");
        try out.appendSlice(allocator, escaped_name);
        try out.appendSlice(allocator, suffix);
        try out.appendSlice(allocator, "</a></td><td style=\"text-align: right;\" class=\"size\">");
        try out.appendSlice(allocator, size_str);
        try out.appendSlice(allocator, "</td><td style=\"text-align: right;\" class=\"mtime\">");
        try out.appendSlice(allocator, mtime_str);
        try out.appendSlice(allocator, "</td></tr>\n");
    }

    try out.appendSlice(allocator,
        \\        </tbody>
        \\      </table>
        \\    </div>
        \\    <div class="footer-bar">
        \\      <span>Lighting HTTP FileServer</span>
        \\      <span>Zig 0.17</span>
        \\    </div>
        \\  </div>
        \\  <script>
        \\    const THEME_KEY = 'lighting_fs_theme';
        \\    const themeBtn = document.getElementById('theme-btn');
        \\    function applyTheme(theme) {
        \\      const root = document.documentElement;
        \\      if (theme === 'dark') { root.setAttribute('data-theme', 'dark'); themeBtn.innerText = '🌙 Dark'; }
        \\      else if (theme === 'light') { root.setAttribute('data-theme', 'light'); themeBtn.innerText = '☀️ Light'; }
        \\      else { root.removeAttribute('data-theme'); themeBtn.innerText = '🌓 Auto'; }
        \\    }
        \\    function cycleTheme() {
        \\      const current = localStorage.getItem(THEME_KEY) || 'auto';
        \\      const next = current === 'auto' ? 'dark' : (current === 'dark' ? 'light' : 'auto');
        \\      if (next === 'auto') localStorage.removeItem(THEME_KEY);
        \\      else localStorage.setItem(THEME_KEY, next);
        \\      applyTheme(next);
        \\    }
        \\    applyTheme(localStorage.getItem(THEME_KEY) || 'auto');
        \\
        \\    function filterEntries() {
        \\      const q = document.getElementById('filter').value.toLowerCase();
        \\      const rows = document.querySelectorAll('.entry-row');
        \\      rows.forEach(r => {
        \\        const name = (r.getAttribute('data-name') || '..').toLowerCase();
        \\        r.style.display = name.includes(q) ? '' : 'none';
        \\      });
        \\    }
        \\  </script>
        \\</body>
        \\</html>
    );

    return out.toOwnedSlice(allocator);
}

test "renderDirectory test" {
    const alloc = std.testing.allocator;
    const entries = [_]DirEntry{
        .{ .name = "folder", .is_dir = true, .size = 0, .mtime_secs = 1700000000 },
        .{ .name = "hello.txt", .is_dir = false, .size = 1048576, .mtime_secs = 1700000000 },
        .{ .name = "javascript:alert(1)", .is_dir = false, .size = 100, .mtime_secs = 1700000000 },
        .{ .name = "file#1?v=2.txt", .is_dir = false, .size = 200, .mtime_secs = 1700000000 },
    };

    const html = try renderDirectory(alloc, "/static/", &entries, false);
    defer alloc.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "href=\"./folder/\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "href=\"./hello.txt\"") != null);
    // Scheme-injection XSS mitigation: must be prefixed with ./ and colon percent-encoded
    try std.testing.expect(std.mem.indexOf(u8, html, "href=\"./javascript%3Aalert%281%29\"") != null);
    // Fragment and query chars encoded
    try std.testing.expect(std.mem.indexOf(u8, html, "href=\"./file%231%3Fv%3D2.txt\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "1.0 MB") != null);
}
