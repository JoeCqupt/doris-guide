# 第 1 章　从 CRUD 到 OLAP：先认识要解决的问题

[全书导航](../README.md) · [下一章：系统地图](02-system-and-source-map.md)

> 教学结构修订：2026-10-14。每章先沿一个问题阅读代码，再做实验、观察结果，最后解释对象和分支。历史正文基线为 `a53b182f810be2b3731c7dfdf6f40ff5a0ad63bd`；本次摘录取自当前本地文件，完整文件 SHA-256 与行号保存在[源码摘录清单](../examples/08-chapter-workshops/source-manifest.json)。运行证据来自报告版本 `doris-0.0.0-a53b182f810` 的二进制，不能仅凭版本前缀认定当前工作目录与二进制逐文件相同。

**本章问题：为什么只返回三个城市，却需要处理多笔订单？**

本章验证方式：已归档运行证据 + 源码走查；扩展分支见本章边界。建议先用 20—40 分钟完成主案例，第四部分的扩展阅读可分次完成；这不是新增的每日必交任务。

## 一、源码讲解：先找到决定行为的对象和分支

把 Java 中的 List<Order> → filter → groupingBy 想象成逻辑计算；Doris 还必须把这段计算变成可以调度的物理工作。先看 NereidsPlanner.planWithoutLock：analyze 解决对象身份，rewrite 改写等价表达式，optimize 选择物理实现。这个方法交付计划，不交付城市销售额。

### 先读这段真实代码

文件：`fe/fe-core/src/main/java/org/apache/doris/nereids/NereidsPlanner.java`，当前文件第 282—305 行。下面是连续原文摘录，局部片段省略了方法的其他部分；不要把片段当完整实现。

```java
    private Plan planWithoutLock(
            LogicalPlan plan, PhysicalProperties requireProperties, ExplainLevel explainLevel,
            boolean showPlanProcess) {
        // analyze this query, resolve column, table and function
        analyze(showAnalyzeProcess(explainLevel, showPlanProcess));
        if (explainLevel == ExplainLevel.ANALYZED_PLAN || explainLevel == ExplainLevel.ALL_PLAN) {
            analyzedPlan = cascadesContext.getRewritePlan();
            if (explainLevel == ExplainLevel.ANALYZED_PLAN) {
                return analyzedPlan;
            }
        }

        // rule-based optimize
        rewrite(showRewriteProcess(explainLevel, showPlanProcess));
        // try to pre mv rewrite
        preMaterializedViewRewrite();
        if (explainLevel == ExplainLevel.REWRITTEN_PLAN || explainLevel == ExplainLevel.ALL_PLAN) {
            rewrittenPlan = cascadesContext.getRewritePlan();
            if (explainLevel == ExplainLevel.REWRITTEN_PLAN) {
                return rewrittenPlan;
            }
        }

        optimize(showPlanProcess);
```

### 这几行应该怎样读

`analyze(...)` 之后才能按绑定后的列和函数讨论改写；`rewrite(...)` 维护语义等价；`optimize(...)` 才进入物理选择。中途按 ExplainLevel 返回的是某阶段的计划对象，说明 EXPLAIN 可以观察规划产物，并不等同执行数据查询。

### 同一张订单表，两种工作

假设你负责电商订单服务。用户打开订单详情时，服务根据 `order_id` 取出一条记录；支付回调到来时，需要修改订单状态，并处理与库存、支付流水之间的业务关系。你关心的是某个业务对象能否被正确、及时地更新，以及多个操作的一致性。

现在运营同事提出另一个问题：“昨天每个城市有多少笔已支付订单、多少销售额、多少购买用户？”

```sql
SELECT city,
       COUNT(*) AS order_count,
       SUM(amount) AS revenue,
       COUNT(DISTINCT user_id) AS buyers
FROM orders
WHERE order_date = '2026-10-01' AND status = 'PAID'
GROUP BY city;
```

