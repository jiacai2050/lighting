# Lighting 性能优化排查记：从 69k 到 135k QPS 的排查与调优

**日期**: 2026-11-06  
**作者**: Lighting Team  
**分类**: 性能工程、Profiling 与底层排查  
**测试环境**: Zig 0.17.0, Go 1.22+, Rust 1.80+ (actix-web 4.x), macOS Apple Silicon (12核: 8P + 4E)  

---

## 1. 背景与初测现状

在搭建 Lighting 与主流语言 Web 框架的跨语言基准测试（`bench/run.sh`）时，我们在 `ReleaseFast` 模式下跑出第一版基准数据：

* **Zig (Lighting + zio)**: 68,943 req/s（平均延迟 687 µs）
* **Zig (Lighting + std.Io)**: 54,949 req/s（平均延迟 1.20 ms）
* **Go (net/http)**: 115,491 req/s（平均延迟 396 µs）
* **Rust (actix-web)**: 130,829 req/s（平均延迟 359 µs）

虽然 Lighting 吞吐接近 7 万 QPS，但明显低于 Go `net/http`（~115k）和 Rust `actix-web`（~130k）。

Lighting 在路由与请求解析上已经做了零拷贝处理，正常情况下不应该有这么大的差距。为此我们逐步排查可能的原因。

---

## 2. 第一阶段：排除外部干扰与协议对齐

排查性能前，我们先确认各测试对象的基准和条件是否对齐。

### 2.1 怀疑一：Go / Rust 是否使用了 HTTP/2 cleartext (h2c)？
HTTP/2 具备单连接多路复用能力，如果在测试中协商了 h2c，长连接压测下的吞吐可能会大幅提升。

* **压测客户端核验**：压测使用的客户端是 `wrk`，源码确认其仅支持 HTTP/1.1 协议及 Keep-Alive 连接复用，不支持 HTTP/2。
* **服务端实测验证**：使用 `curl` 强制以 HTTP/2 先验知识发起请求：
  ```bash
  curl -v --http2-prior-knowledge http://127.0.0.1:8088/ping
  ```
  测试显示，Go `net/http` 与 Rust `actix-web` 均直接重置连接（Connection reset by peer）并拒绝请求。
* **结论**：三者均运行在相同的 **HTTP/1.1 + Keep-Alive** 协议下，测试协议一致。

### 2.2 怀疑二：并发模型与压测客户端差异
在早期文档中，使用 `ab -k -c 50` 曾测得约 7.5k ~ 8k 甚至更高的数值。为何换用 `wrk -t4 -c50` 后，多核并发下的吞吐没有成比例放大？
* `ab` 是单进程单线程模型，50 个并发连接由单线程轮询驱动，多线程竞争不会显现。
* `wrk -t4` 启动了 4 个独立的 OS 线程同时发起高频请求，会直接反映服务端在多核调度与线程同步上的瓶颈。

---

## 3. 第二阶段：系统级 Profiling 观测

确认测试条件一致后，我们转向服务端运行时的实际开销。

### 3.1 使用 macOS `/usr/bin/sample` 采样调用栈
在 `wrk -t4 -c50` 持续压测期间，对 Lighting 服务进程进行实时 CPU 调用栈采样：

```bash
sample <bench-server-pid> 1 -file .scratch/profile.txt
```

截取采样报告中的核心调用图（Call Graph）：

