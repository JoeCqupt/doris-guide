# 全书完整性与内容深度检查报告

[全书导航](README.md) · [目标大纲](OUTLINE.md) · [勘误与版本边界](appendices/E-version-boundaries-and-errata.md)

> 检查日期：2026-10-13。检查对象：28 章正文、附录 A—E、目录、大纲与订单实验材料。源码抽查基线：`a53b182f810be2b3731c7dfdf6f40ff5a0ad63bd`。检查方式：正文通读、逐章对照目标范围、追踪跨章承诺、本地链接/路径检查，以及针对补充和疑点的源码抽查。不是全仓源码审计，也不是每条技术结论的独立复证；未启动服务、执行 SQL 或运行 Doris 测试。外部文档链接本次未逐一联网验活。

## 1. 结论

**文件齐备；系统主线已经覆盖；深度源码书与实验验证尚未完成。**

当前成果适合建立 Doris 系统地图、选择阅读入口，部分章节已经精读了方法与状态分支。但不少章节仍以概念、目录和约束提示为主，距离大纲要求的“关键字段、状态转换、调用证据、验证案例”还有差距。不能因为 28 个标题都有文件，就称内容没有遗漏。

最明显的结构性问题是：第 6、13 章原先把 MV 刷新与 Schema Change 推迟到后面的治理章节，而后文没有兑现；第 2 章提到不存在的 RPC 专章；第 27 章未提供大纲要求的历史修改案例。本次修正前两类转介并补入代表性机制，历史贡献案例仍列为未完成。

全书目前只有一套八行订单 SQL 材料，且未在 Doris 上执行。大量“可参考某测试”只是测试入口，不是测试内容分析或测试通过记录。这些标注本身诚实，但不能替代验证。

## 2. 本次已经修正和补充

| 位置 | 本次处理 | 仍需注意 |
|---|---|---|
| 第 3 章、订单实验 README | 原聚合值正确，原展示行序未对应 ORDER BY；按当前 ColumnStr 字节比较路径修正为上海、北京、杭州 | 属于源码与预期值核对，SQL 仍未执行 |
| 第 6 章 6.7 | 新增 MTMVTask 刷新尝试与 MTMVRewriteUtil 分区可用性分析，区分刷新、语义匹配与代价选择 | IVM 算法、调度恢复和真实改写未展开 |
| 第 13 章 13.8 | 新增 PENDING→WAITING_TXN→RUNNING→FINISHED 的代表性状态推进、影子索引和事务分界 | 不覆盖全部 ALTER、轻量路径和 Cloud 特有行为 |
| 第 2 章 | 移除“后续 RPC 章节”的空转介，指向附录 C 并记录专题缺口 | 逐字段 RPC 分析仍待补 |
| 全书导航 | 各章增加连续前后导航；旧“本批下一章”改成明确的专题阅读路线 | 顺序阅读与 Java 快速路线可以并存 |
| README、OUTLINE、附录 E | 将“已生成齐备”与“精读完成”分开，记录实际缺口和勘误 | 不用完成百分比掩盖不同主题的深度差异 |

## 3. 逐章覆盖核对

下面“局部精读”表示有具体方法或状态分支分析，不表示整章机制已验证完整；“导读”可用于建立概念，但不足以单独支持修改该模块。

