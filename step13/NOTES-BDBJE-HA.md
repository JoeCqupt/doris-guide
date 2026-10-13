# Step 13 附注：BDBJE 分布式日志与 FE 选主

- 记录日期：2026-10-12
- 源码根：`/Users/jiangyuan/open/doris`
- 用途：为 Step 13 第 2 节「确认元数据对象安装与 EditLog 的位置」补齐背后的 FE HA 机制。
- 结论一句话：**FE 的元数据一致性靠 BDBJE 的复制组承担（选主 + 复制），Doris 在其上只做两件事：把写操作封成 EditLog 打到 journal，以及当选后用一个持久化的 epochDB 做 fencing 来防止脑裂。** 它本质是"复用 BDB 的一致性"，不是自己实现一套 Raft。

## 一、三个核心概念：Environment / Database / epochDB

BDBJE 是 Oracle/BD 的 Berkeley DB Java Edition（`com.sleepycat.je`），Doris 用它的 **ReplicatedEnvironment**（复制组，带选主和多数派复制）。

| 概念 | 在 Doris 中是什么 | 关键位置 |
|---|---|---|
| **Environment** | 一个 BDB 复制组，整个 FE 只有一个；负责节点间复制 + 选主 | `journal/bdbje/BDBEnvironment.java:195` `new ReplicatedEnvironment(...)` |
| **Database** | Environment 内的一组持久化 KV，Doris 用它存两类东西：**journal（EditLog）** 和 **epochDB** | `BDBEnvironment.java:205` `openDatabase(null, "epochDB", ...)` |
| **journal Database** | EditLog 的落地载体，按 journal id 命名并分块（rolling） | `journal/bdbje/BDBJEJournal.java:118`、`:548` |
| **epochDB** | 单张表，用来做命名空间的 fencing（见第六节） | `BDBEnvironment.java:249` `getEpochDB()` |

关系一句话：**Environment = 复制组 + 选主；Database = 组内的一张表。journal 表承载"状态机日志"（被复制、被 replay），epochDB 表承载"任期号"（被原子抢占）。** 二者都在同一个 Environment 里，因此都随复制组走多数派。

## 二、写入链：一次元数据变更如何变成一条被复制的日志

```
建库等元数据操作
  → InternalCatalog.createDb()
  → EditLog.logCreateDb(info)                    persist/EditLog.java:1777
  → logEdit(op, writable)                        persist/EditLog.java:1675
  → journal.write(op, writable)                  persist/EditLog.java:1675 → BDBJEJournal.java:230
  → currentJournalDB.put(null, theKey, theData)  BDBJEJournal.java:274
```

要点：

- `BDBJEJournal` 里 `journal.write(...)` 有两条重载：`write(short, Writable)`（`BDBJEJournal.java:230`）和批量的 `write(JournalBatch)`（`:130`），底层都是往 `currentJournalDB.put(...)` 写。
- `rollJournal()`（`BDBJEJournal.java:106-127`）的注释说明分块规则：**Database 用其最小 journal id 命名**，例如库里有 100~200 号日志，库名就是 `100`，下一个库名 `201`；id 与库内条数对不上就 `System.exit(-1)`。
- 这是**多数派写**：follower 上的写会抛 `ReplicaWriteException`（`BDBJEJournal.java:177,282`），Doris 捕获后直接 `exit`（见第七节）。
- **只有 master 写 journal。** 元数据变更不是直接改内存/落盘，而是先写成日志、由 BDB 复制到多数派，再在本地 apply。这也是为什么 `feType` 未就绪时 `waitForReady()` 会一直等（`Env.java` 的启动等待就是等 BDB 选主 + 日志就绪）。

## 三、写的顺序：先内存后日志？——是，但"提交点"仍是日志

Doris 在 DDL 链上是**先改内存、后写 journal**，与标准 WAL（先日志后 apply）相反。以 `createDb` 为例（`datasource/InternalCatalog.java:409`）：

```java
unprotectCreateDb(db);                                   // 434: 先改内存 (idToDb/fullNameToDb.put)
CreateDbInfo dbInfo = new CreateDbInfo(...);
Env.getCurrentEnv().getEditLog().logCreateDb(dbInfo);    // 436: 后写 journal
```

`unprotectCreateDb`（`InternalCatalog.java:452`）就是往 `idToDb` / `fullNameToDb` 里塞对象。但要把两个"顺序"拆开：

| 顺序 | Doris 的做法 | 和 Raft 比 |
|---|---|---|
| **内部 apply 顺序** | 先改内存，后写 journal | 相反 |
| **对外 ack 顺序** | `createDb()` 要等 `logCreateDb()`（journal 多数派写）返回才 return | 一致（commit 后才 ack） |

