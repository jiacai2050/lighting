const std = @import("std");
const sqlite = @import("sqlite");

pub const Todo = struct {
    id: i64,
    title: []const u8,
    completed: bool,
};

pub const SqliteDB = struct {
    io: std.Io,
    db: sqlite.Database,
    mutex: std.Io.Mutex = .init,

    pub fn open(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !SqliteDB {
        const path_z = try allocator.dupeSentinel(u8, path, 0);
        defer allocator.free(path_z);

        const db = try sqlite.Database.open(.{
            .path = path_z,
            .mode = .ReadWrite,
            .create = true,
        });

        var self = SqliteDB{
            .io = io,
            .db = db,
        };
        try self.initSchema();
        return self;
    }

    pub fn deinit(self: *SqliteDB) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.db.close();
    }

    fn initSchema(self: *SqliteDB) !void {
        const schema =
            \\CREATE TABLE IF NOT EXISTS todos (
            \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\    title TEXT NOT NULL,
            \\    completed INTEGER NOT NULL DEFAULT 0
            \\);
        ;
        try self.db.exec(schema, .{});
    }

    pub fn list(self: *SqliteDB, allocator: std.mem.Allocator) ![]Todo {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const Row = struct {
            id: i64,
            title: sqlite.Text,
            completed: i64,
        };

        const stmt = try self.db.prepare(struct {}, Row, "SELECT id, title, completed FROM todos ORDER BY id ASC");
        defer stmt.finalize();

        try stmt.bind(.{});
        defer stmt.reset();

        var list_arr = std.ArrayListUnmanaged(Todo).empty;
        errdefer {
            for (list_arr.items) |item| allocator.free(item.title);
            list_arr.deinit(allocator);
        }

        while (try stmt.step()) |row| {
            const title_copy = try allocator.dupe(u8, row.title.data);
            try list_arr.append(allocator, .{
                .id = row.id,
                .title = title_copy,
                .completed = (row.completed != 0),
            });
        }

        return list_arr.toOwnedSlice(allocator);
    }

    pub fn create(self: *SqliteDB, allocator: std.mem.Allocator, title: []const u8) !Todo {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const InsertParam = struct {
            title: sqlite.Text,
        };

        const stmt = try self.db.prepare(InsertParam, void, "INSERT INTO todos (title, completed) VALUES (:title, 0)");
        defer stmt.finalize();

        try stmt.exec(.{ .title = sqlite.text(title) });

        const id = sqlite.c.sqlite3_last_insert_rowid(self.db.ptr);
        const title_copy = try allocator.dupe(u8, title);
        return .{
            .id = id,
            .title = title_copy,
            .completed = false,
        };
    }

    pub fn toggle(self: *SqliteDB, id: i64) !bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const Param = struct { id: i64 };
        try self.db.exec("UPDATE todos SET completed = CASE completed WHEN 0 THEN 1 ELSE 0 END WHERE id = :id", Param{ .id = id });
        return true;
    }

    pub fn delete(self: *SqliteDB, id: i64) !bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const Param = struct { id: i64 };
        try self.db.exec("DELETE FROM todos WHERE id = :id", Param{ .id = id });
        return true;
    }
};