| 章 | 当前深度 | 已有内容 | 待补要点 |
|---|---|---|---|
| [第 1 章](chapters/01-from-crud-to-olap.md) | 导读主线完整 | 工作负载、MPP/Pipeline/向量化、能力地图 | 增加有条件的选型反例可改善理解，不是当前首要缺口 |
| [第 2 章](chapters/02-system-and-source-map.md) | 导读主线完整 | 组件、控制/数据/元数据、协议入口 | 缺少一条 FE → BE RPC 的发送方、消息字段和接收方逐段对照 |
| [第 3 章](chapters/03-table-read-write-cycle.md) | 教学闭环完整，实验待验 | 八行 SQL、读写时序、事务与扫描版本连接 | 保留实际结果、EXPLAIN、Profile，并对应真实源码版本 |
| [第 4 章](chapters/04-request-session-and-command.md) | 局部精读 | 文本请求、Command 分派、SHOW LOAD | 取消、断连、预处理语句及结果取回未形成完整链路 |
| [第 5 章](chapters/05-parser-binding-and-rewrite.md) | 局部精读 | 绑定阶段、Filter/Project 规则及语义前提 | 补 Slot/ExprId 实例、函数与类型绑定；子查询/窗口仅边界提示 |
| [第 6 章](chapters/06-memo-statistics-and-cost.md) | 导读＋局部精读 | Memo、代价、属性；本次补 MV 刷新/改写边界 | 统计收集→存储/缓存→失效→估计链路；具体候选代价推导；MV 算法专题 |
| [第 7 章](chapters/07-fragments-scheduling-and-exchange.md) | 导读，执行证据不足 | Fragment/实例/Exchange、调度入口 | 缺真实计划到 RPC 的映射、Colocate/Bucket Shuffle 条件、一个倾斜案例 |
| [第 8 章](chapters/08-pipeline-and-vectorized-execution.md) | 局部精读 | Task execute、Dependency、EOS 与 done | 缺完整 Scan→Aggregate→Exchange 的对象创建链与取消唤醒时序 |
| [第 9 章](chapters/09-aggregation-join-and-runtime-optimization.md) | 聚合局部精读，其余偏导读 | COUNT/AVG/DISTINCT、Join/Runtime Filter/Spill 概念 | 具体 Join 分支、Sort/TopN 方法、过滤传播和 Spill 恢复案例 |
| [第 10 章](chapters/10-data-model-and-distribution.md) | 导读主线完整 | 模型、分区/桶/Tablet/副本、写入路由 | 补 Sequence、删除标记、部分更新组合例子；自动/动态分区作为后续专题 |
| [第 11 章](chapters/11-tablet-rowset-and-segment.md) | 局部精读 | Rowset/Segment/ColumnReader/Page 的层次 | 缺页布局与编码具体例子、缓存层级对照、一次字段读取的方法级链路 |
| [第 12 章](chapters/12-index-pruning-and-complex-types.md) | 索引导读，复杂类型仅入口 | Zone Map/Bloom/倒排与候选范围 | Variant/数组没有具体读写例子；Short Key/前缀索引未解释，需纳入索引地图 |
| [第 13 章](chapters/13-updates-compaction-and-schema-evolution.md) | 局部精读，已补作业骨架 | Compaction/旧 Rowset；本次补 Schema Change 状态机 | MOW 并发和部分更新算法、合并策略选择、BE Schema 转换仍浅 |
| [第 14 章](chapters/14-load-entry-and-lifecycle.md) | 局部精读 | Stream Load 与 Broker 作业调度、记录查询 | Routine Load 的 offset/任务/事务协作仅概念；Group Commit 未展开 |
| [第 15 章](chapters/15-physical-write-path.md) | 局部精读，副本链缺口 | 路由、DeltaWriter、MemTable、Rowset、发布 | 尚未解释发送侧通道与接收侧的对应、多副本写入/失败汇总及提交信息 |
| [第 16 章](chapters/16-transaction-commit-publish-visible.md) | 普通事务局部精读 | Begin/Commit/Publish/Visible、日志等待和版本顺序 | 2PC、子事务和跨表/跨分区读写保证未形成模式对照；不应泛化普通路径 |
| [第 17 章](chapters/17-mvcc-snapshots-and-rowset-lifetime.md) | 版本读取局部精读 | VersionGraph、Reader、stale/unused 生命周期 | 缺查询何时固定多个分区版本及其锁范围的完整证据；缺并发实验 |
| [第 18 章](chapters/18-metadata-journal-and-fe-ha.md) | 局部精读 | Image/Journal、切主片段、Checkpoint | 缺一条 DDL 从变更到 log/replay 的实例、兼容序列化例子和恢复实验 |
| [第 19 章](chapters/19-node-management-and-maintenance.md) | 导读＋调度入口 | 心跳、报告、修复、退出、备份区别 | 修复源/目标选择与 Clone 任务闭环浅；备份恢复只有概念和目录 |
| [第 20 章](chapters/20-authentication-authorization-and-entrypoints.md) | 接口导读 | 认证与授权接口、来源路由、正常行为基线 | 缺一个身份对一个表的完整正常调用链；本次未开展安全审查 |
| [第 21 章](chapters/21-resource-governance-observability-and-ui.md) | FE 准入局部精读，BE 治理偏浅 | 队列/token、Profile 页面到 Controller | 缺 MemTracker/内存限额/取消协作；缺逐项解读真实 Profile 的案例 |
| [第 22 章](chapters/22-catalog-and-connector.md) | 架构与作用域局部精读 | Catalog/Connector SPI、metadata memo、Scan 适配 | 缺具体 REFRESH/失效方法与缓存键生命周期案例 |
| [第 23 章](chapters/23-external-table-query.md) | 外表代表路径导读 | Iceberg 快照、planFiles/split、删除与 Schema | FE 范围字段到 BE Reader 参数未逐项连通；缺真实外部环境 |
| [第 24 章](chapters/24-integration-and-extension.md) | 集成概览 | 三种方向、Flight SQL、SPI/Loader | 独立连接器未版本化核验；UDF 注册→执行→关闭仅入口 |
| [第 25 章](chapters/25-object-storage-and-meta-service.md) | 架构导读 | 对象存储/Meta Service/TxnKv/缓存职责 | 缺资源与存储组织的具体对象映射、一次元数据 KV 读写例子 |
| [第 26 章](chapters/26-cloud-read-write-and-maintenance.md) | 局部精读 | 提交选择、CloudTablet 同步、回收职责 | Cloud Compaction 协作和 Recycler 删除前提仍浅；缺故障事件序列 |
| [第 27 章](chapters/27-from-symptom-to-module.md) | 命令局部精读，贡献案例待补 | SHOW LOAD 校验、排序分页、现有测试覆盖 | 大纲要求的历史修改案例未提供；没有实际失败→修复→测试→review 的闭环 |
| [第 28 章](chapters/28-testing-fixes-and-sustained-contribution.md) | 方法导读完整，实践待验 | 测试层次、脚本、回归规范与 review 说明 | 补一个经核实的历史 PR 复盘和真实验证记录，不能用当前方法介绍替代 |

