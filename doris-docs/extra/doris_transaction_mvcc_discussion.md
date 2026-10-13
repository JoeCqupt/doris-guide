# Doris 事务与 MVCC 实现探讨

## 背景

Doris 是 MPP OLAP 数据库，它的事务和 MVCC 设计服务于典型 OLAP 写入场景：批量导入、Stream Load、Routine Load、Insert Into、Delete、Unique Key Merge-on-Write 等。

因此，Doris 的事务不是传统 OLTP 数据库中那种任意多语句、行级锁、每行带 `xmin/xmax` 的事务模型。它更像列存/LSM 系统中的版本发布机制：

```text
写入先生成不可见的数据文件
提交后分配版本号
发布版本后查询才可见
查询固定某个版本号读取
```

在 Doris 里，这套机制由两层共同完成：

```text
FE: 管理全局事务状态、分配版本、判断提交和可见
BE: 管理 tablet 上的 rowset、pending rowset、版本图和实际读取
```

## 一句话总览

Doris 的事务与 MVCC 可以概括为：

```text
事务提交 = FE 认可本次写入，并给 partition 分配一个待发布版本
事务可见 = BE 已经把 pending rowset 发布成该版本，FE 推进 visibleVersion
MVCC = 查询固定 visibleVersion，BE 按版本图选择一组 rowset 来读
```

更短一点：

```text
FE 决定版本是否可见
BE 保存多个版本的数据文件
查询拿一个固定版本读
```

## 事务状态机

事务状态定义在：

- `fe/fe-core/src/main/java/org/apache/doris/transaction/TransactionStatus.java`

核心状态包括：

```text
UNKNOWN
PREPARE
PRECOMMITTED
COMMITTED
VISIBLE
ABORTED
```

常见写入流程是：

```text
PREPARE
  -> COMMITTED
  -> VISIBLE
```

异常或取消流程通常发生在提交前：

```text
PREPARE / PRECOMMITTED
  -> ABORTED
```

其中最重要的是区分 `COMMITTED` 和 `VISIBLE`：

- `COMMITTED`：FE 已经接受这次写入，事务元数据已记录，版本号已经确定，但查询还不能看到。
- `VISIBLE`：BE 已经发布 rowset，FE 推进 partition/table 的 visible version，新查询可以看到。

这和很多数据库中“commit 就立刻可见”的直觉不同。Doris 中 `COMMITTED` 到 `VISIBLE` 之间还有 publish version 阶段。

另一个非常关键的点是：`COMMITTED` 之后，事务已经占用了版本，正常不能再 abort。代码里会拒绝 abort `COMMITTED` / `VISIBLE` 事务。这也是后面“某个版本 publish 不出来会不会卡住”的根源。

## FE 侧事务管理

FE 事务入口主要在：

- `fe/fe-core/src/main/java/org/apache/doris/transaction/GlobalTransactionMgr.java`
- `fe/fe-core/src/main/java/org/apache/doris/transaction/DatabaseTransactionMgr.java`
- `fe/fe-core/src/main/java/org/apache/doris/transaction/TransactionState.java`
- `fe/fe-core/src/main/java/org/apache/doris/transaction/PublishVersionDaemon.java`

`GlobalTransactionMgr` 是全局入口，它按 DB 找到对应的 `DatabaseTransactionMgr`。真正的事务状态管理主要在 `DatabaseTransactionMgr` 中。

### Begin Transaction

入口大致是：

```text
GlobalTransactionMgr.beginTransaction()
  -> DatabaseTransactionMgr.beginTransaction()
```

`beginTransaction()` 会做这些事情：

```text
检查当前 FE 是否 Master
检查 label 是否重复
检查 requestId 幂等
检查运行中事务数量
生成 transaction id
创建 TransactionState
状态设为 PREPARE
写入 edit log
```

关键点：

