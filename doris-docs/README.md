# Apache Doris 源码解析：从 SQL 到分布式分析系统

面向有 Java 业务开发经验的读者，从用户行为出发，沿源码理解查询、写入、存储和分布式协作，并逐步连接到真实贡献。

## 完整性说明

28 章与附录 A—E 的文件已齐备，当前定位是**系统导读与代表性源码分析 v1**。本轮已增加九篇[源码深读专题](deep-dives/README.md)，补充查询 RPC、统计/MV、存储更新、导入恢复、元数据、资源治理、集成、Cloud 与历史修复。代表性链路已展开；Profile、故障与外部环境实验尚未完成。逐章缺口、补充优先级及本次修正见[全书检查报告](BOOK_REVIEW.md)。

## 阅读入口

新增：[九篇源码深读专题](deep-dives/README.md) · [历史运行证据](examples/02-recorded-query/README.md) · [观测采集清单](examples/03-observation-kit/README.md)


| 内容 | 状态 |
|---|---|
| [全书大纲：8 篇、28 章](OUTLINE.md) | 已完成 v1 |
| [第 1 章：从 CRUD 到 OLAP](chapters/01-from-crud-to-olap.md) | 正文 v1；概念与源码入口 |
| [第 2 章：系统地图与源码导航](chapters/02-system-and-source-map.md) | 正文 v1；组件图与仓库地图 |
| [第 3 章：一张表的读写闭环](chapters/03-table-read-write-cycle.md) | 正文 v1；源码核对，Doris 实验待运行 |
| [第 4 章：连接、会话与语句入口](chapters/04-request-session-and-command.md) | 正文 v1；MySQL 请求、命令分派与结果返回 |
| [第 5 章：语法、绑定和逻辑改写](chapters/05-parser-binding-and-rewrite.md) | 正文 v1；规则前提、别名替换与语义边界 |
| [第 6 章：优化器如何选择计划](chapters/06-memo-statistics-and-cost.md) | 正文 v1；Memo、统计、代价和物理属性 |
| [第 7 章：MPP 与 Exchange](chapters/07-fragments-scheduling-and-exchange.md) | 正文 v1；片段、实例、调度和数据交换 |
| [第 8 章：Pipeline 与向量化](chapters/08-pipeline-and-vectorized-execution.md) | 正文 v1；Block、依赖、时间片和资源生命周期 |
| [第 9 章：典型算子与优化](chapters/09-aggregation-join-and-runtime-optimization.md) | 正文 v1；聚合状态、Join、Runtime Filter 与 Spill |
| [第 10 章：数据模型与分布](chapters/10-data-model-and-distribution.md) | 正文 v1；模型、分区、分桶和写入路由 |
| [第 11 章：Tablet 到 Segment](chapters/11-tablet-rowset-and-segment.md) | 正文 v1；列、页、读取层次和文件元信息 |
| [第 12 章：索引与复杂类型](chapters/12-index-pruning-and-complex-types.md) | 正文 v1；裁剪、候选范围与精确语义 |
| [第 13 章：更新与存储演进](chapters/13-updates-compaction-and-schema-evolution.md) | 正文 v1；MOW、Compaction 和回收边界 |
| [第 14 章：导入入口与任务生命周期](chapters/14-load-entry-and-lifecycle.md) | 正文 v1；Stream Load、异步调度与记录查询 |
| [第 15 章：物理写入链路](chapters/15-physical-write-path.md) | 正文 v1；路由、MemTable、Rowset 与发布 |
| [第 16 章：事务与可见性](chapters/16-transaction-commit-publish-visible.md) | 正文 v1；提交、发布、版本检查与等待 |
| [第 17 章：MVCC 与并发读写](chapters/17-mvcc-snapshots-and-rowset-lifetime.md) | 正文 v1；版本路径、Reader 与旧对象生命周期 |
| [第 18 章：元数据、日志与 FE 高可用](chapters/18-metadata-journal-and-fe-ha.md) | 正文 v1；Image、Journal、切主与 Checkpoint |
| [第 19 章：节点管理与后台维护](chapters/19-node-management-and-maintenance.md) | 正文 v1；心跳、报告、修复与备份边界 |
| [第 20 章：身份、权限与访问入口](chapters/20-authentication-authorization-and-entrypoints.md) | 正文 v1；认证接口、授权来源和正常行为验证 |
| [第 21 章：资源治理与可观测性](chapters/21-resource-governance-observability-and-ui.md) | 正文 v1；准入队列、Profile 与 Web 调用链 |
| [第 22 章：Catalog 与 Connector](chapters/22-catalog-and-connector.md) | 正文 v1；分层、能力与元数据生命周期 |
| [第 23 章：外表查询链路](chapters/23-external-table-query.md) | 正文 v1；Iceberg 快照、split、Reader 与删除语义 |
| [第 24 章：集成与扩展](chapters/24-integration-and-extension.md) | 正文 v1；三种方向、Flight SQL 与插件生命周期 |
| [第 25 章：对象存储与元数据服务](chapters/25-object-storage-and-meta-service.md) | 正文 v1；权威状态、TxnKv 与文件缓存 |
| [第 26 章：Cloud 读写与维护](chapters/26-cloud-read-write-and-maintenance.md) | 正文 v1；提交分支、Rowset 同步与回收 |
| [第 27 章：从用户现象定位到一个模块](chapters/27-from-symptom-to-module.md) | 正文 v1；SHOW LOAD 源码与现有测试案例 |
| [第 28 章：测试、修复与长期贡献](chapters/28-testing-fixes-and-sustained-contribution.md) | 正文 v1；验证层次、工程约定与 review 说明 |
| [附录 A：术语速查](appendices/A-glossary.md) | 覆盖全书的术语初版 |
| [附录 B：Java 开发者的 C++ 阅读工具箱](appendices/B-cpp-for-java-readers.md) | 所有权、RAII、Status 与并发 |
| [附录 C：源码、协议与测试索引](appendices/C-source-protocol-test-index.md) | 按行为定位与验证入口 |
| [附录 D：实验与验证记录](appendices/D-experiments-and-evidence.md) | 真实验证状态与记录模板 |
| [附录 E：版本边界与勘误](appendices/E-version-boundaries-and-errata.md) | 覆盖范围、待核实项与修订方法 |
| [配套八行订单 SQL](examples/01-orders/README.md) | 教学脚本；预期值计算已校验 |