## 4. 哪些补充最值得优先做

### 第一优先：让主线可以回到代码与证据

1. **同一条 SQL 的完整查询纵向案例（第 3—9、21 章）。** 给出固定建表/数据/Session、实际 EXPLAIN 与 Profile，用表格把计划节点、Fragment、实例、关键 RPC 字段和 BE 算子对应起来。补一条取消或失败的清理路径。完成标准：读者能解释每个跨进程跳转，而非只有概念箭头。
2. **一次导入的多副本写入和异常路径（第 14—17 章）。** 选定一种写入模式，解释通道、Tablet 分发、结果收集、提交信息和副本条件；加入一个“写入完成但等待可见”的具体事件序列。完成标准：每个状态有所有者、触发方法及观察入口，明确局部与全局完成的差别。
3. **一个真实的 FE 历史贡献案例（第 27—28 章）。** 选择与当前主线相关的已合入修改，核实问题、变更、测试及 review 证据，分别记录修复前后 commit；不得把本地个人配置问题当产品 bug。完成标准：存在可复核的原行为、契约、修改原因和有效验证，不能只有通用模板。

这些补充比再扩十几个只有概念的新章节更接近读者的贡献目标。第一项建立全局联系，第二项深入候选贡献方向，第三项展示社区工程成果的真实形态。

### 第二优先：补齐影响判断的关键机制

