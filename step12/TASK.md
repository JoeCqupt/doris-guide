# Step 12：四个聚合节点在做什么？

发布日期：2026-10-09。预计 40–55 分钟，可跨天完成。
目标：解释本次 COUNT(DISTINCT) 的分组键变化，区分聚合中间状态与最终结果，并接触 FE Java 的物理聚合表示。
系统位置：FE 生成物理计划，BE 执行扫描与聚合。联系：Step 2 的局部/全局统计、Step 3 的去重、Step 11 的实际计划。
调整原因：你已能正确写 SQL、预测结果并定位算子；下一步从“认出名称”进到“说明为什么需要它”。本步只查询现有表，不增加数据、不修改源码、不编译。

## 1. 做一次受控对比（10–15 分钟）

连接现有集群，USE doris_learning。保留 Step 11 的分城市查询作为 A；复制成 B，只移除 SELECT 中的 COUNT(DISTINCT user_id)，其他过滤、分组和排序全部不变。

分别执行 A、B 及 EXPLAIN，保存输出。对比：聚合节点数量、每层 group by、Exchange 的分发键。编号可能变化，以本次输出为准。若结构没变化也如实记录，不修改优化器开关来强行制造差异。

填写简表：查询 / 聚合节点及分组键 / Exchange 分发键 / 你观察到的差异。单 BE 也可能出现多个 fragment；不能仅凭 Exchange 推断发生跨机器网络传输。

## 2. 用 6 行有效订单解释分组键变化（15–20 分钟）

回看 Step 11 的实际计划：节点 1、3 按 city,user_id 分组，节点 4、6 按 city 分组。只用日期与 PAID 过滤后的数据，自己写出逻辑上按 (city,user_id) 完成合并后的表：

| city | user_id | 该组订单数 | 该组金额 |
| --- | --- | --- | --- |

再由这张小表计算每个城市的订单数、金额、去重人数，并回答：

- 为什么只按 user_id 分组会丢失本次查询需要的信息？
- 从这张小表再按 city 统计时，为什么订单数不能简单数行，而用户数在本数据中可以？
- 如果在全局合并去重之前直接相加各局部去重人数，会出现什么问题？联系用户 101 回答即可。

这是手工推导逻辑结果，不是 BE 实际序列化 buffer 的格式。计划中的 cardinality 不当作已测量行数；EXPLAIN 也不当作执行耗时报告。无需解释所有内部 partial_* 名称。

## 3. 读两个小型 FE Java 入口（10–20 分钟）

只读以下已核实的源码，不追完整优化器：

1. `/Users/jiangyuan/open/doris/fe/fe-core/src/main/java/org/apache/doris/nereids/trees/plans/AggMode.java`：枚举值与构造方法。根据 productAggregateBuffer、consumeAggregateBuffer，写出四种模式各自消费“输入行还是聚合状态”、产生“状态还是最终结果”。
2. `/Users/jiangyuan/open/doris/fe/fe-core/src/main/java/org/apache/doris/nereids/trees/plans/physical/PhysicalHashAggregate.java`：仅看 `getGroupByExpressions()`、`getOutputExpressions()`、`getAggregateParam()`、`getAggPhase()`、`getAggMode()`。挑出表示“按哪些字段分组”和“消费/产生何种聚合状态”的字段或类型，各用一句话解释。

最后回答：这些 Java 类在描述计划，还是在亲自扫描订单并计算每行？给一个你依据的字段或方法。它们不是 EXPLAIN 文字输出的全部实现，本步不要求建立逐字符映射。

## 交付与验收

RESULT.md 中保存 A/B SQL 及实际输出、计划对比、小表推导、四种模式与两条源码定位、实际用时。长计划可保存为 A-explain.txt、B-explain.txt 并链接。

验收标准：能用真实计划解释两级分组键的目的，保持订单数和用户数语义正确；能区分中间状态与最终值；知道 FE Java 物理计划描述与 BE 执行的边界。不要求所有查询或所有 Doris 版本都出现四个聚合节点。

遇到连接失败按 Step 10 恢复已有服务，保留 `/Users/jiangyuan/doris-guide/be-storage` 与 FE 元数据，不重建订单表或重复运行 seed.sql。

## 2026-10-09 验收后的最小补充

计划对比与手工推导已通过，不重复整个任务。只完成 [验收反馈](REVIEW.md) 末尾三个小问题，预计 5–10 分钟，尤其补齐 AggMode 的消费侧和 FE 描述/BE 执行边界。

最新状态：补交已验收，核心目标通过。无需重复上方补充题，继续 Step 13；消费侧理解通过新实验验证。
