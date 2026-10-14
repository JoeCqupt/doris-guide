# 第 17 章　MVCC、查询快照与并发读写

[全书导航](../README.md) · [术语表](../appendices/A-glossary.md)

> 教学结构修订：2026-10-14。每章先沿一个问题阅读代码，再做实验、观察结果，最后解释对象和分支。历史正文基线为 `a53b182f810be2b3731c7dfdf6f40ff5a0ad63bd`；本次摘录取自当前本地文件，完整文件 SHA-256 与行号保存在[源码摘录清单](../examples/08-chapter-workshops/source-manifest.json)。运行证据来自报告版本 `doris-0.0.0-a53b182f810` 的二进制，不能仅凭版本前缀认定当前工作目录与二进制逐文件相同。

**本章问题：Compaction 产生覆盖版本的新 Rowset，查询怎样避免重复读？**

本章验证方式：源码推演 + 相关运行证据；并发快照未实测。建议先用 20—40 分钟完成主案例，第四部分的扩展阅读可分次完成；这不是新增的每日必交任务。

## 一、源码讲解：先找到决定行为的对象和分支

读 VersionGraph.capture_consistent_versions 的输入 spec_version 和输出 version_path。它求的是覆盖指定版本范围的一条路径，不能把所有“版本不大于目标”的 Rowset 都相加。Reader 还要持有对应对象，才能与回收并发协作。

### 先读这段真实代码

文件：`be/src/storage/version_graph.cpp`，当前文件第 416—438 行。下面是连续原文摘录，局部片段省略了方法的其他部分；不要把片段当完整实现。

```cpp
Status VersionGraph::capture_consistent_versions(const Version& spec_version,
                                                 std::vector<Version>* version_path) const {
    if (spec_version.first > spec_version.second) {
        return Status::Error<INVALID_ARGUMENT, false>(
                "invalid specified version. spec_version={}-{}", spec_version.first,
                spec_version.second);
    }

    int64_t cur_idx = -1;
    for (size_t i = 0; i < _version_graph.size(); i++) {
        if (_version_graph[i].value == spec_version.first) {
            cur_idx = i;
            break;
        }
    }

    if (cur_idx < 0) {
        return Status::InternalError<false>(
                "failed to find path in version_graph. spec_version: {}-{}", spec_version.first,
                spec_version.second);
    }

    int64_t end_value = spec_version.second + 1;
```

### 这几行应该怎样读

先检查请求区间是否合法，再寻找区间起点的图顶点。`spec_version` 是输入区间，`version_path` 是调用方要取得的路径；寻找不到起点会进入错误返回。后续还要读路径遍历，不能仅凭输入合法就认为存在连续覆盖。

### 新写入发生时，正在运行的查询怎么办

查询开始读取订单后，另一批订单可能提交，后台也可能合并文件。数据库需要让查询按照它取得的读取视图工作，而不是读到一半随意切换成另一组数据。

MVCC 是用版本表达可见性的一类机制，不代表所有数据库都使用相同的行级字段或全库时间戳。本章讲存算一体普通内表的分区版本与 Rowset 选择；不据此宣称所有事务模式拥有相同的跨表快照隔离。

### FE 把读取所需版本带入扫描范围

第 16 章的完成流程推进相关分区的可见版本。查询规划/执行安排会取得相应版本信息并附到扫描范围中。普通内表在 `OlapScanNode.addScanRangeLocations()` 中读取分区 visibleVersion；`updateScanRangeVersions()` 是 Cloud 批量更新扫描版本的路径，不能作为普通部署的统一入口。

这并不等于“每条 SQL 在解析第一字符时取一次全局版本”。获取和更新时机存在不同路径，实际多表快照还涉及锁、模式和其他机制；必须分别核对。

如果某个副本没追上所需版本，不能为了尽快返回而随意改用更旧版本。当读路径无法取得指定数据时，应沿副本选择或错误处理查证，不能偷偷缩小版本要求。

### Rowset 覆盖的是版本范围

写入可以产生增量版本的 Rowset，Compaction 可以把连续范围合成一份新 Rowset。于是同一批逻辑数据在生命周期交叠期间可能有多种物理表示。

教学示例：已有 `[0,1]`、`[2,2]`、`[3,3]` 三个范围，又合并出 `[0,3]`。读取到版本 3 时，可以选覆盖 `[0,3]` 的一致路径，而不能把四份 Rowset 全部相加，否则会重复读取。

这里的数字是示意，不是当前集群的初始化版本承诺。重点在于连续覆盖、终点和不重复，而不是这些具体值。

## 二、动手实验：先预测，再核对

默认使用已保存的实验材料或只读源码，不需要启动服务。运行环境已停止；若选择重新执行 SQL，先按[实验复现说明](../examples/07-live-lab-20261014/REPRODUCE.md)确认服务、版本与数据状态。初始化、导入和更新脚本不可在现有表上盲目重放。

