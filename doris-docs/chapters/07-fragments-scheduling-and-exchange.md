# 第 7 章　MPP：Fragment、调度和 Exchange

[全书导航](../README.md) · [术语表](../appendices/A-glossary.md)

> 教学结构修订：2026-10-14。每章先沿一个问题阅读代码，再做实验、观察结果，最后解释对象和分支。历史正文基线为 `a53b182f810be2b3731c7dfdf6f40ff5a0ad63bd`；本次摘录取自当前本地文件，完整文件 SHA-256 与行号保存在[源码摘录清单](../examples/08-chapter-workshops/source-manifest.json)。运行证据来自报告版本 `doris-0.0.0-a53b182f810` 的二进制，不能仅凭版本前缀认定当前工作目录与二进制逐文件相同。

**本章问题：为什么一台 BE 上也能出现 Exchange 和多个执行实例？**

本章验证方式：已归档运行证据 + 源码走查；扩展分支见本章边界。建议先用 20—40 分钟完成主案例，第四部分的扩展阅读可分次完成；这不是新增的每日必交任务。

## 一、源码讲解：先找到决定行为的对象和分支

从 PhysicalPlanTranslator.visitPhysicalDistribute 切入：物理分布要求被翻译成 ExchangeNode。它先表达上下游的数据组织边界，实例调度再决定这些工作放在哪个进程。

### 先读这段真实代码

文件：`fe/fe-core/src/main/java/org/apache/doris/nereids/glue/translator/PhysicalPlanTranslator.java`，当前文件第 355—369 行。下面是连续原文摘录，局部片段省略了方法的其他部分；不要把片段当完整实现。

```java
        // all PhysicalDistribute translate to ExchangeNode. upstream as input.
        ExchangeNode exchangeNode = new ExchangeNode(context.nextPlanNodeId(), upstreamFragment.getPlanRoot());
        updateLegacyPlanIdToPhysicalPlan(exchangeNode, distribute);
        List<ExprId> validOutputIds = distribute.getOutputExprIds();
        if (upstream instanceof PhysicalHashAggregate) {
            // we must add group by keys to output list,
            // otherwise we could not process aggregate's output without group by keys
            List<ExprId> keys = ((PhysicalHashAggregate<?>) upstream).getGroupByExpressions().stream()
                    .filter(SlotReference.class::isInstance)
                    .map(SlotReference.class::cast)
                    .map(SlotReference::getExprId)
                    .collect(Collectors.toList());
            keys.addAll(validOutputIds);
            validOutputIds = keys;
        }
```

### 这几行应该怎样读

`new ExchangeNode(..., upstreamFragment.getPlanRoot())` 保留上游作为输入；`validOutputIds` 描述下游可见列的身份。聚合上游时还补充分组键，说明交换边界不只是节点摆放，也要保留后续计算需要的列。

### 物理计划还不是机器列表

优化器选择了 Hash Aggregate，并指定某些数据分布要求，并不等于它已经给每一行指定了目标 BE。分布式执行还需要把计划切成可安排的部分、确定扫描范围和运行实例，并连接数据通道。

因此应区分：计划结构说明做什么，分布属性说明数据如何组织，实例安排说明哪些节点执行，RPC 参数把这些安排传给 BE。它们有关联，却不是同一个对象。

### Fragment 与实例

Fragment 是分布式计划片段，执行实例是这个片段在某次运行中的具体工作单元。相同片段可以有多个实例；一个 BE 也可以承担多个片段或实例。

对于城市销售额，可用下面的概念图理解：

```mermaid
flowchart LR
    A[实例 A：扫描与局部聚合] -->|中间状态| X[Exchange]
    B[实例 B：扫描与局部聚合] -->|中间状态| X
    X --> C[后续实例：合并与输出]
```

它不是八行示例的真实计划。实际可能出现更多阶段，也可能利用分布裁剪或小数据优化减少工作。Fragment 数、实例数、BE 数、线程数应分别记录，不能互相代替。

### 翻译器如何把分布需求落成交换边界

`PhysicalPlanTranslator.visitPhysicalDistribute()` 是一个直接的源码窗口。当前方法先翻译子节点，取得目标分布，构造 `ExchangeNode`，再把分布转换成 `DataPartition` 等执行表示。

这说明 Exchange 不是随便插入的“网络加速器”，而是为了让上下游数据满足计划要求。Hash Aggregate 等节点的输出列和分组键也会影响交换参数，遗漏这些信息可能破坏后续计算。

| 分布概念 | 数据移动的含义 |
|---|---|
| Gather | 把相关结果集中到后续处理位置 |
| Hash Shuffle | 相同键按约定规则送到相应接收者 |
| Broadcast | 把一侧输入复制给多个接收者 |

这些是解释概念，不要求一个术语在每一层都使用相同枚举名。阅读 FE 属性、执行节点和 BE 通道时，应查转换代码，不凭名字相似直接连线。

## 二、动手实验：先预测，再核对

默认使用已保存的实验材料或只读源码，不需要启动服务。运行环境已停止；若选择重新执行 SQL，先按[实验复现说明](../examples/07-live-lab-20261014/REPRODUCE.md)确认服务、版本与数据状态。初始化、导入和更新脚本不可在现有表上盲目重放。