- `label` 用于幂等和防重复导入。
- `requestId` 可用于识别重试请求。
- 事务状态本身也作为 FE 元数据的一部分持久化到 edit log。

## BE 写入：pending rowset

BE 侧本地事务由：

- `be/src/storage/txn/txn_manager.h`
- `be/src/storage/txn/txn_manager.cpp`

管理。

BE 的 `TxnManager` 维护的是 tablet 维度的事务映射：

```text
(partition_id, txn_id)
  -> tablet
     -> TabletTxnInfo
        -> rowset
        -> attach_rowsets
        -> delete_bitmap
        -> partial_update_info
        -> state
```

BE 本地事务状态主要包括：

```text
PREPARED
COMMITTED
ROLLEDBACK
ABORTED
DELETED
```

写入数据时，BE 先生成 rowset，但这个 rowset 还没有正式版本，对查询不可见。可以理解为：

```text
数据文件已经写好了
但是还没上架
查询还不知道它存在
```

`commit_txn()` 会把 rowset meta 保存下来，并把 rowset 放进 txn map。此时它仍然是 pending rowset，不在 tablet 的正式版本路径中。

相关代码：

- `be/src/storage/txn/txn_manager.cpp`

## Commit Transaction：FE 分配版本

写入完成后，FE 进入 commit 阶段：

```text
GlobalTransactionMgr.commitTransaction()
  -> DatabaseTransactionMgr.commitTransaction()
  -> unprotectedCommitTransaction()
```

commit 阶段会检查：

```text
事务是否存在
事务状态是否还是 PREPARE
涉及的表和分区是否还存在
tablet commit info 是否满足要求
副本提交是否达到 quorum
```

然后给涉及的 partition 分配版本。

Doris 的 partition 上有两个非常关键的版本字段：

```text
visibleVersion: 当前查询可见版本
nextVersion: 下一次提交要使用的版本
```

代码在：

- `fe/fe-core/src/main/java/org/apache/doris/catalog/Partition.java`

新建 partition 时：

```text
visibleVersion = 1
nextVersion = 2
```

也就是说，第一次导入通常会生成版本 2。

commit 时，FE 会把 `partition.getNextVersion()` 写入 `PartitionCommitInfo`。这个版本就是本事务将来要发布的版本。

此时事务状态变成：

```text
COMMITTED
```

但是 partition 的 `visibleVersion` 还没有推进。查询还看不到这次写入。

## Publish Version：让 BE rowset 变成正式版本

`COMMITTED` 之后，`PublishVersionDaemon` 会周期性扫描 ready-to-publish 的事务：

```text
PublishVersionDaemon.publishVersion()
  -> getReadyToPublishTransactions()
  -> 生成 PublishVersionTask
  -> 下发给相关 BE
```

代码在：

- `fe/fe-core/src/main/java/org/apache/doris/transaction/PublishVersionDaemon.java`
- `fe/fe-core/src/main/java/org/apache/doris/task/PublishVersionTask.java`

BE 收到 publish version task 后，会执行：

```text
TxnManager.publish_txn()
  -> rowset->make_visible(version, commit_tso)
  -> tablet->add_inc_rowset(rowset)
```

核心代码包括：

- `be/src/storage/txn/txn_manager.cpp`
- `be/src/storage/rowset/rowset.cpp`
- `be/src/storage/task/engine_publish_version_task.cpp`
- `be/src/storage/tablet/tablet.cpp`

`rowset->make_visible(version, commit_tso)` 会做几件重要的事：

```text
把 rowset 从 pending 变成非 pending
设置 rowset 的 version
设置 rowset_state = VISIBLE
设置 creation time
设置 commit_tso
```

然后 `tablet->add_inc_rowset(rowset)` 会把这个 rowset 加入 tablet 的正式版本集合中。

到这里，BE 上的数据文件已经有了正式版本。

## Finish Transaction：FE 推进 visibleVersion

Publish version task 完成后，FE 会尝试 finish transaction：