第 1—28 章正文 v1 与附录 A—E 已齐备，可按顺序阅读，也可按问题选章。希望尽早进入 FE Java 贡献的读者，也可先读第 1—4 → 14 → 16 → 27 章，其余按需补充。需要定位对象时查术语表，想观察实际行为时再运行配套 SQL。章节是阅读材料，独立于根目录下的 step 学习任务，不自动增加必交作业。

## 版本与验证范围

正文编写日期为 2026-10-12 至 2026-10-13，参考本地源码 HEAD `a53b182f810be2b3731c7dfdf6f40ff5a0ad63bd`。已阅读并核对文中代表性方法，检查本地引用路径与文档链接；并未逐行审计全仓库。官方 4.x 文档用于概念和语法参考，不代表本地 HEAD 就是某个 4.x 发布版本。

本轮没有启动或修改 Doris 服务，没有运行 FE/BE 测试，也没有实际执行本书 SQL。已归档用户 Step 10—12 的历史运行记录并校验副本，分析其 SQL / EXPLAIN；这些记录来自旧运行环境。订单预期值、AVG 合并、分片计数和版本区间示例已做独立计算校验，不等于数据库执行验证。后续实验应记录实际服务版本，避免将旧构建产物与当前源码混用。

## 旧专题文档

原有六篇文档已完整移入 [extra 参考资料目录](extra/README.md)，其归属与待核对事项见[大纲中的整理计划](OUTLINE.md)。它们是继续编写的素材，尚未统一升级为当前源码基线下的正式章节。

全书二十八章正文 v1 与五份附录已齐备。后续修订优先补充实际运行证据、读者反馈和具体专题；覆盖大纲不等于穷尽所有实现。
