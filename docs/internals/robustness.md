# TigerStyle & Defensive Limits

Lighting is developed following **TigerStyle** principles — an engineering discipline distilled from mission-critical systems like TigerBeetle. It prioritizes explicit limits, defensive invariants, and strict RFC protocol compliance over premature flexibility.

---

## 1. Explicit Defensive Bounds

Unbounded inputs are a primary cause of out-of-memory (OOM) crashes and DoS vulnerabilities. Lighting enforces explicit architectural limits across all subsystems:

| Limit | Value | RFC / Rationale |
| :--- | :--- | :--- |
| **Max Header Size** | `8KB ~ 16KB` | Protects against memory exhaustion from oversized headers (`431 Request Header Fields Too Large`). |
| **Max Headers Count** | `128` | Bounds header parsing stack size and hash table allocations. |
| **Max Body Drain Limit** | `256KB` | Prevents malicious slow drains on rejected keep-alive requests. |
| **Max URL URI Length** | `8KB` | RFC 9112 URI limit (`414 URI Too Long`). |
| **Connection Buffers** | Bounded `8KB ~ 16KB` | Each connection uses deterministic memory. 10,000 idle connections consume only ~80MB RAM. |

---

## 2. Invariants and Preconditions

Every function in Lighting uses assertions to verify invariants at boundaries:

* **Buffer Invariants**: `debug.assert(read_index <= write_index);` ensures buffer pointers cannot desynchronize.
* **Socket Ownership**: Streams are owned by exactly one fiber task at any point in time.
* **HTTP Status Code Bounds**: Status codes outside `100..599` trigger compile-time or runtime assertion failures.

---

## 3. RFC Compliance Matrix

* **RFC 9110 (HTTP Semantics)**:
  * Strict `Host` header presence check on HTTP/1.1 requests (`400 Bad Request` if missing).
  * Automatic `Allow` header formatting on `405 Method Not Allowed`.
  * Proper handling of `If-None-Match` for HTTP `304 Not Modified` caching.
  * Standard Range unit verification (`bytes`) and `416 Range Not Satisfiable` for invalid ranges.
* **RFC 9112 (HTTP/1.1 Messaging)**:
  * Chunked transfer coding parsing with boundary verification.
  * Stripping conflicting `Content-Length` when `Transfer-Encoding: chunked` is present to neutralize request smuggling.
* **RFC 6455 (WebSocket Protocol)**:
  * Strict SHA-1 / Base64 Sec-WebSocket-Accept generation.
  * Proper masking and opcode validation for client frames.
