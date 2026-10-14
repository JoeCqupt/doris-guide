# 第 18 章　元数据、日志与 FE 高可用

[全书导航](../README.md) · [术语表](../appendices/A-glossary.md)

> 教学结构修订：2026-10-14。每章先沿一个问题阅读代码，再做实验、观察结果，最后解释对象和分支。历史正文基线为 `a53b182f810be2b3731c7dfdf6f40ff5a0ad63bd`；本次摘录取自当前本地文件，完整文件 SHA-256 与行号保存在[源码摘录清单](../examples/08-chapter-workshops/source-manifest.json)。运行证据来自报告版本 `doris-0.0.0-a53b182f810` 的二进制，不能仅凭版本前缀认定当前工作目录与二进制逐文件相同。

**本章问题：FE 重启后，为什么还认识原来的表和导入统计？**

本章验证方式：已归档运行证据 + 源码走查；扩展分支见本章边界。建议先用 20—40 分钟完成主案例，第四部分的扩展阅读可分次完成；这不是新增的每日必交任务。

## 一、源码讲解：先找到决定行为的对象和分支

把 Env 看作进程内对象的管理入口，Image/Journal 看作重建这些对象的信息。replayJournal 从已回放位置之后读取增量，不能只因 Java 对象存在于重启前就假定它会恢复。

### 先读这段真实代码

文件：`fe/fe-core/src/main/java/org/apache/doris/catalog/Env.java`，当前文件第 3411—3425 行。下面是连续原文摘录，局部片段省略了方法的其他部分；不要把片段当完整实现。

```java
    public synchronized boolean replayJournal(long toJournalId) {
        long newToJournalId = toJournalId;
        if (newToJournalId == -1) {
            newToJournalId = getMaxJournalId();
        }
        if (newToJournalId <= replayedJournalId.get()) {
            return false;
        }

        LOG.info("replayed journal id is {}, replay to journal id is {}", replayedJournalId, newToJournalId);
        JournalCursor cursor = editLog.read(replayedJournalId.get() + 1, newToJournalId);
        if (cursor == null) {
            LOG.warn("failed to get cursor from {} to {}", replayedJournalId.get() + 1, newToJournalId);
            return false;
        }
```

### 这几行应该怎样读

`toJournalId=-1` 会先换成当前最大日志 ID；已回放位置足够时返回 false；否则从 `replayedJournalId+1` 取游标。这个 false 可以是“没有增量要回放”，并不自动代表数据库损坏。

### FE 重启后怎么认识原来的表

前面章节反复使用表、分区、Tablet 路由和事务对象。它们在 FE 内存里便于访问，但进程重启会丢失内存状态，因此必须有恢复依据。元数据持久化既要支持快速访问，也要让多个 FE 对已经接受的变更形成一致认识。

这里先区分 FE 元数据与 BE 业务数据。FE 镜像中记录了系统理解表和任务所需的状态，并不是把所有订单的 Segment 文件一起装进去。只备份 FE 镜像不能代替完整的数据备份。

本章主线是当前 FE 的 Image、Journal 和 BDBJE 路径；存算分离还有其他元数据权威来源，不能用这条路径概括全部 Cloud 状态。

### Image 与增量日志如何合作

Image 保存某个恢复位置上的元数据快照；Journal 记录之后需要回放的变更。启动恢复可以先加载镜像，再应用后续日志，避免每次从系统创建之初重放全部历史。

```text
Image：已覆盖到日志位置 K 的状态
  + Journal：K 之后的变更记录
  → 恢复到目标位置的元数据状态
```

日志位置不是第 16 章的分区数据版本。两者都带有顺序，但一个组织 FE 变更历史，另一个参与数据发布与读取，不能直接比较或互换。

`Env.loadImage()` 与 `Env.replayJournal()` 是两个阅读入口。具体对象如何写日志及应用日志，需要进一步查对应记录类型和 replay 方法，不能假设所有业务方法都只是自动调用同一套通用状态机。

## 二、动手实验：先预测，再核对

默认使用已保存的实验材料或只读源码，不需要启动服务。运行环境已停止；若选择重新执行 SQL，先按[实验复现说明](../examples/07-live-lab-20261014/REPRODUCE.md)确认服务、版本与数据状态。初始化、导入和更新脚本不可在现有表上盲目重放。

1. 打开 load-before-restart.tsv 与 load-after-restart.tsv，只比较相同 Label 的相同字段，忽略展示顺序和时长等不相关项。
2. 查看 restart-results.json 的三条检查，核对订单、Unique Key 行、Stream Load 行和两条 SHOW LOAD 记录的统计。
3. 进入 Env.replayJournal，标记已回放 ID、目标 ID、读取起点；再沿具体记录的 replay 路径查持久化字段。本章使用已有重启证据，不要求再次停服务。

本章实验材料：[load-before-restart.tsv](../examples/07-live-lab-20261014/load-before-restart.tsv) · [load-after-restart.tsv](../examples/07-live-lab-20261014/load-after-restart.tsv) · [restart-results.json](../examples/07-live-lab-20261014/restart-results.json) · [33-after-restart.out.txt](../examples/07-live-lab-20261014/33-after-restart.out.txt)。

## 三、观察结果：先陈述事实，再划清证据范围

两次服务都经历优雅停止/启动。重启后数据和 Schema 对照通过；两条 Type=INSERT 记录的 ScannedRows 分别 100000、1，LoadBytes 分别 1700000、19，重启前后相同。

