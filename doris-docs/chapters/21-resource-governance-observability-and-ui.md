# 第 21 章　资源治理、可观测性与 Web 控制台

[全书导航](../README.md) · [术语表](../appendices/A-glossary.md)

> 日期：2026-10-13。源码基线：`a53b182f810be2b3731c7dfdf6f40ff5a0ad63bd`。正文 v1；已核对文中明确分析的关键方法和入口，未启动集群、执行 SQL、运行测试或进行故障实验。示意图不代表本机实测拓扑。

## 21.1 慢查询可能还没有开始计算

用户看到 SQL 用了十秒，并不能直接说 BE 花了十秒扫描。它可能在 FE 排队，规划较慢，等待某个实例，或者执行完成后仍在传输结果。

资源治理的任务是让多个工作负载分享有限资源，可观测性的任务是解释时间和资源消耗发生在哪里。两者必须结合：观察到排队可以说明准入限制在工作，但也可能提示资源配置与负载不匹配。

## 21.2 FE 准入与 BE 执行控制

当前 `Coordinator.exec()` 在适用的上下文和配置下取得 Workload Group；当查询需要排队时，从 QueryQueue 获取 token 并等待，然后才进入后续执行。`Coordinator.close()` 还负责在相应条件下释放 token 并通知等待者。

这条路径不覆盖所有导入或特殊执行方式，不能说“Doris 的每项后台工作都先排在同一个队列”。BE 内存、CPU、Pipeline 依赖和 Spill 又属于运行阶段的控制，见第 8 章。

```mermaid
flowchart LR
    Q[请求与计划] --> A[FE 适用的准入判断]
    A --> W[等待 / 拒绝 / 获得 token]
    W --> E[BE 执行与资源控制]
    E --> C[结束与清理]
    C --> R[释放准入资源并通知]
```

图中省略异常分支。检查泄漏或排队不前进时，需要看失败与取消是否同样完成释放，不能只看成功路径。

## 21.3 一个队列为何不只是 Semaphore

`QueryQueue.getToken()` 不仅检查运行查询数，还比较查询所需 slot 与可用 slot，并向 AdmissionControl 询问资源是否可用。满足条件时完成 token，否则可能入队；队列容量已满则抛出用户错误。

因此查询数相同，也可能占用不同的准入额度。调高最大并发可能减少排队，却也可能增加 BE 内存竞争，导致整体更慢。优化目标应是符合业务要求的延迟和吞吐，而不是让队列永远为空。

`releaseAndNotify()` 是另一半契约：释放后哪些等待者能推进，仍要结合资源和队列条件。不能把“请求线程结束”当作资源必然释放的证明。

## 21.4 四种证据分别回答什么

| 证据 | 适合的问题 | 使用边界 |
|---|---|---|
| EXPLAIN | 计划准备怎样扫描、连接和交换 | 普通计划不是实际运行耗时 |
| Profile | 某次执行的算子、实例和等待信息 | 计时可能重叠，不应随便累加成总耗时 |
| Metrics | 一段时间的趋势、容量、积压和错误率 | 聚合指标不一定能定位某条 SQL |
| 日志 | 状态变化、异常和关联标识 | 单条日志需要调用路径与时间上下文 |

把它们关联起来，通常需要 query ID、事务 ID、Label、BE/Tablet ID 和时间范围。不同 ID 的作用不同，不能拿 query ID 去替代所有事务追踪。

Profile 为空或缺失也需要解释：是否启用采集、请求是否执行到相应阶段、查看的是哪个 FE、记录是否保留。不能直接判定“查询没有执行”。

## 21.5 用 Profile 页面贯穿 UI 到 Java 服务

当前 `ui/src/api/queryProfiles.ts` 的 `fetchQueryProfiles()` 请求 `/rest/v1/query_profile`；`fetchQueryProfileText()` 对 Profile ID 做编码后访问文本接口。

FE 的 `QueryProfileController` 注册对应路径，并通过 `ProfileManager` 取得列表或文本。由此可得到一条已核对的阅读路线：

```text
页面需要 Profile
→ UI API 适配层
→ FE HTTP Controller
→ ProfileManager
→ HTTP 结果
→ UI 解析与显示
```

图不覆盖所有访问检查、代理或多节点收集路径。它说明 Web 控制台是系统能力的入口和展示层，并不是另一套查询引擎。页面图形出错时先区分原始 Profile、HTTP 结果、解析和布局问题；BE 执行问题不应仅通过修改页面字符串掩盖。

当前 `ui/src/pages/queryProfiles/` 还包含解析和图布局相关代码。可以先比较同一 Profile 的文本与图形是否表达一致，而不必一开始就追数据库算子实现。

## 21.6 三个常见诊断场景

**查询慢。** 先分清排队、规划与执行。若执行慢，再比较实例：所有实例都慢，还是一个实例拖尾？随后结合实际扫描量、Exchange 和内存/Spill 信息。没有控制数据规模与缓存条件的两次运行，不能直接证明某个参数更优。

**导入已提交但不可见。** 按第 16 章检查原事务、发布与前序版本条件；Workload Group 的排队信息不能替代事务状态。不要看到客户端超时就重新导入同一批数据。

**内存不足。** 先判断消耗来自哪个查询/算子与哪个资源范围，再看并发、输入基数、状态大小和 Spill 支持。单纯提高限制可能把错误推迟到更大范围，而没有解决原因。

## 21.7 入口与验证

| 路径（相对仓库根目录） | 重点 |
|---|---|
| `fe/fe-core/src/main/java/org/apache/doris/qe/Coordinator.java` | `exec()` 与 `close()` 的 token 生命周期 |
| `fe/fe-core/src/main/java/org/apache/doris/resource/workloadgroup/QueryQueue.java` | `getToken()`、`releaseAndNotify()` |
| `fe/fe-core/src/main/java/org/apache/doris/resource/workloadgroup/WorkloadGroupMgr.java` | 分组管理入口 |
| `ui/src/api/queryProfiles.ts` | 列表与文本请求 |
| `fe/fe-core/src/main/java/org/apache/doris/httpv2/controller/QueryProfileController.java` | HTTP 到 ProfileManager |
| `ui/src/pages/queryProfiles/` | 文本解析和可视化入口 |

已有 UI 验证入口包括 `ui/src/api/queryProfiles.test.ts` 和 `ui/src/pages/queryProfiles/profileParser.test.ts`。接口适配测试不等于真实集群查询测试；本章均未运行。

后续可以选择一条已有只读查询，记录 SQL、版本、配置、实际 Profile 和对应页面，不为采集材料随意改变集群参数。这样得到的证据也可成为诊断文档或测试改进的依据。


---

[上一章：第 20 章](20-authentication-authorization-and-entrypoints.md) · [全书导航](../README.md) · [下一章：第 22 章](22-catalog-and-connector.md)

## 源码深读补充（2026-10-13）

- [专题 1　从真实 EXPLAIN 走到 FE/BE 协议与取消](../deep-dives/01-query-rpc-and-cancellation.md)
- [专题 6　算子内存、背压、Spill 与缓存分层](../deep-dives/06-memory-operators-and-caches.md)