```text
PublishVersionDaemon.tryFinishTxn()
  -> GlobalTransactionMgr.finishTransaction()
  -> DatabaseTransactionMgr.finishTransaction()
```

finish 阶段会检查：

```text
BE publish 是否达到要求
副本是否满足 quorum
partition version 是否连续
```

满足条件后，FE 会：

```text
transactionState.status = VISIBLE
partition.visibleVersion = 本次事务版本
table.visibleVersion = 对应版本
写入 edit log
```

关键逻辑在：

- `fe/fe-core/src/main/java/org/apache/doris/transaction/DatabaseTransactionMgr.java`

这里的 `setTableVersion()` 会更新 partition 的 visible version：

```text
partition.updateVisibleVersionAndTime(version, versionTime, tso)
```

此后，新查询会看到这次写入的数据。

## 查询如何使用 MVCC

Doris 内部 OLAP 表的 MVCC 核心不是行级事务 ID，而是：

```text
partition visibleVersion
+ tablet rowset version graph
```

查询规划阶段，FE 会为每个 selected partition 获取当前 `visibleVersion`，并写入 scan range：

```text
TPaloScanRange.version = partition.visibleVersion
```

相关代码：

- `fe/fe-core/src/main/java/org/apache/doris/planner/OlapScanNode.java`

例如普通模式下：

```text
visibleVersion = partition.getVisibleVersion()
paloRange.setVersion(visibleVersion)
```

这意味着：一个查询启动时，会固定自己要读的版本。后续即使有新的导入变成可见，这个已经规划好的查询仍然读旧版本。

这就是 Doris 查询侧 MVCC 的基础。

## BE 如何按版本读取 rowset

BE 收到 scan range 后，知道要读哪个 tablet、哪个 version。

tablet 上不是只有一个文件，而是很多 rowset。每个 rowset 有版本范围：

```text
[0-1]
[2-2]
[3-3]
[4-4]
```

compaction 之后，也可能变成：

```text
[0-1]
[2-4]
[5-5]
```

BE 要做的是：给定目标版本 V，找到一条从初始版本到 V 的连续 rowset 路径。

例如目标版本是 5：

```text
可选路径 A:
[0-1] + [2-2] + [3-3] + [4-4] + [5-5]

可选路径 B:
[0-1] + [2-4] + [5-5]
```

这件事由 `VersionGraph` 和 `TimestampedVersionTracker` 完成。

相关代码：

- `be/src/storage/version_graph.h`
- `be/src/storage/version_graph.cpp`
- `be/src/storage/rowset_version_mgr.cpp`

`VersionGraph` 的注释说得很清楚：rowset version 是图中的边，给定 `spec_version`，找一条最短 version path。

核心流程：

```text
BaseTablet::capture_consistent_versions_unlocked()
  -> TimestampedVersionTracker.capture_consistent_versions()
  -> VersionGraph.capture_consistent_versions()
  -> 返回 Version path

BaseTablet::capture_consistent_rowsets_unlocked()
  -> 根据 Version path 找 Rowset

BaseTablet::capture_rs_readers_unlocked()
  -> 为 Rowset 创建 RowsetReader
```

也就是说，查询真正读取的是：

```text
目标 visibleVersion 对应的一组 rowset reader
```

## Compaction 与旧版本保留

OLAP 列存系统会不断 compaction，把多个小 rowset 合并成大 rowset。

例如：

```text
合并前:
[2-2] [3-3] [4-4]

合并后:
[2-4]
```

问题是：如果有旧查询已经拿到了旧版本路径，正在读 `[2-2] [3-3] [4-4]`，这些旧 rowset 能不能立刻删？

不能。

Doris 的做法是：被 compaction 替换掉的 rowset 会进入 stale rowset map：

```text
_rs_version_map: 当前主版本路径上的 rowset
_stale_rs_version_map: 被 compaction 替换但暂时保留的旧 rowset
```

