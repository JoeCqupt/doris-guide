# 第 7 章　MPP：Fragment、调度和 Exchange

[全书导航](../README.md) · [术语表](../appendices/A-glossary.md)

> 日期：2026-10-12。源码基线：`a53b182f810be2b3731c7dfdf6f40ff5a0ad63bd`。本章是源码阅读版 v1：关键入口与文中明确标出的分支已核对，未运行 Doris SQL、单测或性能实验。图和算例为教学示意；测试文件仅为后续验证入口，不代表已运行或完整覆盖。

## 7.1 物理计划还不是机器列表

优化器选择了 Hash Aggregate，并指定某些数据分布要求，并不等于它已经给每一行指定了目标 BE。分布式执行还需要把计划切成可安排的部分、确定扫描范围和运行实例，并连接数据通道。

因此应区分：计划结构说明做什么，分布属性说明数据如何组织，实例安排说明哪些节点执行，RPC 参数把这些安排传给 BE。它们有关联，却不是同一个对象。

## 7.2 Fragment 与实例

Fragment 是分布式计划片段，执行实例是这个片段在某次运行中的具体工作单元。相同片段可以有多个实例；一个 BE 也可以承担多个片段或实例。

对于城市销售额，可用下面的概念图理解：

```mermaid
flowchart LR
    A[实例 A：扫描与局部聚合] -->|中间状态| X[Exchange]
    B[实例 B：扫描与局部聚合] -->|中间状态| X
    X --> C[后续实例：合并与输出]
```

它不是八行示例的真实计划。实际可能出现更多阶段，也可能利用分布裁剪或小数据优化减少工作。Fragment 数、实例数、BE 数、线程数应分别记录，不能互相代替。

## 7.3 翻译器如何把分布需求落成交换边界

`PhysicalPlanTranslator.visitPhysicalDistribute()` 是一个直接的源码窗口。当前方法先翻译子节点，取得目标分布，构造 `ExchangeNode`，再把分布转换成 `DataPartition` 等执行表示。

这说明 Exchange 不是随便插入的“网络加速器”，而是为了让上下游数据满足计划要求。Hash Aggregate 等节点的输出列和分组键也会影响交换参数，遗漏这些信息可能破坏后续计算。

| 分布概念 | 数据移动的含义 |
|---|---|
| Gather | 把相关结果集中到后续处理位置 |
| Hash Shuffle | 相同键按约定规则送到相应接收者 |
| Broadcast | 把一侧输入复制给多个接收者 |

这些是解释概念，不要求一个术语在每一层都使用相同枚举名。阅读 FE 属性、执行节点和 BE 通道时，应查转换代码，不凭名字相似直接连线。

## 7.4 调度需要哪些信息

扫描侧需要知道读取哪些分区、Tablet、版本及可选副本；执行侧需要知道哪些 BE 可用、运行实例和发送/接收关系。Coordinator 汇合这些信息并组织执行。

当前 `Coordinator` 中可以找到 `prepare()`、`exec()` 及远程片段提交代码。多片段路径还存在 prepare/start 分阶段安排，其目的之一是让接收方具备接收条件，再推进发送方。具体启用条件要看当前代码，不能把它推广为每条 RPC 都必须两阶段。

分片副本提供容错和选择余地，并不意味着把每个副本上的同一份订单都扫描后相加。读哪个副本必须满足版本和可用性条件，读副本选择也不是对业务数据再做一次去重。

## 7.5 Exchange 同时是数据与等待关系

发送端产生 Block，接收端消费 Block。若发送比消费快，队列会增长；因此需要缓冲限制和背压，让上游等待，而不是无限把数据塞进内存。

此外，接收者要知道还有哪些发送者可能继续产生数据。一个发送者结束不代表整个 Exchange 结束。错误、取消和正常结束还需要释放等待中的任务，否则数据计算可能结束了，查询却一直无法完成。

网络时间也可能是倾斜或下游慢的结果。看到 Exchange 等待高，不能立刻判定网卡带宽不足；应比较发送量、接收速率、实例差异和上游/下游等待。第 8 章将从任务调度解释这些等待如何落到 BE。

## 7.6 源码与观察入口

| 文件或目录（相对仓库根目录） | 阅读位置 |
|---|---|
| `fe/fe-core/src/main/java/org/apache/doris/nereids/glue/translator/PhysicalPlanTranslator.java` | `visitPhysicalDistribute()`、聚合与连接翻译 |
| `fe/fe-core/src/main/java/org/apache/doris/qe/Coordinator.java` | `prepare()`、`exec()`、远程提交路径 |
| `gensrc/proto/internal_service.proto` | 执行、取消、取结果、数据传输接口 |
| `be/src/service/internal_service.cpp` | BE RPC 接收入口 |
| `be/src/exec/exchange/` | 数据通道、队列和接收相关实现 |

验证应把一份 EXPLAIN 的 Fragment/Exchange 与同次 Profile 的实例对应起来，再看扫描范围和数据量。计划文本是结构证据，Profile 才描述某次运行；本章没有生成二者的实测样本。已有 BE 执行测试可从 `be/test/exec/` 查找具体模块，不把单个 Pipeline 测试等同于跨节点 RPC 验证。

对于 Java 贡献者，FE 的分布翻译和调度仍是可进入的方向；但改变分布属性时，要沿 RPC 一直检查到 BE 的输入假设，不能只让 Java 类型检查通过。


---

[上一章：第 6 章](06-memo-statistics-and-cost.md) · [全书导航](../README.md) · [下一章：第 8 章](08-pipeline-and-vectorized-execution.md)

## 源码深读补充（2026-10-13）

- [专题 1　从真实 EXPLAIN 走到 FE/BE 协议与取消](../deep-dives/01-query-rpc-and-cancellation.md)
- [专题 2　列身份、统计、分布属性与增量物化视图](../deep-dives/02-optimizer-statistics-and-mv.md)
- [专题 6　算子内存、背压、Spill 与缓存分层](../deep-dives/06-memory-operators-and-caches.md)
