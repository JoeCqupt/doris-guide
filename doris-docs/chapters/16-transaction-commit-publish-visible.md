# 第 16 章　事务精读：从提交决定到查询可见

[全书导航](../README.md) · [写入路径](15-physical-write-path.md) · [源码来源记录](../examples/06-transaction-visible/source-map.json)

> 教学结构修订：2026-10-14。每章先沿一个问题阅读代码，再做实验、观察结果，最后解释对象和分支。历史正文基线为 `a53b182f810be2b3731c7dfdf6f40ff5a0ad63bd`；本次摘录取自当前本地文件，完整文件 SHA-256 与行号保存在[源码摘录清单](../examples/08-chapter-workshops/source-manifest.json)。运行证据来自报告版本 `doris-0.0.0-a53b182f810` 的二进制，不能仅凭版本前缀认定当前工作目录与二进制逐文件相同。

**本章问题：PRECOMMITTED、COMMITTED、VISIBLE 分别允许我们得出什么结论？**

本章验证方式：已归档运行证据 + 源码走查；扩展分支见本章边界。建议先用 20—40 分钟完成主案例，第四部分的扩展阅读可分次完成；这不是新增的每日必交任务。

## 一、源码讲解：先找到决定行为的对象和分支

用两个独立实验回答两个问题：2PC 看“接收数据后尚未最终提交”的可见性；双分区 INSERT 看“一个事务推进多个分区”。不要把 PRECOMMITTED 当 COMMITTED，也不要把字段赋值那一行当作所有观察者已看到新状态。

### 先读这段真实代码

文件：`fe/fe-core/src/main/java/org/apache/doris/transaction/DatabaseTransactionMgr.java`，当前文件第 1358—1369 行。下面是连续原文摘录，局部片段省略了方法的其他部分；不要把片段当完整实现。

```java
            try {
                transactionState.afterStateTransform(TransactionStatus.VISIBLE, txnOperated);
            } catch (Throwable e) {
                LOG.warn("afterStateTransform txn {} failed. exception: ", transactionState, e);
            }
            if (txnOperated) {
                awaitTransactionState(logItem, transactionState);
            }
            updateCatalogAfterVisible(transactionState, db, partitionVisibleVersions, backendPartitions);
        } finally {
            MetaLockUtils.writeUnlockTables(tableList);
        }
```

### 这几行应该怎样读

`afterStateTransform` 是回调阶段，异常在此记录；`awaitTransactionState` 是状态日志等待；随后 `updateCatalogAfterVisible` 更新可见目录。`finally` 中释放表锁。这一小段必须与前面的版本/副本检查一起读，不能只截取更新目录一行推导提交顺序。

### 先固定问题与数据

一次导入 X 写表 T 的两个分区 P、Q。BE 已返回 TabletCommitInfo，FE 接下来提交并等待可见。设初始状态：

| 对象 | 初始值 |
|---|---|
| transactionId | X=700，仅教学编号 |
| T | tableId=100 |
| P | partitionId=10，visibleVersion=9，nextVersion=10 |
| Q | partitionId=20，visibleVersion=20，nextVersion=21 |
| 每 Tablet | 示例配置要求的成功副本数为 2；不是所有环境的固定值 |
| X 状态 | PREPARE；BE 写入结果已准备供 FE 检查 |

目标不是计算 SQL 的业务金额，而是回答：**什么对象记录了 P=10、Q=21，什么时候只是预留了这些版本，什么时候查询能按这些版本读？**

再安排下一笔事务 Y 只写 P，它可能随后取得 P 的版本 11。若 Y 的物理发布比 X 快，能不能直接把 P 从 9 推进到 11？本章会用真实条件解释。

### 对象表：版本不都在一个地方