这段 SQL 仍然很像你熟悉的业务 SQL，但工作量不同。它通常需要读取许多订单，逐行判断条件，再按城市维护聚合状态。最终可能只返回几十行，返回行数无法代表执行成本。

**OLAP 描述的是这一类面向分析的工作负载。** 重点从单个业务对象转向一批数据的分布、总量、趋势和关联。OLTP 与 OLAP 是理解需求的分类；不能只看 SQL 是否出现 `GROUP BY`，就断言某个数据库适合或不适合。

| 观察角度 | 订单业务操作 | 订单分析 |
|---|---|---|
| 常见入口 | 一个订单 ID、一笔支付事件 | 一段日期、一个人群、一组维度 |
| 常见数据访问 | 少量记录的查改 | 大量记录的筛选、分组、关联 |
| 主要结果 | 业务状态变化或对象详情 | 汇总指标、明细分析、趋势 |
| 需要追问 | 并发修改与事务语义 | 扫描量、计算量、新鲜度和查询并发 |

Doris 的分析能力应放在这些需求中理解。选型时仍要核实实际事务语义、查询方式、更新模式和运维条件；“支持 SQL”不意味着不同数据库拥有相同的事务和执行模型。

### 第一次看源码，只确认三件事

本章不要求跟踪完整调用链。下面三个入口用于把术语落回具体代码，路径相对源码根目录：

| 入口 | 本次核对到的事实 | 先读到什么程度 |
|---|---|---|
| `fe/fe-core/src/main/java/org/apache/doris/nereids/NereidsPlanner.java`：`planWithoutLock()` | 包含 `analyze()`、`rewrite()`、`optimize()` 等规划步骤 | 知道 SQL 计划有多个阶段，不在本章展开规则 |
| `fe/fe-core/src/main/java/org/apache/doris/qe/Coordinator.java`：`exec()`、`getNext()` | 分别是执行协调和获取结果的入口；`exec()` 还涉及资源队列 | 知道计划生成、实际执行、取回结果是不同动作 |
| `be/src/exec/pipeline/pipeline_task.cpp`：`PipelineTask::prepare()`、`execute()` | 存在 BE 任务准备和推进执行的方法 | 认识跨过 RPC 后还有节点内任务生命周期 |

这些方法名不构成一条直接调用链，中间还有计划翻译、调度、RPC 接收等环节。概念关系在下一章展开。

## 二、动手实验：先预测，再核对

默认使用已保存的实验材料或只读源码，不需要启动服务。运行环境已停止；若选择重新执行 SQL，先按[实验复现说明](../examples/07-live-lab-20261014/REPRODUCE.md)确认服务、版本与数据状态。初始化、导入和更新脚本不可在现有表上盲目重放。

1. 先读 03-orders-assertions.sql，遮住输出，手算北京的订单数和购买人数。把 COUNT(*) 与 COUNT(DISTINCT user_id) 的状态分别写出来。
2. 打开对应输出，再读 02-orders-queries.out.txt 的扫描、聚合、Exchange 节点；将每个节点归到“读数据 / 算状态 / 搬数据”。
3. 在源码中定位 analyze、rewrite、optimize 三次调用，说明哪个阶段应当知道列类型，哪个阶段决定物理实现。

```sql
SELECT city, COUNT(*) AS orders, SUM(amount) AS revenue,
       COUNT(DISTINCT user_id) AS buyers
FROM doris_book.orders_intro_v1
WHERE order_date='2026-10-01' AND status='PAID'
GROUP BY city ORDER BY city;
```

本章实验材料：[03-orders-assertions.sql](../examples/07-live-lab-20261014/03-orders-assertions.sql) · [03-orders-assertions.out.txt](../examples/07-live-lab-20261014/03-orders-assertions.out.txt) · [02-orders-queries.out.txt](../examples/07-live-lab-20261014/02-orders-queries.out.txt)。

## 三、观察结果：先陈述事实，再划清证据范围

