# 专题 6　算子内存、背压、Spill 与缓存分层

[全书导航](../README.md) · [专题导航](README.md)

> 源码基线：`a53b182f810be2b3731c7dfdf6f40ff5a0ad63bd`；补写日期：2026-10-13。以下为源码分析与标明的教学推演，未运行对应功能测试。仓库路径均相对 `/Users/jiangyuan/open/doris`。

## 1. Hash Join 的两边不是对称流式执行

`be/src/exec/operator/hashjoin_build_sink.cpp` 的 Build 侧构造供 Probe 使用的结构。Probe 需要对应的 Build 状态就绪，Pipeline 因此有依赖，而不是让两个线程随时读取同一个半成品 Hash Table。

Inner Join 输出匹配组合；Left Outer Join 还需输出没有匹配的左行；Semi Join 只表达存在性。NULL 与残余条件决定“Hash Key 命中”是否就是 SQL 意义的匹配。例子：一个左行匹配三个右行，Inner Join 可输出三行，Semi Join 保留左行一次。只比较最终行数的单一用例无法验证所有 Join 类型。

Runtime Filter 由执行中得到的信息向读取侧提供过滤机会；它减少候选输入，不能替代完整 Join 条件。排障要区分未生成、未及时到达、已到达但选择率低、应用后仍有残余过滤。外连接的保留行语义限制了哪些方向可以安全过滤。

## 2. 内存记账为什么跟线程切换有关

`be/src/runtime/memory/mem_tracker_limiter.cpp` 中的 Limiter 对应资源限制层，细粒度 MemTracker 用于归因。`ThreadMemTrackerMgr` 维护线程上的记账上下文。Pipeline/异步回调会切换执行线程，所以 `SCOPED_ATTACH_TASK` 一类 RAII 作用域必须将分配归到正确查询。

教学事件：查询 A 提交异步读取 → 工作线程执行回调 → 分配 Block → 交给 A 消费。若只按工作线程原来的上下文记账，A 的实际占用与限额判断就可能脱节。阅读时把“谁持有内存”和“计到哪个 Tracker”分别画出来。

共享指针保证对象活到引用释放，不提供字段并发保护；锁保证临界区互斥，不保证对象在异步任务执行时仍然存在。两种问题需要分别审视。

## 3. 背压把消费速度反馈给生产者

`be/src/exec/exchange/vdata_stream_recvr.cpp` 的接收队列既要在无数据时阻塞消费者，也要在缓冲受限时对生产者施加约束。Dependency 的 block/set_ready 是调度信号，不是忙等循环。

```text
生产者快、消费者慢 → 队列积压 → 限制继续生产
消费者取走数据 → 缓冲释放 → 依赖就绪 → 生产恢复
取消/关闭 → 唤醒等待者 → 观察终止状态 → 释放资源
```

空队列并不意味着 EOS：上游可能尚未发送。等待者也不能在取消后永久等待数据，取消链必须使其退出。具体 QueryContext → Fragment → Task 的路径见[专题 1](01-query-rpc-and-cancellation.md)。

## 4. Sort Spill 的写出和恢复

`be/src/exec/operator/spill_sort_sink_operator.cpp` 的 `SpillSortSinkOperatorX::revoke_memory()` 及 `SpillSortSinkLocalState::_execute_spill_sort()` 是内存回收与写出接缝；Source 在 `spill_sort_source_operator.cpp` 中通过 `execute_merge_sort_spill_files()`、`_create_intermediate_merger()`、`get_block_impl()` 组织归并读取。

教学例子：输入分三批，每批在内存中排序形成有序 run，写出后再归并。不能将三份有序文件直接拼接；各文件内部有序不代表文件之间有序。恢复过程仍要内存、缓冲和 IO，因此 Spill 并不是“内存不足必然成功”的保证。

TopN 可以利用只保留部分候选的机会，普通全排序需要完整顺序；当 LIMIT、OFFSET、排序表达式或数据分布改变时，两者的实际资源行为也改变。看 `sort_sink_operator.cpp` 与 Spill 对应实现时，要记录创建了哪一种 sorter，避免用统一算法推断所有查询。

## 5. 四种缓存的命中含义

| 层次 | 缓存对象 | 命中能省什么 | 不能据此得出的结论 |
|---|---|---|---|
| FE 统计缓存 | 行数、NDV 等估计信息 | 收集/加载统计开销 | 数据结果已经缓存 |
| SQL/查询缓存 | 满足复用条件的查询结果或中间结果 | 对应计算路径 | 所有参数、版本都可复用 |
| 页缓存 | 存储页读取结果 | 部分页 IO/处理 | 聚合与 Join 不再执行 |
| 文件缓存 | 远端文件的本地缓存范围 | 对象存储远端读取 | FE 元数据一定最新 |

FE SQL 缓存入口 `fe/fe-core/src/main/java/org/apache/doris/qe/cache/SqlCache.java`；存储页入口 `be/src/storage/segment/page_io.cpp`。失效依赖各自身份和生命周期，不能把清一种缓存当成清理全部系统状态。

## 6. 怎样读 Profile 才能回答问题

先固定 query ID、SQL、版本和会话配置，再比较实例之间的扫描行数、输出行数、耗时、等待、内存及 Spill/IO 信息。具体计数器名称随算子和版本变化，以实际 Profile 为准。

高耗时同时伴随低 CPU 与长依赖等待，优先检查上游或背压；扫描大而输出少，检查过滤位置与裁剪；只有一个实例极慢，检查倾斜；Spill 字节高，检查 Build/排序规模与限额。上述是诊断假设，需要计划和计数器共同支持。当前没有真实 Profile，不能给这些假设填上虚构数值。采集入口见[观测清单](../examples/03-observation-kit/README.md)。

## 2026-10-14 运行证据更新

新增[本地 SQL/导入/恢复实验](../examples/07-live-lab-20261014/REPORT.md)与[真实 Profile 解读](../examples/07-live-lab-20261014/PROFILE_ANALYSIS.md)。它们补充初稿中的未运行项；没有执行多副本/Cloud/取消/Spill 故障实验，也不替代历史修复前后的测试。