| 对象/字段 | 保存什么 | 主例 |
|---|---|---|
| `TabletCommitInfo` | 提交侧返回的 Tablet 与 BE 身份 | 哪个 Tablet 在哪个 BE 完成适用写入 |
| `TransactionState` | 事务身份、状态、错误副本、提交信息、发布任务与等待设施 | X，PREPARE/COMMITTED/VISIBLE |
| `idToTableCommitInfos` | tableId → TableCommitInfo | 100 → T 的提交信息 |
| `TableCommitInfo.idToPartitionCommitInfo` | partitionId → PartitionCommitInfo | 10→version10；20→version21 |
| `Partition.nextVersion` | 后续提交分配所需的版本位置 | X 提交后 P=11、Q=22 |
| `Partition.visibleVersion` | 当前目录中对读取可见的分区版本 | X 可见前仍为 P=9、Q=20 |
| `publishVersionTasks` | BE 发布任务及完成结果 | 需要检查到 Tablet 级成功信息 |
| `visibleLatch` | 提交等待者使用的 CountDownLatch | 与状态值的读取共同决定等待结果 |

Txn ID 与分区版本不相等。一笔 X 可对应 P 的 10 和 Q 的 21；不同分区的数字空间独立。表级版本又是其他元信息，不能把所有 `version` 字段混在一个时间线上。

从对象关系可以理解为何 FE 不必在 TransactionState 里保留整批订单行：数据已沿 BE 写入路径处理，这里主要保存完成协调所需身份、版本和状态。

### 三条执行链，而不是一个超长同步调用

```text
客户端请求线程：
GlobalTransactionMgr.commitAndPublishTransaction
  → 取得相关表写锁
  → commitTransactionWithoutLock → DatabaseTransactionMgr.commitTransaction
  → 释放表写锁
  → waitForTransactionFinished（等待可见）

后台发布流程：
PublishVersionDaemon.publishVersion
  → 遍历待发布事务、构建/分发 PublishVersionTask
  → tryFinishTxn / tryFinishOneTxn（包含同步/异步推进分支）
  → GlobalTransactionMgr.finishTransaction → DatabaseTransactionMgr.finishTransaction

BE 发布与报告：
执行 Publish 任务 → 处理本地 Rowset/版本 → 回报任务结果
  → FE 保存对应任务的成功 Tablet / 失败信息
```

这里明确区分直接调用、任务分发与回报。后台进度不受单个客户端等待窗口直接控制：客户端等待结束不等于发布线程停止。BE 的具体动作接回第 15 章，本章不把 FE 分发任务画成一次已成功完成的远程调用。

## 二、动手实验：先预测，再核对

默认使用已保存的实验材料或只读源码，不需要启动服务。运行环境已停止；若选择重新执行 SQL，先按[实验复现说明](../examples/07-live-lab-20261014/REPRODUCE.md)确认服务、版本与数据状态。初始化、导入和更新脚本不可在现有表上盲目重放。

1. 顺序打开 20、21、22、23、24：记下 TxnId=10 与每个观察时刻的状态/行数，先画一条真实时间线。
2. 另开一张卡读 26：写下 txnId=16、p1/p2 的 1→2，把它与第一张卡分开。
3. 沿 DatabaseTransactionMgr.finishTransaction 查版本/副本检查、状态日志、updateCatalogAfterVisible 和唤醒；用下文原码与单测推演补上本次没有制造的失败分支。

本章实验材料：[20-two-phase-precommit.response.json](../examples/07-live-lab-20261014/20-two-phase-precommit.response.json) · [21-before-2pc-commit.out.txt](../examples/07-live-lab-20261014/21-before-2pc-commit.out.txt) · [22-transaction-precommitted.out.txt](../examples/07-live-lab-20261014/22-transaction-precommitted.out.txt) · [23-two-phase-commit.response.json](../examples/07-live-lab-20261014/23-two-phase-commit.response.json) · [24-after-2pc-commit.out.txt](../examples/07-live-lab-20261014/24-after-2pc-commit.out.txt) · [26-partition-table.out.txt](../examples/07-live-lab-20261014/26-partition-table.out.txt)。

## 三、观察结果：先陈述事实，再划清证据范围

TxnId=10：precommit 响应成功，SHOW TRANSACTION 为 PRECOMMITTED，此时 3 行/60；最终 commit 成功后 6 行/120。TxnId=16：双分区由 VisibleVersion=1 变成 2，各读到一行。

### 两组实测记录分开看

| 记录 | 操作后状态 | 查询观察 | 可以得出的结论 |
|---|---|---|---|
| TxnId=10，第一阶段 | PRECOMMITTED | 3 行，合计 60 | 接收成功不等于新数据可见 |
| TxnId=10，最终 commit 后 | 提交接口成功且新数据可读 | 6 行，合计 120 | 本次三行写入已进入可读结果 |
| TxnId=16，双分区 INSERT | 客户端 VISIBLE | p1/p2 各一行，版本各为 2 | 这次写入推进了两个分区 |

