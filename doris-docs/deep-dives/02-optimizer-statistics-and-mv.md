# 专题 2　列身份、统计、分布属性与增量物化视图

[全书导航](../README.md) · [专题导航](README.md)

> 源码基线：`a53b182f810be2b3731c7dfdf6f40ff5a0ad63bd`；补写日期：2026-10-13。以下为源码分析与标明的教学推演，未运行对应功能测试。仓库路径均相对 `/Users/jiangyuan/open/doris`。

## 1. 为什么同名列不能用字符串替换

考虑 `SELECT a.id, b.id FROM t a JOIN t b ON a.id=b.id`。两个 id 的名字相同，但来自两个关系实例。Nereids 的 `SlotReference` 除 name、类型、nullable 外还持有 `ExprId`。绑定与改写必须保留正确的引用关系；把所有名为 id 的表达式替换成一列，会改变 Join 语义。

入口是 `fe/fe-core/src/main/java/org/apache/doris/nereids/trees/expressions/SlotReference.java`。阅读构造方法、`getExprId()`、`equals()`，再看保留原身份的复制方法。Alias 生成的输出与它引用的输入也要分别看待：输出名改变，不代表下游可以直接拿原名称查找输入。

函数绑定还要确定参数类型、重载、返回类型及必要的 Cast。`SUM(INT)` 的输出不能仅根据输入 Java 类型猜测；表达式的数据类型属于 SQL 契约。观察改写时同时记录表达式身份和类型，才能发现“计划看上去相同、输出却发生变化”的问题。

## 2. 子查询与窗口为什么不能随意提前执行

`SubqueryToApply` 把相关性显式化为 Apply；随后 `InApplyToJoin`、`ExistsApplyToJoin`、`ScalarApplyToJoin` 按不同语义转成 Join。它们分别位于 `nereids/rules/analysis/` 与 `nereids/rules/rewrite/` 下。IN 涉及 NULL 的三值逻辑，标量子查询涉及单行结果要求，EXISTS 只关心是否存在。不能统一替换成普通 Inner Join。

例子：左表一行，右表匹配两行。普通 Join 产生两行；EXISTS 仍只决定保留左表一次。再把右表改成含 NULL 的集合，NOT IN 与 NOT EXISTS 也不再能无条件互换。规则的职责包括选择合适的 Join 类型和保留必要检查。

窗口计算保留输入行数。`SUM(v) OVER(PARTITION BY k ORDER BY ts)` 需要分区、顺序和窗口范围；提前过滤掉窗口中的一行可能改变其他行的累计值。`WindowExpression` 保存窗口描述；`RequestPropertyDeriver` 的窗口访问方法推导物理分布/排序需求。这里应区分“表达式能算”与“输入满足算子的前提”。

## 3. 一份统计如何进入优化器

以下路径都在 `fe/fe-core/src/main/java/org/apache/doris/`：

| 阶段 | 方法/对象 | 关键含义 |
|---|---|---|
| 发起收集 | `statistics/analysis/AnalysisManager.buildAndAssignJob()` | 建立 Job、按列建立 Task，区分同步执行和异步提交 |
| 自动入口 | `statistics/analysis/StatisticsAutoCollector.java` | 自动收集也有任务选择与调度，不能认为每次 INSERT 都立即全表分析 |
| 形成并保存列统计 | `statistics/analysis/AnalysisJob.flushBuffer()` | 将 ColStatsData 组成统计表写入语句，内部执行后推进任务状态 |
| 更新收集元信息 | `AnalysisManager.updateTableStats()` | 更新 TableStatsMeta 并写日志，记录的是收集管理状态 |
| 查询缓存 | `statistics/cache/StatisticsCache.getColumnStatistics()` / `doGetColumnStatistics()` | 缓存键含 catalog/db/table/index/column；异步值未完成时可返回 UNKNOWN |
| 缓存加载 | `statistics/cache/ColumnStatisticsCacheLoader.doLoad()` | 读统计表，缺失时可询问表的列统计来源 |

