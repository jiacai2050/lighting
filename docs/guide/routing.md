# Routing & URL Patterns

Lighting features a high-performance, radix-tree-based request router called `ServeMux`, heavily inspired by Go 1.22's routing enhancements.

---

## 1. Initializing `ServeMux`

```zig
var mux = http.ServeMux.init(allocator);
defer mux.deinit();
```

To pass the router to your server or middleware chain, use `mux.handler()`:

```zig
var server = http.Server.init(allocator, io, .{
    .handler = mux.handler(),
});
```

---

## 2. Route Registration Syntax

Route patterns take the form:

```text
[METHOD ][HOST]/[PATH]
```

### Examples:
* `"GET /"`: Matches `GET` requests to `/` and any sub-path (prefix match).
* `"GET /{$}"`: Matches `GET` requests strictly to `/` (exact match).
* `"POST /api/v1/users"`: Matches `POST` requests to `/api/v1/users`.
* `"/healthz"`: Matches any HTTP method (`GET`, `POST`, `PUT`, etc.) to `/healthz`.
* `"api.example.com/items"`: Matches requests with `Host: api.example.com` specifically.

---

## 3. Path Parameters

Path segments enclosed in curly braces `{...}` capture dynamic URL segments:

### Single-Segment Wildcards (`{name}`)
Matches exactly one non-empty path segment between slashes `/`:

```zig
try mux.handleFunc("GET /users/{id}", struct {
    fn handle(w: *http.ResponseWriter, req: *http.Request) anyerror!void {
        const id = req.pathValue("id") orelse return error.MissingParam;
        try w.writer().print("User ID: {s}\n", .{id});
    }
}.handle);
```

* `GET /users/42` -> `id = "42"`
* `GET /users/42/profile` -> Does not match this rule (falls through).

### Multi-Segment Catch-All Wildcards (`{path...}`)
Captures the remainder of the URL path including slashes:

```zig
try mux.handleFunc("GET /static/{filepath...}", struct {
    fn handle(w: *http.ResponseWriter, req: *http.Request) anyerror!void {
        const filepath = req.pathValue("filepath") orelse "";
        try w.writer().print("Requested file: {s}\n", .{filepath});
    }
}.handle);
```

* `GET /static/css/theme.css` -> `filepath = "css/theme.css"`
* `GET /static/images/logo.png` -> `filepath = "images/logo.png"`

---

## 4. Exact Root Matching (`/{$}`)

By default in standard URL routing, a trailing slash `/` acts as a subtree prefix. If you want a handler that only executes for the root URL `/` without catching unregistered routes, use the Go 1.22+ `/{$}` syntax:

```zig
try mux.handleFunc("GET /{$}", struct {
    fn handle(w: *http.ResponseWriter, _: *http.Request) anyerror!void {
        try w.writeAll("Welcome to the homepage!\n");
    }
}.handle);
```

---

## 5. Specificity and Precedence Rules

When multiple patterns could match a given request, `ServeMux` selects the most specific route using deterministic precedence rules:

1. **Host-specific** matches take precedence over wildcard host matches.
2. **Method-specific** matches take precedence over any-method matches.
3. Path segment precedence:
   `Literal Segment` > `Single-Segment Wildcard {id}` > `Catch-All Wildcard {path...}`

For example, given:
* `GET /users/admin` (Literal)
* `GET /users/{id}` (Wildcard)

A request to `GET /users/admin` will reliably dispatch to the literal handler, whereas `GET /users/123` dispatches to the wildcard handler.

---

## 6. Automatic `405 Method Not Allowed`

If a route matches a registered path pattern but fails to match the HTTP method, `ServeMux` automatically:
1. Traverses the routing tree to collect all registered methods for that path.
2. Sets the standard `Allow` header (e.g., `Allow: GET, HEAD`).
3. Responds with `405 Method Not Allowed`.