这些结果不包含单独观察到的 COMMITTED 等待窗口；该窗口的条件由下文源码与测试案例解释。

**本章边界：** 没有实测副本不足、COMMITTED 等待超时或并发提交乱序；本次只有单副本。

## 四、回到源码解释：把现象还原成执行过程

PRECOMMITTED 说明 2PC 第一阶段完成，并不允许把数据计入当前读视图。最终提交后还涉及发布和可见目录。finishTransaction 的 awaitTransactionState 与 updateCatalogAfterVisible 表明状态持久化和目录更新是需要区分的步骤；下面继续展开锁范围与副本条件。

### 用自己的话走完这条链

合上结果后，按“输入 → 关键对象/状态 → 分支条件 → 可观察结果”的顺序回答本章问题：**PRECOMMITTED、COMMITTED、VISIBLE 分别允许我们得出什么结论？** 再指出一项尚不能从现有实验得出的结论。能把每个箭头落到本章的方法或证据，比记住术语更接近读懂源码。

### 提交入口：表锁包住哪些工作

普通重载的 `commitAndPublishTransaction()` 启动 StopWatch，获得 TransactionState，使用 `buildLockTableList()` 确定锁列表，并调用带超时的表写锁工具。取得失败会抛异常，不会进入下面提交块。

主例没有额外 stream update，所以 `buildLockTableList()` 返回传入的 tableList；源码在需要额外流表时才另建排序集合。不能把这个 helper 说成所有情况下都会重新排序传入列表。本例只有一张表，无多表顺序歧义。

```java
    try {
        commitTransactionWithoutLock(db.getId(), tableList, transactionId, tabletCommitInfos, txnCommitAttachment);
    } finally {
        MetaLockUtils.writeUnlockTables(tableList);
    }
}

private void commitTransaction2PC(long dbId, long transactionId)
        throws UserException {
    if (Config.disable_load_job) {
        throw new TransactionCommitFailedException("disable_load_job is set to true, all load jobs are prevented");
    }

    DatabaseTransactionMgr dbTransactionMgr = getDatabaseTransactionMgr(dbId);
    dbTransactionMgr.commitTransaction(null, transactionId, null, null, true);
}

public boolean commitAndPublishTransaction(DatabaseIf db, List<Table> tableList, long transactionId,
        List<TabletCommitInfo> tabletCommitInfos, long timeoutMillis)
        throws UserException {
    return commitAndPublishTransaction(db, tableList, transactionId, tabletCommitInfos, timeoutMillis, null);
}

public boolean commitAndPublishTransaction(DatabaseIf db, List<Table> tableList, long transactionId,
        List<TabletCommitInfo> tabletCommitInfos, long timeoutMillis,
        TxnCommitAttachment txnCommitAttachment)
        throws UserException {
    DatabaseTransactionMgr dbTransactionMgr = getDatabaseTransactionMgr(db.getId());
    StopWatch stopWatch = new StopWatch();
    stopWatch.start();
    TransactionState transactionState = dbTransactionMgr.getTransactionState(transactionId);
    List<Table> lockTableList = buildLockTableList(tableList, transactionState);
    if (!MetaLockUtils.tryWriteLockTablesOrMetaException(lockTableList, timeoutMillis, TimeUnit.MILLISECONDS)) {
        throw new UserException("get tableList write lock timeout, tableList=("
                + StringUtils.join(lockTableList, ",") + ")");
    }
    try {
        commitTransactionWithoutLock(db.getId(), tableList, transactionId, tabletCommitInfos, txnCommitAttachment);
    } finally {
        MetaLockUtils.writeUnlockTables(lockTableList);
    }
    stopWatch.stop();
    long publishTimeoutMillis = timeoutMillis - stopWatch.getTime();
    if (publishTimeoutMillis < 0) {
        // here commit transaction successfully cost too much time
        // to cause that publishTimeoutMillis is less than zero,
        // so we just return false to indicate publish timeout
        return false;
    }
    return dbTransactionMgr.waitForTransactionFinished(db, transactionId, publishTimeoutMillis);
```

