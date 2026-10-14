# 第 26 章　存算分离下的读写、事务与维护

[全书导航](../README.md) · [术语表](../appendices/A-glossary.md)

> 教学结构修订：2026-10-14。每章先沿一个问题阅读代码，再做实验、观察结果，最后解释对象和分支。历史正文基线为 `a53b182f810be2b3731c7dfdf6f40ff5a0ad63bd`；本次摘录取自当前本地文件，完整文件 SHA-256 与行号保存在[源码摘录清单](../examples/08-chapter-workshops/source-manifest.json)。运行证据来自报告版本 `doris-0.0.0-a53b182f810` 的二进制，不能仅凭版本前缀认定当前工作目录与二进制逐文件相同。

**本章问题：两个线程都发现元数据落后，为什么只有一个需要拉取？**

本章验证方式：源码走查与状态推演；无该主题的集群实测。建议先用 20—40 分钟完成主案例，第四部分的扩展阅读可分次完成；这不是新增的每日必交任务。

## 一、源码讲解：先找到决定行为的对象和分支

聚焦 CloudTablet.sync_rowsets 的两次版本检查。第一次快速判断避免不必要同步；拿到 _sync_meta_lock 后再次检查，是为了处理等待期间另一线程已推进本地视图的情况。

### 先读这段真实代码

文件：`be/src/cloud/cloud_tablet.cpp`，当前文件第 310—348 行。下面是连续原文摘录，局部片段省略了方法的其他部分；不要把片段当完整实现。

```cpp
        auto lock_start = std::chrono::steady_clock::now();
        std::shared_lock rlock(_meta_lock);
        if (stats) {
            stats->meta_lock_wait_ns += std::chrono::duration_cast<std::chrono::nanoseconds>(
                                                std::chrono::steady_clock::now() - lock_start)
                                                .count();
        }
        if (_max_version >= options.query_version) {
            return Status::OK();
        }
    }

    // serially execute sync to reduce unnecessary network overhead
    auto sync_lock_start = std::chrono::steady_clock::now();
    std::unique_lock lock(_sync_meta_lock);
    if (stats) {
        stats->sync_meta_lock_wait_ns += std::chrono::duration_cast<std::chrono::nanoseconds>(
                                                 std::chrono::steady_clock::now() - sync_lock_start)
                                                 .count();
    }
    if (options.query_version > 0) {
        auto lock_start = std::chrono::steady_clock::now();
        std::shared_lock rlock(_meta_lock);
        if (stats) {
            stats->meta_lock_wait_ns += std::chrono::duration_cast<std::chrono::nanoseconds>(
                                                std::chrono::steady_clock::now() - lock_start)
                                                .count();
        }
        if (_max_version >= options.query_version) {
            return Status::OK();
        }
    }

    auto st = _engine.meta_mgr().sync_tablet_rowsets_unlocked(this, lock, options, stats);
    if (st.is<ErrorCode::NOT_FOUND>()) {
        clear_cache();
    }

    return st;
```

### 这几行应该怎样读

`std::shared_lock` 保护本地元信息读取，`std::unique_lock(_sync_meta_lock)` 串行化同步者。两次 `_max_version >= query_version` 的条件相同，但发生时刻不同；锁等待期间状态可能改变，所以第二次判断不是冗余。

### 复用原有概念，重新检查状态所有者

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

### Rowset 完成与事务完成

`CloudRowsetBuilder::init` 调用 Meta Manager 的 `prepare_rowset`；构建结束后的 `CloudRowsetBuilder::commit_rowset` 调用同名元数据提交接口。Meta Service 在 `meta_service.cpp` 处理 Rowset 登记。

这里最容易误读的是方法名称：`commit_rowset` 和 `commit_txn` 对象不同。前者完成一个 Rowset 的登记步骤，并不独自证明整次导入覆盖的所有 Tablet 都满足事务可见条件。

FE 的 `CloudGlobalTransactionMgr` 发起事务层协调，Meta Service 在 `meta_service_txn.cpp` 处理。排查导入时至少保留事务 ID、Tablet/Rowset 身份以及具体失败 RPC；只看到上传成功日志，无法证明 SQL 已经能读到数据。

## 二、动手实验：先预测，再核对

默认使用已保存的实验材料或只读源码，不需要启动服务。运行环境已停止；若选择重新执行 SQL，先按[实验复现说明](../examples/07-live-lab-20261014/REPRODUCE.md)确认服务、版本与数据状态。初始化、导入和更新脚本不可在现有表上盲目重放。

1. 设 query_version=8、本地 max_version=7，画线程 A/B 都通过第一次检查、A 先拿锁同步到 8、B 后拿锁的顺序。
2. 逐行走摘录：为 A、B 分别记录第二次检查结果和是否进入 sync_tablet_rowsets_unlocked；再设本地仍是 7，比较分支。
3. 回看 CloudRowsetBuilder.commit_rowset 与 MetaService commit_txn，写明 Rowset 登记、业务提交和查询同步的三个完成条件。

本地只读入口（不连接外部服务、不修改配置）：

```bash
cd /Users/jiangyuan/open/doris
rg -n 'query_version|_sync_meta_lock|sync_tablet_rowsets_unlocked' 'be/src/cloud/cloud_tablet.cpp'
```

## 三、观察结果：先陈述事实，再划清证据范围

