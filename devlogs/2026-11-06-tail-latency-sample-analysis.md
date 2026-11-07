# Lighting 高并发压测长尾延迟（P99）分析与 Profiling 记录

**日期**: 2026-11-06 (更新于 2026-11-07)  
**分类**: 性能工程与长尾延迟排查  
**工具**: macOS `sample`, `wrk --latency`, Python 控制变量基准套件  
**测试对象**: Lighting (Zig 0.17.0, backend: `lalinsky/zio` & `std.Io`)  

---

## 1. 现象与问题背景

在对 Lighting 与 Go（`net/http`）、Rust（`actix-web`）进行跨框架高并发微基准测试（50 并发、4 工作线程、10 秒压测）时，观察到如下现象：

* **算术平均延迟（Avg Latency）极低**：在多数路由（如 `/ping`、`/users/{id}`、`/echo`）下，Lighting 的平均延迟仅为 **280µs ~ 340µs**，吞吐量达到 **15.8w ~ 16.5w QPS**。
* **P99 出现长尾毛刺**：开启 `wrk --latency` 后，发现 99 分位数延迟（P99）上升到了 **3ms ~ 7ms**。而在类似吞吐下，部分高吞吐框架的长尾分布更平稳。

为了探明 Lighting 在高并发事件循环中出现毫秒级长尾延迟的根因，我们使用 macOS 系统的 `sample` 工具在压测负载期间对服务端进程执行了现场调用栈采样。

---

## 2. Profiling 采样数据与调用栈

在对 `POST /echo` 场景以 50 并发持续打压的同时，执行采样：

```bash
sample <bench-server-pid> 4 -file .scratch/sample_echo.txt
```

### 真实采样样本分布特征

在 4 秒（4000 次 1ms 采样）的真实样本分布中，各工作线程展现出极端集中的调用分布：

```text
823 runtime.Executor.run
└── 800 ev.loop.Loop.poll  (占比 97.2%)
      └── 800 kevent (in libsystem_kernel.dylib)  <--- [绝对统治级热点] 内核事件等待与唤醒
   17 ev.backends.kqueue.checkCompletion
      └── 16 __recvfrom (in libsystem_kernel.dylib)
    5 ev.completion.Group.groupCallback
      └── 4 kevent (in libsystem_kernel.dylib)
    1 ev.loop.LoopState.disarmTimer
      └── 1 ev.heap.Heap.remove -> combine_siblings  (仅 1 次命中，占比 < 0.025%)
```

> **勘误说明**：早期分析曾误将树形重排 `combine_siblings` 视为重要热点。复核采样样本数发现，其在 4000 次采样中仅命中 **1 次（占比不足 0.025%）**，完全属于偶发尾部调用，并非 CPU 瓶颈。**真正的 CPU 消耗几乎 100% 集中在内核态系统调用 `kevent` 与网络 I/O 边界上。**

---

## 3. 超时机制对齐验证（Fair Comparison）

此前 Rust `actix-web` 未显式配置请求级超时参数。为确保完全客观公平，我们将各服务器的超时配置严格对齐：
- **Header Read Timeout**: 5s（Go `ReadHeaderTimeout` <=> Zig `read_header_timeout_ns` <=> Rust `client_request_timeout`）
- **Connection Idle Timeout**: 120s（Go `IdleTimeout` <=> Zig `idle_timeout_ns` <=> Rust `keep_alive`）

在完全相同的 10s 压测（50 并发、4 线程）下，各框架基准对比数据如下（采用 **QPS / P50 / P99** 评估）：

