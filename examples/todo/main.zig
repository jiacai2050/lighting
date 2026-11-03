const std = @import("std");
const http = @import("lighting");
const SqliteDB = @import("db.zig").SqliteDB;

pub const App = struct {
    allocator: std.mem.Allocator,
    db: *SqliteDB,

    pub fn handleIndex(_: *App, w: *http.ResponseWriter, _: *http.Request) anyerror!void {
        const html = @embedFile("index.html");
        try w.header().set("Content-Type", "text/html; charset=utf-8");
        try w.writeAll(html);
    }

    pub fn handleList(self: *App, w: *http.ResponseWriter, req: *http.Request) anyerror!void {
        const todos = try self.db.list(req.arena);
        try w.header().set("Content-Type", "application/json");
        try w.writer().print("{f}\n", .{std.json.fmt(todos, .{})});
    }

    pub fn handleCreate(self: *App, w: *http.ResponseWriter, req: *http.Request) anyerror!void {
        const body = try req.readBodyAlloc(64 * 1024);
        const parsed = try std.json.parseFromSlice(
            struct { title: []const u8 },
            req.arena,
            body,
            .{ .ignore_unknown_fields = true },
        );
        defer parsed.deinit();

        const title = std.mem.trim(u8, parsed.value.title, " \t\r\n");
        if (title.len == 0) {
            w.writeHeader(.bad_request);
            try w.header().set("Content-Type", "application/json");
            try w.writeAll("{\"error\":\"Title cannot be empty\"}\n");
            return;
        }

        const todo = try self.db.create(req.arena, title);
        w.writeHeader(.created);
        try w.header().set("Content-Type", "application/json");
        try w.writer().print("{f}\n", .{std.json.fmt(todo, .{})});
    }

    pub fn handleToggle(self: *App, w: *http.ResponseWriter, req: *http.Request) anyerror!void {
        const id_str = req.pathValue("id") orelse {
            w.writeHeader(.bad_request);
            return;
        };
        const id = std.fmt.parseInt(i64, id_str, 10) catch {
            w.writeHeader(.bad_request);
            return;
        };
        _ = try self.db.toggle(id);
        try w.header().set("Content-Type", "application/json");
        try w.writeAll("{\"ok\":true}\n");
    }

    pub fn handleDelete(self: *App, w: *http.ResponseWriter, req: *http.Request) anyerror!void {
        const id_str = req.pathValue("id") orelse {
            w.writeHeader(.bad_request);
            return;
        };
        const id = std.fmt.parseInt(i64, id_str, 10) catch {
            w.writeHeader(.bad_request);
            return;
        };
        _ = try self.db.delete(id);
        try w.header().set("Content-Type", "application/json");
        try w.writeAll("{\"ok\":true}\n");
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const port: u16 = if (init.environ_map.get("PORT")) |p| std.fmt.parseInt(u16, p, 10) catch 7000 else 7000;
    const db_path = init.environ_map.get("DB_PATH") orelse "/tmp/lighting-todo.db";

    var db = try SqliteDB.open(allocator, io, db_path);
    defer db.deinit();

    var app = App{
        .allocator = allocator,
        .db = &db,
    };

    var mux = http.ServeMux.init(allocator);
    defer mux.deinit();

    try mux.handle("GET /{$}", http.Handler.bind(&app, App.handleIndex));
    try mux.handle("GET /api/todos", http.Handler.bind(&app, App.handleList));
    try mux.handle("POST /api/todos", http.Handler.bind(&app, App.handleCreate));
    try mux.handle("POST /api/todos/{id}/toggle", http.Handler.bind(&app, App.handleToggle));
    try mux.handle("DELETE /api/todos/{id}", http.Handler.bind(&app, App.handleDelete));

    var logging = http.LoggingHandler{ .next = mux.handler() };

    var server = http.Server.init(allocator, io, .{
        .handler = logging.handler(),
        .num_threads = 8,
    });
    defer server.deinit();

    std.log.info("Todo server running at http://127.0.0.1:{d} (SQLite: {s})...", .{ port, db_path });
    try server.listenAndServe("127.0.0.1", port);
}
