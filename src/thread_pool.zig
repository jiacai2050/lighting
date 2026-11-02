const std = @import("std");

/// A production-grade fixed-size worker thread pool for dispatching connection tasks.
/// Uses std.Io.Mutex and std.Io.Condition (futex-based) to guarantee 0% CPU consumption when idle,
/// and O(1) task dequeue.
pub const ThreadPool = struct {
    allocator: std.mem.Allocator,
    threads: []std.Thread,
    queue: std.ArrayListUnmanaged(Task),
    queue_head: usize = 0,
    max_queue_size: usize = 1024,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    running: std.atomic.Value(bool) = .init(true),
    io: std.Io,

    pub const Task = struct {
        runFn: *const fn (*anyopaque) void,
        ctx: *anyopaque,
    };

    pub fn create(allocator: std.mem.Allocator, io: std.Io, num_threads: usize, max_queue_size: usize) !*ThreadPool {
        const self = try allocator.create(ThreadPool);
        const actual_threads = if (num_threads == 0) 4 else num_threads;
        self.* = .{
            .allocator = allocator,
            .threads = try allocator.alloc(std.Thread, actual_threads),
            .queue = .empty,
            .queue_head = 0,
            .max_queue_size = if (max_queue_size == 0) 1024 else max_queue_size,
            .mutex = .init,
            .cond = .init,
            .running = .init(true),
            .io = io,
        };

        for (self.threads) |*t| {
            t.* = try std.Thread.spawn(.{}, workerLoop, .{self});
        }
        return self;
    }

    fn workerLoop(self: *ThreadPool) void {
        while (self.running.load(.acquire)) {
            self.mutex.lockUncancelable(self.io);
            while (self.queue_head >= self.queue.items.len and self.running.load(.acquire)) {
                self.cond.waitUncancelable(self.io, &self.mutex);
            }

            if (!self.running.load(.acquire) and self.queue_head >= self.queue.items.len) {
                self.mutex.unlock(self.io);
                break;
            }

            var task: ?Task = null;
            if (self.queue_head < self.queue.items.len) {
                task = self.queue.items[self.queue_head];
                self.queue_head += 1;
                // Compact when all items consumed to prevent unbound slice growth
                if (self.queue_head > 64 and self.queue_head == self.queue.items.len) {
                    self.queue.clearRetainingCapacity();
                    self.queue_head = 0;
                }
            }
            self.mutex.unlock(self.io);

            if (task) |t| {
                t.runFn(t.ctx);
            }
        }
    }

    pub fn spawn(self: *ThreadPool, comptime fn_ptr: anytype, args: anytype) !void {
        const Args = @TypeOf(args);
        const Closure = struct {
            arguments: Args,
            allocator: std.mem.Allocator,

            fn run(ctx: *anyopaque) void {
                const closure: *@This() = @ptrCast(@alignCast(ctx));
                const alloc = closure.allocator;
                defer alloc.destroy(closure);
                @call(.auto, fn_ptr, closure.arguments);
            }
        };

        const closure = try self.allocator.create(Closure);
        errdefer self.allocator.destroy(closure);
        closure.* = .{
            .arguments = args,
            .allocator = self.allocator,
        };

        const task = Task{
            .runFn = Closure.run,
            .ctx = closure,
        };

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.queue.items.len - self.queue_head >= self.max_queue_size) {
            return error.QueueFull;
        }

        try self.queue.append(self.allocator, task);
        self.cond.signal(self.io);
    }

    pub fn hasPendingTasks(self: *ThreadPool) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return (self.queue.items.len > self.queue_head);
    }

    pub fn pendingTaskCount(self: *ThreadPool) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return if (self.queue.items.len > self.queue_head) self.queue.items.len - self.queue_head else 0;
    }

    pub fn destroy(self: *ThreadPool) void {
        self.mutex.lockUncancelable(self.io);
        self.running.store(false, .release);
        self.mutex.unlock(self.io);

        self.cond.broadcast(self.io);

        for (self.threads) |t| {
            t.join();
        }
        self.allocator.free(self.threads);

        self.mutex.lockUncancelable(self.io);
        self.queue.deinit(self.allocator);
        self.mutex.unlock(self.io);

        self.allocator.destroy(self);
    }
};

test "ThreadPool execution" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const pool = try ThreadPool.create(allocator, io, 2, 1024);
    defer pool.destroy();

    const Worker = struct {
        fn run(val: *std.atomic.Value(usize)) void {
            _ = val.fetchAdd(10, .release);
        }
    };

    var counter = std.atomic.Value(usize).init(0);
    try pool.spawn(Worker.run, .{&counter});

    var tries: usize = 0;
    while (counter.load(.acquire) == 0 and tries < 100) : (tries += 1) {
        try io.sleep(.{ .nanoseconds = 1000 * 1000 }, .boot);
    }
    try std.testing.expectEqual(@as(usize, 10), counter.load(.acquire));
}
