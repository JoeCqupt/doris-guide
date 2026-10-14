# Apache Doris 源码解析：从 SQL 到分布式分析系统

面向有 Java 业务开发经验的读者，从用户行为出发，沿源码理解查询、写入、存储和分布式协作，并逐步连接到真实贡献。

## 当前阅读方式

**28 章已改写为“源码讲解 → 动手实验 → 观察结果 → 回到源码解释”的连续结构。** 每章以一个行为问题贯穿，含真实源码片段、最多三个实验步骤、实际观察或明确标注的源码推演，以及回到实现的解释。原有深入内容重新分配到实验前后，第 5、16 章的细致规则/事务分析继续保留。

先看[阅读指南与 28 个主案例](TEACHING_GUIDE.md)，再选章。现有运行证据覆盖单 FE/单 BE 的 SQL、导入、Profile 与优雅重启；Cloud、外表、授权矩阵等仍采用源码走查，**章节结构完成不等于所有机制均已实测**。九篇深读专题与附录继续作为扩展材料。

历史[全书检查](BOOK_REVIEW.md)与[源码深度复评](SOURCE_DEPTH_REVIEW.md)保留原审查背景；当前逐章验证方式以阅读指南和正文第三部分为准。

## 阅读入口

新增：[九篇源码深读专题](deep-dives/README.md) · [历史运行证据](examples/02-recorded-query/README.md) · [观测采集清单](examples/03-observation-kit/README.md)


| 内容 | 状态 |
|---|---|
| [全书大纲：8 篇、28 章](OUTLINE.md) | 已完成 v1 |
| [第 1 章：从 CRUD 到 OLAP](chapters/01-from-crud-to-olap.md) | 四段教学结构；真实记录回放与源码解释 |
| [第 2 章：系统地图与源码导航](chapters/02-system-and-source-map.md) | 四段教学结构；真实记录回放与源码解释 |
| [第 3 章：一张表的读写闭环](chapters/03-table-read-write-cycle.md) | 四段教学结构；真实记录回放与源码解释 |
| [第 4 章：连接、会话与语句入口](chapters/04-request-session-and-command.md) | 四段教学结构；真实记录回放与源码解释 |
| [第 5 章：语法、绑定和逻辑改写](chapters/05-parser-binding-and-rewrite.md) | 四段教学结构；真实记录回放与源码解释 |
| [第 6 章：优化器如何选择计划](chapters/06-memo-statistics-and-cost.md) | 四段教学结构；真实记录回放与源码解释 |
| [第 7 章：MPP 与 Exchange](chapters/07-fragments-scheduling-and-exchange.md) | 四段教学结构；真实记录回放与源码解释 |
| [第 8 章：Pipeline 与向量化](chapters/08-pipeline-and-vectorized-execution.md) | 四段教学结构；真实记录回放与源码解释 |
| [第 9 章：典型算子与优化](chapters/09-aggregation-join-and-runtime-optimization.md) | 四段教学结构；真实记录回放与源码解释 |
| [第 10 章：数据模型与分布](chapters/10-data-model-and-distribution.md) | 四段教学结构；真实记录回放与源码解释 |
| [第 11 章：Tablet 到 Segment](chapters/11-tablet-rowset-and-segment.md) | 四段教学结构；真实记录回放与源码解释 |
| [第 12 章：索引与复杂类型](chapters/12-index-pruning-and-complex-types.md) | 四段教学结构；真实记录回放与源码解释 |
| [第 13 章：更新与存储演进](chapters/13-updates-compaction-and-schema-evolution.md) | 四段教学结构；真实记录回放与源码解释 |
| [第 14 章：导入入口与任务生命周期](chapters/14-load-entry-and-lifecycle.md) | 四段教学结构；真实记录回放与源码解释 |
| [第 15 章：物理写入链路](chapters/15-physical-write-path.md) | 四段教学结构；真实记录回放与源码解释 |
| [第 16 章：事务与可见性](chapters/16-transaction-commit-publish-visible.md) | 四段教学结构；真实记录回放与源码解释 |
| [第 17 章：MVCC 与并发读写](chapters/17-mvcc-snapshots-and-rowset-lifetime.md) | 四段教学结构；版本覆盖推演，相关运行对照 |
| [第 18 章：元数据、日志与 FE 高可用](chapters/18-metadata-journal-and-fe-ha.md) | 四段教学结构；真实记录回放与源码解释 |
| [第 19 章：节点管理与后台维护](chapters/19-node-management-and-maintenance.md) | 四段教学结构；真实记录回放与源码解释 |
| [第 20 章：身份、权限与访问入口](chapters/20-authentication-authorization-and-entrypoints.md) | 四段教学结构；源码走查实验，尚无对应集群实测 |
| [第 21 章：资源治理与可观测性](chapters/21-resource-governance-observability-and-ui.md) | 四段教学结构；真实记录回放与源码解释 |
| [第 22 章：Catalog 与 Connector](chapters/22-catalog-and-connector.md) | 四段教学结构；源码走查实验，尚无对应集群实测 |
| [第 23 章：外表查询链路](chapters/23-external-table-query.md) | 四段教学结构；源码走查实验，尚无对应集群实测 |
| [第 24 章：集成与扩展](chapters/24-integration-and-extension.md) | 四段教学结构；真实记录回放与源码解释 |
| [第 25 章：对象存储与元数据服务](chapters/25-object-storage-and-meta-service.md) | 四段教学结构；源码走查实验，尚无对应集群实测 |
| [第 26 章：Cloud 读写与维护](chapters/26-cloud-read-write-and-maintenance.md) | 四段教学结构；源码走查实验，尚无对应集群实测 |
| [第 27 章：从用户现象定位到一个模块](chapters/27-from-symptom-to-module.md) | 四段教学结构；真实记录回放与源码解释 |
| [第 28 章：测试、修复与长期贡献](chapters/28-testing-fixes-and-sustained-contribution.md) | 四段教学结构；真实记录回放与源码解释 |
| [附录 A：术语速查](appendices/A-glossary.md) | 覆盖全书的术语初版 |
| [附录 B：Java 开发者的 C++ 阅读工具箱](appendices/B-cpp-for-java-readers.md) | 所有权、RAII、Status 与并发 |
| [附录 C：源码、协议与测试索引](appendices/C-source-protocol-test-index.md) | 按行为定位与验证入口 |
| [附录 D：实验与验证记录](appendices/D-experiments-and-evidence.md) | 真实验证状态与记录模板 |
| [附录 E：版本边界与勘误](appendices/E-version-boundaries-and-errata.md) | 覆盖范围、待核实项与修订方法 |
| [配套八行订单 SQL](examples/01-orders/README.md) | 2026-10-14 已执行；原始结果及 Profile 已归档 |