持久统计、收集任务元信息和内存缓存是三个对象。不同任务路径可能先同步缓存或先批量入库，不能凭一个调用顺序推广成所有任务都一样。

诊断“数据变多，计划没变”时，按以下顺序找证据：这张表是否收集过对应列；行数、NDV、NULL 数等是否新鲜；当前 FE 是否拿到缓存结果；估计是否传入目标计划；另一候选是否真的更便宜。刷新数据缓存解决不了缺失的 NDV。

## 4. 代价选择的可计算例子

教学模型：4 个执行节点，事实表过滤后 100 MB，维表 2 MB。若向四个接收节点各发维表，传输量上界近似 8 MB；若双方 Shuffle，近似传输两侧需要重分布的数据，共 102 MB。此模型忽略本地流量、压缩、并发、CPU 与 Hash Table 内存，**不是 Doris 代价公式**。

维表若因为统计过期被估为 2 MB、实际是 2 GB，Broadcast 可能让每个接收节点承担大 Hash Table。由此可以解释统计为何影响内存，而不是只影响“计划好不好看”。源码中的 `RequestPropertyDeriver.visitPhysicalHashJoin()` 先根据合法性、hint 和统计等条件提出分布候选；Cost 与 Memo 再参与选择。没有合法候选时，比较数字没有意义。

Colocate 要求兼容的桶分布和位置关系，相关元信息由 `catalog/ColocateTableIndex.java` 管理；仅两边都有同名 Join Key 不够。Bucket Shuffle 则利用一侧既有桶布局，把另一侧送到对应桶。两者都应在实际 EXPLAIN 中确认，不能从建表字段相同就宣布无网络交换。

倾斜例子：一个 Join Key 占输入 60%。增加桶数仍可能让这一 Key 聚集到一个分区。检查每实例输入行数和耗时的最大值与分布，平均值会掩盖慢尾；过滤、预聚合、改变计划的适用性取决于 SQL 语义。

## 5. MV 刷新与查询改写是两个时刻

第 6 章已解释 `MTMVTask` 刷新任务和 `MTMVRewriteUtil` 的可用分区判断。补充一个时间线：基表更新 → MV 尚未刷新 → 查询到来 → 判断哪些分区可用 → 构造合法替代计划 → 比较代价。任务上次成功，并不能保证当前所有分区仍匹配查询需要的数据。

当前快照还有 IVM 实现。`mtmv/ivm/IvmJoinDeltaHandler.java` 的 Inner Join 增量公式可以写成：

```text
Δ(L ⋈ R) = (ΔL ⋈ R_pre) UNION ALL (L_post ⋈ ΔR)
L_post = L_pre + ΔL
```

展开第二项后，新增左右行之间的交叉项只计一次。若两项都使用 post 快照，会重复计算交叉项。这里的“+”是带符号的多重集增量：插入/更新后为 +1，删除/更新前为 -1。重复行的次数有意义，因此不能随意改成去重 UNION。

聚合增量还要维护组是否存在：SUM 变成 0 不表示组消失，而组计数变成 0 才可能需要删除该组。Outer Join 更复杂，新增匹配可能要撤销原先的 NULL 扩展行；行身份必须稳定。对应入口是 `IvmDeltaRewriteVisitor` 和 `IvmJoinDeltaHandler`，测试目录为 `regression-test/suites/mtmv_p0/ivm`。这是当前源码能力分析，不承诺任何已发布版本都支持这些模式。

## 6. 应怎样验证

最小验证组合是：同名列自连接；带 NULL 的 IN/NOT IN；窗口前后过滤对照；收集统计前后同一 SQL 的 EXPLAIN；MV 刷新前后结果与计划对照。记录结果等价与计划差异是两项不同断言。已有测试可作为写法参考，本次没有执行上述实验。
