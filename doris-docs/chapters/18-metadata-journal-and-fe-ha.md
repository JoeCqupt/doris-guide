# 第 18 章　元数据、日志与 FE 高可用

[全书导航](../README.md) · [术语表](../appendices/A-glossary.md)

> 日期：2026-10-13。源码基线：`a53b182f810be2b3731c7dfdf6f40ff5a0ad63bd`。正文 v1；已核对文中明确分析的关键方法和入口，未启动集群、执行 SQL、运行测试或进行故障实验。示意图不代表本机实测拓扑。

## 18.1 FE 重启后怎么认识原来的表

前面章节反复使用表、分区、Tablet 路由和事务对象。它们在 FE 内存里便于访问，但进程重启会丢失内存状态，因此必须有恢复依据。元数据持久化既要支持快速访问，也要让多个 FE 对已经接受的变更形成一致认识。

这里先区分 FE 元数据与 BE 业务数据。FE 镜像中记录了系统理解表和任务所需的状态，并不是把所有订单的 Segment 文件一起装进去。只备份 FE 镜像不能代替完整的数据备份。

本章主线是当前 FE 的 Image、Journal 和 BDBJE 路径；存算分离还有其他元数据权威来源，不能用这条路径概括全部 Cloud 状态。

## 18.2 Image 与增量日志如何合作

Image 保存某个恢复位置上的元数据快照；Journal 记录之后需要回放的变更。启动恢复可以先加载镜像，再应用后续日志，避免每次从系统创建之初重放全部历史。

```text
Image：已覆盖到日志位置 K 的状态
  + Journal：K 之后的变更记录
  → 恢复到目标位置的元数据状态
```

日志位置不是第 16 章的分区数据版本。两者都带有顺序，但一个组织 FE 变更历史，另一个参与数据发布与读取，不能直接比较或互换。

`Env.loadImage()` 与 `Env.replayJournal()` 是两个阅读入口。具体对象如何写日志及应用日志，需要进一步查对应记录类型和 replay 方法，不能假设所有业务方法都只是自动调用同一套通用状态机。

## 18.3 BDBJE 放在哪一层

`BDBJEJournal` 实现日志的写入、读取和相关管理，提供 `write()`、`read()`、`rollJournal()` 等入口。FE 元数据业务对象并不是每次读取都直接去 BDBJE 查询一行；内存对象、日志和底层复制系统承担不同职责。

你读过 Raft 论文，可以借用“日志复制、主角色、恢复位置”等问题来比较，但不要据此把当前代码称为标准 Raft 状态机。协议、日志组织、业务变更应用时机及锁范围，都需要按实际实现解释。

一条变更可靠返回的边界，应沿业务入口、内存修改、日志写入/等待和失败处理一起确认。第 16 章已经出现日志排队和等待的配置分支，足以说明“赋值之后调用一次 log”不是所有路径的完整模型。

## 18.4 切主不是只改一个角色枚举

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

## 18.5 Checkpoint 如何压缩恢复成本

当前 `Checkpoint` 代码加载已有镜像、回放到选定日志位置、核对回放位置，再保存镜像；之后还有重新加载验证、分发和清理相关处理。Checkpoint 使用相应的恢复环境组织快照，不应想象成随便序列化一个正在被各线程修改的全局对象。

旧日志也不能在新镜像刚写出时随意删除。当前 `deleteOldJournalsAndImages()` 会结合镜像分发与其他节点的日志进度处理清理，代码中明确考虑落后节点仍需旧日志的情况。

因此可观察到几种不同状态：镜像生成失败、镜像验证失败、分发不完整、其他 FE 尚未追上。它们的解决方向不同。手工删除日志或镜像可能破坏恢复条件，不属于常规排障的第一步。

## 18.6 锁、Replay 与演进

元数据对象被查询规划、DDL、后台任务等共同访问。一个改动即使在单线程测试里正确，仍可能破坏锁顺序、恢复时的依赖或旧记录兼容性。

Replay 的输入来自持久化历史，不等同于用户重新提交一遍原 SQL。恢复过程不应随意重做依赖当前外部环境的副作用；实际新增字段、日志类型和默认值要与旧镜像、旧日志的读取行为一起考虑。

旧参考文档中关于历史选型原因或更换复制协议的设想，只能作为讨论素材。本章确认的是当前代码职责，不把这些设想写成项目已经决定的路线。

## 18.7 源码与验证入口

| 路径（相对仓库根目录） | 阅读重点 |
|---|---|
| `fe/fe-core/src/main/java/org/apache/doris/catalog/Env.java` | `loadImage()`、`replayJournal()`、`transferToMaster()` |
| `fe/fe-core/src/main/java/org/apache/doris/journal/bdbje/BDBJEJournal.java` | 日志读写与滚动 |
| `fe/fe-core/src/main/java/org/apache/doris/master/Checkpoint.java` | 镜像生成、验证、分发及清理 |
| `fe/fe-core/src/main/java/org/apache/doris/persist/` | 业务日志类型与恢复相关实现 |
| `fe/fe-core/src/main/java/org/apache/doris/ha/` | HA 协作入口 |

现有测试入口为 `fe/fe-core/src/test/java/org/apache/doris/journal/bdbje/BDBJEJournalTest.java`。单个 Journal 测试不等于多 FE 切主验证；恢复相关修改还需要对应业务对象的序列化/回放测试，必要时用隔离集群验证。本文未运行这些测试。


---

[上一章：第 17 章](17-mvcc-snapshots-and-rowset-lifetime.md) · [全书导航](../README.md) · [下一章：第 19 章](19-node-management-and-maintenance.md)

## 源码深读补充（2026-10-13）

- [专题 5　元数据持久化、维护作业与正常授权链](../deep-dives/05-metadata-maintenance-and-access.md)
- [专题 9　真实 FE 修复复盘：SHOW LOAD 统计为什么在重启后消失](../deep-dives/09-historical-fe-fix.md)
