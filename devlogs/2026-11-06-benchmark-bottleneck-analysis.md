# Lighting 性能优化记录：从 69k 到 135k QPS

**日期**: 2026-11-06  
**作者**: Lighting Team  
**分类**: 性能工程与 Profiling  
**测试环境**: Zig 0.17.0, Go 1.22+, Rust 1.80+ (actix-web 4.x), macOS Apple Silicon  

---

## 1. 概述

在跨语言基准测试（[`bench/run.sh`](../bench/run.sh)）中，未优化的 `ReleaseFast` 版本基准数据如下：
* **Zig (Lighting + zio)**: 68,943 req/s (延迟 687 µs)
* **Zig (Lighting + std.Io)**: 54,949 req/s (延迟 1.20 ms)

这一成绩低于 Go `net/http` (~115k req/s) 和 Rust `actix-web` (~130k req/s)。

通过系统调用追踪和代码排查，我们找到了三处瓶颈并做了调整：
1. **I/O Vector 碎片化导致系统调用放大**：响应头序列化生成了 19 个离散的 `iovec` 切片，超出了 ZIO 单次 `max_iovecs_len = 8` 的上限，使得一个 140 字节左右的 HTTP 响应需要调用 3 次 `writev`。
2. **ZIO 默认单工作线程**：`zio.Runtime.init` 默认设置 `.executors = .exact(1)`，限制底层仅有 1 个工作线程在处理 I/O 事件。
3. **高并发下的内存分配器竞争**：将通用堆分配器换为 Zig 0.17 的无锁并发分配器 `std.heap.smp_allocator`，减少多线程锁争用。

调整后，Lighting 的吞吐量从 **68,943 req/s 提升到 134,724 req/s**（提升 95%，延迟降至 364 µs），在各路径均超越 Go `net/http`，齐平甚至部分超过 Rust `actix-web`，同时内存占用仅为 Go 的一半左右（12.6 MB vs 22.4 MB）。

---

## 2. 基准环境与协议验证

### 2.1 协议对齐验证
为确认测试条件一致，我们先排除了 Go 和 Rust 协商 HTTP/2 cleartext (h2c) 的可能：
* **测试客户端**：`wrk` 原生仅支持 HTTP/1.1 与持久连接（Keep-Alive）。
* **服务端验证**：使用 `curl -v --http2-prior-knowledge` 逐个请求，Go 和 Rust 均直接重置连接拒绝 h2c。确认三者均运行在相同的 **HTTP/1.1 + Keep-Alive** 协议下。

### 2.2 未优化基准数据 (`ReleaseFast`, `wrk -t4 -c50 -d3s`)

| 实现 | 引擎 / 框架 | GET /ping 吞吐量 | 平均延迟 | CPU 使用率 | 峰值内存 (RSS) |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Zig** | Lighting + zio | 68,943 req/s | 687 µs | 392% | **11.2 MB** |
| **Zig** | Lighting + std.Io | 54,949 req/s | 1.20 ms | 410% | **7.6 MB** |
| **Go** | net/http | 113,223 req/s | 407 µs | 588% | 22.3 MB |
| **Rust** | actix-web | 130,819 req/s | 358 µs | 254% | 15.1 MB |

---

## 3. 瓶颈排查与优化方案

### 3.1 瓶颈 1：I/O Vector 碎片化与系统调用放大

#### 发现过程
Profiling 显示热点已从内存分配转移到网络 I/O 与事件轮询。查看 [`src/response_writer.zig`](../src/response_writer.zig) 中的响应头写入逻辑：

```zig
stack_vecs[vec_count] = status_line;
vec_count += 1;
for (self.headers.entries.items) |entry| {
    stack_vecs[vec_count] = entry.name;
    stack_vecs[vec_count + 1] = ": ";
    stack_vecs[vec_count + 2] = entry.value;
    stack_vecs[vec_count + 3] = "\r\n";
    vec_count += 4;
}
stack_vecs[vec_count] = "\r\n";
```

一个包含 4 个常规 Header 的基础响应，会被切分为：
`1 (状态行) + 4 * 4 (响应头) + 1 (空行分隔符) + 1 (body) = 19 个 iovec`。