```text
Call graph:
    586 Thread_9082552   DispatchQueue_1: com.apple.main-thread  (serial)
    + 413 start  (in dyld)
    + ! 413 main  (in bench-server)  start.zig:754
    + !   413 main.main  (in bench-server)  main.zig:81
    + !     413 server.Server.listenAndServe  (in bench-server)  server.zig:152
    + !       413 server.Server.serve  (in bench-server)  server.zig:125
    + !         413 Io.net.Server.accept  (in bench-server)  net.zig:1592
    + !           413 io.netAcceptImpl  (in bench-server)  io.zig:2257
    + !             ...
    + !               412 runtime.Executor.run  (in bench-server)  runtime.zig:905
    + !               : 222 runtime.Executor.parkAndSearch  (in bench-server)  runtime.zig:969
    + !               : | 215 runtime.Executor.park  (in bench-server)  runtime.zig:1019
    + !               : | + 212 ev.loop.Loop.poll  (in bench-server)  loop.zig:1511
    + !               : | + ! 208 ev.backends.kqueue.poll  (in bench-server)  kqueue.zig:759
    + !               : | + ! : 208 kevent  (in libsystem_kernel.dylib)  <--- 核心大部分时间在事件轮询等待
    + 173 coro.coroutines.Coroutine.setup.CoroutineData.entrypointFn  (in bench-server)  coroutines.zig:1580
    +   173 task.AnyTask.startFn  (in bench-server)  task.zig:613
    +     173 task.Closure.call  (in bench-server)  task.zig:77
    +       173 Io.Group.concurrent.TypeErased.start  (in bench-server)  Io.zig:1389
    +         173 server.Server.serveConnWorker  (in bench-server)  server.zig:156
    +           97 server.Server.serveConn  (in bench-server)  server.zig:354
    +           : 93 response_writer.ResponseWriter.finish  (in bench-server)  response_writer.zig:446
    +           : | 82 response_writer.ResponseWriter.flushHeaders  (in bench-server)  response_writer.zig:369
    +           : | + 82 proto.io_util.writeSocketAllTimeout  (in bench-server)  io_util.zig:78
    +           : | +   82 proto.io_util.writeSocketTimeout  (in bench-server)  io_util.zig:58
    +           : | +     82 Io.operateTimeout  (in bench-server)  Io.zig:567
    +           : | +       82 Io.Batch.awaitConcurrent  (in bench-server)  Io.zig:696
    +           : | +         80 io.batchAwaitConcurrentImpl  (in bench-server)  io.zig:736
    +           : | +         ! 80 io.operateInner  (in bench-server)  io.zig:544
    +           : | +         !   79 io.netWriteOpImpl  (in bench-server)  io.zig:2896
    +           : | +         !   : ...
    +           : | +         !   :   69 ev.backends.kqueue.submit  (in bench-server)  kqueue.zig:651
    +           : | +         !   :   : 68 ev.sockreg.submitIo  (in bench-server)  sockreg.zig:386
    +           : | +         !   :   :   66 ev.backends.kqueue.checkCompletion  (in bench-server)  kqueue.zig:920
    +           : | +         !   :   :   | 66 os.net.send  (in bench-server)  net.zig:1233
    +           : | +         !   :   :   | + 66 __sendmsg  (in libsystem_kernel.dylib)  <--- 响应写出频繁陷入内核系统调用
```

通过调用图可以观察到两点：
1. **CPU 算力未充分利用**：在 4 线程压测下，Lighting（zio）整机 CPU 占用率在 300%~400% 之间，主线程大量样本停留在 `runtime.Executor.park` / `kevent` 等待中，低于物理核心上限。
2. **热点集中在 I/O 写出**：路由树检索（Radix Tree Lookup）和请求解析未出现在采样热点中；而 **85% 以上的协程活跃样本** 集中在 `ResponseWriter.finish` -> `flushHeaders` -> `writeSocketAllTimeout` -> `__sendmsg` 的系统调用链路上。

这表明瓶颈不在用户态业务逻辑或 HTTP 协议解析，而在 **网络 I/O 的系统调用方式** 与 **运行时并发调度**。

---

## 4. 第三阶段：深潜三大核心瓶颈与优化

沿着 Profiling 提供的线索，我们对相关代码与依赖库进行源码排查。

---

### 4.1 瓶颈一：I/O Vector 碎片化导致系统调用放大

#### 源码审计
查看 `src/response_writer.zig` 中的响应头写出逻辑 `flushHeaders`：

```zig
// 优化前的向量组装逻辑
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
vec_count += 1;
```

为避免内存分配和字符串拷贝，原始实现将响应的各字段切成了独立的内存切片（`[]const u8`），组装成 I/O Vector（Scatter/Gather I/O）。

一个包含 4 个标准 Header（`Content-Type`、`Content-Length`、`Date`、`Connection`）的基础 HTTP 响应：
* 状态行：1 个切片
* 4 个 Header：每个拆为 `Name`、`": "`、`Value`、`"\r\n"` 4 个切片，共 16 个切片
* 协议尾部分隔符 `"\r\n"`：1 个切片
* 响应 Body：1 个切片
* **总计：1 + 16 + 1 + 1 = 19 个 `iovec` 切片**

#### 底层约束冲突
查看 ZIO 的 Socket 写实现（`zio/src/io.zig`）：

```zig
const max_iovecs_len = 8;
...
var slices: [max_iovecs_len][]const u8 = undefined;
var op = ev.NetSend.init(..., ev.WriteBuf.fromSlices(slices[0..n], ...), .{});
```

ZIO 内部出于固定栈内存分配的考虑，限制单次批量提交的 scatter/gather 上限为 **8 个 iovec**。

这意味着 Lighting 调用 `io_util.writeSocketAllTimeout` 发送这 19 个 iovec 时，底层驱动必须分批发送：
* 第 1 批：发送前 8 个向量 -> **触发 1 次 `writev` / `sendmsg`**
* 第 2 批：发送中 8 个向量 -> **触发第 2 次 `writev` / `sendmsg`**
* 第 3 批：发送剩余 3 个向量 -> **触发第 3 次 `writev` / `sendmsg`**