相关代码：

- `be/src/storage/tablet/base_tablet.h`
- `be/src/storage/tablet/tablet.cpp`

这样，旧查询仍然可能从 stale rowset 中找到它需要的版本路径。等旧查询结束、rowset 过期后，后台再清理。

这就是 Doris rowset 级 MVCC 能支持读写并发和 compaction 的关键。

## Unique Key Merge-on-Write 的特殊点

对于 Duplicate Key 或 Aggregate Key 表，版本路径基本决定了读到哪些数据。

但 Unique Key Merge-on-Write 表还需要处理覆盖、删除、部分更新等行级可见性问题。Doris 通过 `delete_bitmap` 做这件事。

在 publish 阶段，如果是 Unique Key MOW 表：

```text
计算 delete bitmap
保存 delete bitmap
查询时 rowset path + delete bitmap 一起决定可见行
```

相关代码：

- `be/src/storage/txn/txn_manager.cpp`
- `be/src/storage/tablet/tablet.cpp`

可以理解为：

```text
rowset version path 决定读哪些文件
delete bitmap 决定这些文件里哪些行已经被新版本覆盖或删除
```

这比普通 rowset 版本 MVCC 多了一层行级过滤，但仍然不是 PostgreSQL 那种每行事务 ID MVCC。

## FE 的 MvccSnapshot 抽象

Doris FE 还有一套 `datasource.mvcc` 包：

- `fe/fe-core/src/main/java/org/apache/doris/datasource/mvcc/MvccSnapshot.java`
- `fe/fe-core/src/main/java/org/apache/doris/datasource/mvcc/MvccTable.java`
- `fe/fe-core/src/main/java/org/apache/doris/datasource/mvcc/MvccUtil.java`

这套更多用于表级快照抽象，尤其是：

- 外部表
- Paimon
- Hudi
- Iceberg
- Hive metastore 表
- 物化视图刷新

`MvccTable` 的注释说明：一次查询加载当前 snapshot，并在整个查询过程中复用这个 snapshot，保证查询过程中表信息不变。

所以 Doris 中“MVCC”有两个语境：

```text
内部 OLAP 表:
  partition visibleVersion + tablet rowset version graph

外部表/查询规划:
  MvccSnapshot 抽象，固定一次查询看到的表快照
```

这两者思想相同：查询要固定一个快照。但实现层次不同。

## 几个追问：把版本链路想清楚

下面这几问，其实比状态机本身更能帮助理解 Doris 的事务实现。

### 查询是不是拿 visibleVersion，然后扫小于等于它的所有 rowset？

不是。

这个理解前半句是对的：查询确实会带一个 `visibleVersion` 到 BE。

但 BE 不是简单找出所有 `end_version <= visibleVersion` 的 rowset 去 scan。它要找的是一组刚好连续覆盖目标版本的 rowset 路径。

假设目标版本是 5，tablet 上有：

```text
[0-1]
[2-2]
[3-3]
[4-4]
[5-5]
[2-4]   // compaction 后生成的 rowset
```

如果把所有小于等于 5 的 rowset 都读出来，就会同时读到：

```text
[2-2] + [3-3] + [4-4] + [2-4]
```

版本 2、3、4 就重复了。

所以 BE 只能选择其中一条连续路径：

```text
[0-1] -> [2-2] -> [3-3] -> [4-4] -> [5-5]
```

或者：

```text
[0-1] -> [2-4] -> [5-5]
```

这就是 Doris 需要 `VersionGraph` 的原因。rowset 的版本范围在图里是一条边，读请求要在图里找一条从初始版本走到目标版本的路径。

### 为什么每个 rowset 要有版本范围？

因为普通导入和 compaction 需要用同一种方式表达。

普通导入通常是单点版本：

```text
[2-2]
[3-3]
[4-4]
```

compaction 会把多个小 rowset 合成一个大 rowset：

