# 第 10 章　数据模型与数据分布

[全书导航](../README.md) · [术语表](../appendices/A-glossary.md)

> 教学结构修订：2026-10-14。每章先沿一个问题阅读代码，再做实验、观察结果，最后解释对象和分支。历史正文基线为 `a53b182f810be2b3731c7dfdf6f40ff5a0ad63bd`；本次摘录取自当前本地文件，完整文件 SHA-256 与行号保存在[源码摘录清单](../examples/08-chapter-workshops/source-manifest.json)。运行证据来自报告版本 `doris-0.0.0-a53b182f810` 的二进制，不能仅凭版本前缀认定当前工作目录与二进制逐文件相同。

**本章问题：相同 Key 的更新和写入哪个分区，是同一个决定吗？**

本章验证方式：已归档运行证据 + 源码走查；扩展分支见本章边界。建议先用 20—40 分钟完成主案例，第四部分的扩展阅读可分次完成；这不是新增的每日必交任务。

## 一、源码讲解：先找到决定行为的对象和分支

先把表模型和路由拆开。Unique Key/Sequence 决定同一业务键的竞争语义；OlapTabletFinder.find_tablets 先为每行找分区，再进入分桶等逻辑。分区是日期范围，分桶是分发规则，二者都不等于“自动去重”。

### 先读这段真实代码

文件：`be/src/exec/sink/vtablet_finder.cpp`，当前文件第 37—54 行。下面是连续原文摘录，局部片段省略了方法的其他部分；不要把片段当完整实现。

```cpp
Status OlapTabletFinder::find_tablets(RuntimeState* state, Block* block, int rows,
                                      std::vector<VOlapTablePartition*>& partitions,
                                      std::vector<uint32_t>& tablet_index, std::vector<bool>& skip,
                                      std::vector<uint32_t>* miss_rows) {
    for (int index = 0; index < rows; index++) {
        _vpartition->find_partition(block, index, partitions[index]);
    }

    std::vector<uint32_t> qualified_rows;
    qualified_rows.reserve(rows);

    for (int row_index = 0; row_index < rows; row_index++) {
        if (partitions[row_index] == nullptr) [[unlikely]] {
            if (miss_rows != nullptr) {          // auto partition table
                miss_rows->push_back(row_index); // already reserve memory outside
                skip[row_index] = true;
                continue;
            }
```

### 这几行应该怎样读

第一个循环为每行执行 `find_partition`，把结果写入 partitions；第二个循环处理未找到分区的行。`miss_rows` 存在时的自动分区分支会记录行号并跳过当前处理，不能从这段片段推出所有缺分区数据都会静默丢弃。

### 先决定相同 Key 再次到来时发生什么

同一笔订单可能被上游重复发送，也可能因为支付状态变化再次出现。在业务数据库里，你可能用主键约束和 UPDATE 处理；在 Doris 中首先要选择表模型及相应写入语义。

| 模型 | 核心含义 | 需要先确认的问题 |
|---|---|---|
| Duplicate Key | 保留明细行 | 重复导入是否允许，查询是否需要完整明细 |
| Aggregate Key | 相同 Key 按值列定义的聚合方式合并 | 是否接受丢失部分原始明细，重放是否重复累计 |
| Unique Key | 按 Key 维护更新后的逻辑记录 | 更新顺序、覆盖规则、部分列语义 |

模型不是只影响建表语法的标签。它决定相同键值在写入、合并、查询中的含义。Duplicate Key 的 Key 不能当作唯一约束；Unique Key 的记录胜出规则也不应简化成“永远按业务时间选最新”，Sequence 等配置会参与相关语义。

例如城市日销售额的 SUM 聚合表，如果把同一批金额再导入一次，可能再次累计；它不会因为源业务订单号相同就自动知道这是重放。数据模型与导入批次去重是不同问题。

### 四个维度：模型、分区、分桶、排序

模型决定同键数据如何解释；分区把表分成较大的管理和裁剪范围；分桶决定范围内的数据分布；排序键影响数据在局部组织及访问方式。四者关联，但不能互相替代。

订单表可以按日期管理分区，按订单 ID 做 Hash 分桶。这样日期条件有机会排除无关分区，订单数据可以分散到多个分片。但如果只是把日期放入 Key 前缀，没有声明分区，就不能声称发生了日分区裁剪。

排序也不是跨所有 BE 的全局顺序。用户需要有序结果时，仍应使用 ORDER BY；不能因为存储按 Key 组织就依赖无 ORDER BY 查询的返回顺序。

## 二、动手实验：先预测，再核对

默认使用已保存的实验材料或只读源码，不需要启动服务。运行环境已停止；若选择重新执行 SQL，先按[实验复现说明](../examples/07-live-lab-20261014/REPRODUCE.md)确认服务、版本与数据状态。初始化、导入和更新脚本不可在现有表上盲目重放。

1. 比较 09-model-setup.sql 与 26-partition-table.sql，分别标出 UNIQUE KEY、Sequence、PARTITION、DISTRIBUTED BY 四类配置。
2. 读 10-sequence-assert.out.txt：为什么后来到达的 seq=90 没覆盖 seq=100？再读双分区输出，按日期放置两行。
3. 沿 find_tablets 的 find_partition 调用看一行如何找到目标分区；把唯一键冲突处理留在存储语义链，不在路由循环里寻找所有更新规则。