出处：`fe/fe-core/src/main/java/org/apache/doris/transaction/GlobalTransactionMgr.java`，本次读取行 287 起（原文节选）。

依次看四个事实：

1. 实际提交发生在外层表写锁内；方法名中的 WithoutLock 表示调用方已经负责相应锁，不能脱离上文随处调用。
2. finally 先释放表写锁，再进行可见性等待。
3. 等待预算要扣除取得锁及提交等已耗时间。
4. `publishTimeoutMillis < 0` 时返回 false；源码注释明确此时提交已经成功，只是提交消耗时间超过等待预算。

假设请求预算 1000ms，提交消耗 1200ms，返回 false 不能翻译为“什么都没写，换 Label 重试”。假设提交仅消耗 200ms，剩余 800ms 用于等待。数字仅展示控制流，不承诺调度器或等待循环绝对精确到这个上限。

异常也必须按发生阶段解释。锁未取得与提交后的持久化/回调失败不是同一种结果；一旦缺少完整响应，先查询原事务状态。

### 从提交结果到分区版本：按代码顺序构造

`DatabaseTransactionMgr.commitTransaction()` 先在管理器读锁内取 TransactionState，释放读锁后检查前态和提交信息。普通非 2PC 路径通过 `checkCommitStatus()` 组织：

```text
tableToPartition       = {T → {P,Q}}
errorReplicaIds        = 失败副本身份集合
totalInvolvedBackends  = 参与的 BE 集合
```

前态、表和 Tablet/副本要求不满足时不会直接构造 COMMITTED 成功结果。源码还在回调之前取得适用的 commitTSO，并在进入事务对象 monitor 后重新检查状态；这个重检防止前面准备工作期间状态已经被别的路径改变。主例不展开 TSO 算法，但不会从代码流程图中删除它的同步影响。

`beforeStateTransform(COMMITTED)` 在转换前执行。进入 `synchronized(transactionState)` 后，普通路径调用 `unprotectedCommitTransaction(...)`。该方法对每张表创建 TableCommitInfo，对每个分区以 `partition.getNextVersion()` 建立 PartitionCommitInfo。

因此主例在转换前应形成：

```text
X.idToTableCommitInfos = {
  100: TableCommitInfo {
    10: PartitionCommitInfo(version=10),
    20: PartitionCommitInfo(version=21)
  }
}
```

接着才执行：

```java
// set COMMITTED only after idToTableCommitInfos is fully populated, so that
// PublishVersionDaemon (which checks status without synchronized(transactionState))
// will never see COMMITTED with empty commit info.
transactionState.setTransactionStatus(TransactionStatus.COMMITTED);
// Update in-memory state only; caller handles edit log persistence
unprotectUpdateInMemoryState(transactionState, false);
transactionState.setInvolvedBackends(totalInvolvedBackends);
```

出处：`fe/fe-core/src/main/java/org/apache/doris/transaction/DatabaseTransactionMgr.java`，本次读取行 1760 起（原文节选）。

注释直接解释了顺序：发布后台检查状态时不一定同步在同一个 transactionState monitor 上，不能让它先看到 COMMITTED、后看到空的提交信息。这里建立的是特定字段的发布顺序约束，不是说这一行之后所有目录、日志和远端状态都完成了。

`unprotectUpdateInMemoryState()` 更新事务管理器中的状态组织；实际日志工作由调用方处理。方法名 unprotected 的含义要结合调用者，不能据此推断无同步。

### 三种锁范围与持久化等待

本条提交链涉及的同步范围不同：

| 同步对象 | 本次看到的作用域 | 不能混淆的地方 |
|---|---|---|
| 外层相关表写锁 | commitAndPublishTransaction 取得，提交调用返回后释放 | 直到释放前，内层很多步骤仍在它的范围内 |
| DatabaseTransactionMgr 读锁 | 查找 TransactionState 的短临界区 | 不是把整个提交包在这个读锁里 |
| transactionState monitor | 前态重检、状态转换及相应日志提交动作 | after 回调与异步日志 await 位于此 monitor 外 |

调用方根据 `Config.enable_txn_log_outside_lock` 选择：

```text
true： monitor 内 enqueueTransactionState → monitor 外 awaitTransactionState
false：monitor 内 persistTransactionState → 没有异步句柄可等待
```