实测：全表 8 行；当天已支付 6 行、金额 580.00、全局用户 4 人。按城市输出上海 2/180.00/2，北京 3/200.00/2，杭州 1/200.00/1。城市人数相加是 5，不能替代全局去重人数 4。

**本章边界：** 八行数据验证语义，不验证 Doris 比业务数据库快，也不验证跨机器加速。

## 四、回到源码解释：把现象还原成执行过程

输入是订单行，输出是分组状态的最终值，因此返回三行不能用于估计扫描成本。规划器只能描述怎样计算，实际值要由 BE 算子产生。跨城市重复的用户 101 说明：一个看似普通的 COUNT，在分布式执行时必须明确合并的是计数还是去重状态。

### 用自己的话走完这条链

合上结果后，按“输入 → 关键对象/状态 → 分支条件 → 可观察结果”的顺序回答本章问题：**为什么只返回三个城市，却需要处理多笔订单？** 再指出一项尚不能从现有实验得出的结论。能把每个箭头落到本章的方法或证据，比记住术语更接近读懂源码。

### 分析查询的时间花在哪里

先把上面的查询拆成五件事：找到可能符合日期条件的数据；读取必要的列；过滤未支付订单；更新每个城市的计数、金额和去重状态；汇总并返回结果。

假设一张表有一亿行、每行有 50 个字段，而当前查询只需要其中 5 个字段。数据库若能少读无关列，就有机会减少 I/O 和解码工作；若能根据日期、统计信息或索引跳过部分数据，还能进一步减少实际处理量。这解释了列存、裁剪和索引在分析系统里的价值。

这里的“少读 45 列”不等于“必然快十倍”。列大小、压缩率、缓存、谓词选择性、索引访问与 CPU 成本都可能改变结果。我们先建立因果关系，具体效果要靠执行数据验证。

聚合也有内存成本。`SUM(amount)` 可以为每个分组维护一个累计值；精确去重则需要保留足够的信息，区分此前见过和没见过的用户。城市数量很少，并不意味着去重状态也很小：一个城市可能包含数千万用户。具体状态表示会随类型和执行计划变化，第 9 章再展开。

一个用于分析瓶颈的模型是：

```text
响应时间受以下工作及其重叠程度影响：
排队 → 规划 → 扫描/解码 → 算子计算 ↔ 网络交换 → 结果传输
```

这不是可直接相加的精确公式。不同节点、不同流水线上的工作会重叠；一个慢节点或一次等待可能决定整体完成时间。它的用处是提醒我们：不要只用“扫描了多少行”解释所有慢查询。

### MPP：把一次查询分给多台机器

你开发 RPC 系统时，可能已经把一次业务请求拆成多个远程调用。MPP 也需要协调多台机器，但它还必须保持 SQL 的整体语义，并决定数据按什么规则移动。

设订单分布在两个 BE 上。每个 BE 可以先统计本地城市销售额，再把同一城市的局部结果汇合：

```mermaid
flowchart LR
    Q[城市销售额查询] --> F[FE 规划与协调]
    F -.下发工作.-> A[BE A 扫描并局部求和]
    F -.下发工作.-> B[BE B 扫描并局部求和]
    A --> M[按城市汇合局部结果]
    B --> M
    M --> R[最终城市销售额]
```

