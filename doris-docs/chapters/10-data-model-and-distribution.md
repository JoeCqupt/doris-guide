# 第 10 章　数据模型与数据分布

[全书导航](../README.md) · [术语表](../appendices/A-glossary.md)

> 日期：2026-10-12。源码基线：`a53b182f810be2b3731c7dfdf6f40ff5a0ad63bd`。本章是源码阅读版 v1：关键入口与文中明确标出的分支已核对，未运行 Doris SQL、单测或性能实验。图和算例为教学示意；测试文件仅为后续验证入口，不代表已运行或完整覆盖。

## 10.1 先决定相同 Key 再次到来时发生什么

同一笔订单可能被上游重复发送，也可能因为支付状态变化再次出现。在业务数据库里，你可能用主键约束和 UPDATE 处理；在 Doris 中首先要选择表模型及相应写入语义。

| 模型 | 核心含义 | 需要先确认的问题 |
|---|---|---|
| Duplicate Key | 保留明细行 | 重复导入是否允许，查询是否需要完整明细 |
| Aggregate Key | 相同 Key 按值列定义的聚合方式合并 | 是否接受丢失部分原始明细，重放是否重复累计 |
| Unique Key | 按 Key 维护更新后的逻辑记录 | 更新顺序、覆盖规则、部分列语义 |

模型不是只影响建表语法的标签。它决定相同键值在写入、合并、查询中的含义。Duplicate Key 的 Key 不能当作唯一约束；Unique Key 的记录胜出规则也不应简化成“永远按业务时间选最新”，Sequence 等配置会参与相关语义。

例如城市日销售额的 SUM 聚合表，如果把同一批金额再导入一次，可能再次累计；它不会因为源业务订单号相同就自动知道这是重放。数据模型与导入批次去重是不同问题。

## 10.2 四个维度：模型、分区、分桶、排序

模型决定同键数据如何解释；分区把表分成较大的管理和裁剪范围；分桶决定范围内的数据分布；排序键影响数据在局部组织及访问方式。四者关联，但不能互相替代。

订单表可以按日期管理分区，按订单 ID 做 Hash 分桶。这样日期条件有机会排除无关分区，订单数据可以分散到多个分片。但如果只是把日期放入 Key 前缀，没有声明分区，就不能声称发生了日分区裁剪。

排序也不是跨所有 BE 的全局顺序。用户需要有序结果时，仍应使用 ORDER BY；不能因为存储按 Key 组织就依赖无 ORDER BY 查询的返回顺序。

## 10.3 分区、索引、Tablet 与副本

以存算一体普通内表为范围：Table 之下有 Partition，分区包含相关 MaterializedIndex，索引之下组织 Tablet，Tablet 有副本信息。这里的 MaterializedIndex 是元数据/存储组织概念，不等同于“用户创建了一个异步物化视图”。

一个仅有基表索引、3 个分区、每分区 4 桶的教学例子，可以理解为 12 个基表 Tablet；若各有 3 个副本，则有 36 份对应副本。它们不是 36 个不同逻辑分片。实际还需看额外索引、状态和配置，这个算式不能直接用于所有表。

分桶过少可能限制并行和数据分散；过多则增加小分片、元数据和调度成本。合理数量取决于数据量、节点与工作负载，本章不提供脱离场景的固定数字。

## 10.4 写入路由与查询裁剪是两件事

写入侧需要决定每行属于哪个分区和 Tablet。当前 `OlapTabletFinder::find_tablets()` 会查找分区，再根据相关模式决定桶。Hash、随机或其他适用路径的选择不同，不能把所有写入都画成同一个取模公式。

查询侧希望少读不相关数据。分区条件可用于排除范围，分桶键条件在适用情况下有助于缩小 Tablet 范围，排序与索引又进一步影响文件内部读取。某一层无法裁剪，不代表所有层都必须全读。

读源码时应把两个方向画开：一条是“这行应该放哪”，另一条是“这次查询可以不去哪里”。它们使用同一份表设计信息，但不是同一段代码逆向运行。

## 10.5 FE Java 的源码落点

| 文件（相对仓库根目录） | 阅读重点 |
|---|---|
| `fe/fe-core/src/main/java/org/apache/doris/nereids/trees/plans/commands/info/CreateTableInfo.java` | `validate()` 与 Key 模型相关检查 |
| `fe/fe-core/src/main/java/org/apache/doris/catalog/OlapTable.java` | 表级模型、分区与索引组织 |
| `fe/fe-core/src/main/java/org/apache/doris/catalog/Partition.java` | 分区对象、可见版本与下一版本字段 |
| `fe/fe-core/src/main/java/org/apache/doris/catalog/HashDistributionInfo.java` | Hash 分布信息 |
| `fe/fe-core/src/main/java/org/apache/doris/planner/OlapScanNode.java` | 扫描范围和版本相关信息 |
| `be/src/exec/sink/vtablet_finder.cpp` | `find_tablets()` 写入路由 |

这里的入口定位与部分关键分支已核对，不表示完整验证了建表所有约束。使用 Unique Key 和部分更新前应按具体版本确认能力：[Unique Key 文档](https://doris.apache.org/docs/dev/table-design/data-model/unique/)区分了整行与部分列处理；该 dev 页面会变化，不能替代本地基线实现。

## 10.6 如何验证设计确实生效

第一步是 SHOW CREATE TABLE 确认真实定义。接着对比查询的扫描范围和运行信息，不能只凭 SQL 含有日期条件就认定裁剪成功。分布键倾斜还要观察实际数据分布；多个桶数量相同不保证每桶字节数相同。

可从 `fe/fe-core/src/test/java/org/apache/doris/nereids/rules/rewrite/PartitionPrunerTest.java` 阅读分区裁剪测试。一个有用的贡献问题应指出某种边界条件下裁剪遗漏或错误，并保留结果正确性的验证；仅让计划扫描更少分区，若漏了数据，属于错误而不是优化。


---

[上一章：第 9 章](09-aggregation-join-and-runtime-optimization.md) · [全书导航](../README.md) · [下一章：第 11 章](11-tablet-rowset-and-segment.md)

## 源码深读补充（2026-10-13）

- [专题 3　从一列读取到更新、索引与 Schema Change](../deep-dives/03-storage-updates-and-indexes.md)
