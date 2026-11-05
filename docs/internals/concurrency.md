# Structured Concurrency

Lighting adopts Zig 0.17's native structured concurrency via `std.Io.Group`, aligning directly with Go's `go c.serve()` model while avoiding the pitfalls of unbounded thread pools.

---

## 1. Structured Concurrency vs Thread Pools

Traditional web servers in C or Rust often use a fixed-size worker thread pool fronted by a mutex-protected task queue:
* **Queue Saturation**: When slow clients or keep-alive connections hold worker threads, queue backpressure blocks the entire server.
* **Complex Teardown**: Coordinating thread shutdown, draining task queues, and freeing connection states requires distributed ref-counting or lock-free queues.

In Lighting, every accepted connection is scheduled onto the runtime fiber scheduler:

```zig
// Inside Server accept loop:
try self.group.concurrent(self.io, serveConnWorker, .{ self, stream });
```

### Advantages of Structured Concurrency:
1. **Hierarchical Lifecycles**: All running connection tasks belong to `self.group`. When `server.shutdown()` is invoked, calling `self.group.cancel(self.io)` immediately notifies all connection workers.
2. **Guaranteed Joining**: Awaiting the group guarantees that every connection has completed its shutdown cleanup before `server.deinit()` returns.
3. **No Thread Starvation**: Fibers yield cooperatively to the Zig runtime whenever they wait on network socket reads or writes.

---

## 2. Absolute Deadline Timeouts (`io_util.zig`)

Relative socket timeouts (e.g. `setsockopt(SO_RCVTIMEO)`) are susceptible to **Slowloris attacks**: a malicious client sending 1 byte every 4.9 seconds can hold a connection open indefinitely against a 5-second relative timeout.

Lighting implements **absolute deadline timeouts**:

```zig
pub fn readSocketWithDeadline(
    io: std.Io,
    stream: std.Io.net.Stream,
    buf: []u8,
    deadline: ?std.Io.Clock.Awake.Instant,
) !usize {
    // Calculates the remaining time relative to an immutable instant in the future
}
```

* **Header Deadline**: Sockets have a strict deadline (e.g., 2 seconds from TCP handshake) to complete the entire HTTP header frame.
* **Keep-Alive Idle Deadline**: When a connection becomes idle, it sleeps with an idle deadline. If no new request arrives within the window, the kernel closes the connection cleanly.