本章实验材料：[09-model-setup.sql](../examples/07-live-lab-20261014/09-model-setup.sql) · [10-sequence-assert.out.txt](../examples/07-live-lab-20261014/10-sequence-assert.out.txt) · [26-partition-table.sql](../examples/07-live-lab-20261014/26-partition-table.sql) · [26-partition-table.out.txt](../examples/07-live-lab-20261014/26-partition-table.out.txt)。

## 三、观察结果：先陈述事实，再划清证据范围

Sequence 案例保留 id=7/name=A/score=10/seq=100；两个日期分区分别得到一行，金额 10 与 20，两个 VisibleVersion 都由 1 到 2。

**本章边界：** 归档展示中间状态；当前 unique_updates 已经经过第 13 章删除/重插，不能再期待查询到 A。

## 四、回到源码解释：把现象还原成执行过程

同 Key 的“谁更新”由模型和 Sequence 决定，不是网络到达顺序天然正确。find_partition 只回答本行属于哪个分区；后续路由选择 Tablet。版本在两个分区分别推进，不能把两个“2”当一个全库时间戳。

### 用自己的话走完这条链

合上结果后，按“输入 → 关键对象/状态 → 分支条件 → 可观察结果”的顺序回答本章问题：**相同 Key 的更新和写入哪个分区，是同一个决定吗？** 再指出一项尚不能从现有实验得出的结论。能把每个箭头落到本章的方法或证据，比记住术语更接近读懂源码。

### 分区、索引、Tablet 与副本

以存算一体普通内表为范围：Table 之下有 Partition，分区包含相关 MaterializedIndex，索引之下组织 Tablet，Tablet 有副本信息。这里的 MaterializedIndex 是元数据/存储组织概念，不等同于“用户创建了一个异步物化视图”。

一个仅有基表索引、3 个分区、每分区 4 桶的教学例子，可以理解为 12 个基表 Tablet；若各有 3 个副本，则有 36 份对应副本。它们不是 36 个不同逻辑分片。实际还需看额外索引、状态和配置，这个算式不能直接用于所有表。

分桶过少可能限制并行和数据分散；过多则增加小分片、元数据和调度成本。合理数量取决于数据量、节点与工作负载，本章不提供脱离场景的固定数字。

### 写入路由与查询裁剪是两件事

写入侧需要决定每行属于哪个分区和 Tablet。当前 `OlapTabletFinder::find_tablets()` 会查找分区，再根据相关模式决定桶。Hash、随机或其他适用路径的选择不同，不能把所有写入都画成同一个取模公式。

查询侧希望少读不相关数据。分区条件可用于排除范围，分桶键条件在适用情况下有助于缩小 Tablet 范围，排序与索引又进一步影响文件内部读取。某一层无法裁剪，不代表所有层都必须全读。

读源码时应把两个方向画开：一条是“这行应该放哪”，另一条是“这次查询可以不去哪里”。它们使用同一份表设计信息，但不是同一段代码逆向运行。

### FE Java 的源码落点

| 文件（相对仓库根目录） | 阅读重点 |
|---|---|
| `fe/fe-core/src/main/java/org/apache/doris/nereids/trees/plans/commands/info/CreateTableInfo.java` | `validate()` 与 Key 模型相关检查 |
| `fe/fe-core/src/main/java/org/apache/doris/catalog/OlapTable.java` | 表级模型、分区与索引组织 |
| `fe/fe-core/src/main/java/org/apache/doris/catalog/Partition.java` | 分区对象、可见版本与下一版本字段 |
| `fe/fe-core/src/main/java/org/apache/doris/catalog/HashDistributionInfo.java` | Hash 分布信息 |
| `fe/fe-core/src/main/java/org/apache/doris/planner/OlapScanNode.java` | 扫描范围和版本相关信息 |
| `be/src/exec/sink/vtablet_finder.cpp` | `find_tablets()` 写入路由 |

这里的入口定位与部分关键分支已核对，不表示完整验证了建表所有约束。使用 Unique Key 和部分更新前应按具体版本确认能力：[Unique Key 文档](https://doris.apache.org/docs/dev/table-design/data-model/unique/)区分了整行与部分列处理；该 dev 页面会变化，不能替代本地基线实现。

### 如何验证设计确实生效

第一步是 SHOW CREATE TABLE 确认真实定义。接着对比查询的扫描范围和运行信息，不能只凭 SQL 含有日期条件就认定裁剪成功。分布键倾斜还要观察实际数据分布；多个桶数量相同不保证每桶字节数相同。

可从 `fe/fe-core/src/test/java/org/apache/doris/nereids/rules/rewrite/PartitionPrunerTest.java` 阅读分区裁剪测试。一个有用的贡献问题应指出某种边界条件下裁剪遗漏或错误，并保留结果正确性的验证；仅让计划扫描更少分区，若漏了数据，属于错误而不是优化。

### 延伸源码专题

- [专题 3　从一列读取到更新、索引与 Schema Change](../deep-dives/03-storage-updates-and-indexes.md)

---

[全书导航](../README.md) · [术语表](../appendices/A-glossary.md)