再核对 ZIO 底层实现（`zio/src/io.zig`）：
```zig
const max_iovecs_len = 8;
```
ZIO 的单次 scatter/gather 上限是 8。因此 `io_util.writeSocketAllTimeout` 必须执行 **3 次独立的 `writev` / `sendmsg` 系统调用**，才能把 140 字节的小响应发完。

#### 优化方案：连续栈缓冲区 Fast Path
在 [`src/response_writer.zig`](../src/response_writer.zig) 中增加一块 1024 字节的栈缓冲区，把状态行和所有 Header 格式化为一段连续内存，与 body 组合为最多 2 个 iovec：

```zig
var header_buf: [1024]u8 = undefined;
var h_len: usize = 0;
// 格式化状态行与所有响应头至 header_buf...
if (fits) {
    var vecs: [2][]const u8 = undefined;
    vecs[0] = header_buf[0..h_len];
    var v_count: usize = 1;
    if (!self.chunked_mode and self.buffer_len > 0) {
        vecs[1] = self.buffer[0..self.buffer_len];
        v_count = 2;
    }
    try io_util.writeSocketAllTimeout(self.stream, self.io, vecs[0..v_count], self.write_timeout_ns);
}
```

这样每次响应就能通过**单次系统调用**发送完毕。

---

### 3.2 瓶颈 2：ZIO 多核调度配置

#### 发现过程
查看 [`bench/zig/main.zig`](../bench/zig/main.zig) 的运行时初始化：
```zig
const rt = try zio.Runtime.init(allocator, .{});
```
对应 `zio/src/runtime.zig` 中的定义：
```zig
executors: ExecutorCount = .exact(1),
```
默认配置只启动了 1 个 worker 线程，压测时其他 CPU 核心处于闲置状态。

#### 优化方案
显式配置自动使用所有可用核心：
```zig
const rt = try zio.Runtime.init(allocator, .{
    .executors = .auto,
});
```

---

### 3.3 瓶颈 3：并发内存分配器配置

#### 发现过程
在 50 并发长连接压测下，默认通用堆分配器存在多线程锁同步开销。

#### 优化方案
在 [`bench/zig/main.zig`](../bench/zig/main.zig) 中换用 Zig 0.17 专为多线程设计的 `smp_allocator`：
```zig
const allocator = std.heap.smp_allocator;
```

---

## 4. 优化后压测对比

在 Apple Silicon macOS 环境运行完整压测套件（`./bench/run.sh`，每项时长 10s）：

| 框架 / 语言实现 | GET /ping (QPS / 延迟) | GET /users/{id} (QPS / 延迟) | POST /echo (QPS / 延迟) | GET /files/* (QPS / 延迟) | CPU 使用率 | 峰值内存 (RSS) |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Zig (Lighting + zio)** | **134,724 req/s (364 µs)** | **132,420 req/s (390 µs)** | **116,358 req/s (438 µs)** | **125,299 req/s (393 µs)** | 769% | **12.6 MB** |
| **Zig (Lighting + std.Io)** | **97,322 req/s (533 µs)** | **92,616 req/s (563 µs)** | **100,999 req/s (558 µs)** | **90,204 req/s (639 µs)** | 781% | **8.2 MB** |
| **Rust (actix-web)** | 130,829 req/s (359 µs) | 130,831 req/s (359 µs) | 127,470 req/s (369 µs) | 131,193 req/s (358 µs) | 252% | 14.6 MB |
| **Go (net/http)** | 115,491 req/s (396 µs) | 115,141 req/s (402 µs) | 104,511 req/s (461 µs) | 113,738 req/s (405 µs) | 591% | 22.4 MB |

### 总结
1. **吞吐提升**：Lighting (zio) 在 `/ping` 场景从 68,943 req/s 提升到 134,724 req/s (+95%)，在动态路由（`/users/{id}`）达 132,420 req/s，均高于 Go `net/http`（~115k req/s），齐平 Rust `actix-web`（~130k req/s）。
2. **延迟降低**：平均延迟由 687 µs 降至 364 µs。
3. **低内存占用**：达到峰值吞吐时，Lighting (zio) 内存占用为 12.6 MB，仅为 Go（22.4 MB）的约一半。
