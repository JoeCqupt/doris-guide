# 第 17 章　MVCC、查询快照与并发读写

[全书导航](../README.md) · [术语表](../appendices/A-glossary.md)

> 日期：2026-10-12。源码基线：`a53b182f810be2b3731c7dfdf6f40ff5a0ad63bd`。本章是源码阅读版 v1：关键入口与文中明确标出的分支已核对，未运行 Doris SQL、单测或性能实验。图和算例为教学示意；测试文件仅为后续验证入口，不代表已运行或完整覆盖。

## 17.1 新写入发生时，正在运行的查询怎么办

查询开始读取订单后，另一批订单可能提交，后台也可能合并文件。数据库需要让查询按照它取得的读取视图工作，而不是读到一半随意切换成另一组数据。

MVCC 是用版本表达可见性的一类机制，不代表所有数据库都使用相同的行级字段或全库时间戳。本章讲存算一体普通内表的分区版本与 Rowset 选择；不据此宣称所有事务模式拥有相同的跨表快照隔离。

## 17.2 FE 把读取所需版本带入扫描范围

第 16 章的完成流程推进相关分区的可见版本。查询规划/执行安排会取得相应版本信息并附到扫描范围中。普通内表在 `OlapScanNode.addScanRangeLocations()` 中读取分区 visibleVersion；`updateScanRangeVersions()` 是 Cloud 批量更新扫描版本的路径，不能作为普通部署的统一入口。

这并不等于“每条 SQL 在解析第一字符时取一次全局版本”。获取和更新时机存在不同路径，实际多表快照还涉及锁、模式和其他机制；必须分别核对。

如果某个副本没追上所需版本，不能为了尽快返回而随意改用更旧版本。当读路径无法取得指定数据时，应沿副本选择或错误处理查证，不能偷偷缩小版本要求。

## 17.3 Rowset 覆盖的是版本范围

写入可以产生增量版本的 Rowset，Compaction 可以把连续范围合成一份新 Rowset。于是同一批逻辑数据在生命周期交叠期间可能有多种物理表示。

教学示例：已有 `[0,1]`、`[2,2]`、`[3,3]` 三个范围，又合并出 `[0,3]`。读取到版本 3 时，可以选覆盖 `[0,3]` 的一致路径，而不能把四份 Rowset 全部相加，否则会重复读取。

这里的数字是示意，不是当前集群的初始化版本承诺。重点在于连续覆盖、终点和不重复，而不是这些具体值。

## 17.4 版本图如何帮助选择

`VersionGraph::capture_consistent_versions()` 接收目标范围。当前实现从起点寻找向前的边，避免超过目标结束位置，并收集对应版本区间；找不到满足条件的路径则返回错误。

可以把 Rowset 的 `[a,b]` 想成从 a 到 b+1 的边：连接这些边得到完整覆盖。这个表示解释了为什么读到某个上界不是简单检查每个 Rowset 的最大版本小于它。

```text
示例路径 1：0 ─[0,1]→ 2 ─[2,2]→ 3 ─[3,3]→ 4
示例路径 2：0 ─────────[0,3]────────────────→ 4
```

算法还存在带校验、缓存偏好等其他入口，本章只精读普通 `capture_consistent_versions()`。不要把这里的路径选择细节推导成所有模式下唯一策略。

## 17.5 从版本路径取得 Reader

当前 `BaseTablet::capture_rs_readers_unlocked()` 按已选版本路径查找 Rowset，当前集合没有时还会查看 stale 集合；找不到则返回错误，找到后创建 Reader 并加入读取结构。

这表明 stale 不必然等于“可以立即删除”，也说明选出版本区间后还需要真实 Rowset 对象存在。调用名中的 `unlocked` 提醒读者核对外部同步前提；不能从函数本体没有加锁就认定调用路径没有保护。

Reader 与共享对象的持有关系使运行中的查询可以继续使用已经取得的产物。但这不代表 Doris 为任意历史时间保留所有文件；历史选择与正在持有 Reader 是不同能力。

## 17.6 Compaction 与文件回收的边界

Compaction 可以为同一逻辑范围生成新布局，更新 Tablet 的 Rowset/版本组织。旧对象进入 stale 或 unused 等生命周期后，清理仍要检查引用及回收条件。

当前 `StorageEngine::start_delete_unused_rowset()` 中可见 `use_count() == 1` 与 `need_delete_file()` 等条件，并区分本地与远端处理。它提供了“不能在仍有人持有时随意删除”的具体落点，但完整回收过程还涉及其他路径和配置。

慢查询因此可能延长某些旧对象的存活，带来空间或资源影响；不应简单宣称“慢查询会阻止所有新事务发布”，也不能宣称“慢查询对后台维护完全没影响”。必须区分逻辑版本推进与物理资源回收。

## 17.7 MOW 还要考虑行级失效信息

选择正确 Rowset 只是读取正确性的一个层次。对于 Unique Key MOW，相关 Delete Bitmap 等信息决定同键物理记录哪些还应参与结果。版本、行位置和删除信息要共同满足当前读语义。

因此，证明“覆盖了所有版本”还不足以证明更新表读出的每行都正确。Compaction 改变布局时，行位置映射与失效信息同样需要保持一致。这接回第 13 章，而不是把 MVCC 当作孤立的一个版本号。

## 17.8 源码和验证问题

| 文件（相对仓库根目录） | 阅读位置 |
|---|---|
| `fe/fe-core/src/main/java/org/apache/doris/planner/OlapScanNode.java` | `updateScanRangeVersions()` |
| `be/src/storage/version_graph.cpp` | `VersionGraph::capture_consistent_versions()` |
| `be/src/storage/tablet/base_tablet.cpp` | `capture_rs_readers_unlocked()` |
| `be/src/storage/tablet/tablet.cpp` | Rowset 集合变更与版本相关调用 |
| `be/src/storage/storage_engine.cpp` | `start_delete_unused_rowset()` |

测试入口为 `be/test/storage/timestamped_version_tracker_test.cpp`、`be/test/storage/tablet/tablet_test.cpp`。本章没有运行并发读写实验。

后续验证可拆成三类：指定范围有完整路径时选对数据；范围缺失时正确报错；Compaction 与查询持有旧对象交叠时不丢数据、不重复且正确回收。只比较某次查询前后总行数，不足以覆盖这些独立条件。

现在可以把全链路接起来：FE 的可见状态给出读取边界，BE 的版本路径选择相应存储对象，Reader 保持使用期内的对象生命，表模型和删除信息决定最终行语义。它们共同形成普通内表读写并发的一部分实现基础。


---

[上一章：第 16 章](16-transaction-commit-publish-visible.md) · [全书导航](../README.md) · [下一章：第 18 章](18-metadata-journal-and-fe-ha.md)

## 源码深读补充（2026-10-13）

- [专题 1　从真实 EXPLAIN 走到 FE/BE 协议与取消](../deep-dives/01-query-rpc-and-cancellation.md)
- [专题 3　从一列读取到更新、索引与 Schema Change](../deep-dives/03-storage-updates-and-indexes.md)