`enqueueTransactionState()` 调用 `editLog.submitEdit(...)` 返回 EditLogItem；`awaitTransactionState()` 对非空 item 调用 await。回调 `afterStateTransform(COMMITTED, txnOperated)` 在 finally 中执行，位于事务 monitor 外，再按实际转换结果等待日志。

**移出 transactionState monitor，不等于已释放所有表锁。** 外层表写锁要等提交调用返回后才释放。分析配置效果必须把调用栈展开，不能只照搬方法注释中的“outside lock”一句话。这里是描述现有作用域，不提出锁重构或缺陷结论。

日志处理之后 `updateCatalogAfterCommitted()` 调用 `updatePartitionNextVersion()`。主例 nextVersion 变为 P=11、Q=22，而 visibleVersion 仍是 P=9、Q=20。这给后续提交留位置，尚未让读路径使用 X 的数据。

### 发布完成检查：先版本，再副本

`PublishVersionDaemon.publishVersion()` 取得待发布事务，读取包含不存活节点的 BE 列表，组织任务并尝试完成。当前代码明确不把“没有向某 BE 发送任务”当成成功证据；每一相关任务仍需要结果解释。

`DatabaseTransactionMgr.finishTransaction()` 取得相关表并按 ID 顺序组织列表，尝试取得表写锁。主例没有子事务，所以进入普通分支：

```text
finishCheckPartitionVersion
  → 如果不满足，return
finishCheckQuorumReplicas
  → 如果结果 FAILED，return
状态转换、日志、更新可见目录
```

普通版本条件原文：

```java
if (partition.getVisibleVersion() != partitionCommitInfo.getVersion() - 1) {
    if (LOG.isDebugEnabled()) {
        LOG.debug("for table {} partition {}, transactionId {} partition commitInfo version {} is not"
                                + " equal with partition visible version {} plus one, need wait",
                table.getId(), partition.getId(), transactionState.getTransactionId(),
                partitionCommitInfo.getVersion(), partition.getVisibleVersion());
    }
    String errMsg = String.format("wait for publishing partition %d version %d."
                    + " self version: %d. table %d", partitionId, partition.getVisibleVersion() + 1,
            partitionCommitInfo.getVersion(), tableId);
    transactionState.setErrorMsg(errMsg);
    return false;
}
```

出处：`fe/fe-core/src/main/java/org/apache/doris/transaction/DatabaseTransactionMgr.java`，本次读取行 1460 起（原文节选）。

对于 X：P 的 9 等于 10−1，Q 的 20 等于 21−1，版本条件均可通过。对于 Y：若 P 仍是 9，则 9 不等于 11−1，Y 必须等待，不会用“11 的文件先好了”绕开 10。

失败时方法写入事务错误信息并返回 false。它没有在这个检查处先更新 P 再发现 Q 不满足；相关目录更新发生在后续阶段。但由此仍不能推导所有跨表查询模式的快照隔离，查询如何固定版本需结合第 17 章。

源码对已经删除的表或分区还有移除提交信息后跳过的分支。主例保持对象存在，因此版本表更清楚；不要将主例的所有对象必检推广到删除对象路径。

### 副本检查要落到 Tablet，不是数 RPC 成功次数

`finishCheckQuorumReplicas()` 遍历相关分区、适用索引和 Tablet，取得该分区的 `getLoadRequiredReplicaNum()`。对每个副本，`checkReplicaContinuousVersionSucc()` 结合任务完成情况、成功 Tablet 集合、错误副本集合及历史版本追赶情况分类。

以主例一个 Tablet 的三个副本为例：

| 副本 | 当前发布任务 | 旧版本连续性 | 不能仅凭什么计成功 |
|---|---|---|---|
| A | 已完成且含该 Tablet | 能追上所需前序版本 | 不能只看 BE 存活 |
| B | 已完成且含该 Tablet | 能追上所需前序版本 | 不能只看 RPC 返回码 |
| C | 未提供成功 Tablet 证据 | 另需检查其已报告版本等分支 | 不能只看目标文件存在 |

源码也允许已经达到目标版本的副本经适用分支计为成功，还对 ALTER 副本有专门条件。因此表格是普通判定维度，不是对整个函数的等价替代。

