# 专题 4　副本写入、导入确认与恢复

[全书导航](../README.md) · [补充专题导航](README.md)

> 2026-10-13；源码基线 `a53b182f810be2b3731c7dfdf6f40ff5a0ad63bd`。方法链按当前本地源码核对。历史记录另列版本和来源；示意事件不冒充实测。本专题不修改 Doris 源码。

## 1. 选一条具体通道

本节选择存算一体 `VTabletWriter` / `VNodeChannel` 普通 Block RPC 路径。仓库也有 writer v2、Cloud、单副本等分支，不能混成一个固定时序。输入行经过转换和 Tablet 定位后，发送方按索引和目标节点组织通道；接收方按 load/index/Tablet 组织写入器。

```text
VTabletWriter / IndexChannel / VNodeChannel
 → PTabletWriterAddBlockRequest
 → PInternalService::tablet_writer_add_block
 → LoadChannelMgr::add_batch
 → LoadChannel::add_batch
 → TabletsChannel::add_batch / close
 → DeltaWriter / RowsetBuilder / 本地 TxnManager
 → 响应 tablet_vec / tablet_errors
 → TTabletCommitInfo(tabletId, backendId)
 → FE 事务提交与后续发布
```

发送通道与接收通道不是同一个对象。Load ID 定位一次导入上下文，index ID 选择该导入下的 TabletsChannel，tablet IDs 把行路由到具体 writer。单个响应的状态为 OK，仍要查看 `tablet_errors`；RPC 成功只是拿到了业务响应。

## 2. 包顺序与 EOS

`TabletsChannel::add_batch()` 取得 sender 的当前包序；请求比已处理序号旧时按重复包返回，未来序号在校验中报错。这个机制作用于既有通道的包处理，不能代替跨事务、跨进程重启的业务去重。

EOS 带着 sender 身份进入 `TabletsChannel::close()`。它用 `_closed_senders` 避免同一 sender 重复关闭，并减少 `_num_remaining_senders`。只有相应发送者都结束，才具备完成这组写入的条件。最后一个普通数据包与最终关闭确认因此不同。

关闭流程等待 writer、Flush、适用的 delete bitmap 计算，再提交本地事务。`_commit_txn()` 只把成功的 Tablet 放入响应 `tablet_vec`；失败写入进入 `tablet_errors`。看到物理文件不代表这个 Tablet 产生了可用提交信息。

## 3. 副本条件按 Tablet 判断

`IndexChannel::mark_as_failed()` 以 Tablet 为键累计失败节点。`_max_failed_replicas()` 使用每 Tablet 的总副本数和必需副本数；没有相应信息时使用当前代码中的回退计算。不能把全批次“有两个 BE 成功”当作每个 Tablet 都达到条件。

教学例子：T1、T2 各有 3 副本，假设这个场景各要求 2 份成功。A、B 成功写 T1，只有 C 成功写 T2，整批仍不满足 T2 条件。这个例子是对已指定条件的推演，不宣称所有配置都固定要求 2 份。

发送方 `_add_block_success_callback()` 先合并 Tablet 级失败；最后 RPC 的成功 `tablet_vec` 转成 `(tabletId, backendId)` 提交信息。FE 还要结合事务、表与版本条件验证，发送方等待到 quorum 不等于 FE 已经 VISIBLE。

| 层次 | 成功证明什么 | 还缺什么 |
|---|---|---|
| HTTP/RPC 接收 | 通信请求被处理 | 行是否合法、Tablet 是否成功 |
| writer 本地提交 | 对应 Tablet 的 Rowset 已登记 | 全局提交与发布 |
| FE COMMITTED | 事务提交条件被接受 | 发布和可见状态推进 |
| VISIBLE | 适用事务已达到查询可见阶段 | 某个外部消费者是否已读取，不属于本次提交保证 |

## 4. 一次发布超时的完整事件

示意：客户端发批次 L；BE 返回提交信息；FE 接受事务 X 为 COMMITTED；某分区的前序版本尚未满足完成条件；客户端等待窗口耗尽；后台发布继续；稍后 X 变为 VISIBLE。

此时以新 Label 重传不是继续等待 X，而可能创建新事务。Duplicate Key 会保留第二次写入。正确诊断先保存原 Label、Txn ID 和完整响应，再查原事务，不把超时转换成“数据肯定没进去”。取消请求也不能把已提交结果退回 PREPARE。

## 5. 2PC、事务 INSERT 与普通导入分开建模