1. 先做不启动服务的纸面实验：旧 Rowset 覆盖 [0,1]、[2,2]、[3,3]，新 Rowset 覆盖 [0,3]。为查询 [0,3] 写出两种可行覆盖；再删掉 [2,2] 且尚无新 Rowset，判断是否还能连续覆盖。
2. 进入 capture_consistent_versions，跟踪起点查找、目标范围、version_path 的填充与错误返回；再找 capture_rs_readers_unlocked 如何取得 Reader。
3. 对照 26 分区版本变化与 33 重启输出，列清已经观测到的是“当前可见结果”，不是旧快照正在运行时的行为。

本章实验材料：[26-partition-table.out.txt](../examples/07-live-lab-20261014/26-partition-table.out.txt) · [33-after-restart.out.txt](../examples/07-live-lab-20261014/33-after-restart.out.txt)。

## 三、观察结果：先陈述事实，再划清证据范围

纸面推演：旧三段或新一段可以分别覆盖 [0,3]，二者一起读会重复覆盖；中间缺 [2,2] 且没有替代路径则有缺口。这是教学模型，不是 Doris VersionGraph 测试输出。实际归档只证明当前数据和正常重启可读。

**本章边界：** 未运行并发读写/Compaction 的故障注入；本章动手项是源码状态推演。

## 四、回到源码解释：把现象还原成执行过程

版本图解决逻辑覆盖，Reader/共享所有权解决对象使用期限，回收器解决最终物理删除。三个条件不能混为一个“版本号够大”。要证明并发快照稳定，还需控制读任务启动、版本捕获和 Compaction 的事件顺序。

### 用自己的话走完这条链

合上结果后，按“输入 → 关键对象/状态 → 分支条件 → 可观察结果”的顺序回答本章问题：**Compaction 产生覆盖版本的新 Rowset，查询怎样避免重复读？** 再指出一项尚不能从现有实验得出的结论。能把每个箭头落到本章的方法或证据，比记住术语更接近读懂源码。

### 版本图如何帮助选择

`VersionGraph::capture_consistent_versions()` 接收目标范围。当前实现从起点寻找向前的边，避免超过目标结束位置，并收集对应版本区间；找不到满足条件的路径则返回错误。

可以把 Rowset 的 `[a,b]` 想成从 a 到 b+1 的边：连接这些边得到完整覆盖。这个表示解释了为什么读到某个上界不是简单检查每个 Rowset 的最大版本小于它。

```text
示例路径 1：0 ─[0,1]→ 2 ─[2,2]→ 3 ─[3,3]→ 4
示例路径 2：0 ─────────[0,3]────────────────→ 4
```

算法还存在带校验、缓存偏好等其他入口，本章只精读普通 `capture_consistent_versions()`。不要把这里的路径选择细节推导成所有模式下唯一策略。

### 从版本路径取得 Reader

当前 `BaseTablet::capture_rs_readers_unlocked()` 按已选版本路径查找 Rowset，当前集合没有时还会查看 stale 集合；找不到则返回错误，找到后创建 Reader 并加入读取结构。

这表明 stale 不必然等于“可以立即删除”，也说明选出版本区间后还需要真实 Rowset 对象存在。调用名中的 `unlocked` 提醒读者核对外部同步前提；不能从函数本体没有加锁就认定调用路径没有保护。

Reader 与共享对象的持有关系使运行中的查询可以继续使用已经取得的产物。但这不代表 Doris 为任意历史时间保留所有文件；历史选择与正在持有 Reader 是不同能力。

### Compaction 与文件回收的边界

Compaction 可以为同一逻辑范围生成新布局，更新 Tablet 的 Rowset/版本组织。旧对象进入 stale 或 unused 等生命周期后，清理仍要检查引用及回收条件。

当前 `StorageEngine::start_delete_unused_rowset()` 中可见 `use_count() == 1` 与 `need_delete_file()` 等条件，并区分本地与远端处理。它提供了“不能在仍有人持有时随意删除”的具体落点，但完整回收过程还涉及其他路径和配置。

慢查询因此可能延长某些旧对象的存活，带来空间或资源影响；不应简单宣称“慢查询会阻止所有新事务发布”，也不能宣称“慢查询对后台维护完全没影响”。必须区分逻辑版本推进与物理资源回收。

### MOW 还要考虑行级失效信息

选择正确 Rowset 只是读取正确性的一个层次。对于 Unique Key MOW，相关 Delete Bitmap 等信息决定同键物理记录哪些还应参与结果。版本、行位置和删除信息要共同满足当前读语义。

因此，证明“覆盖了所有版本”还不足以证明更新表读出的每行都正确。Compaction 改变布局时，行位置映射与失效信息同样需要保持一致。这接回第 13 章，而不是把 MVCC 当作孤立的一个版本号。

### 源码和验证问题

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

### 延伸源码专题

- [专题 1　从真实 EXPLAIN 走到 FE/BE 协议与取消](../deep-dives/01-query-rpc-and-cancellation.md)
- [专题 3　从一列读取到更新、索引与 Schema Change](../deep-dives/03-storage-updates-and-indexes.md)

---

[全书导航](../README.md) · [术语表](../appendices/A-glossary.md)
