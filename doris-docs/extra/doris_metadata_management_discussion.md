# Doris 元数据管理探讨：机制、选型与一致性边界

## 背景

Apache Doris 的前身是 Baidu Palo。Doris 官方介绍中提到，Doris 最早由百度广告报表业务创建，原名 Palo，2017 年开源，2018 年进入 Apache 孵化器，2022 年成为 Apache 顶级项目。

这段历史对理解 Doris 的 FE 元数据管理很重要。Doris 当前的元数据架构并不是现代 Raft 控制面风格的产物，而更接近早期分布式数据库和 Hadoop NameNode 一类系统的设计：单主内存元数据、edit log、checkpoint/image、复制日志和 failover。

代码中仍能看到不少 Palo 时代的痕迹，例如：

- `gensrc/thrift/PaloInternalService.thrift`
- `fe/fe-core/src/main/java/org/apache/doris/master/Checkpoint.java` 中关于 Palo checkpoint 的注释
- `fe/fe-core/src/main/java/org/apache/doris/persist/meta/PersistMetaModules.java` 中的 `paloAuth`

## Doris 元数据管理的大体结构

Doris 的核心元数据主要由 FE 管理。BE 更多负责本地 tablet、rowset、segment 文件以及查询执行。

FE 内部的元数据对象大致可以理解为：

```text
Env
  -> CatalogMgr
     -> InternalCatalog / ExternalCatalog
        -> Database
           -> Table / OlapTable / View / ExternalTable
              -> Partition
                 -> MaterializedIndex
                    -> Tablet
                       -> Replica
```

其中：

- `Env` 是 FE 全局环境入口。
- `CatalogMgr` 管理 internal catalog 和 external catalog。
- `InternalCatalog` 管理 Doris 内部数据库和表。
- `Database` 维护 `idToTable`、`nameToTable` 等表映射。
- `OlapTable`、`Partition`、`Tablet`、`Replica` 等对象描述 Doris 内部表的物理和逻辑分布。

这套元数据结构长期驻留在 FE 内存中，查询规划、DDL 校验、事务和调度都会频繁访问它。因此 Doris 选择了内存 catalog，而不是每次从外部 RDBMS 或 metastore 读取。

## 持久化：Image + EditLog / Journal

Doris FE 的元数据持久化主要由两部分组成：

```text
image/checkpoint: 某一时刻完整元数据快照
edit log/journal: image 之后的增量元数据操作日志
```

启动或恢复时，FE 会先加载最新 image，然后 replay 后续 journal：

```text
读取最新 image
  -> 恢复完整内存元数据对象图
  -> 从 image 对应 journal id 之后继续 replay edit log
  -> 得到最新元数据状态
```

这和 Hadoop NameNode 的 `fsimage + edits` 思路非常相似。

Doris 中负责 image 读写的关键类包括：

- `fe/fe-core/src/main/java/org/apache/doris/persist/meta/MetaWriter.java`
- `fe/fe-core/src/main/java/org/apache/doris/persist/meta/MetaReader.java`
- `fe/fe-core/src/main/java/org/apache/doris/master/Checkpoint.java`

`Checkpoint` 会在 Master FE 上定期生成新的 image，从而避免系统启动时 replay 过长的 edit log。

## 元数据修改路径

以 `CREATE DATABASE` 为例，当前代码路径大致是：

```text
SQL DDL
  -> FE 解析和校验
  -> InternalCatalog.createDb()
  -> 构造 Database 对象
  -> 修改 Master FE 内存元数据
  -> 写 EditLog / Journal
  -> 返回客户端
```

关键代码逻辑类似：

```java
unprotectCreateDb(db);
CreateDbInfo dbInfo = new CreateDbInfo(InternalCatalog.INTERNAL_CATALOG_NAME, db.getName(), db);
Env.getCurrentEnv().getEditLog().logCreateDb(dbInfo);
```

表创建也是类似模式。`Database.createTableWithLock()` 会先把表注册进 `Database` 的内存映射；如果不是 replay 场景，再写 `logCreateTable()`。

这就是我们讨论中觉得“奇怪”的地方：它不是典型 Raft 状态机里的“先 append log，commit 后 apply”，而是很多路径上先修改 Master FE 的内存对象，再写日志。

## 它不是标准 Raft 状态机

标准 Raft 状态机通常是：

```text
leader 构造 command
append Raft log
多数派复制
commit
apply 到本机状态机
返回成功
follower 按相同顺序 apply
```

Doris 当前 FE 元数据更像：