第 1—28 章四段教学正文与附录 A—E 已齐备，可按顺序阅读，也可按问题选章。希望尽早进入 FE Java 贡献的读者，也可先读第 1—4 → 14 → 16 → 27 章，其余按需补充。需要定位对象时查术语表，想观察实际行为时再运行配套 SQL。章节是阅读材料，独立于根目录下的 step 学习任务，不自动增加必交作业。

## 版本与验证范围

原稿编写日期为 2026-10-12 至 2026-10-13，教学结构修订于 2026-10-14，参考本地源码 HEAD `a53b182f810be2b3731c7dfdf6f40ff5a0ad63bd`。已阅读并核对文中代表性方法，检查本地引用路径与文档链接；并未逐行审计全仓库。官方 4.x 文档用于概念和语法参考，不代表本地 HEAD 就是某个 4.x 发布版本。

本轮初次编写时没有启动或修改 Doris 服务，没有运行 FE/BE 测试，也没有实际执行本书 SQL；2026-10-14 已完成下述独立运行实验。已归档用户 Step 10—12 的历史运行记录并校验副本，分析其 SQL / EXPLAIN；这些记录来自旧运行环境。订单预期值、AVG 合并、分片计数和版本区间示例已做独立计算校验，不等于数据库执行验证。后续实验应记录实际服务版本，避免将旧构建产物与当前源码混用。

## 旧专题文档

原有六篇文档已完整移入 [extra 参考资料目录](extra/README.md)，其归属与待核对事项见[大纲中的整理计划](OUTLINE.md)。它们是继续编写的素材，尚未统一升级为当前源码基线下的正式章节。

全书二十八章教学正文与五份附录已齐备。后续修订优先补充实际运行证据、读者反馈和具体专题；覆盖大纲不等于穷尽所有实现。

## 2026-10-14 早期精读修订（历史记录）

- [第 5 章](chapters/05-parser-binding-and-rewrite.md)：以 Filter/Project 规则贯穿输出身份、条件拆分、表达式替换、树重建、窗口与随机表达式限制、LIMIT 专用分支和四个已有测试。Parser/Binding 的其余部分仍为导读。
- [第 16 章](chapters/16-transaction-commit-publish-visible.md)：以普通内表事务贯穿双分区版本、提交信息、三层同步范围、日志等待、发布副本条件、可见目录与 latch，以及两个现有测试场景。

摘录与实际本地源码文件摘要归档于 examples/05-filter-project、examples/06-transaction-visible。该轮曾核对 13 段摘录及文档链接、独立计算教学算例；当时未运行 SQL。其后实测见下一节，最新四段教学正文已整合这些结果。Java 测试与集群故障实验仍未执行。

## 2026-10-14 实测入口

[运行实验报告](examples/07-live-lab-20261014/REPORT.md) · [真实 Profile 解读](examples/07-live-lab-20261014/PROFILE_ANALYSIS.md) · [原始证据与复现](examples/07-live-lab-20261014/README.md)。本轮运行用户提供的 FE/BE 构建，验证订单 SQL、查询语义、MOW 更新、Stream Load/2PC、双分区写入与重启恢复。范围为单 FE/单 BE/单副本，不代表整个系统所有机制实测完成。
