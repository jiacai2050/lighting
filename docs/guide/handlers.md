# Handlers & State Injection

Handlers are the core building blocks for processing HTTP requests in Lighting. Lighting uses a fat-pointer interface (`Handler`) that mirrors Go's `http.Handler`, enabling clean composition, zero-cost state injection, and seamless middleware integration.

---

## 1. The `Handler` Interface

A `Handler` is represented by a fat pointer containing an opaque context pointer and a virtual function table (`VTable`):

```zig
pub const Handler = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        serveHTTP: *const fn (ctx: *anyopaque, w: *ResponseWriter, req: *Request) anyerror!void,
    };

    pub fn serveHTTP(self: Handler, w: *ResponseWriter, req: *Request) anyerror!void {
        return self.vtable.serveHTTP(self.ptr, w, req);
    }
};
```

---

## 2. Stateless Handlers (`handleFunc`)

For endpoints that do not require state (e.g., database connections or external caches), register a stateless function using `mux.handleFunc`:

```zig
try mux.handleFunc("GET /ping", struct {
    fn handle(w: *http.ResponseWriter, _: *http.Request) anyerror!void {
        try w.writeAll("pong\n");
    }
}.handle);
```

Under the hood, `mux.handleFunc` wraps the function using `Handler.fromFn`, avoiding pointer dereferences.

---

## 3. Stateful Handlers & Dependency Injection (`Handler.bind`)

In real-world applications, endpoints frequently need access to shared services such as database pools, Redis clients, configuration objects, or user sessions.

Lighting provides `Handler.bind`, allowing you to bind any struct instance and its member method directly into a `Handler`:

```zig
const AppState = struct {
    db_pool: *DatabasePool,
    app_version: []const u8,

    pub fn getUser(self: *AppState, w: *http.ResponseWriter, req: *http.Request) anyerror!void {
        const id = req.pathValue("id") orelse return error.MissingId;

        // Access database via self.db_pool
        const user = try self.db_pool.queryUser(id);

        try w.header().set("Content-Type", "application/json");
        try w.writer().print("{{\"id\": \"{s}\", \"name\": \"{s}\", \"v\": \"{s}\"}}\n", .{
            user.id, user.name, self.app_version,
        });
    }
};

// In main.zig:
var state = AppState{
    .db_pool = &db,
    .app_version = "1.0.0",
};

// Bind the instance and method:
try mux.handle("GET /users/{id}", http.Handler.bind(&state, AppState.getUser));
```

### Why `Handler.bind` Excels:
1. **Zero Heap Allocation**: Wraps the stack or heap instance directly using compile-time `@call`.
2. **Type-Safe**: The method signature `fn (*Self, *ResponseWriter, *Request) anyerror!void` is validated at compile time.
3. **No Global Variables**: Keeps your state completely isolated and thread-safe.

---

## 4. Struct-Level Handlers (`Handler.from`)

If a struct implements a `serveHTTP` method directly:

```zig
const MetricsHandler = struct {
    counter: std.atomic.Value(u64) = .init(0),

    pub fn serveHTTP(self: *MetricsHandler, w: *http.ResponseWriter, _: *http.Request) anyerror!void {
        const count = self.counter.fetchAdd(1, .monotonic) + 1;
        try w.writer().print("Total requests: {d}\n", .{count});
    }
};

var metrics = MetricsHandler{};
try mux.handle("GET /metrics", http.Handler.from(&metrics));
```