```text
Master FE 执行 DDL
先修改 Master 内存元数据
再同步写 EditLog / BDBJE journal
写成功后认为 DDL 成功
Follower/Observer 通过 replay journal 修改内存
写失败则 Master FE 退出
```

所以它确实不是一个教科书式的 Raft replicated state machine。

## 一致性是如何保证的

Doris 的一致性边界主要靠以下几个约束叠加起来。

### 1. 只有 Master FE 写元数据

DDL 写入只应该发生在 Master FE。Follower 和 Observer 不直接处理元数据写入，而是通过 replay journal 追随 Master。

### 2. 成功返回以 journal 写成功为边界

虽然 Master FE 可能先改内存，但 `logEdit()` 会等待 journal 写入完成。batch editlog 模式下，调用方也会等待 flush 线程把日志真正写完后才返回 log id。

因此客户端看到 DDL 成功时，原则上这条元数据变更已经进入持久化 journal。

### 3. 写 journal 失败直接退出

这是 Doris 当前设计最“粗糙”也最关键的部分。它并不尝试在写日志失败后回滚已经修改过的内存状态，而是直接 `System.exit(-1)`。

这意味着：

```text
日志成功:
  内存状态和持久状态一致，DDL 可以返回成功

日志失败:
  当前 FE 内存状态不再可信，进程退出
  重启后从 image + journal 恢复，未落盘的修改自然消失
```

这不是优雅的事务回滚，而是 fail-fast。

### 4. BDBJE 承担复制日志和选主

Doris 默认 `edit_log_type = bdb`，即使用 Berkeley DB Java Edition 作为 journal 存储和复制机制。

相关配置包括：

- `replica_ack_policy = SIMPLE_MAJORITY`
- `bdbje_heartbeat_timeout_second = 30`
- `bdbje_replica_ack_timeout_second = 10`

BDBJE 提供类似 Paxos 的复制、选主和多数派确认能力。Doris 把 FE HA 的很大一部分托付给 BDBJE。

### 5. 新 Master 必须先 fencing 和 replay

FE 切换到 Master 时，会先 open editlog、做 BDBJE fencing、replay 到最新 journal，然后才进入 Master 服务状态。

这样新 Master 的内存状态来自已确认的 journal，而不是旧的本地脏状态。

## 网络分区下会发生什么

假设有 3 个 FE：

```text
A = Master
B/C = Follower
```

如果发生网络分区：

```text
A | B,C
```

A 落到少数派。由于默认 ack 策略是 `SIMPLE_MAJORITY`，A 无法拿到多数派确认。此时：

- A 继续处理 DDL 时，BDBJE journal 写入会失败或超时。
- Doris 写 journal 失败会直接退出。
- B/C 所在多数派可以选出新的 Master，并继续服务。

因此，是的，少数派上的旧 Master 确实可能反复退出。如果外部 supervisor、systemd 或 Kubernetes 不断拉起它，而网络分区仍未恢复，它可能进入：

```text
启动
  -> 加入失败 / 无法成为合法写入节点 / 无法写 journal
  -> 退出
  -> 再启动
```

这看起来粗糙，但它避免了更危险的问题：旧 Master 在少数派继续接受 DDL，形成 split-brain 元数据写入。

换句话说，Doris 把一部分一致性问题转化成了进程生命周期问题：

```text
宁可旧 Master 反复退出
也不让它带着不可提交的内存元数据继续服务
```

## 为什么当年会这样选型

这套设计要放在 Palo/Doris 早期背景下看。

### 1. OLAP 系统需要高频访问元数据

查询规划会频繁访问 database、table、partition、tablet、replica 信息。如果每次都访问外部 metastore，会影响高并发查询性能。

因此内存 catalog 是一个很自然的选择。

### 2. 当时 Raft 生态不是今天的默认选项

Palo 设计成型较早。那时 Java 服务做 HA，选择 ZooKeeper、BDBJE、BookKeeper 或自己封装 replicated log 都很常见。

BDBJE 能同时提供：

- 本地持久化 KV/log
- replicated environment
- leader election
- majority ack
- rollback / recovery 支持

所以它对当年的工程选型来说是合理的。

### 3. 类 NameNode 模式成熟且简单

`内存状态 + edit log + checkpoint` 是非常经典的 master 元数据服务模型。

它的优点是：

- 查询内存元数据很快。
- checkpoint 降低恢复成本。
- edit log 容易追加。
- replay 逻辑直观。

对于早期 Palo 这种 MPP OLAP 系统来说，这比从零构建一整套 Raft metadata state machine 更快落地。

### 4. 业务代码长期围绕内存对象演进

