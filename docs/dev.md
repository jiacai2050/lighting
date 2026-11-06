# Lighting Development & Debugging Guide

This guide compiles common workflows, debugging tips, and verification techniques for working on the **Lighting** web framework.

---

## 1. Verifying HTTP Keep-Alive

Validating persistent connection reuse (Keep-Alive) is critical when developing network services. The simplest and most reliable way to test this is with `curl`.

### 1.1 Requesting Multiple URLs in a Single Command (Recommended)

Specify multiple URLs in a single `curl` invocation with verbose mode (`-v`):

```bash
curl -v http://127.0.0.1:7000/ http://127.0.0.1:7000/
```

When Keep-Alive is operating correctly, two key markers appear in the verbose output:

1. **At the end of the first request**:
   ```text
   < HTTP/1.1 200 OK
   < Connection: keep-alive
   < Content-Length: 46
   <
   * Connection #0 to host 127.0.0.1 left intact   <-- Connection remains open
   ```

2. **At the beginning of the second request**:
   ```text
   * Re-using existing connection with host 127.0.0.1 <-- Reuses TCP socket, no new handshake
   > GET / HTTP/1.1
   > Host: 127.0.0.1:7000
   ```

---

### 1.2 Testing Sequential Endpoints with `--next`

To test different paths or endpoints over the exact same persistent TCP connection:

```bash
curl -v http://127.0.0.1:7000/hello/alice --next http://127.0.0.1:7000/hello/bob
```

Both HTTP requests are transmitted sequentially across the same socket, with `Re-using existing connection` displayed before the second request.

---

### 1.3 Negative Verification (`Connection: close`)

To confirm proper behavior when the client requests disconnection via `Connection: close`:

```bash
curl -v -H "Connection: close" http://127.0.0.1:7000/ http://127.0.0.1:7000/
```

Both server and client acknowledge the termination:
* `< Connection: close`
* `* Closing connection 0`
* The subsequent request triggers a fresh TCP three-way handshake (`* Connected to ...`).