常规分支下，健康成功数达到该 Tablet 的要求才满足副本条件。P 的 Tablet 成功两份、Q 的 Tablet 只成功一份，不能用全事务累计三份成功掩盖 Q 的不足。

#### 一个必须明确的额外分支：等待足够久后

```java
long now = System.currentTimeMillis();
long firstPublishVersionTime = transactionState.getFirstPublishVersionTime();
boolean allowPublishOneSucc = false;
if (Config.publish_wait_time_second > 0 && firstPublishVersionTime > 0
        && now >= firstPublishVersionTime + Config.publish_wait_time_second * 1000L) {
    allowPublishOneSucc = true;
}
```

出处：`fe/fe-core/src/main/java/org/apache/doris/transaction/DatabaseTransactionMgr.java`，本次读取行 1545 起（原文节选）。

启用且达到 `publish_wait_time_second` 的条件后，`checkQuorumReplicas()` 在 `allowPublishOneSucc && healthReplicaNum > 0` 时可以返回 TIMEOUT_SUCC；否则数量不足是 FAILED。`finishTransaction()` 将 FAILED 作为不能继续的结果，所以“任何时候都必须等通常 quorum”也不是完整描述。

本章数值主例固定为未进入这个超时分支，不修改配置。客户端等待预算与这个发布策略阈值是两个不同计时问题，不能看到客户端超时就断言已启用 TIMEOUT_SUCC。改变该策略会影响可用性与失败容忍边界，不是为了让教学样例完成就随手设置的参数。

### VISIBLE：状态、目录、唤醒按什么顺序发生

普通 finish 在相关表写锁内通过前述检查后，进入 transactionState monitor，设置错误副本集合、finishTime、清理错误信息、设为 VISIBLE、处理表版本和内存事务状态，再选择日志处理路径。

退出 monitor 后执行 VISIBLE 回调、等待适用日志，然后调用 `updateCatalogAfterVisible()`。这个方法更新副本信息与分区/表的可见版本，并更新一些统计相关状态。主例完成后的稳定值如下：

| 观察时刻 | X 状态 | P visible / next | Q visible / next |
|---|---|---|---|
| 提交前 | PREPARE | 9 / 10 | 20 / 21 |
| X 提交后，Y 尚未提交 | COMMITTED | 9 / 11 | 20 / 22 |
| Y 随后提交，只写 P | X 仍 COMMITTED | 9 / 12 | 20 / 22 |
| X 完成可见，Y 尚未完成 | VISIBLE | 10 / 12 | 21 / 22 |
| Y 再通过检查并完成 | X、Y 均 VISIBLE | 11 / 12 | 21 / 22 |

注意这里是各阶段完成后的观察表，不意味着中间每个字段同时原子改变。源码先设状态，再处理日志与可见目录，所以不能看到 `setTransactionStatus(VISIBLE)` 就宣称所有后续动作已完成。查询侧读取与表锁的配合同样重要。

`finishTransaction()` 最后释放表锁，处理适用事件，再调用 `countdownVisibleLatch()`。`TransactionState` 构造的 latch 初始计数为 1，等待方法调用带超时的 await。唤醒设施与状态轮询共同工作，方法返回以实际状态为依据。

等待循环原文：

```java
while (currentTimeMillis < timeoutTimeMillis
        && transactionState.getTransactionStatus() == TransactionStatus.COMMITTED) {
    try {
        transactionState.waitTransactionVisible(timeoutMillis);
    } catch (InterruptedException e) {
        // CHECKSTYLE IGNORE THIS LINE
    }
    currentTimeMillis = System.currentTimeMillis();
}
return transactionState.getTransactionStatus() == TransactionStatus.VISIBLE;
```

出处：`fe/fe-core/src/main/java/org/apache/doris/transaction/DatabaseTransactionMgr.java`，本次读取行 1072 起（原文节选）。

进入循环之前方法只接受 COMMITTED/VISIBLE，其他状态会抛 TransactionCommitFailedException。返回值回答“检查时是否为 VISIBLE”。当前循环每次传入原 timeoutMillis；不应将外层预算描述成严格实时上限，也不在没有复现的情况下把它宣布为产品 bug。

### 两个真实测试怎样证明这条链