即**客户端拿到"OK"仍然在日志落多数派之后**；真正和 Raft 不同的是"状态机 apply 提前到了 commit 之前"。

### 为什么"先内存"没炸：失败即死（fail-stop）

journal 写失败即退出进程（`EditLog.logEditDirectly:1675-1683`）：

```java
logId = journal.write(op, writable);
} catch (Throwable t) {
    LOG.error("Fatal Error : write stream Exception", t);
    System.exit(-1);          // EditLog.java:1683
}
```

关键是**内存态易失**：进程一死，`unprotectCreateDb` 刚加进去的 DB 随进程消失；重启时元数据从 **image + journal replay** 重建，而 journal 里没有 `OP_NEW_CREATE_DB` → 这个 DB 不会存在。

所以"先内存"的半成品**永远不会变成持久的不一致**，因为唯一的失败模式是进程死亡。前提是 **fail-stop，不是 fail-continue**。

> 附：live 与 replay 共用同一段 apply 逻辑——`replayCreateDb`（`InternalCatalog.java:463`）也调 `unprotectCreateDb`；leader 上 live 执行直接调它改内存，journal 条目只记录"这件事发生过"，供 follower / 重启后的 replay 重放。

### 与 Raft 的真实差异：不变量由谁保

| | Raft | Doris + BDBJE |
|---|---|---|
| 唯一真相源 | log | log（journal） |
| apply 时机 | **只**在 commit 之后 | leader 上**先** apply 内存，再写日志 |
| 未提交状态可见性 | 状态机绝不暴露未提交状态 | 有极小窗口：内存已有 DB，journal 未复制 |
| 一致性不变量靠什么保 | 算法本身（commit 前不暴露） | 算法**不**保证，靠"失败即死"兜底 |

那个窗口是真实的——它是 apply 早于 commit 的**唯一真实代价**，纯 Raft 不会出现，Doris 用 fail-stop 把它限界在"进程存活期内"。完整的窗口成因、最坏时序与危害定级见**第四节**。

**一句话**：差异不在"先写哪个"，而在**一致性不变量由谁保证**——Raft 写进算法，Doris 外包给 **BDB 的复制 + fail-stop**（要么成功，要么整个进程死掉重放日志）。

## 四、"幻影 DB"窗口：apply 早于 commit 的唯一真实代价

### 窗口为什么真实存在：读不加锁，写才串行

- 写路径 `createDb` 全程持有 catalog 独占锁 `lock`（`InternalCatalog.java:208` `MonitoredReentrantLock`；`tryLock` :323 / `unlock` :357），一直到 `logCreateDb` 之后（:441）才释放；
- 但读路径 `getDbNullable`（`InternalCatalog.java:258`）**直接读 map，不取锁**；
- 而承载元数据的 `idToDb` / `fullNameToDb` 是 `ConcurrentHashMap`（`InternalCatalog.java:209-210`），**可被无锁并发读**。

于是 `unprotectCreateDb`（:434）一执行，DB 立刻进入被读路径可见的 map；而 `logCreateDb`（:436）此时尚未写、更未复制到多数派。**这个时间差就是窗口。**

> 关键限定：窗口**只对写路径之外的读敞开**。其它写操作（例如紧接着的 `CREATE TABLE`）要抢同一把 `lock`，会被 `createDb` 阻塞到窗口关闭之后，所以**窗口内不可能再产生新的 journal 条目**——幻影不会被"固化"进日志。

### 最坏时序

1. `unprotectCreateDb` → 内存 map 出现 DB
2. 并发连接的**无锁读**读到它（如 `SHOW DATABASES`、按 db 名解析）
3. leader 在 `logCreateDb` 达成多数派前崩溃，或被 fencing 踢掉
4. 新 leader 从 image + journal replay 重建，**没有** `OP_NEW_CREATE_DB` → DB 不存在
5. 那个读过的连接"看到过一个随后消失的 DB"——幻影 DB

### 属什么级别的违反

- 纯 Raft：apply 只在 commit 后 → 状态机绝不暴露未提交状态 → 无幻影；
- Doris：允许未提交状态被读路径看到 → 违反「commit 前不可见」；
- 定位：**不是持久性问题，也不是最终一致性问题，而是提交可见性（commit visibility）**，且被 fail-stop 限界在"进程存活期内"。

### 为什么被接受

- 窗口时长 ≈ 一次 journal 多数派往返（毫秒级）；
- DDL 低频，要可观测需同时满足三件事：① `createDb` 尚未提交 ② 恰好有读落在窗口内 ③ leader 恰好崩溃且该条未达多数派；
- 做 DDL 的客户端要等 journal 写完才拿到 OK，它自己**永远看不到**幻影；只有**旁路读**可能撞上；
- fail-stop 保证不会有**持久**不一致：要么日志落盘被重放，要么进程死掉、DB 从未存在过。