| 模式 | 额外边界 | 需要保存的身份 | 不能沿用的假设 |
|---|---|---|---|
| 普通 Stream Load/INSERT | 提交后等待可见 | Label、事务、查询/导入 ID | 客户端一次返回代表全部后台过程结束 |
| Stream Load 2PC | 预提交与最终提交分开 | 原事务 ID 与协调者恢复状态 | 上传成功就代表最终已提交 |
| 多语句/子事务路径 | 多次写入的提交信息组织 | 父事务及相关子事务身份 | 每条 INSERT 都独立完成全局提交 |
| Cloud | Meta Service 的提交路径 | 业务事务与服务端状态 | 必须有存算一体的同一套 Publish 任务 |

当前 `DatabaseTransactionMgr.preCommitTransaction2PC()` 对 PRECOMMITTED 等状态有专门处理，最终提交分支期望的前态与普通 PREPARE 不同。协议层的两次操作需要调用方在故障后恢复决策；仅支持预提交接口不能证明外部作业端到端 exactly-once。跨表、跨分区保证必须以选定事务模式的锁、提交记录和查询快照为依据，而非从状态名概括。

## 6. Routine Load：数据与 offset 怎样连接

Routine Load Job 持续生成任务；任务对应事务，事务附件 `RLTaskTxnCommitAttachment` 携带消费进度及行统计。`RoutineLoadJob.afterCommitted()` 在事务操作实际发生时找到任务，经 `executeTaskOnTxnStatusChanged()` 检查附件，再更新进度与任务状态。回放也有 `replayOnCommitted()`，不是重启后重新猜 offset。

Kafka 实现 `checkCommitInfo()` 对 COMMITTED/VISIBLE 允许更新进度；ABORTED 的这条分支不推进 offset。`updateProgressAndOffsetsCache()` 还涉及最后已消费位置与下一读取位置的 `+1` 转换。因此展示 offset、缓存的最新 offset 和下一次消费起点不能直接比较成“丢了一条”。

示意：已确认消费到 99，本任务读取 100—109。若事务终止，不应仅因 Kafka 已把这批返回给消费者就把 Doris 的恢复进度推进到 110；提交成功时再按附件约定更新。若提交后回调异常导致暂停，暂停不意味着已提交数据消失，应同时查事务与 Job。

Kafka 保留周期、分区变化、非法数据过滤和显式 offset 重置仍影响整体效果。这里解释 Doris 侧协调，不能替外部环境作永久不丢不重承诺。

## 7. Group Commit：合批与 WAL 各解决什么

Group Commit 把多次小写入组织进合适的批次，减少每请求独立推进的开销。`group_commit_mgr.cpp` 中的队列在适用条件调用 `write_wal`，并在总排队字节达到限制时阻塞相应 Dependency。合批不是无限内存缓冲。

`WalManager::_replay_background()` 区分首次处理残留 WAL 与当前进程的待重放表，再交给各表的 replay。WAL 表达可恢复的输入，最终 Rowset/事务状态表达数据库可读结果，两者不是同一存储层。

sync/async 确认语义应连同所选入口、配置及 WAL 条件解释。诊断时分开记录：请求何时被接受、WAL 是否成功、合批事务何时可见、失败后谁重放。不能把某种异步接受响应解释成“查询此刻一定能看到”，也不能把 Group Commit WAL 推广到所有普通导入路径。

## 8. 源码及有效验证设计

| 路径（相对仓库根） | 精读位置 |
|---|---|
| `be/src/exec/sink/writer/vtablet_writer.cpp` | `mark_as_failed`、`_max_failed_replicas`、`_add_block_success_callback` |
| `be/src/load/channel/load_channel.cpp` | `add_batch`、`_handle_eos` |
| `be/src/load/channel/tablets_channel.cpp` | 包序、`close`、`_commit_txn` |
| `fe/fe-core/src/main/java/org/apache/doris/load/routineload/RoutineLoadJob.java` | 提交回调、附件进度和 replay |
| `fe/fe-core/src/main/java/org/apache/doris/load/routineload/kafka/KafkaRoutineLoadJob.java` | `checkCommitInfo`、offset 更新 |
| `be/src/load/group_commit/group_commit_mgr.cpp` | WAL 与队列背压 |
| `be/src/load/group_commit/wal/wal_manager.cpp` | `_replay_background` |

包重传测试应证明旧序号不重复追加；关闭测试应覆盖同 sender 重复 EOS 与最后一个 sender；副本测试应让不同 Tablet 拥有不同成功集合；恢复测试应比较数据和进度而非只看 Job RUNNING。本专题的事件为源码推演，未制造副本故障或重启现有数据。
