# Static Files

Lighting provides a production-grade static file server module in `lighting.extra.fs`. It supports RFC 9110 HTTP Range requests (for video/audio seeking), ETag caching, directory traversal defense, and responsive dark-mode directory browsing.

---

## 1. Quick Setup

```zig
const std = @import("std");
const http = @import("lighting");

var fs = http.extra.fs.FileServer.init(allocator, .{
    .root_dir = "./public",         // Filesystem directory to serve
    .strip_prefix = "/static",      // Strip "/static" from the request path
    .auto_index = true,             // Enable HTML directory listing if no index.html
    .index_file = "index.html",     // Default file to serve when targeting a directory
    .show_hidden = false,           // Disallow access to dot-files (.git, .env, etc.)
});

// Mount on the router:
try mux.handle("GET /static/{path...}", fs.handler());
```

---

## 2. Configuration Options (`FileServerOptions`)

| Option | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `root_dir` | `[]const u8` | *(Required)* | The root directory on the local filesystem. Supports both relative and absolute paths. |
| `strip_prefix` | `?[]const u8` | `null` | URL path prefix to strip before resolving filesystem paths (e.g., `"/static"` or `"/assets"`). |
| `auto_index` | `bool` | `true` | If `true`, renders a responsive directory listing when no `index.html` exists in the folder. |
| `index_file` | `[]const u8` | `"index.html"` | Default file served when a directory is requested. |
| `show_hidden` | `bool` | `false` | When `false`, requests targeting files or directories starting with `.` return `404 Not Found`. |
| `chunk_size` | `usize` | `64 * 1024` (64KB) | Buffer size used for streaming file contents across the network. |

---

## 3. RFC 9110 Features

### HTTP 206 Partial Content (Range Seeking)
Supports video seeking, large file resumption, and audio streaming:
* `Range: bytes=0-1023`: Returns the first 1024 bytes with `206 Partial Content` and `Content-Range: bytes 0-1023/500000`.
* `Range: bytes=1000-`: Returns all bytes from byte offset 1000 to end-of-file.
* `Range: bytes=-500`: Returns the final 500 bytes of the file.
* If the range is completely outside file bounds, responds with `416 Range Not Satisfiable`.

### ETag & HTTP 304 Caching
* Generates deterministic ETags based on file size and last-modification timestamp.
* Honors `If-None-Match` request headers. If the file has not changed, responds immediately with `304 Not Modified` and zero body payload, saving bandwidth.

### Traversal Defense & Security
* Strips redundant slashes, dot-segments (`.`, `..`), and percent-encoded traversal attempts (`%2e%2e%2f`).
* Any path attempting to escape outside `root_dir` returns `404 Not Found`.
* Symlinks escaping the root boundary are safely rejected.

---

## 4. Built-in Directory Browser

When `auto_index = true` and a directory without an `index.html` is requested:
* Displays file names, sizes in human-readable units (B, KB, MB, GB), and last-modified dates.
* Automatic dark/light theme switching based on user system preferences (`@media (prefers-color-scheme: dark)`).
* Folders are sorted before files, with convenient breadcrumb navigation and up-directory links.