### 若要彻底消除

- 改成"先写 journal 多数派、再 apply 内存"（标准 WAL / Raft 顺序）：会丢掉 live / replay 共用 apply 逻辑的简洁性，且 DDL 多一次往返；
- 或给读路径也加锁 / 读屏障：代价更大，影响所有查询；
- Doris 选择折中：**用 fail-stop 换 apply 顺序的自由**。

## 五、选主状态机：BDB 状态 → FE 角色

BDB 复制组内部完成选主，选完通过 `StateChangeListener` 通知 Doris：

```
BDB 复制组状态变化
  → BDBStateChangeListener.stateChange()          ha/BDBStateChangeListener.java:38
       MASTER  → FrontendNodeType.MASTER
       REPLICA → FOLLOWER（isElectable）或 OBSERVER
       UNKNOWN → UNKNOWN
  → Env.notifyNewFETypeTransfer(newType)          catalog/Env.java:3266
       （仅 put 进 typeTransferQueue，非阻塞）
  → stateListener 守护线程 take()                  catalog/Env.java:3282-3404
  → 按 (旧 feType → 新 newType) 分派：
       → transferToMaster()                       catalog/Env.java:1735
       → transferToNonMaster(newType)
```

`stateListener` 的分派表（`Env.java:3304-3383`）覆盖 INIT/UNKNOWN/FOLLOWER → MASTER、INIT/UNKNOWN/FOLLOWER → FOLLOWER/OBSERVER 等；关键一条：

```java
case MASTER: {
    // exit if master changed to any other type
    String msg = "transfer FE type from MASTER to " + newType.name() + ". exit";
    ...
    System.exit(-1);
}
```

即 **master 一旦被 BDB 降级为任何其他角色，进程直接退出**——Doris 不让"前 master"以非 master 身份继续活在同一进程里（见第七节）。

## 六、fencing + epoch：当选之后如何标定"唯一 master"

`transferToMaster()`（`Env.java:1735`）在真正开始干活前，先做 fencing（`Env.java:1756`）：

```java
if (!haProtocol.fencing()) {
    LOG.error("fencing failed. will exit.");
    System.exit(-1);
}
```

`BDBHA.fencing()`（`ha/BDBHA.java:72-104`）：

```java
long count = epochDb.count();
long myEpoch = count + 1;
status = epochDb.putNoOverwrite(null, theKey, theData);  // key = myEpoch
if (status == SUCCESS)   { Env.getCurrentEnv().setEpoch(myEpoch); return true; }
else if (status == KEYEXIST) { return false; }           // 没抢到，放弃
```

它的作用：

- **epochDB 持久化在 BDB 里**，`count()+1` 保证编号**全局单调递增**，跨 FE 重启也成立；
- `putNoOverwrite` 做**原子抢占**：同一个 epoch 只可能一个节点写成功，第二个拿到 `KEYEXIST`；
- 抢不到 → fencing 返回 false → `transferToMaster()` 直接 `System.exit(-1)`。

这就是 Doris 版的"任期号"（term）：**极端情况下若两个节点都自认 master，epochDB 的原子抢占保证最终只有一个 epoch 有效**，拿不到号的节点自杀，从而消除脑裂。

## 七、旧 master 的写是如何被阻止的

问题：新 master 已选出、旧 master 还没下线，旧 master 的写为什么进不去？答案是**四道锁，从内到外**：

| 层 | 机制 | 证据 |
|---|---|---|
| 1. BDB 复制层 | 旧 master 已被降为 replica，对 journal 的写抛 `ReplicaWriteException` | `BDBJEJournal.java:177,282` |
| 2. Doris 写路径 | 捕获 `ReplicaWriteException` 后 `System.exit(-1)` | `BDBJEJournal.java:191,296` |
| 3. 状态机层 | BDB 状态一变为 REPLICA/UNKNOWN，`stateListener` 命中 `case MASTER → exit` | `Env.java:3373-3378` |
| 4. 对外(→BE) 层 | 心跳 epoch 校验；BE 拒绝 epoch 不大于本地的 master | `be/src/agent/heartbeat_server.cpp:189-215` |

所以"老 leader 的写被阻止"**不是**靠 `journal.write` 报错后继续跑——报错即进程退出。第 1、2 道是"写不进 + 自杀"，第 3 道是"状态一降级就自杀"，第 4 道是"即使旧 master 真发出心跳，BE 也不认"。