这里的 INSERT 是 SHOW LOAD 的 Type 字段：第二条 `label_f9562a491d394d6b_9516eec9bb053a86` 对应实验 27 中的 DELETE（txnId=17），不能把展示分类直接当成原始 SQL 动词。证据是 [DELETE 原始输出](../examples/07-live-lab-20261014/27-delete.out.txt) 与两份 SHOW LOAD 记录中的 Label/TransactionId 对照。

**本章边界：** 单 FE 优雅重启没有验证 BDBJE 多 FE 选主、断电、日志损坏或所有字段兼容。

## 四、回到源码解释：把现象还原成执行过程

replayedJournalId+1 表达增量起点，Image 与后续 Journal 共同重建元数据。某个展示字段能恢复，需要在写日志、反序列化、replay、结果组织各层保留含义。此次正向观察不等于复现过旧版本丢统计缺陷。

### 用自己的话走完这条链

合上结果后，按“输入 → 关键对象/状态 → 分支条件 → 可观察结果”的顺序回答本章问题：**FE 重启后，为什么还认识原来的表和导入统计？** 再指出一项尚不能从现有实验得出的结论。能把每个箭头落到本章的方法或证据，比记住术语更接近读懂源码。

### BDBJE 放在哪一层

`BDBJEJournal` 实现日志的写入、读取和相关管理，提供 `write()`、`read()`、`rollJournal()` 等入口。FE 元数据业务对象并不是每次读取都直接去 BDBJE 查询一行；内存对象、日志和底层复制系统承担不同职责。

你读过 Raft 论文，可以借用“日志复制、主角色、恢复位置”等问题来比较，但不要据此把当前代码称为标准 Raft 状态机。协议、日志组织、业务变更应用时机及锁范围，都需要按实际实现解释。

一条变更可靠返回的边界，应沿业务入口、内存修改、日志写入/等待和失败处理一起确认。第 16 章已经出现日志排队和等待的配置分支，足以说明“赋值之后调用一次 log”不是所有路径的完整模型。

### 切主不是只改一个角色枚举

当前 `Env.transferToMaster()` 有一段很清楚的顺序：停止原回放线程、调整就绪状态、打开 EditLog，在 BDB 路径下执行 fencing，回放日志，再继续后续准备。

```mermaid
flowchart LR
    A[角色转换触发] --> B[停止原回放线程]
    B --> C[调整可读与就绪状态]
    C --> D[打开日志并进行适用的 fencing]
    D --> E[回放日志]
    E --> F[继续 Master 初始化]
```

这只是方法中的关键片段，不是完整选举协议。它说明“成为候选主角色”和“完成恢复、能够承担相应服务”之间还有准备过程。遇到切主后短暂不可用，应看转换进度与恢复状态，而不是只检查进程是否存在。

Follower/Observer 等角色如何回放和提供读取还需结合 `transferToNonMaster()` 与相关线程。不同 FE 的元数据观察存在同步过程，这也解释了第 4 章为什么有转发和 Journal 同步相关分支。

### Checkpoint 如何压缩恢复成本

当前 `Checkpoint` 代码加载已有镜像、回放到选定日志位置、核对回放位置，再保存镜像；之后还有重新加载验证、分发和清理相关处理。Checkpoint 使用相应的恢复环境组织快照，不应想象成随便序列化一个正在被各线程修改的全局对象。

旧日志也不能在新镜像刚写出时随意删除。当前 `deleteOldJournalsAndImages()` 会结合镜像分发与其他节点的日志进度处理清理，代码中明确考虑落后节点仍需旧日志的情况。

因此可观察到几种不同状态：镜像生成失败、镜像验证失败、分发不完整、其他 FE 尚未追上。它们的解决方向不同。手工删除日志或镜像可能破坏恢复条件，不属于常规排障的第一步。

### 锁、Replay 与演进

元数据对象被查询规划、DDL、后台任务等共同访问。一个改动即使在单线程测试里正确，仍可能破坏锁顺序、恢复时的依赖或旧记录兼容性。

Replay 的输入来自持久化历史，不等同于用户重新提交一遍原 SQL。恢复过程不应随意重做依赖当前外部环境的副作用；实际新增字段、日志类型和默认值要与旧镜像、旧日志的读取行为一起考虑。

旧参考文档中关于历史选型原因或更换复制协议的设想，只能作为讨论素材。本章确认的是当前代码职责，不把这些设想写成项目已经决定的路线。

### 源码与验证入口

| 路径（相对仓库根目录） | 阅读重点 |
|---|---|
| `fe/fe-core/src/main/java/org/apache/doris/catalog/Env.java` | `loadImage()`、`replayJournal()`、`transferToMaster()` |
| `fe/fe-core/src/main/java/org/apache/doris/journal/bdbje/BDBJEJournal.java` | 日志读写与滚动 |
| `fe/fe-core/src/main/java/org/apache/doris/master/Checkpoint.java` | 镜像生成、验证、分发及清理 |
| `fe/fe-core/src/main/java/org/apache/doris/persist/` | 业务日志类型与恢复相关实现 |
| `fe/fe-core/src/main/java/org/apache/doris/ha/` | HA 协作入口 |

现有测试入口为 `fe/fe-core/src/test/java/org/apache/doris/journal/bdbje/BDBJEJournalTest.java`。单个 Journal 测试不等于多 FE 切主验证；恢复相关修改还需要对应业务对象的序列化/回放测试，必要时用隔离集群验证。本文未运行这些测试。

### 延伸源码专题

- [专题 5　元数据持久化、维护作业与正常授权链](../deep-dives/05-metadata-maintenance-and-access.md)
- [专题 9　真实 FE 修复复盘：SHOW LOAD 统计为什么在重启后消失](../deep-dives/09-historical-fe-fix.md)

---

[全书导航](../README.md) · [术语表](../appendices/A-glossary.md)