```text
[2-2] + [3-3] + [4-4]
  -> [2-4]
```

如果 rowset 只能表示一个版本，compaction 结果就不好表达。用 `[startVersion-endVersion]` 之后，普通导入是特殊情况，compaction 结果也是同一个模型。

可以把它想成一本账：

```text
[3-3] 表示第 3 页账本
[2-4] 表示第 2 到第 4 页已经装订成一本小册子
```

查询要么读散页，要么读装订本，但不能两个都读。

### 为什么一定要找连续路径？

因为 Doris 的版本语义是“从初始状态一步步演进到目标版本”。

如果目标是版本 5，那么路径必须完整覆盖：

```text
[0, 5]
```

不能缺：

```text
[0-1] -> [2-2] -> [4-4] -> [5-5]
```

这里缺了 3，会漏数据。

也不能重：

```text
[0-1] -> [2-4] -> [3-3] -> [5-5]
```

这里 3 被读了两次，可能重复数据。

所以 Doris 的 rowset 读取不是过滤问题，而是拼路径问题。

### compaction 在这里到底起什么作用？

compaction 不改变事务语义，只改变物理布局。

合并前：

```text
[0-1] -> [2-2] -> [3-3] -> [4-4] -> [5-5]
```

合并后：

```text
[0-1] -> [2-4] -> [5-5]
```

查询看到的版本还是 5，但要读的 rowset 变少了。这样扫描更快，rowset 元数据更少，后续查询规划和读取也更轻。

不过旧 rowset 不能马上删。因为可能还有老查询已经拿到了旧路径：

```text
[0-1] -> [2-2] -> [3-3] -> [4-4] -> [5-5]
```

所以 Doris 会把被替换的旧 rowset 放进 `_stale_rs_version_map`。等确认过期之后，后台再清理。

### 慢查询会不会阻塞后面的导入？

一般不会。

慢查询开始时已经拿到了自己的 `visibleVersion`。之后新导入继续 commit、publish、visible，新查询可以看到新版本，老查询继续读老版本。

慢查询可能影响的是旧 rowset 的清理。比如 compaction 已经产生 `[2-4]`，但老查询还在读 `[2-2] [3-3] [4-4]`，这些旧 rowset 就需要暂时保留。它影响的是垃圾回收节奏，不是新版本发布。

### 慢导入会不会阻塞后面的导入？

要分清慢在哪里。

如果一个导入还在写数据，还没 commit，它通常还没有占用 partition version。后面的导入如果先 commit，反而可能先拿到版本。

例如：

```text
Txn A 先开始，但写得慢，还在 PREPARE
Txn B 后开始，但先 commit
```

B 可以先进入 `COMMITTED`，拿到某个版本。A 之后 commit 时，再拿下一个版本。

真正会阻塞的是：某个较小版本已经 `COMMITTED`，但迟迟不能 `VISIBLE`。

例如：

```text
partition visibleVersion = 9

Txn A commit version = 10, COMMITTED
Txn B commit version = 11, COMMITTED
Txn C commit version = 12, COMMITTED
```

Doris 只能按顺序推进：

```text
9 -> 10 -> 11 -> 12
```

如果 10 还没 visible，11 和 12 不能越过 10 直接 visible。原因很简单：如果跳过 10，BE 就无法保证查询能拼出一条不缺版本的 rowset 路径。

所以更准确地说：

```text
写入可以并发
commit 可以排队拿版本
publish 可以并发尝试
visible 必须按 partition 连续推进
```

### 如果 version 10 一直 publish 不了，partition 会卡死吗？

会卡住这个 partition 的新版本可见性，但不是整个 partition 完全不可用。

仍然可以读旧版本：

```text
partition visibleVersion = 9
新查询继续读版本 9
```

但新版本会堆在 `COMMITTED`：

```text
10 COMMITTED，不能 VISIBLE
11 COMMITTED，等 10
12 COMMITTED，等 10
```