阅读文件 `fe/fe-core/src/test/java/org/apache/doris/transaction/GlobalTransactionMgrTest.java`。这些测试用 FakeEnv/FakeEditLog 和测试目录对象模拟 FE，不是连接真实多 BE 集群。

#### testFinishTransaction

测试步骤依次是：

1. begin，构造 TabletCommitInfo 并提交，检查日志里状态为 COMMITTED，再在 follower 模拟环境回放。
2. 用 `setSuccessTablet()`、`setTransactionFinishPublish()` 构造发布完成信息，调用 finishTransaction。
3. 断言 VISIBLE；分区 visibleVersion 为起始版本+1、nextVersion 为起始版本+2；检查各副本版本。
4. 检查 partitionVisibleVersions / backendPartitions 输出映射，回放新状态，并比较两份目录。

测试中有一个副本仍保持起始版本，其他副本向前推进。它说明在该夹具与配置下，VISIBLE 不等于每个副本都已经追上；它并没有真的让三台 BE 发生网络传输。

#### testFinishTransactionWithOneFailed：只展开第一组场景

该测试较长，本章分析它第一组“BE1、BE2 写入成功，BE2 第一次发布未成功”的步骤：

| 步骤 | 修改的模拟状态 | 断言 |
|---|---|---|
| 提交 | BE1/BE2 的写入提交信息 | follower 回放后目录可比较 |
| 第一次 finish | 只有 BE1 被标记为成功发布 | 事务仍 COMMITTED；两个可见性输出 Map 为空 |
| 检查副本 | 未达到可见推进条件 | 副本版本保持对应旧状态及失败版本信息 |
| 补充成功证据 | BE2 的 PublishVersionTask 设置 succTablets | 再次 finish |
| 第二次 finish | 达到夹具所需条件 | VISIBLE；BE1/BE2 前进，BE3 保持落后 |

核心证据是同一事务、同一流程，在改变明确的 Tablet 成功信息前后，状态从不能完成变成能完成。只断言最后 VISIBLE，会失去第一阶段“应该继续等待”的保障。

这些测试还不能证明磁盘持久化掉电恢复、客户端断连重试或所有配置组合。本章选择具体断言来解释代码，没有把测试名、存在性或未运行的结果当作通过证明。

### 三个失败窗口与实际排查动作

| 失败/等待窗口 | 已知状态 | 下一步证据 | 避免的错误操作 |
|---|---|---|---|
| 取得表锁前失败 | 尚未执行这次提交调用 | 锁错误与原事务状态 | 把任何异常都视作已提交 |
| COMMITTED 后客户端等待结束 | 提交决定可能已成立 | 原 Txn ID/Label、状态和发布记录 | 新 Label 无条件重传造成重复 |
| 某分区版本未连续 | 后序版本不能通过 finish 检查 | 对应分区 visible 与 commit version、前序事务 | 手工把 visibleVersion 改到目标值 |
| Tablet 成功证据不足 | 常规发布条件未满足 | 任务 succTablets、错误副本、旧版本追赶 | 将全局成功节点数当作每 Tablet 条件 |
| 日志等待/回调异常 | 需按调用位置判断 | 原日志、事务状态及目录观察 | 仅凭抛异常认定持久化不存在 |

上述是诊断顺序，本轮没有制造这些故障。普通事务阶段的正确理解，应先服务于读日志、定位实现和构造有效测试，而不是直接改状态字段。

### 本章达到哪里

这次把普通提交与 finish 的代表性路径展开到了对象、具体版本、原码条件、锁范围、唤醒顺序和已有测试断言。Begin 的 Label 去重全流程、全部提交副本策略、BE 物理发布细节、日志底层可靠性仍分别需要其他章节支撑；不把这个案例当作整个事务系统已精读完毕。

[本章证据材料](../examples/06-transaction-visible/README.md)记录文件摘要与原文摘录。需要验证时使用仓库 `run-fe-ut.sh --run` 选择 `org.apache.doris.transaction.GlobalTransactionMgrTest` 的相关测试方法；具体环境按项目要求准备。本轮没有运行这些测试，也没有构建 Doris。

---

[全书导航](../README.md) · [写入路径](15-physical-write-path.md) · [源码来源记录](../examples/06-transaction-visible/source-map.json)