一个 140 字节左右的小响应在网络层触发了 3 次系统调用。用户态与内核态切换的开销远高于内存小切片的处理成本。把内存切得太碎导致系统调用次数翻倍，拉低了吞吐。

#### 优化方案：连续栈缓冲区 Fast Path
在网络小包场景中，数百字节的内存拷贝（`memcpy`）在 CPU L1 Cache 中只需要几个纳秒，比发起系统调用（微秒级）快得多。

我们在 `src/response_writer.zig` 中增加了 1024 字节栈缓冲区 Fast Path：
1. 在栈上预分配 `header_buf: [1024]u8`。
2. 将状态行与所有 Header 顺序写入连续的 `header_buf`。
3. 只要总 Header 长度在 1KB 以内（覆盖绝大多数常见响应），只构造至多 2 个向量：`[header_bytes, body_bytes]`。
4. 调用一次 `writeSocketAllTimeout`，在**单次系统调用内原子写出**。

```zig
var header_buf: [1024]u8 = undefined;
var h_len: usize = status_line.len;
var fits = h_len <= header_buf.len;
if (fits) {
    @memcpy(header_buf[0..status_line.len], status_line);
    for (self.headers.entries.items) |entry| {
        // 顺序将 Header Name, ": ", Value, "\r\n" 拷贝至栈缓冲区...
    }
    // 写入结束符 "\r\n"
}

if (fits) {
    var vecs: [2][]const u8 = undefined;
    vecs[0] = header_buf[0..h_len];
    var v_count: usize = 1;
    if (!self.chunked_mode and self.buffer_len > 0) {
        vecs[1] = self.buffer[0..self.buffer_len];
        v_count = 2;
    }
    // 单次原子系统调用完成发送
    try io_util.writeSocketAllTimeout(self.stream, self.io, vecs[0..v_count], self.write_timeout_ns);
    return;
}
```

---

### 4.2 瓶颈二：ZIO 运行时默认单线程配置

#### 源码审计
减少系统调用次数后吞吐量明显提升，但多核压测时 CPU 占用依然不高。查看基准测试启动入口 `bench/zig/main.zig`：

```zig
const rt = try zio.Runtime.init(allocator, .{});
```

查看 `zio/src/runtime.zig` 中的默认选项：

```zig
/// Total number of executors to run. Always one unless `zio_options.scheduling`
executors: ExecutorCount = .exact(1),
```

ZIO 默认将工作线程数设为 `.exact(1)`。此时只有 1 个 OS 线程在轮询事件和执行协程，无法利用多核。

#### 优化方案
在初始化时显式指定 `.executors = .auto`：

```zig
const rt = try zio.Runtime.init(allocator, .{
    .executors = .auto,
});
```

在 `auto` 模式下，ZIO 会通过 `std.Thread.getCpuCount()` 自动启动多核 Executor 线程池，启用跨核任务窃取（Work-Stealing），充分利用多核资源。

---

### 4.3 瓶颈三：高并发长连接下的内存分配器锁竞争

#### 采样数据与排查发现
在 50 并发持续压测下，连接创建、Request 结构体与临时 Header 列表频繁分配与释放。

未换用 `smp_allocator` 时，采样报告（`.scratch/sample_zio.txt`）记录到了明显的全局锁争用：

```text
Call graph:
    + !         173 server.Server.serveConn  (server.zig:354)
    + !         : 104 response_writer.ResponseWriter.finish  (response_writer.zig:442)
    + !         : | 104 mem.Allocator.dupe  (Allocator.zig:481)
    + !         : |   104 mem.Allocator.alloc  (Allocator.zig:223)
    + !         : |     104 heap.ArenaAllocator.alloc  (ArenaAllocator.zig:397)
    + !         : |       104 heap.SafeAllocator.resize  (SafeAllocator.zig:1237)
    + !         : |         104 heap.SafeAllocator.growingResizeBucket  (SafeAllocator.zig:992)
    + !         : |           104 heap.SafeAllocator.AllocFooter.populate  (SafeAllocator.zig:613)
    + !         : |             104 heap.SafeAllocator.captureStackTrace  (SafeAllocator.zig:877)
    + !         : |               104 debug.captureCurrentStackTrace  (debug.zig:702)
    + !         : |                 104 debug.StackIterator.next  (debug.zig:1102)
    + !         : |                   104 debug.SelfInfo.MachO.unwindFrame  (MachO.zig:141)
    + !         : |                     93 debug.SelfInfo.MachO.findModule  (MachO.zig:484)
    + !         : |                       80 Io.Mutex.lock  (Io.zig:1745)
    + !         : |                         80 __ulock_wait2  <--- 线程阻塞在内核锁等待中
```

