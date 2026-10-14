# 第 8 章　BE Pipeline 与向量化执行

[全书导航](../README.md) · [术语表](../appendices/A-glossary.md)

> 教学结构修订：2026-10-14。每章先沿一个问题阅读代码，再做实验、观察结果，最后解释对象和分支。历史正文基线为 `a53b182f810be2b3731c7dfdf6f40ff5a0ad63bd`；本次摘录取自当前本地文件，完整文件 SHA-256 与行号保存在[源码摘录清单](../examples/08-chapter-workshops/source-manifest.json)。运行证据来自报告版本 `doris-0.0.0-a53b182f810` 的二进制，不能仅凭版本前缀认定当前工作目录与二进制逐文件相同。

**本章问题：流水线在等待数据时，为什么不应该一直占用线程？**

本章验证方式：已归档运行证据 + 源码走查；扩展分支见本章边界。建议先用 20—40 分钟完成主案例，第四部分的扩展阅读可分次完成；这不是新增的每日必交任务。

## 一、源码讲解：先找到决定行为的对象和分支

先把 PipelineTask 看成可重复调度的状态机。execute 的前提是 RUNNABLE 且没有 blocked dependency；一次调用不是“整条查询从头到尾执行到底”。Block 是批量数据容器，Task 是工作推进单位，二者都不等于线程。

### 先读这段真实代码

文件：`be/src/exec/pipeline/pipeline_task.cpp`，当前文件第 455—468 行。下面是连续原文摘录，局部片段省略了方法的其他部分；不要把片段当完整实现。

```cpp
Status PipelineTask::execute(bool* done) {
    if (_exec_state != State::RUNNABLE || _blocked_dep != nullptr) [[unlikely]] {
#ifdef BE_TEST
        return Status::InternalError("Pipeline task is not runnable! Task info: {}",
                                     debug_string());
#else
        return Status::FatalError("Pipeline task is not runnable! Task info: {}", debug_string());
#endif
    }

    auto fragment_context = _fragment_context.lock();
    if (!fragment_context) {
        return Status::InternalError("Fragment already finished! Query: {}", print_id(_query_id));
    }
```

### 这几行应该怎样读

`_exec_state` 和 `_blocked_dep` 是 execute 的入口前提；违反前提时返回错误，而不是继续空转。`_fragment_context.lock()` 从弱引用取得上下文，拿不到则报告片段已结束。这两层检查分别约束任务状态和关联对象寿命。

### 一台 BE 上的并发问题

MPP 把工作分到多台机器，BE 还需要在有限线程上推进许多任务。若每个任务在等待数据、网络或内存时都独占线程，资源会被等待者占据。

Pipeline 将一部分可以连续推进的数据处理组织起来，再由 Task 与依赖关系参与调度。它不是简单地为每个计划节点新建一条线程。算子、Pipeline、Task、线程四者要分别理解。

### Block：在内存中成批处理列

Doris 的执行代码使用 Block 与 Column 等结构表示批量数据。一批订单可以包含城市列、金额列和状态列；过滤结果决定哪些行继续参与后续计算。

批处理可以减少逐行虚函数调用或重复准备工作，也更适合连续访问及某些 SIMD 优化。但它不意味着数据永远不复制，更不意味着所有表达式都执行为同一种 CPU 指令。可空列、字符串、复杂类型与常量列都有自己的表示和处理成本。

`be/src/core/block/block.h` 是识别容器的入口。先看它如何组织列和行数，不必第一次就读完全部模板。随后挑一个具体算子的输入输出，对照类型和生命周期，理解它是在复用、引用还是构造新的列数据。

## 二、动手实验：先预测，再核对

默认使用已保存的实验材料或只读源码，不需要启动服务。运行环境已停止；若选择重新执行 SQL，先按[实验复现说明](../examples/07-live-lab-20261014/REPRODUCE.md)确认服务、版本与数据状态。初始化、导入和更新脚本不可在现有表上盲目重放。

1. 查看聚合 Profile 中 Exchange 和 LocalMergeSort 的 dependency wait，记录等待所属的对象，而非只抄总耗时。
2. 打开 execute，继续向下检索 blocked、dependency、eos、time，沿一次拿不到输入与一次拿到 Block 的分支画状态图。
3. 把 50000 → 1000 → 5 的行数变化分别连到扫描、聚合和排序输出；不要把每一层累计计数再加一次。

本章实验材料：[PROFILE_ANALYSIS.md](../examples/07-live-lab-20261014/PROFILE_ANALYSIS.md)。

## 三、观察结果：先陈述事实，再划清证据范围

该次 Profile 的 Exchange 等待数据为 2.603ms，LocalMergeSortSource 的依赖等待均值约 2.531ms，总查询约 17ms。它们有并发与包含关系，不能相加当总耗时。

**本章边界：** Profile 不是线程时间线；没有验证公平性、取消竞态或强制 Spill。