图中“汇合”也是执行工作，通常由计划安排在 BE 上；它不暗示 FE 把全部订单读入 Java 内存。FE 负责规划和协调，BE 执行分布式计划，是 Doris 查询架构的基本分工。[官方 MPP 说明](https://doris.apache.org/docs/4.x/key-features/mpp/)提供了概念入口，具体代码从第 2 章的 `NereidsPlanner` 和 `Coordinator` 开始。

金额求和可以合并局部和，但局部去重人数不能直接相加。若 A 看见用户 `{101,102}`，B 看见 `{101,103}`，两边人数都是 2，全局却只有 3 人。分布式执行必须传递可以继续合并的状态，或通过数据重分布确保正确处理相同用户。实际方案由计划决定。

多机器带来并行资源，也带来成本。如果大量数据都属于北京，按城市重新分发可能让某个接收方承担更多工作，这就是一种数据倾斜。增加 BE 不一定能缩短最忙的那部分工作；小查询也可能因为协调、调度和网络开销无法从更多节点获益。

因此，MPP 不是“每个查询一定使用全部节点”，而是数据库能够把适合并行的工作分布到多个节点。计划可能只访问一部分数据和节点。

### MPP、Pipeline 和向量化分别负责什么

这三个词常在同一篇介绍中出现，可以用工作粒度区分：

| 概念 | 主要解决的问题 | 阅读时观察什么 |
|---|---|---|
| MPP | 多节点如何共同完成 SQL | Fragment、执行实例、Exchange、数据分布 |
| Pipeline | 一个执行节点内部如何推进算子链并调度工作 | Task、依赖、阻塞和唤醒 |
| 向量化 | 算子如何成批处理列数据 | Block、Column、批量表达式求值 |

向量化不意味着每个操作都直接使用 SIMD 指令；Pipeline 也不意味着一个任务永远占用一条线程。第 8 章会用执行代码讨论这些边界。当前只需认识到：三者分别围绕跨节点协作、节点内调度和批量计算展开。

### 数据新鲜度、吞吐和并发也属于设计问题

运营可能从“每天生成一次报表”改成“支付后一秒内看见销售额变化”。需求改变的不只是导入频率。频繁小批写入会改变任务、事务、文件和后台维护的压力；多张看板同时刷新还会改变查询并发。

分析系统因此需要同时处理查询与写入，管理有限的 CPU、内存、网络和存储资源。查询正确并不代表资源使用合理，数据进入存储也不意味着已满足可见条件。后面的事务、Compaction 和资源治理章节，都来自这些实际约束。

外部 Catalog 则回答另一类问题：数据已经在数据湖或其他数据库里，能否通过 Doris 访问？这会引入外部元数据、文件格式、类型映射和远端系统的能力边界。它与“把数据先导入 Doris 内表”是两条不同路径。

| 需求 | 对应能力 | 本书位置 |
|---|---|---|
| 城市销售额、去重人数、多表分析 | 优化器、MPP、算子执行 | 第 4—9 章 |
| 减少扫描、保留明细或更新记录 | 数据模型、存储与索引 | 第 10—13 章 |
| 持续接收订单变化并及时可查 | 导入、事务、版本可见性 | 第 14—17 章 |
| 集群故障时恢复、多人共享资源 | 元数据、节点管理、资源治理 | 第 18—21 章 |
| 查询外部数据或接入数据管道 | Catalog、Connector、集成协议 | 第 22—24 章 |
| 计算与持久存储独立组织 | 存算分离 | 第 25—26 章 |

### 如何把理解连接到贡献

你不需要先实现一个聚合算子，才能开始为 Doris 做贡献。Java 经验可以先用于解释一个命令的输入、校验、状态查询和错误行为。系统全景的价值是让你知道改动会影响哪一段链路，以及该找哪类测试。

可以用一个小问题检验本章理解：“查询只返回三行，为什么仍可能扫描很多数据？”如果你能从过滤、聚合和数据分布解释它，就已经有了继续读源码的抓手。这里不设置提交作业要求。

本章已有订单 SQL 实测，未做性能基准。与执行机制对应的现有测试可从 `fe/fe-core/src/test/java/org/apache/doris/nereids/NereidsPlannerTest.java` 开始查看；本次只确认其存在，没有运行测试。下一章把这些入口放回整套系统。

### 延伸源码专题

- [专题 1　从真实 EXPLAIN 走到 FE/BE 协议与取消](../deep-dives/01-query-rpc-and-cancellation.md)

---

[全书导航](../README.md) · [下一章：系统地图](02-system-and-source-map.md)