| 主题 | 为什么重要 | 建议落点 |
|---|---|---|
| 统计收集、自动分析、缓存与失效 | 解释“数据已变，为何计划没变”，连接运维与优化器 | 第 6、21 章 |
| MOW / Sequence / 删除标记 / 部分列更新 | 更新正确性不能仅靠 Delete Bitmap 名词解释 | 第 10、13、17 章 |
| 内存跟踪、背压、取消、Spill 恢复 | 内存错误与查询挂起需要生命周期证据 | 第 7—9、21 章 |
| Group Commit/WAL、Routine Load offset、2PC | 当前普通导入流程无法回答所有确认与恢复语义 | 第 14—16、24 章 |
| FE 变更→Journal→Replay 与兼容性 | Java 元数据修改必须理解持久化和恢复后果 | 第 18、28 章 |
| 异步 MV、Schema Change 完整任务链 | 本次补了骨架，尚缺构建、恢复与正确性案例 | 第 6、13、19 章 |

这里的 WAL 专指待研究的 Group Commit 路径，不能推广成所有普通导入都使用同一套 WAL。

### 第三优先：完善系统全景中的专题

Colocate/Bucket Shuffle、Short Key/前缀索引、查询/页/文件缓存区别、窗口与子查询、复杂类型和全文检索、备份恢复、UDF、外部 Connector 能力矩阵、Cloud Compaction 与 Recycler。可以按真实问题补入原章或独立专题，无需全部变成新的主章节。

这些主题有的在原大纲中只要求概览，不能都算成硬性漏章；但若要把书定位为“深入理解整个 Doris”，必须在范围声明中说明它们的覆盖程度。

## 5. 已定位的继续阅读入口

以下是补写起点，**只核对文件存在及部分声明，没有把整条链路视为已分析完成**。路径相对源码根目录。

| 待补主题 | 入口 |
|---|---|
| 统计生成与刷新 | `fe/fe-core/src/main/java/org/apache/doris/statistics/analysis/AnalysisManager.java`；`fe/fe-core/src/main/java/org/apache/doris/statistics/analysis/StatisticsAutoCollector.java` |
| 统计缓存 | `fe/fe-core/src/main/java/org/apache/doris/statistics/cache/StatisticsCache.java` |
| Colocate 元信息 | `fe/fe-core/src/main/java/org/apache/doris/catalog/ColocateTableIndex.java` |
| 写入发送通道 | `be/src/exec/sink/writer/vtablet_writer.cpp`；`be/src/exec/sink/writer/vtablet_writer_v2.cpp` |
| Routine Load 生命周期 | `fe/fe-core/src/main/java/org/apache/doris/load/routineload/RoutineLoadJob.java`；`fe/fe-core/src/main/java/org/apache/doris/load/routineload/RoutineLoadTaskScheduler.java` |
| Group Commit 与 WAL | `fe/fe-core/src/main/java/org/apache/doris/planner/GroupCommitPlanner.java`；`be/src/load/group_commit/wal/wal_manager.cpp` |
| 运行期内存与结果对象 | `be/src/runtime/memory/mem_tracker_limiter.cpp`；`be/src/runtime/result_buffer_mgr.cpp` |
| SQL 缓存 | `fe/fe-core/src/main/java/org/apache/doris/qe/cache/SqlCache.java` |

## 6. 附录、证据和写法还应怎样改进

- 附录 A 可补 Key 模型、Sequence、Short Key、Colocate、统计与缓存的交叉索引；它目前是分批累加的术语表，存在少量重复词条。
- 附录 B 够支撑第一轮 C++ 阅读，但应配一个真实类的持有关系图与锁范围图；一般语法说明不能替代生命周期分析。
- 附录 C 目前以目录索引为主。深入章节应进一步提供协议类型/字段、配置名/作用域及测试用例名，避免读者又回到全仓搜索。
- 附录 D 的未执行标注正确。应增加可重放的原始产物，保留“预期计算”和“数据库实际输出”两类证据，禁止用教学结果填充实测栏。
- 附录 E 应持续记录勘误和源码版本变化；所有架构结论目前面向本地快照，没有逐一建立与官方发布版本的对应关系。
- 多章反复解释“不能从 X 推导 Y”，有助于限定结论，但会挤占机制描述。后续优先增加对象字段表、状态/事件表和一个具体反例，减少重复提醒。
- 关键结论最好使用“文件＋方法＋短代码/条件＋解释＋对应测试”证据块。仅给出存在的目录，不足以兑现源码精读标准。