Doris 不会自动跳过 10 去发布 11。因为一旦允许跳版本，查询就可能读到缺失版本的数据。

实际处理方式是持续重试 publish version 10。只要达到足够副本成功，FE 就可以把 10 推成 `VISIBLE`。如果 publish 等待超过配置时间，并且至少有一个副本成功，Doris 还有一个超时成功的兜底路径：先推进版本，把坏副本交给后续修复。

但如果 10 永远没有任何可接受的成功副本，那这个 partition 的新版本可见性就会长期卡住。后续 `COMMITTED` 事务堆多了，还可能触发表级 publishing 事务数量限制，影响新的导入。

这不是 Doris 忽略了这个问题，而是它在一致性和可用性之间做的选择：

```text
宁愿新数据暂时不可见
也不允许查询看到缺版本的数据
```

## 和传统数据库 MVCC 的区别

以 PostgreSQL 为代表的 OLTP MVCC 通常是：

```text
每行带事务 ID
查询根据事务快照判断每行是否可见
UPDATE 生成新行版本
VACUUM 清理旧行版本
```

Doris 内表更像：

```text
每次写入生成 rowset
rowset 带版本范围
查询固定 partition visibleVersion
BE 根据版本图选择 rowset
compaction 产生新 rowset，旧 rowset 暂留 stale map
```

因此：

```text
PostgreSQL MVCC 粒度偏行
Doris MVCC 粒度偏 rowset/tablet/partition 版本
```

这也符合两者的定位：

- PostgreSQL 面向 OLTP，高并发行级读写。
- Doris 面向 OLAP，高吞吐导入和大规模列式扫描。

## 小白版解释：把 Doris 想成一个仓库

下面用一个仓库上架的类比解释。

### 角色对应

```text
FE = 仓库总调度
BE = 各个仓库货架
tablet = 一个货架区域
rowset = 一批打包好的货物
version = 货架目录版本号
visibleVersion = 当前对顾客公开的目录版本
```

### 写入数据像是进货

一批新货来了，BE 先把它打包好：

```text
新 rowset 写好了
但是先放在后台仓库
顾客还不能买
```

这就是 pending rowset。

### COMMITTED 像是总调度审核通过

FE 检查这批货：

```text
货到了吗？
数量对吗？
副本够吗？
哪些分区被影响？
这批货应该成为第几版目录？
```

审核通过后，事务进入 `COMMITTED`。

但这时只是“审核通过”，货还没正式摆到顾客能看到的货架上。

### Publish Version 像是通知各仓库上架

FE 发通知给 BE：

```text
把这批货标成版本 8
放到正式货架
```

BE 收到后，把 pending rowset 变成 visible rowset。

### VISIBLE 像是新目录正式发布

当足够多的仓库完成上架后，FE 更新公开目录：

```text
visibleVersion 从 7 变成 8
```

从此以后，新来的顾客会看到版本 8 的目录。

### 老顾客为什么不会被影响

假设一个顾客进店时拿到的是目录版本 7。

他逛店期间，版本 8 发布了。但他手里的目录仍然是版本 7，所以他继续按版本 7 找货。

这就是查询固定 snapshot：

```text
查询开始时拿 visibleVersion = 7
整个查询都读版本 7
```

新查询才会拿到版本 8。

### Compaction 像是整理货架

仓库管理员觉得货架太碎：

```text
原来:
第 2 批货 + 第 3 批货 + 第 4 批货

整理后:
合并成第 2-4 批大包装
```

但是如果有顾客还拿着旧目录，正在找第 2、3、4 批原包装，就不能马上扔掉旧包装。

所以 Doris 会把旧 rowset 放到 stale map 里暂时保留。

等没有查询需要它们了，再清理。

### 用一句生活化的话说

Doris 的事务就是：

```text
先把货送到仓库后台
总调度审核并分配目录版本
通知仓库正式上架
最后发布新目录
顾客永远按自己进店时拿到的目录购物
```

