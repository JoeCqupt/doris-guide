# 第 15 章　一批数据如何写进 BE

[全书导航](../README.md) · [术语表](../appendices/A-glossary.md)

> 日期：2026-10-12。源码基线：`a53b182f810be2b3731c7dfdf6f40ff5a0ad63bd`。本章是源码阅读版 v1：关键入口与文中明确标出的分支已核对，未运行 Doris SQL、单测或性能实验。图和算例为教学示意；测试文件仅为后续验证入口，不代表已运行或完整覆盖。

## 15.1 本章接在哪里

第 14 章讲请求、作业和导入入口，第 16 章讲事务完成。本章填上中间的物理数据路径：输入 Block 如何被分到目标 Tablet，如何进入 MemTable，如何形成 Rowset，最终如何参与发布。

范围为存算一体普通内表写入。当前代码存在不同通道、writer 版本以及特殊表路径，下面选代表性实现解释共同职责，不声称每种导入依次调用同一组函数。

## 15.2 从输入列到目标分片

导入需要把外部字段或 SQL 输出转换成目标表所需的列。类型转换、空值、长度和过滤等问题，应在相关阶段产生明确的行处理结果，而不是把不能写入的数据默默当成成功。

转换后还要决定目标分区与桶。当前 `OlapTabletFinder::find_tablets()` 先进行分区查找，再处理合格行的 Tablet 定位。当前实现包含按行定位、随机桶或批次相关模式，所以图中的“路由”只是一个职责名称。

```mermaid
flowchart LR
    I[输入数据 / Block] --> C[列转换与校验]
    C --> R[Partition / Tablet 路由]
    R --> T1[目标 Tablet 写入通道]
    R --> T2[目标 Tablet 写入通道]
    T1 --> M1[MemTable 与 Flush]
    T2 --> M2[MemTable 与 Flush]
    M1 --> S1[Rowset]
    M2 --> S2[Rowset]
```

图中画两个目标只是示意。副本传输和通道具体协议尚未展开，不能从它推导副本写入顺序或提交数量要求。

## 15.3 DeltaWriter 把写入与存储对象衔接起来

`DeltaWriter::write()` 接收 Block 与该 Tablet 对应的行信息，并交给 MemTable writer。代码还能看到 Flush 并发相关等待，说明写入速度会受后台落盘能力约束，而非无限积累内存。

`build_rowset()` 和 `commit_txn()` 又把工作交给 Rowset builder。这里的名字值得特别注意：**BE 本地 `commit_txn()` 不等于 FE 全局事务已经 VISIBLE。** 它登记和保存本地事务关联的 Rowset 等状态，是分布式完成链路的一部分。

如果日志只看到 BE commit 成功，下一步应继续查 FE 提交/发布与可见状态；不要直接把这一条日志当作客户端查询一定能看到数据的证据。

## 15.4 MemTable：内存中的组织与 Flush

当前 `MemTable::insert()` 使用输入 Block 和行下标等信息组织内容。随后排序、聚合或同键处理会根据模型及配置进入相应路径。Duplicate Key、Aggregate Key、Unique Key 不应被描述成在内存中做完全相同的动作。

Flush 把整理后的数据交给后续文件写出流程。异步 Flush 允许前台与后台交错，但也需要等待、错误传播和取消处理。`wait_flush()` 的存在提醒我们：提交依赖的产物可能还没准备完，不能只因为已经发起 Flush 就构建成功结果。

一次输入批次、一个 MemTable、一个 Segment、一个 Rowset 不是固定一对一映射。批次大小、写入目标、Flush 条件和文件组织都会改变数量。性能分析应记录实际产物，而不是用 SQL 次数估计文件数。

## 15.5 RowsetBuilder 与本地事务

当前 `RowsetBuilder::init()` 的路径包含事务准备；`build_rowset()` 组织构建输出；`RowsetBuilder::commit_txn()` 调用存储引擎的 TxnManager。阅读时要同时追资源持有与失败清理：某个步骤失败后，待用文件和事务记录由谁处理？

`TxnManager` 有 prepare、commit、publish 等不同入口。名字与 FE 阶段相似，但对象范围不同：这里面向本地 Tablet 等存储状态，FE 还要协调全部相关数据和副本。把两个层次画在同一状态框里，会丢失失败定位所需的信息。

## 15.6 Publish 把本地产物接入可读取组织

当前 `engine_publish_version_task.cpp` 的 `publish_version_and_add_rowset()` 是明确的代码窗口：先调用 TxnManager 的发布处理，再把 Rowset 加入 Tablet 的相关组织，同时记录出错的 Tablet。

但单个 BE 的动作完成仍不等于整个事务已对查询可见。FE 还需检查发布结果、版本连续性和其他完成条件，见第 16 章。这个边界解释了为什么“文件存在”“BE 发布成功”“FE VISIBLE”可以是三个不同观察点。

## 15.7 源码与验证

| 路径（相对仓库根目录） | 阅读入口 |
|---|---|
| `be/src/exec/sink/vtablet_block_convertor.cpp` | 输入转换 |
| `be/src/exec/sink/vtablet_finder.cpp` | `find_tablets()` |
| `be/src/load/delta_writer/delta_writer.cpp` | `write()`、`wait_flush()`、`build_rowset()`、`commit_txn()` |
| `be/src/load/memtable/memtable.cpp` | `insert()`、排序与聚合组织 |
| `be/src/storage/rowset_builder.cpp` | 本地产物与事务衔接 |
| `be/src/storage/task/engine_publish_version_task.cpp` | `publish_version_and_add_rowset()` |

可读 `be/test/load/delta_writer/delta_writer_test.cpp`、`be/test/load/memtable/memtable_sort_test.cpp` 和 `be/test/storage/txn/txn_manager_test.cpp`。未运行这些测试。

后续验证应从同一个事务关联输入行数、目标 Tablet、Flush/Rowset 和发布结果。不要直接改内存限额掩盖持续增长，也不要删除不熟悉的文件来“修好”可见性；先确认它处于未完成写入、等待发布还是待回收状态。


---

[上一章：第 14 章](14-load-entry-and-lifecycle.md) · [全书导航](../README.md) · [下一章：第 16 章](16-transaction-commit-publish-visible.md)

## 源码深读补充（2026-10-13）

- [专题 4　副本写入、导入确认与恢复](../deep-dives/04-load-replicas-and-recovery.md)