一旦大量 DDL、调度、事务、load、alter、recover 逻辑都围绕 `Env`、`InternalCatalog`、`Database`、`OlapTable` 等可变内存对象编写，系统会自然演化成“先改内存，再记录日志”的风格。

这不是最漂亮的分布式状态机抽象，但在长期迭代的工程系统中很常见。

## 和 Raft 模式相比

如果今天从零设计 Doris FE 元数据管理，我更倾向于选择标准 Raft 状态机：

```text
DDL command
  -> Raft log
  -> commit
  -> deterministic apply
  -> memory metadata state
```

这种模式的优点是：

- 提交边界更清楚。
- 不需要靠进程退出清理脏内存。
- failover 语义更标准。
- 开发者心智负担更低。
- 更容易做一致性推理和测试。

但对现有 Doris 来说，改成 Raft 不是“替换 BDBJE 库”这么简单，而是一次大手术。

真正要改，需要解决：

- 把校验和 apply 分离。
- 所有元数据变更都封装成 deterministic command/event。
- ID 分配、tablet 分布、replica 分布必须在 log command 中确定。
- BE tablet 创建等外部副作用必须后置、幂等或可恢复。
- image/checkpoint 要接入 Raft snapshot。
- follower read 的一致性语义要重新定义。
- 现有 editlog/image 格式需要兼容迁移。

因此：

```text
新系统从零设计:
  推荐 Raft 状态机

现有 Doris 演进:
  先抽象 MetadataCommand / MetadataStateMachine
  再考虑底层 journal 从 BDBJE 迁移到 Raft

只把 BDBJE 替换成 Raft:
  收益有限，风险很高
```

## 一个更现实的演进路线

如果要让 Doris 元数据管理逐步现代化，可以考虑分阶段推进。

### 阶段 1：收敛 replay/apply 路径

把 `unprotectXxx`、`replayXxx` 和直接修改内存的逻辑收敛成统一的 apply 函数。

目标是：

```text
同一类元数据变更
  只有一份真正修改内存状态的代码
```

### 阶段 2：引入 MetadataCommand

DDL 执行阶段只负责生成 command：

```text
CreateDatabaseCommand
CreateTableCommand
DropTableCommand
AlterTableCommand
```

command 中包含 apply 所需的完整确定性信息。

### 阶段 3：把 commit 和 apply 解耦

让 Master 不再在日志提交前修改全局元数据，而是：

```text
校验
  -> 构造 command
  -> 写入并提交 journal
  -> apply command
```

这一步即使底层仍是 BDBJE，也能显著改善一致性模型。

### 阶段 4：替换底层复制协议

当上层已经具备标准状态机边界后，再考虑用 Raft 替换 BDBJE，风险会小很多。

## 总结

Doris 当前元数据管理模式可以概括为：

```text
单主 FE 内存元数据
+ BDBJE replicated journal
+ image/checkpoint
+ follower replay
+ 写失败 fail-fast
```

它的发源不是现代 Raft 控制面，而是 Palo 时代为了高性能 OLAP 查询做出的内存 catalog 设计，并结合了 NameNode 式 `image + edit log` 和 BDBJE HA。

这种设计确实显得粗糙，尤其是“先改内存，再写日志，写失败退出”这一点。但它有明确的一致性边界：成功必须落 journal，失败则退出并通过恢复丢弃未落盘内存状态。

从现代工程审美看，标准 Raft 状态机会更干净；从现有 Doris 的历史包袱看，真正可行的路线不是直接换底层，而是先把元数据修改抽象成统一、确定、可 replay 的状态机 apply 层。

## 参考资料

- Apache Doris 官方介绍：https://doris.apache.org/docs/dev/getting-started/what-is-apache-doris
- Doris Metadata Design：https://doris.apache.org/community/design/metadata-design/
- Palo Overview：https://github.com/apache/doris/wiki/Palo-Overview
- `fe/fe-core/src/main/java/org/apache/doris/catalog/Env.java`
- `fe/fe-core/src/main/java/org/apache/doris/datasource/InternalCatalog.java`
- `fe/fe-core/src/main/java/org/apache/doris/catalog/Database.java`
- `fe/fe-core/src/main/java/org/apache/doris/persist/EditLog.java`
- `fe/fe-core/src/main/java/org/apache/doris/journal/bdbje/BDBJEJournal.java`
- `fe/fe-core/src/main/java/org/apache/doris/persist/meta/MetaWriter.java`
- `fe/fe-core/src/main/java/org/apache/doris/persist/meta/MetaReader.java`
- `fe/fe-core/src/main/java/org/apache/doris/master/Checkpoint.java`