## 四、回到源码解释：把现象还原成执行过程

入口状态检查说明调度器必须先满足任务可运行条件。Dependency 将“等输入”变成调度状态，Block 才承载这一轮真正处理的数据。某个依赖等待高应继续查上游产出；并不能仅凭等待时间认定 CPU 算得慢。

### 用自己的话走完这条链

合上结果后，按“输入 → 关键对象/状态 → 分支条件 → 可观察结果”的顺序回答本章问题：**流水线在等待数据时，为什么不应该一直占用线程？** 再指出一项尚不能从现有实验得出的结论。能把每个箭头落到本章的方法或证据，比记住术语更接近读懂源码。

### Task 如何推进一轮工作

当前 `PipelineTask::execute(bool* done)` 首先要求任务处于可运行状态，并取得片段上下文。随后准备/打开算子，在循环中检查依赖、取消和时间片，取得数据并推进 Sink。

```text
RUNNABLE
  → 检查是否被依赖阻塞
  → 获取并处理一批数据
  → 交给 Sink
  → 继续 / 因时间片让出 / 等待依赖 / 进入结束处理
```

这是逻辑示意，不是完整枚举状态机。源码中的 `_is_blocked()`、`_exec_time_slice` 与 `get_block_after_projects()` 给出了可以核对的落点。

当达到时间片时，当前实现会更新 yield 相关计数并退出本轮循环。退出 `execute()` 不一定代表查询完成：任务可能之后继续被调度。一个 Java 请求处理方法返回后请求就结束的直觉，在这里不适用。

### Dependency 让等待成为可调度状态

数据尚未到达、Sink 暂时不能接收、内存条件尚未满足，都可能阻止继续推进。依赖关系表达“什么时候可以再做”，调度器才有机会把线程分给别的任务。

假设上游完成但没有唤醒下游，下游可能永久等待；假设被取消的任务再次按正常数据路径执行，则可能访问已经进入清理阶段的状态。这解释了为什么依赖连接、取消与回调属于执行正确性，而非外围优化。

当前 `execute()` 在依赖检查后还再次检查取消，并处理 `_wake_up_early` 等路径。阅读这些代码应建立线程与事件关系，不把重复检查直接视为可删除的冗余。本书不在没有并发证据时提出清理补丁。

### EOS 不等于可以马上释放资源

`PipelineTask` 源码明确区分 `_eos` 与 `done`。前者表示数据执行阶段到达结束；后者还关系到任务是否可以关闭，例如是否存在待完成的异步工作。

一种情形是输入已读完，但 Sink 或 RPC 回调仍在使用资源。若此时仅凭 EOS 就销毁对象，可能产生生命周期错误；反过来，等待条件永远不释放又会泄漏任务或让查询挂住。

因此读一个算子时，不只看如何产生输出，还要看 prepare/open、执行、finish/close 及取消路径。对 C++ 初学者，先追对象“由谁持有、谁最后使用”比先掌握所有语言特性更有帮助。

### 内存与 Spill 在这条链路中的位置

Hash Join、聚合或排序可能积累大量状态。内存压力下，适用算子可以走 Spill 路径，把部分数据写出并在后续恢复处理。这需要额外 I/O、状态管理和依赖协调，不是免费扩容。

当前 Task 代码会处理 spilling 状态及尚未输出的 Block；不能在任意让出时都清空它，否则可能丢数据。哪些算子、数据形态和版本支持 Spill，要沿具体实现核对，本章不承诺所有查询都能靠落盘避免 OOM。

### 精读与验证

| 路径（相对仓库根目录） | 目的 |
|---|---|
| `be/src/exec/pipeline/pipeline_task.cpp` | `prepare()`、`execute()`、阻塞与完成判断 |
| `be/src/exec/pipeline/pipeline_fragment_context.cpp` | 片段内 Pipeline/Task 的组织入口 |
| `be/src/core/block/block.h` | 批量列数据表示 |
| `be/src/exec/operator/` | 具体算子与本地状态 |
| `be/src/exec/spill/` | Spill 相关工作 |

测试入口为 `be/test/exec/pipeline/pipeline_task_test.cpp`，本章仅确认存在，没有运行。后续观察可选择一条查询，区分执行时间、依赖等待、yield 和 close 等信息；不能把总等待时间都称为 CPU 计算时间。

对源码贡献，生命周期问题需要相应事件序列或并发测试，单纯输入一批数据得到正确输出并不足够。下一章先精读聚合状态，建立一个可计算的正确性例子。

### 延伸源码专题

- [专题 1　从真实 EXPLAIN 走到 FE/BE 协议与取消](../deep-dives/01-query-rpc-and-cancellation.md)
- [专题 6　算子内存、背压、Spill 与缓存分层](../deep-dives/06-memory-operators-and-caches.md)

---

[全书导航](../README.md) · [术语表](../appendices/A-glossary.md)