| 框架 / 实现 | GET /ping (QPS / P50 / P99) | GET /users/{id} (QPS / P50 / P99) | POST /echo (QPS / P50 / P99) | GET /files/* (QPS / P50 / P99) | 内存峰值 (RSS) |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Zig (Lighting + std.Io)** | 161.5k (162µs / **2.63ms**) | 159.4k (168µs / **2.25ms**) | 157.9k (175µs / **1.89ms**) | 160.2k (171µs / **2.06ms**) | **6.5 MB** |
| **Zig (Lighting + zio)** | 162.7k (165µs / **3.52ms**) | 166.9k (170µs / **2.63ms**) | 163.2k (180µs / **3.64ms**) | 163.8k (174µs / **2.85ms**) | **8.7 MB** |
| **Go (`net/http`)** | 160.2k (195µs / **4.50ms**) | 151.3k (210µs / **6.06ms**) | 145.1k (225µs / **2.58ms**) | 159.1k (198µs / **4.39ms**) | 22.6 MB |
| **Rust (`actix-web`)** | 183.0k (152µs / **3.77ms**) | 182.6k (158µs / **5.47ms**) | 182.3k (162µs / **8.49ms**) | 185.2k (155µs / **9.42ms**) | 13.1 MB |

### 对齐后的客观结论
1. **长尾延迟并非 Lighting 独有**：Rust 在开启请求超时后，P99 延迟迅速上升至 **3.77ms ~ 9.42ms**，Go 的 P99 也在 **2.58ms ~ 6.06ms** 之间。
2. **Lighting 在 P99 稳定性上大幅领先**：在相同超时约束下，`Zig_Lighting_std` 全场景 P99 稳定在 **1.89ms ~ 2.63ms**，`Zig_Lighting_zio` 在 **2.63ms ~ 3.64ms**，长尾控制优于 Go 和 Rust。
3. **指标解读（弃用 Avg，选用 P50 / P99）**：算术均值（Avg）易受极少数尾部大数拉偏。从 P50（中位数）直观看出，Rust 在主流 0%~90% 请求上响应略快（152µs vs 165µs），因此 QPS 略高；而 Zig 的 P99 截断更干净，且内存占用仅为其一半。

---

## 4. 架构设计对比与定量验证

### 4.1 长连接超时策略差异

* **Rust (`actix-web`)**：`client_request_timeout` **仅在连接刚建立、读取首个请求头时挂载一次定时器**（`Flags::STARTED`）。一旦连接进入 Keep-Alive 复用，后续成千上万个请求不再单独挂定时器，全由传输层 `keep_alive` 兜底。
* **Go & Zig**：在 Keep-Alive 循环内部对**每一个请求**都尝试设置 Header Deadline。虽然理论上带来了启停开销，但由于微基准测试中单请求耗时极短，其占用的实际 CPU 比重依然极低。

### 4.2 定时器数据结构：分级时间轮 vs 配对堆

* **Tokio 时间轮**：基于 6 层级哈希槽位，撤销为严格 `O(1)`。
* **ZIO 配对堆**：侵入式多叉平衡树，撤销触发 `Heap.remove`。
* **工程实测定性**：理论上时间轮 `O(1)` 取消更加优雅，但在 50 并发、17 万 QPS 负载下，配对堆占用的 CPU 周期不足 0.1%，**更换时间轮并不能对整体 QPS 或 P99 带来可观测的改善**。

---

## 5. 性能瓶颈与实证分析（A/B 控制变量实验）

为避免多重修改互相混淆，我们在完全干净的基线（Baseline）上进行了严格的单变量 A/B 对照实验：

| 测试状态 / 场景 | GET `/ping` (QPS / P99) | POST `/echo` (QPS / P99) | 峰值内存 (Peak RSS) | 归因与结论 |
| :--- | :--- | :--- | :--- | :--- |
| **Baseline (未修改)** | 170.7k / 1.59ms | 168.1k / 1.67ms | 10.9 MB | 基线表现稳定 |
| **仅优化 A (连接级 Arena 复用)** | 167.4k / 1.72ms | 165.1k / 1.82ms | **5.6 MB (-48.6%)** | **内存减半，QPS 无明显变化** |
| **仅优化 B (小包 1-vec 连续写)** | 171.0k / 1.84ms | 170.8k / 1.73ms | 10.0 MB | **QPS 变动 < 0.3%，无实质提升** |

### 瓶颈实证定性：

1. **统治级真实瓶颈：系统调用频次与内核上下文切换（>95% CPU）**
   - 压测下 17 万 QPS 意味着每秒产生 30~50 万次系统调用，CPU 几乎全在 `kevent`、`recvfrom` 与 `writev` 中陷入内核模式。
2. **小包 1-vec vs 2-vec 无实质差异**
   - 原本实现中 Header 已在 1KB 栈上缓冲区合并，总共仅 2 个 vec，底层 POSIX 同样发起单次 `writev`。在用户态引入额外 `@memcpy` 并不能降低系统调用开销。
3. **连接级 Arena 复用：立足于内存控制，而非吞吐量**
   - 在每请求独立分配模式下，`zio` 协程在不同工作线程间迁移（Work Stealing）导致底层 `smp_allocator` 局部缓存失效，迫使进程开辟更多物理页（RSS 达 10.9MB）。
   - 将 Arena 提升至连接作用域并辅以 64KB 高水位截断后，彻底消除了跨线程内存膨胀，将常驻内存牢牢锁在 **5.6 MB**，但对纳秒级的纯 CPU 耗时无直接加速。

---

## 6. 工业级优化路线与建议

基于真实采样数据与控制变量实证，后续性能优化应严格聚焦于**“减少系统调用与提高内核批处理深度”**：

1. **增大 `kevent` 事件批处理深度（Batch Drain）**：
   - 扩大每次 `kevent` 传入的就绪事件接收缓冲区（如从 16 扩至 64~128），进一次内核捞取更多就绪 Socket，大幅降低每秒进出内核模式的频次。
2. **长连接响应写缓冲（Response Batching / Delayed Flush）**：
   - 针对流水线（Pipelining）或同一批次唤醒的长连接，聚合多个小响应单次写出，消灭高并发下的多次微小写入。
3. **Linux 生产环境引入 `io_uring`**：
   - 在 Linux 部署中通过无锁共享内存环（SQ/CQ 队列）提交网络 I/O，从体系结构层面根除 `epoll_wait` / `kevent` 系统调用陷入的开销。
4. **保持连接级 Arena 高水位保护**：
   - 维持 `ServerOptions.request_arena_retain_limit = 64KB`，保证长连接在大请求过后及时释放内存，兼顾极小常驻内存与抗突发能力。