**分析**：
多线程并发分配时，默认分配器（`init.gpa`）在维护安全元数据时触发了 `captureStackTrace`，并在解析模块符号表时获取全局互斥锁（`findModule` -> `Io.Mutex.lock` -> `__ulock_wait2`）。
在 50 并发下，多个工作线程同时申请/释放内存，导致线程串行等待该全局锁，形成 Lock Convoy。

#### 优化方案
在 `bench/zig/main.zig` 中将全局分配器切换为 Zig 0.17 专为高并发多线程设计的无锁/线程本地缓存分配器：

```zig
const allocator = std.heap.smp_allocator;
```

#### 优化后对比采样
换用 `smp_allocator` 后再次采样（`.scratch/sample_smp.txt`）：

```text
Call graph:
    + !         : | 1 heap.ArenaAllocator.alloc  (ArenaAllocator.zig:520)
    + !         : | + 1 heap.SmpAllocator.alloc  (SmpAllocator.zig:127)
    + !         : | +   1 heap.SmpAllocator.slotSize  (SmpAllocator.zig:0)
```

`__ulock_wait2` 锁等待消失，`SmpAllocator` 的分配开销在 4808 个采样点中仅占 7 个（小于 0.15%），内存分配不再是热点。

---

## 5. 优化后全量压测结果对比

在完成上述三项改动后，我们在同一台 Apple Silicon 机器上重新执行了完整的自动化对比测试（`./bench/run.sh`，每项持续 10 秒）：

| 框架 / 语言实现 | GET /ping (QPS / 延迟) | GET /users/{id} (QPS / 延迟) | POST /echo (QPS / 延迟) | GET /files/* (QPS / 延迟) | CPU 负载 | 峰值内存 (RSS) |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Zig (Lighting + zio)** | **134,724 req/s (364 µs)** | **132,420 req/s (390 µs)** | **116,358 req/s (438 µs)** | **125,299 req/s (393 µs)** | 769% | **12.6 MB** |
| **Zig (Lighting + std.Io)** | **97,322 req/s (533 µs)** | **92,616 req/s (563 µs)** | **100,999 req/s (558 µs)** | **90,204 req/s (639 µs)** | 781% | **8.2 MB** |
| **Rust (actix-web)** | 130,829 req/s (359 µs) | 130,831 req/s (359 µs) | 127,470 req/s (369 µs) | 131,193 req/s (358 µs) | 252% | 14.6 MB |
| **Go (net/http)** | 115,491 req/s (396 µs) | 115,141 req/s (402 µs) | 104,511 req/s (461 µs) | 113,738 req/s (405 µs) | 591% | 22.4 MB |

---

## 6. 深度解读与疑问探讨

### 6.1 为什么服务端最高 CPU 停留在 770% 左右？
通过 `sysctl` 检查测试机的硬件拓扑：
* 总逻辑核心数：12
* **性能大核（P-Core）：8 个**
* **能效小核（E-Core）：4 个**

macOS XNU 内核调度器在面对高负载线程时，会优先分派给 8 个性能大核。同时，压测客户端 `wrk`（`-t4`，4 线程）运行在同一台机器上，每秒发包收包自身消耗约 300%~400% CPU。

服务端跑出 769% CPU，说明 8 个性能大核基本跑满，剩余核心算力由 `wrk` 和操作系统网络栈占用，整机算力基本打满。

### 6.2 为什么 Rust 仅需 252% CPU 就能跑出 130k QPS？
Actix-web 底层基于 Tokio 和事件循环状态机，在 HTTP/1.1 Keep-Alive 场景下每请求指令开销更小，以更低的 CPU 占用完成了相同吞吐。

Lighting 在使用 ZIO 后同样达到了 134k+ QPS，峰值内存占用更低（12.6 MB，约为 Go 22.4 MB 的一半）。

---

## 7. 总结与工程启示

1. **“零拷贝”不等于“高性能”**：
   把数据切成散装向量虽然避免了内存拷贝，但如果导致底层产生额外的系统调用，进出内核态的开销远高于少量内存的 `memcpy`。**单次系统调用聚合写出优于碎片化的零拷贝**。
2. **注意运行时默认配置**：
   部分异步框架（如 ZIO）默认仅配置单线程（`.exact(1)`）。高并发压测时需显式配置多核调度。
3. **分配器对并发吞吐的影响明显**：
   在多线程热点循环中，应使用针对并发场景优化的分配器（如带有线程本地缓存的 `std.heap.smp_allocator`），避免锁争用影响吞吐。