源码推演中，A 更新到 8 后，B 在锁内复查即可返回；若本地仍不足，B 仍要同步。该结论来自分支条件，不是已经采集到的 Cloud RPC 计数。

### 手工调度两个线程（源码推演，未运行）

| 次序 | 线程 A | 线程 B | 本地版本 |
|---|---|---|---:|
| 1 | 第一次检查不足 | 第一次检查不足 | 7 |
| 2 | 获得同步锁 | 等待同步锁 | 7 |
| 3 | 同步使本地达到 8，释放锁 | 仍在等待/准备获锁 | 8 |
| 4 | 已返回 | 获锁后复查，直接返回 | 8 |

如果删去第二次检查，B 就可能重复发起本来不再需要的同步。这个反事实解释代码意图，不代表本轮实际删除代码或进行了压力测试。

**本章边界：** 未实测 lazy/immediate commit 切换、Cloud Compaction、Recycler 或冷缓存扩容。

## 四、回到源码解释：把现象还原成执行过程

双重检查避免重复同步，而查询正确性还依赖捕获连续版本路径和读取文件。commit_rowset 登记一个物理产物，commit_txn 协调整个事务；本地 max_version 快路径不能替代所有 Reader/删除语义检查。

### 用自己的话走完这条链

合上结果后，按“输入 → 关键对象/状态 → 分支条件 → 可观察结果”的顺序回答本章问题：**两个线程都发现元数据落后，为什么只有一个需要拉取？** 再指出一项尚不能从现有实验得出的结论。能把每个箭头落到本章的方法或证据，比记住术语更接近读懂源码。

### 提交为什么有多条路径

`MetaServiceImpl::commit_txn` 先检查请求与实例身份、取得事务所属数据库；事务导入子事务等情况有单独分支。普通路径扫描临时 Rowset 元数据后，选择 immediate 或 eventual 提交。

源码中的选择受 2PC 条件、请求与服务端开关、Rowset 数量等影响；immediate 遇到底层事务过大且允许 lazy commit 时还可能转入另一条路径。某些附带更新的请求则强制使用特定路径。因此不能把“Cloud 提交都是一次 KV commit”或“所有事务都异步返回成功”当作结论。

理解 eventual/lazy 的关键是继续追踪响应和最终状态，不是凭名字推测。当前代码存在 lazy committer 的提交与等待逻辑；某个 RPC 的返回语义应由对应分支的状态写入、等待和响应字段共同确定。

从 RPC 经验出发，重试要围绕稳定业务身份保持幂等。冲突、参数错误、超时与结果不确定不是同一类失败；盲目重复整个导入会让排查更难。

### 读取为什么需要同步 Rowset

`CloudTablet::sync_rowsets` 先检查 Tablet 状态；当指定查询版本时，在元数据读锁下判断本地最大版本是否已足够。需要同步才取得 `_sync_meta_lock`，随后再次检查，再调用 `sync_tablet_rowsets_unlocked`。

这个双重检查可以用熟悉的 Java 并发概念理解：等待同步锁期间，另一个线程可能已经完成相同工作。锁内复查减少重复网络请求，并保护本地元信息更新的序列。

不过“本地最大版本达到查询版本”只是该函数特定快路径的条件，不能扩展成整个查询正确性的全部证明。实际 Reader 还要捕获相应版本路径与 Rowset；文件读取和删除语义也必须成功。

同一个事务提交后，不同计算节点可能尚未缓存同样的元信息和文件。查询需要的同步与缓存拉取解释了为什么权威状态已推进，而某个节点仍有额外首次访问成本。

### Compaction 和 Recycler 各自解决什么

Compaction 改善物理数据组织，产生新的 Rowset；它必须通过元数据协调让新的表示替代旧表示。共享存储并不自动解决多个维护者之间的任务竞争和结果发布。

Recycler 负责判断并清理不再需要的数据，不能简化为“删除创建时间很久的文件”。源码按 Rowset、Tablet、事务等对象处理回收；相关实现约定强调先建立回收标记或终止关联事务/任务，再执行物理删除。否则写入者可能还会发布指向已删除文件的元数据。

回收还要面对对象删除失败和重试。阅读时把“逻辑上不再引用”“进入回收流程”“物理文件删除完成”画为三个不同状态；不能把前一个状态日志当成后一个状态的实测证据。

### 用故障现象划分排查方向

| 现象 | 首先验证 | 不足以证明原因的单一证据 |
|---|---|---|
| 导入返回超时 | 事务身份、服务端状态、具体 RPC | 客户端超时本身 |
| 新计算节点首次查询慢 | 元数据同步、远端 I/O、缓存命中 | 只有总耗时 |
| Compaction 后存储未立即下降 | 回收状态、保留条件、删除结果 | 新 Rowset 已生成 |
| 某节点查询失败 | 节点资源、版本同步、对象读取错误 | 其他节点能读 |

扩容并不保证一条查询按节点数线性加速；冷缓存、数据交换和瓶颈迁移都会影响结果。验证扩缩容需要明确资源组、数据量、并发、缓存冷热和对象存储条件，本书未做这类实验。

### 源码和验证入口

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

### 延伸源码专题

- [专题 8　Cloud 元数据提交、Compaction 与回收](../deep-dives/08-cloud-compaction-and-recycler.md)

---

[全书导航](../README.md) · [术语表](../appendices/A-glossary.md)