1. 打开 30-scale-profile.out.txt，在聚合计划中从 OLAP_SCAN 向结果节点逆向读，给 Exchange 两侧标注输入与输出。
2. 打开聚合 Profile，搜索 LOCAL_EXCHANGE、instance_num、Fragment RPC；将数值分别标为“实例”“RPC”，不要标成机器数。
3. 回到创建 ExchangeNode 的代码，跟踪 upstreamFragment 和 distribute.getDistributionSpec，解释计划边界如何携带分布需求。

本章实验材料：[30-scale-profile.out.txt](../examples/07-live-lab-20261014/30-scale-profile.out.txt) · [PROFILE_ANALYSIS.md](../examples/07-live-lab-20261014/PROFILE_ANALYSIS.md)。

## 三、观察结果：先陈述事实，再划清证据范围

本次聚合 Profile 有本地 Hash Shuffle，相关 instance_num 为 6，Fragment RPC Count 为 2；环境中只有 1 台 BE。最终返回 5 行。

**本章边界：** 没有两台 BE 的网络流量、倾斜或故障实验。

## 四、回到源码解释：把现象还原成执行过程

实例并发与节点并行是两层。按 k 重分布是为了让相同键进入合适的聚合位置；即使所有任务同机，也可能经过本地交换。不能从 EXCHANGE 名字直接得出跨网卡传输了多少字节。

### 用自己的话走完这条链

合上结果后，按“输入 → 关键对象/状态 → 分支条件 → 可观察结果”的顺序回答本章问题：**为什么一台 BE 上也能出现 Exchange 和多个执行实例？** 再指出一项尚不能从现有实验得出的结论。能把每个箭头落到本章的方法或证据，比记住术语更接近读懂源码。

### 调度需要哪些信息

扫描侧需要知道读取哪些分区、Tablet、版本及可选副本；执行侧需要知道哪些 BE 可用、运行实例和发送/接收关系。Coordinator 汇合这些信息并组织执行。

当前 `Coordinator` 中可以找到 `prepare()`、`exec()` 及远程片段提交代码。多片段路径还存在 prepare/start 分阶段安排，其目的之一是让接收方具备接收条件，再推进发送方。具体启用条件要看当前代码，不能把它推广为每条 RPC 都必须两阶段。

分片副本提供容错和选择余地，并不意味着把每个副本上的同一份订单都扫描后相加。读哪个副本必须满足版本和可用性条件，读副本选择也不是对业务数据再做一次去重。

### Exchange 同时是数据与等待关系

发送端产生 Block，接收端消费 Block。若发送比消费快，队列会增长；因此需要缓冲限制和背压，让上游等待，而不是无限把数据塞进内存。

此外，接收者要知道还有哪些发送者可能继续产生数据。一个发送者结束不代表整个 Exchange 结束。错误、取消和正常结束还需要释放等待中的任务，否则数据计算可能结束了，查询却一直无法完成。

网络时间也可能是倾斜或下游慢的结果。看到 Exchange 等待高，不能立刻判定网卡带宽不足；应比较发送量、接收速率、实例差异和上游/下游等待。第 8 章将从任务调度解释这些等待如何落到 BE。

### 源码与观察入口

| 文件或目录（相对仓库根目录） | 阅读位置 |
|---|---|
| `fe/fe-core/src/main/java/org/apache/doris/nereids/glue/translator/PhysicalPlanTranslator.java` | `visitPhysicalDistribute()`、聚合与连接翻译 |
| `fe/fe-core/src/main/java/org/apache/doris/qe/Coordinator.java` | `prepare()`、`exec()`、远程提交路径 |
| `gensrc/proto/internal_service.proto` | 执行、取消、取结果、数据传输接口 |
| `be/src/service/internal_service.cpp` | BE RPC 接收入口 |
| `be/src/exec/exchange/` | 数据通道、队列和接收相关实现 |

验证应把一份 EXPLAIN 的 Fragment/Exchange 与同次 Profile 的实例对应起来，再看扫描范围和数据量。计划文本是结构证据，Profile 才描述某次运行；本章没有生成二者的实测样本。已有 BE 执行测试可从 `be/test/exec/` 查找具体模块，不把单个 Pipeline 测试等同于跨节点 RPC 验证。

对于 Java 贡献者，FE 的分布翻译和调度仍是可进入的方向；但改变分布属性时，要沿 RPC 一直检查到 BE 的输入假设，不能只让 Java 类型检查通过。

### 延伸源码专题

- [专题 1　从真实 EXPLAIN 走到 FE/BE 协议与取消](../deep-dives/01-query-rpc-and-cancellation.md)
- [专题 2　列身份、统计、分布属性与增量物化视图](../deep-dives/02-optimizer-statistics-and-mv.md)
- [专题 6　算子内存、背压、Spill 与缓存分层](../deep-dives/06-memory-operators-and-caches.md)

---

[全书导航](../README.md) · [术语表](../appendices/A-glossary.md)