这就是 Doris 的 MVCC。

## 常见困惑

### 为什么 COMMITTED 了还不能查到？

因为 Doris 中 `COMMITTED` 只表示 FE 已经接受这次写入，并记录了版本信息。BE 还需要 publish version，把 pending rowset 变成 visible rowset。

只有事务进入 `VISIBLE` 后，新查询才会看到。

### 为什么查询不会读到一半新数据、一半旧数据？

因为查询开始时，FE 会把 partition 的 visibleVersion 写入 scan range。BE 后续按这个固定版本找 rowset 路径。

只要查询版本固定，它读到的就是一个稳定快照。

### 为什么 compaction 不会破坏旧查询？

因为 compaction 替换掉的旧 rowset 不会立刻删除，而是进入 `_stale_rs_version_map`。旧查询如果需要旧版本路径，仍然可以找到这些 rowset。

### Doris 是不是支持完整 OLTP 事务？

不是。Doris 的事务主要保证导入和写入的原子可见性，适合批量写入和分析查询。它不是为高频小事务、行级锁、多语句交互式 OLTP 设计的。

### Doris 的 MVCC 是不是行级 MVCC？

内部 OLAP 表主要不是。它的核心是 rowset 版本 MVCC。Unique Key MOW 表会通过 delete bitmap 补充行级可见性，但整体仍建立在 rowset 版本体系上。

## 总结

Doris 事务与 MVCC 的关键点是：

```text
1. FE 管全局事务状态
2. BE 写入 pending rowset
3. commit 阶段 FE 分配 partition version
4. publish 阶段 BE 把 rowset 变成 visible
5. finish 阶段 FE 推进 visibleVersion
6. 查询固定 visibleVersion
7. BE 通过 VersionGraph 找连续 rowset 路径，而不是扫描所有小于等于目标版本的 rowset
8. compaction 后旧 rowset 暂存在 stale map 支撑旧查询
9. 慢查询一般不挡新版本发布，只可能延缓旧 rowset 清理
10. 已经 COMMITTED 的较小版本如果 publish 卡住，会挡住同 partition 后续版本 visible
```

最终形成的读写模型是：

```text
写入不直接覆盖旧数据
新数据通过新版本发布
查询只读自己开始时看到的版本
visibleVersion 按 partition 连续推进
旧版本数据延迟清理
```

这就是 Doris 面向 OLAP 场景的事务和 MVCC 实现方式。

## 参考代码

- `fe/fe-core/src/main/java/org/apache/doris/transaction/TransactionStatus.java`
- `fe/fe-core/src/main/java/org/apache/doris/transaction/GlobalTransactionMgr.java`
- `fe/fe-core/src/main/java/org/apache/doris/transaction/DatabaseTransactionMgr.java`
- `fe/fe-core/src/main/java/org/apache/doris/transaction/TransactionState.java`
- `fe/fe-core/src/main/java/org/apache/doris/transaction/PublishVersionDaemon.java`
- `fe/fe-core/src/main/java/org/apache/doris/catalog/Partition.java`
- `fe/fe-core/src/main/java/org/apache/doris/planner/OlapScanNode.java`
- `fe/fe-core/src/main/java/org/apache/doris/datasource/mvcc/MvccSnapshot.java`
- `fe/fe-core/src/main/java/org/apache/doris/datasource/mvcc/MvccTable.java`
- `be/src/storage/txn/txn_manager.h`
- `be/src/storage/txn/txn_manager.cpp`
- `be/src/storage/rowset/rowset.cpp`
- `be/src/storage/task/engine_publish_version_task.cpp`
- `be/src/storage/tablet/tablet.cpp`
- `be/src/storage/tablet/base_tablet.h`
- `be/src/storage/rowset_version_mgr.cpp`
- `be/src/storage/version_graph.h`
- `be/src/storage/version_graph.cpp`
