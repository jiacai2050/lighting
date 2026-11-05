# Zero-Copy Protocol Parser

The HTTP/1.1 protocol parser in `src/proto/parser.zig` is designed for high throughput, zero heap allocation, and strict RFC 9112 conformance.

---

## 1. Zero-Copy In-Place Slicing

Traditional parsers copy strings into newly allocated buffers for method names, header keys, and values.

Lighting takes a different approach:
* The connection read buffer (`conn_buf`) receives raw socket data.
* As `parseRequestHead` validates HTTP tokens, it produces slices `[]const u8` pointing directly into `conn_buf`.
* **Zero heap memory** is requested from the OS or GPA during request line and header parsing.

---

## 2. Request Smuggling Defenses (RFC 9112 Section 6.3)

HTTP request smuggling occurs when upstream proxies and downstream servers disagree on request body boundaries. Lighting enforces strict RFC 9112 defenses:

1. **Both `Transfer-Encoding` and `Content-Length` Present**:
   * RFC 9112 §6.3 mandates that if a request contains both headers, `Transfer-Encoding` takes precedence.
   * To prevent desynchronization attacks against naive proxies, Lighting strips the `Content-Length` header entirely when `chunked` is detected.
2. **Invalid `Transfer-Encoding`**:
   * If `Transfer-Encoding` contains an unsupported coding (e.g. `gzip` as transfer coding), Lighting immediately rejects the request with `501 Not Implemented`.
3. **Invalid `Content-Length`**:
   * If `Content-Length` contains non-numeric characters, multiple values, or exceeds max integer bounds, Lighting immediately returns `400 Bad Request`.

---

## 3. Pipelining & CRLF Boundary Detection

HTTP/1.1 pipelining allows clients to send multiple requests in a single TCP stream without waiting for responses.

* After a request finishes, leftover bytes in `conn_buf` are scanned for the `\r\n\r\n` boundary.
* If a full header frame is already present in the buffer, Lighting parses it immediately without incurring an unnecessary `recv` syscall.
* If a partial frame is present, remaining bytes are shifted forward to the buffer head via `std.mem.copyForwards` before the next socket read.
