# SQLite & Embedded SPA

This recipe demonstrates building a full-stack CRUD web application with an embedded dark-mode Single Page Application (SPA), REST API endpoints, and a local SQLite database using state injection (`Handler.bind`).

Source code: [`examples/todo/`](https://github.com/jiacai2050/lighting/tree/main/examples/todo)

---

## Key Highlights

### 1. State Injection with `Handler.bind`

Instead of relying on global database pointers, the `App` struct holds the database handle and binds methods cleanly to the router:

```zig
pub const App = struct {
    allocator: std.mem.Allocator,
    db: *SqliteDB,

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

        const todo = try self.db.create(req.arena, parsed.value.title);
        w.writeHeader(.created);
        try w.header().set("Content-Type", "application/json");
        try w.writer().print("{f}\n", .{std.json.fmt(todo, .{})});
    }
};

// Route binding in main:
try mux.handle("GET /api/todos", http.Handler.bind(&app, App.handleList));
try mux.handle("POST /api/todos", http.Handler.bind(&app, App.handleCreate));
try mux.handle("POST /api/todos/{id}/toggle", http.Handler.bind(&app, App.handleToggle));
try mux.handle("DELETE /api/todos/{id}", http.Handler.bind(&app, App.handleDelete));
```

### 2. Single-Binary Distribution with `@embedFile`

The frontend HTML/JS/CSS assets are embedded directly into the compiled executable at compile time:

```zig
pub fn handleIndex(_: *App, w: *http.ResponseWriter, _: *http.Request) anyerror!void {
    const html = @embedFile("index.html");
    try w.header().set("Content-Type", "text/html; charset=utf-8");
    try w.writeAll(html);
}
```

The resulting binary has zero filesystem asset dependencies and can be deployed anywhere as a single standalone executable.

---

## Running the Example

```bash
make run-todo
```

Open `http://127.0.0.1:7000` in your web browser to interact with the SPA.
