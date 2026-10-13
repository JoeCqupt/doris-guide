# 专题 5　元数据持久化、维护作业与正常授权链

[全书导航](../README.md) · [专题导航](README.md)

> 源码基线：`a53b182f810be2b3731c7dfdf6f40ff5a0ad63bd`；补写日期：2026-10-13。以下为源码分析与标明的教学推演，未运行对应功能测试。仓库路径均相对 `/Users/jiangyuan/open/doris`。

## 1. CREATE DATABASE 的对象、锁和日志

`fe/fe-core/src/main/java/org/apache/doris/datasource/InternalCatalog.java` 的 `createDb()` 先分配 ID、建立 Database、检查属性，再获取 Catalog 锁，检查同名库。成功分支取得 Database 写锁，调用 `unprotectCreateDb()`，再用 `CreateDbInfo` 调用 `EditLog.logCreateDb()`；finally 释放两层锁。

`unprotectCreateDb()` 更新 idToDb、fullNameToDb，并建立对应的数据库事务管理器。它不是单纯往一个 Map 填值。持久化内容包含库名、Catalog 信息以及恢复所需 Database 数据，定义见 `persist/CreateDbInfo.java`。

这里先修改内存再记录日志，不能据此概括成所有 DDL 都遵循“先日志后内存”。应把失败处理、日志确认和对外返回一起检查，也不能把拿到锁当成持久化完成。

## 2. 回放不是重新执行用户 SQL

`persist/EditLog.java` 中 `logCreateDb()` 对应新创建库操作类型；回放 switch 同时保留历史 OP_CREATE_DB 与较新的操作。旧格式兼容路径的存在说明：改 Java 字段名、修改序列化键或删除分支，可能影响旧 Image/Journal 恢复。

Replay 使用已有 ID 和日志内容恢复状态，不应重新分配 ID，也不应再次把同一个事件写入 Journal。否则恢复会改变对象身份或不断产生新日志。看 `InternalCatalog.replayCreateDb()` 时要把它与正常 `createDb()` 对照，而不是只看两个方法是否最终创建了 Database。

一个可靠恢复测试应保存“重启前对象 ID、属性、数据/统计”，然后重启、重连再比较。只测试当前内存中的 getter，发现不了缺少序列化字段；[专题 9 的真实修复](09-historical-fe-fix.md) 正是这个问题。

## 3. 修复副本不是从任意机器拷一份文件

第 19 章的 TabletScheduler 要把健康判断转成具体任务：目标 Tablet 缺的是副本、版本还是位置约束；源副本是否包含所需版本；目标 BE 是否有合适磁盘与调度资源。Clone 执行后还要依据报告更新 FE 的副本状态，派出任务不等于修复完成。

用事件表检查一次修复：

| 时刻 | 必须能回答 |
|---|---|
| 发现异常 | 哪个 Tablet、哪种健康状态、期望副本数是多少？ |
| 选择源/目标 | 源版本是否足够，目标资源/位置是否满足约束？ |
| 执行 Clone | 任务身份是什么，超时或失败如何重试？ |
| 接收完成报告 | 报告是否对应当前任务，版本是否满足要求？ |
| 再次健康检查 | FE 看到的副本集合是否真正恢复？ |

这是阅读和排障顺序，不是在本次模拟了故障。恢复实验必须有多副本环境；单 BE 的订单实验不能证明副本修复能力。

## 4. Backup 与 Restore 的两套状态机

`backup/BackupJob.java` 的状态明确区分：

```text
PENDING → SNAPSHOTING → UPLOAD_SNAPSHOT → UPLOADING
        → SAVE_META → UPLOAD_INFO → FINISHED
```

先获取快照和复制元信息，再上传数据，最后保存并上传元信息/作业信息。上传完成处理还会比较预期与实际文件集合。只看到远端有几个文件，无法宣布备份可恢复。

`backup/RestoreJob.java` 则是：

```text
PENDING → CREATING → SNAPSHOTING → DOWNLOAD → DOWNLOADING
        → COMMIT → COMMITTING → FINISHED
```

下载完成意味着数据准备好，之后仍有使其生效的阶段。两套作业都存在 CANCELLED；它们与查询取消、导入事务 ABORTED 的状态所有者不同。恢复验证应在独立目标上核对结构、行数、关键聚合和作业状态，不能只检查备份目录大小。

## 5. 一次普通 SELECT 的权限检查

身份认证建立 ConnectContext 的用户身份；后续分析绑定明确被访问的表与列，再决定授权是否满足。Nereids 的具体入口是 `nereids/rules/rewrite/CheckPrivileges.java`：`rewriteRoot()` 获取 StatementContext，遍历计划，完成后设置 privChecked；`visitLogicalRelation()` 对 CatalogRelation 调用 `checkColumnPrivileges()`，使用真实表对象和所需列。

示例 `SELECT amount FROM orders WHERE city='Beijing'` 同时读取输出列 amount 和条件列 city。仅从 SELECT 列表猜权限需求是不够的。View 与 CTE 有自己的访问路径：当前实现分别处理 View 边界与 CTE producer，不能把所有树节点当成普通基表叶子。

本节解释正常调用链，不是安全审查。验证时准备具有明确授权的测试身份，分别执行应成功和应拒绝的查询，保存身份、授权与错误；不要把管理员执行成功当作普通用户路径的证据。
