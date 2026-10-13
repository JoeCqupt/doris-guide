# 第 26 章　存算分离下的读写、事务与维护

[全书导航](../README.md) · [术语表](../appendices/A-glossary.md)

> 日期：2026-10-13。源码基线：`a53b182f810be2b3731c7dfdf6f40ff5a0ad63bd`。正文 v1；已核对代表性源码与模块说明，未启动集群、执行 SQL 或运行测试。图为职责示意，不是本机实测拓扑。

## 26.1 复用原有概念，重新检查状态所有者

第 15—17 章已经区分 MemTable、Rowset、提交和读取版本。Cloud 路径保留这些概念，但不能照搬存算一体的 FE 发布任务和 BE 本地副本流程。

```mermaid
flowchart LR
 A[开始导入事务] --> B[BE 构造并写出 Rowset 文件]
 B --> C[登记 Rowset 元数据]
 C --> D[Meta Service 处理事务提交]
 D --> E[查询选择版本]
 E --> F[CloudTablet 同步元数据]
 F --> G[Reader + 本地缓存 / 对象存储]
```

图只展示主要因果关系。真实实现包含准备阶段、异常清理、不同提交模式与并发维护，不能把它当成没有分支的七次 RPC。

## 26.2 Rowset 完成与事务完成

`CloudRowsetBuilder::init` 调用 Meta Manager 的 `prepare_rowset`；构建结束后的 `CloudRowsetBuilder::commit_rowset` 调用同名元数据提交接口。Meta Service 在 `meta_service.cpp` 处理 Rowset 登记。

这里最容易误读的是方法名称：`commit_rowset` 和 `commit_txn` 对象不同。前者完成一个 Rowset 的登记步骤，并不独自证明整次导入覆盖的所有 Tablet 都满足事务可见条件。

FE 的 `CloudGlobalTransactionMgr` 发起事务层协调，Meta Service 在 `meta_service_txn.cpp` 处理。排查导入时至少保留事务 ID、Tablet/Rowset 身份以及具体失败 RPC；只看到上传成功日志，无法证明 SQL 已经能读到数据。

## 26.3 提交为什么有多条路径

`MetaServiceImpl::commit_txn` 先检查请求与实例身份、取得事务所属数据库；事务导入子事务等情况有单独分支。普通路径扫描临时 Rowset 元数据后，选择 immediate 或 eventual 提交。

源码中的选择受 2PC 条件、请求与服务端开关、Rowset 数量等影响；immediate 遇到底层事务过大且允许 lazy commit 时还可能转入另一条路径。某些附带更新的请求则强制使用特定路径。因此不能把“Cloud 提交都是一次 KV commit”或“所有事务都异步返回成功”当作结论。

理解 eventual/lazy 的关键是继续追踪响应和最终状态，不是凭名字推测。当前代码存在 lazy committer 的提交与等待逻辑；某个 RPC 的返回语义应由对应分支的状态写入、等待和响应字段共同确定。

从 RPC 经验出发，重试要围绕稳定业务身份保持幂等。冲突、参数错误、超时与结果不确定不是同一类失败；盲目重复整个导入会让排查更难。

## 26.4 读取为什么需要同步 Rowset

`CloudTablet::sync_rowsets` 先检查 Tablet 状态；当指定查询版本时，在元数据读锁下判断本地最大版本是否已足够。需要同步才取得 `_sync_meta_lock`，随后再次检查，再调用 `sync_tablet_rowsets_unlocked`。

这个双重检查可以用熟悉的 Java 并发概念理解：等待同步锁期间，另一个线程可能已经完成相同工作。锁内复查减少重复网络请求，并保护本地元信息更新的序列。

不过“本地最大版本达到查询版本”只是该函数特定快路径的条件，不能扩展成整个查询正确性的全部证明。实际 Reader 还要捕获相应版本路径与 Rowset；文件读取和删除语义也必须成功。

同一个事务提交后，不同计算节点可能尚未缓存同样的元信息和文件。查询需要的同步与缓存拉取解释了为什么权威状态已推进，而某个节点仍有额外首次访问成本。

## 26.5 Compaction 和 Recycler 各自解决什么

Compaction 改善物理数据组织，产生新的 Rowset；它必须通过元数据协调让新的表示替代旧表示。共享存储并不自动解决多个维护者之间的任务竞争和结果发布。

Recycler 负责判断并清理不再需要的数据，不能简化为“删除创建时间很久的文件”。源码按 Rowset、Tablet、事务等对象处理回收；相关实现约定强调先建立回收标记或终止关联事务/任务，再执行物理删除。否则写入者可能还会发布指向已删除文件的元数据。

回收还要面对对象删除失败和重试。阅读时把“逻辑上不再引用”“进入回收流程”“物理文件删除完成”画为三个不同状态；不能把前一个状态日志当成后一个状态的实测证据。

## 26.6 用故障现象划分排查方向

| 现象 | 首先验证 | 不足以证明原因的单一证据 |
|---|---|---|
| 导入返回超时 | 事务身份、服务端状态、具体 RPC | 客户端超时本身 |
| 新计算节点首次查询慢 | 元数据同步、远端 I/O、缓存命中 | 只有总耗时 |
| Compaction 后存储未立即下降 | 回收状态、保留条件、删除结果 | 新 Rowset 已生成 |
| 某节点查询失败 | 节点资源、版本同步、对象读取错误 | 其他节点能读 |

扩容并不保证一条查询按节点数线性加速；冷缓存、数据交换和瓶颈迁移都会影响结果。验证扩缩容需要明确资源组、数据量、并发、缓存冷热和对象存储条件，本书未做这类实验。

## 26.7 源码和验证入口

| 路径（相对仓库根目录） | 阅读目标 |
|---|---|
| `be/src/cloud/cloud_rowset_builder.cpp` | `init`、`commit_rowset` 的职责边界 |
| `cloud/src/meta-service/meta_service.cpp` | `MetaServiceImpl::commit_rowset` |
| `cloud/src/meta-service/meta_service_txn.cpp` | `commit_txn` 与两类普通提交路径 |
| `be/src/cloud/cloud_tablet.cpp` | `sync_rowsets` 与版本读取 |
| `cloud/src/recycler/recycler.cpp` | `InstanceRecycler` 的分类回收流程 |
| `cloud/test/meta_service_test.cpp` | 元数据服务测试入口 |
| `be/test/cloud/cloud_tablet_test.cpp` | CloudTablet 测试入口 |
| `cloud/test/recycler_test.cpp` | 回收测试入口 |

测试入口未运行。至此全书系统主线已经连接起来：SQL 定义行为，计划分配工作，执行与存储产生结果，事务和元数据定义有效状态，协议与治理维持系统可用。第 27—28 章将这些认识转成一个范围明确、可验证的贡献。


---

[上一章：第 25 章](25-object-storage-and-meta-service.md) · [全书导航](../README.md) · [下一章：第 27 章](27-from-symptom-to-module.md)

## 源码深读补充（2026-10-13）

- [专题 8　Cloud 元数据提交、Compaction 与回收](../deep-dives/08-cloud-compaction-and-recycler.md)
