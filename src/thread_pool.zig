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
        cancelFn: *const fn (*anyopaque) void,
        ctx: *anyopaque,
    };

    pub fn create(allocator: std.mem.Allocator, io: std.Io, num_threads: usize, max_queue_size: usize) !*ThreadPool {
        const self = try allocator.create(ThreadPool);
        errdefer allocator.destroy(self);

        const actual_threads = if (num_threads == 0) 4 else num_threads;
        const threads = try allocator.alloc(std.Thread, actual_threads);
        errdefer allocator.free(threads);

        self.* = .{
            .allocator = allocator,
            .threads = threads,
            .queue = .empty,
            .queue_head = 0,
            .max_queue_size = if (max_queue_size == 0) 1024 else max_queue_size,
            .mutex = .init,
            .cond = .init,
            .running = .init(true),
            .io = io,
        };

        var spawned: usize = 0;
        errdefer {
            self.running.store(false, .release);
            self.cond.broadcast(self.io);
            for (self.threads[0..spawned]) |t| {
                t.join();
            }
        }

        for (self.threads) |*t| {
            t.* = try std.Thread.spawn(.{}, workerLoop, .{self});
            spawned += 1;
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
            io: std.Io,

            fn run(ctx: *anyopaque) void {
                const closure: *@This() = @ptrCast(@alignCast(ctx));
                const alloc = closure.allocator;
                defer alloc.destroy(closure);
                @call(.auto, fn_ptr, closure.arguments);
            }

            fn cancel(ctx: *anyopaque) void {
                const closure: *@This() = @ptrCast(@alignCast(ctx));
                const alloc = closure.allocator;
                const io = closure.io;
                defer alloc.destroy(closure);
                inline for (@typeInfo(Args).@"struct".field_names, @typeInfo(Args).@"struct".field_types) |field_name, field_type| {
                    if (field_type == std.Io.net.Stream) {
                        const stream = @field(closure.arguments, field_name);
                        stream.close(io);
                    }
                }
            }
        };

        const closure = try self.allocator.create(Closure);
        errdefer self.allocator.destroy(closure);
        closure.* = .{
            .arguments = args,
            .allocator = self.allocator,
            .io = self.io,
        };

        const task = Task{
            .runFn = Closure.run,
            .cancelFn = Closure.cancel,
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
        while (self.queue_head < self.queue.items.len) {
            const task = self.queue.items[self.queue_head];
            self.queue_head += 1;
            task.cancelFn(task.ctx);
        }
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

test "ThreadPool: pending tasks in queue are properly canceled on destroy" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    // Pool with 1 thread
    const pool = try ThreadPool.create(allocator, io, 1, 1024);

    const Blocker = struct {
        fn run(io_ctx: std.Io) void {
            io_ctx.sleep(.{ .nanoseconds = 100 * std.time.ns_per_ms }, .boot) catch {};
        }
    };

    // 1. First task blocks the single worker thread
    try pool.spawn(Blocker.run, .{io});

    // 2. Queue multiple tasks behind it
    for (0..10) |_| {
        try pool.spawn(Blocker.run, .{io});
    }

    try std.testing.expect(pool.hasPendingTasks());

    // 3. destroy() must cancel all unexecuted tasks, free their closures, and exit without leak
    pool.destroy();
}

test "ThreadPool: create failure cleans up self and threads without leaks" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    // 1. Fail on first allocation (ThreadPool struct)
    var failing_alloc1 = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, ThreadPool.create(failing_alloc1.allocator(), io, 2, 1024));

    // 2. Fail on second allocation (threads array)
    var failing_alloc2 = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 1 });
    try std.testing.expectError(error.OutOfMemory, ThreadPool.create(failing_alloc2.allocator(), io, 2, 1024));
}