## 八、epoch 递增号：只服务于 BE 吗？——不是

epoch 最主要的消费者是 **BE**，但**并非 BE 独享**。

FE 起 master-only 线程时把 epoch 下发：

```
Env.java:2013   heartbeatMgr.setMaster(clusterId, token, epoch)
HeartbeatMgr.java:97-111   new TMasterInfo(host, rpc_port, clusterId, epoch)
HeartbeatService.thrift    TMasterInfo.3: required Types.TEpoch epoch
```

BE 侧在 `be/src/agent/heartbeat_server.cpp:189-215` 用本地 `_fe_epoch`（`heartbeat_server.h:62`）比较：

- master 地址变了 → 只有 `master_info.epoch > _fe_epoch` 才接受，否则返回
  `InternalError("epoch is not greater than local. ignore heartbeat")`；
- 同一地址（master 重启，host/port 不变）→ 同样要求 epoch 递增才接受。

即 **BE 只认 epoch 更高的那个 master，过期的 master 心跳被丢弃**。

但两点澄清：

1. epoch 的**权威来源在 FE**（`Env.epoch`，字段定义 `Env.java:384`，`getEpoch/setEpoch` `Env.java:5489-5494`），BE 只是消费者。
2. epoch **不落进 FE 的 image 元数据**。`MasterInfo` 只存 `host / httpPort / rpcPort`（`ha/MasterInfo.java:30-49`），`saveMasterInfo/loadMasterInfo`（`Env.java:2840/2452`）也只读写这三个字段，**没有 epoch**。所以 FE 的 `epoch` 是内存态，每次重新当选都重新 fencing 拿更大的号；**跨重启的单调性由 BDB 里持久化的 epochDB 保证，而非 FE 的 image**。

## 九、和 Raft 的对照（为什么读起来不如 Raft 顺）

| 维度 | Raft | Doris + BDBJE |
|---|---|---|
| 选主 | 显式 RequestVote / term / 心跳 | 藏在 `ReplicatedEnvironment` 内部，Doris 只能被动收 `StateChangeListener` |
| 任期号 | `currentTerm` 显式贯穿 | `epochDB` 抢占式生成 epoch，代码里只有 `fencing()` 一处 |
| 复制 | AppendEntries 显式 | `journal.write → currentJournalDB.put`，多数派语义由 BDB 承担 |
| 角色切换 | 代码里能读到完整的转换逻辑 | 只读到"BDB 通知 → 队列 → 分派 → transferToX"，真正的选举看不见 |

所以"不如 Raft 好懂"是因为 **Raft 把一致性算法摆在明面上，而 Doris 把它外包给了 BDBJE，源码里只剩下"用结果"的部分**（fencing、epoch 下发、状态分派）。

## 十、关键文件清单

- `fe/fe-core/.../journal/bdbje/BDBEnvironment.java` — 打开复制组、epochDB、state listener
- `fe/fe-core/.../journal/bdbje/BDBJEJournal.java` — journal 写入 / rollJournal / ReplicaWriteException
- `fe/fe-core/.../ha/BDBHA.java` — `fencing()`
- `fe/fe-core/.../ha/BDBStateChangeListener.java` — BDB 状态 → FE 角色
- `fe/fe-core/.../ha/MasterInfo.java` — master 身份元数据（无 epoch）
- `fe/fe-core/.../catalog/Env.java` — 状态机 `stateListener`(3282)、`transferToMaster`(1735)、`fencing` 调用(1756)、epoch(384/5489)
- `fe/fe-core/.../persist/EditLog.java` — `logEdit`(1675) / `logEditDirectly`(1672, 写失败即 `exit` :1683) / `logCreateDb`(1777) / `logMasterInfo`(1954)
- `fe/fe-core/.../datasource/InternalCatalog.java` — `createDb`(409，先 `unprotectCreateDb` 改内存再写日志) / `unprotectCreateDb`(452) / `replayCreateDb`(463)
- `fe/fe-core/.../system/HeartbeatMgr.java` — `setMaster(...)` 把 epoch 塞进 TMasterInfo
- `gensrc/thrift/HeartbeatService.thrift` — `TMasterInfo.epoch`
- `be/src/agent/heartbeat_server.{h,cpp}` — BE 侧 `_fe_epoch` 校验

## 十一、与 Step 13 的衔接

本文覆盖"元数据为什么先写 EditLog、FE 如何选主与防脑裂"。**具体落库链**（`Env.createDb → InternalCatalog.createDb → EditLog.logCreateDb`）按 `TASK.md` 第 2 节顺序阅读；入口全景见同目录 `NOTES-CREATE-DATABASE-ENTRY.md`。