## 7. 下一版的验收边界

不要求穷尽每个功能或每行源码。核心章应至少有一条可跟随的真实方法链、关键字段/状态所有者、一个明确失败或并发边界、具体测试/实验入口。跨章承诺必须有真实落点；教学输出、源码推导和实测输出分别标识。

普通订单读写与 FE 命令至少各保留一个实际验证闭环；外部系统与 Cloud 暂无环境时允许维持源码阅读版，但不能在状态中写成实验完成。读者无需等全部专题成熟才参与一个范围明确的贡献。

## 8. 本地文档检查记录

- 章节编号 1—28 连续，附录 A—E 齐备；检查 37 份当前正文/导航/附录/实验说明文档。
- 266 处本地 Markdown 链接的文件目标有效；抽取到的 206 个完整仓库路径均存在。方法语义只对本次涉及的补充和疑点抽查，路径检查不等于语义复证。
- Markdown 代码围栏成对；已加入连续章节导航。未做全书 Mermaid 渲染或外部 URL 验活，图的视觉排版仍有独立验证空间。
- 从实际 setup.sql 提取八行，独立复算过滤、金额和去重结果；按 UTF-8 字节排序核对表格行序。未连接 Doris，不能称 SQL 实测通过。
- extra 目录中的原文件检查前后 SHA-256 一致；Doris 源码未修改，已有未跟踪文件未处理。
- 本次未运行构建/单测/回归；内容检查不产生这些测试的通过结论。

## 2026-10-13 缺口补写记录

以上原始大纲/检查结论保留为修订前快照。当前增补见[九篇专题](deep-dives/README.md)，原 28 章均已接入相关专题。

| 原缺口 | 本轮补充 | 证据状态 |
|---|---|---|
| 查询 RPC、结果取回、取消、版本与锁 | 专题 1；普通/Cloud 版本路径勘误 | 源码核对＋旧 EXPLAIN；新 Profile 待采集 |
| 列身份、子查询/窗口、统计、分布、IVM | 专题 2 | 代表性方法与教学推演；未运行功能测试 |
| Short Key、复杂列、更新、Compaction、BE Schema Change | 专题 3 | 方法链与边界案例；并发实验待运行 |
| 多副本通道、事务模式、Routine Load、WAL | 专题 4 | 源码事件分析；多副本故障待验证 |
| DDL 日志/回放、备份恢复、权限正常路径 | 专题 5 | CREATE DB / 状态机分析；重启与授权实验待运行 |
| Join、内存、背压、Spill、缓存 | 专题 6 | 生命周期分析；真实 Profile 尚缺 |
| 外部范围、刷新作用域、Java/Python UDF | 专题 7 | 当前实现分析；独立连接器版本矩阵及外部环境待核实 |
| Cloud KV、Compaction、Recycler | 专题 8 | 事务与失败窗口分析；未运行 Cloud 环境 |
| 真实 FE 贡献复盘 | 专题 9 | 本地历史补丁与测试内容、公开 PR 状态；本轮未重跑测试 |

本轮没有把“未执行实验”改写成完成，也未穷尽每种算子和部署模式。当前书籍已从全景导读扩展到代表性机制深读；如需验证发布版本兼容、生产性能、故障恢复，仍需独立环境与实测记录。

### 本轮补写后的检查结果

检查 49 份当前文档（不含 extra 及历史原文副本）：371 处本地链接目标有效，抽取的 164 个完整源码文件路径存在，代码围栏成对。统计口径与首轮不同，不用于比较内容增减。历史 Step 10—12 原件和副本均符合归档 SHA-256；extra 七个文件与首轮哈希一致。源码工作区仍只有原有 `fe/.env` 未跟踪项，本轮未修改 Doris 源码。未执行数据库实验、构建、FE/BE 测试或 Mermaid 渲染；路径检查不是逐行语义证明。
