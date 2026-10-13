# 附录 A　术语与对象关系速查（初版）

[全书导航](../README.md)

> 覆盖第 1—28 章。前部基础解释默认围绕存算一体内表；外表与存算分离的术语见本附录末尾，状态权威来源与读取边界见第 22—26 章。

| 术语 | 在本书中的含义 | 容易混淆的边界 |
|---|---|---|
| OLAP | 面向批量数据分析的工作负载 | 不以一个 GROUP BY 判断所有选型 |
| MPP | 跨节点分解和协作执行分析任务的架构方式 | 不保证所有查询使用全部节点 |
| FE | 请求处理、规划、元数据和协调等工作的进程角色 | 不等于 Web 前端，也不只转发 SQL |
| BE | 执行计算、读写和维护数据等工作的进程角色 | 一个 BE 可以承载多个 Tablet |
| Nereids | Doris 查询规划与优化体系 | 生成计划与实际执行是不同阶段 |
| Coordinator | FE 中协调查询/写入执行的对象 | 不等于整个 FE，也不负责逐行完成全部计算 |
| Fragment | 分布式执行计划的一个片段 | 计划片段不等于一个操作系统进程 |
| Fragment instance | 执行计划片段的运行实例 | 一个片段可以有多个运行实例 |
| Exchange | 执行阶段间传输、重分布数据的机制 | 具体分布方式由计划决定 |
| Pipeline | BE 内组织算子推进执行的流水线 | 不等同于 MPP 或固定的一条线程 |
| Block / Column | 批量列数据的内存表示相关对象 | 与磁盘上的文件不是一一对应 |
| Catalog | 组织数据库、表等元数据的抽象与管理入口 | 外部 Catalog 不代表数据已导入 Doris |
| Partition | 表的数据组织层级之一 | 排序键中包含日期不等于按日期分区 |
| Bucket | 分桶概念，在具体分区/索引中对应数据分片组织 | 不等于 BE 节点数 |
| Tablet | 数据分片与调度相关的关键单位 | 一张表通常不只一个 Tablet |
| Replica | 存算一体中某个 Tablet 副本及其相关位置/状态 | 多副本通常不表示查询把所有副本重复计数 |
| Rowset | Tablet 中与写入/合并及版本相关的一组数据 | 不能假设一次 SQL 在全表只生成一个 Rowset |
| Segment | Rowset 中的数据文件组织单元 | 不等同于一列或一行 |
| MemTable | 写入过程中用于内存缓冲和组织数据的结构 | 不表示全部数据已发布可查 |
| COMMITTED | 本章普通写入链路中的已提交状态 | 不等于已经达到可见条件 |
| VISIBLE | 事务达到可见状态 | 完整边界还要结合锁、持久化、目录更新和观察路径 |
| MVCC | 通过版本支持数据可见性与并发访问的一类机制 | 不同系统、模式的版本粒度与实现并不相同 |
| Compaction | 对已有存储数据进行合并整理的后台工作 | 不应被理解成再次重复插入所有数据 |
| Duplicate Key | 保留明细的表模型 | Key 不是唯一性约束 |
| EXPLAIN | 查看计划的入口 | 普通计划文本不是实际运行性能记录 |
| Profile | 查询运行阶段的观测信息 | 解释结果需要实际版本、配置及工作负载 |
| Meta Service | 存算分离中承担相关元数据服务职责的组件 | 不替代全部 FE 功能 |
| Connector | 对接特定外部系统的接口与实现 | 读外部数据与外部向 Doris 写数据应分别理解 |

概念层级：Database → Table → Partition → MaterializedIndex → Tablet。存算一体中还需跟踪副本；在 BE 本地继续观察 Tablet、Rowset、Segment。这个箭头用于表示阅读层级，不表示所有类由同一进程保存，或每层只有一个对象。

## FE 请求、导入与事务补充

| 术语 | 含义 | 需要区分的边界 |
|---|---|---|
| ConnectContext | 连接/执行上下文的入口对象 | 与某一条语句的局部分析状态区分 |
| StatementContext | 语句分析与规划相关上下文 | 不代表整个连接的永久状态 |
| Command | Nereids 体系中的命令类计划 | 命令内部仍可能组织 BE 执行 |
| ShowResultSet | SHOW 等结果的列信息与行数据 | 构造结果与协议发送是不同职责 |
| Label | 导入批次定位和重复处理相关标识 | 有范围、状态与保留条件，不是永久全局去重保证 |
| Txn ID | 事务标识 | 不等同于 query ID、作业 ID 或 Label |
| Load Job | 导入作业 | 生命周期不一定等于一次请求或一个事务 |
| PublishVersionTask | FE 组织的发布版本任务 | 已下发不代表执行成功或事务已可见 |
| nextVersion | 分区下一次版本分配相关状态 | 与查询可见版本不同 |
| visibleVersion | 分区当前可见版本相关状态 | 不能直接理解成全库统一时间戳 |
| PRECOMMITTED | 当前事务枚举中的预提交状态 | 普通四状态示意图并未覆盖两阶段提交 |
| Replay | 根据持久化记录恢复或同步相关状态的过程 | 与客户端重新发起原请求不同 |

## 优化、执行与存储补充

| 术语 | 含义 | 需要区分的边界 |
|---|---|---|
| Parse / Analyze / Rewrite | 识别结构、绑定语义、进行适用改写 | 合法语法不代表列引用已绑定，也不代表所有改写都合法 |
| Slot | 计划/表达式中的列引用相关对象 | 身份不只靠显示名称 |
| Memo / Group / GroupExpression | 组织等价候选和共享子问题的优化结构 | 与 SQL 结果缓存不同 |
| Cardinality / NDV | 结果行数与不同值数量的统计概念 | 规划估计不等于本次真实运行结果 |
| Physical Properties | 分布、顺序等物理要求或属性 | 逻辑结果相同仍可能需要不同交换或排序成本 |
| Dependency | 表达任务可推进条件的依赖 | 正常完成、取消和错误都需保持相应生命周期 |
| EOS / done | 数据执行结束与任务可关闭的相关状态 | 输入读完不一定所有异步资源已完成 |
| Spill | 在适用执行路径中借助磁盘缓解内存压力 | 有额外 I/O 和恢复成本，不是所有查询通用的 OOM 解决方案 |
| Runtime Filter | 查询执行期间产生并传递的过滤信息 | 与持久存储索引不同 |
| Zone Map | 以范围等摘要帮助排除不可能匹配的数据 | 保留某范围不代表范围内每行都匹配 |
| Bloom Filter | 成员存在性概率结构 | 可能存在不等于精确匹配 |
| Delete Bitmap | MOW 等路径中的物理行失效信息 | 与物理对象身份、版本和行位置关联 |
| MOW | 写入相关阶段处理同键合并/可见关系的实现方式 | 不等于原地覆写文件或立即删除旧数据 |
| Version Graph | 用版本范围及连通关系组织覆盖路径 | 不是把上界以下的所有 Rowset 相加 |
| stale / unused Rowset | Rowset 生命周期中的不同跟踪状态 | 不自动等同于物理文件立即可删除 |
| Page / Segment | 页级数据组织与分段文件组织 | 与内存 Block 没有固定一一对应关系 |

## 集群、访问与工程验证补充

| 术语 | 含义 | 需要区分的边界 |
|---|---|---|
| Image / Journal | FE 元数据镜像与增量变更记录 | 日志位置与分区数据版本不是同一编号 |
| Checkpoint | 生成并管理元数据恢复快照的过程 | 不等于完整业务数据备份 |
| Fencing | 角色转换中的适用隔离/主身份确认步骤 | 不能仅凭方法名推导完整选举协议 |
| Heartbeat / Report | 节点运行状态与更细粒度状态报告 | 可达不等于所有 Tablet 版本可用 |
| Repair / Balance | 恢复适用数据状态与调整布局的维护任务 | 目标不同，可能共享部分调度机制 |
| Authentication / Authorization | 确认身份与判断访问权限 | 登录成功不等于能访问所有对象 |
| Authentication Integration | 认证配置实例 | 配置持久化与运行时初始化是不同阶段 |
| Authorization source | 为适用资源作出权限判断的来源 | 来源路由不等于多个来源投票 |
| Workload Group / QueryQueue | 工作负载组织与适用的查询准入队列 | FE 准入与 BE 执行资源控制不同 |
| QueueToken | 适用查询的准入等待和释放关联对象 | 请求线程结束不自动证明额度已释放 |
| 行为基线 | 记录既定输入组合下的决策或结果 | 改写基线不能代替解释行为变化 |


## 湖仓、扩展与存算分离补充

| 术语 | 本书中的含义 | 章节 |
|---|---|---|
| Catalog / Connector | 数据命名空间入口与接入能力契约；一个类型可有多个实例 | [22](../chapters/22-catalog-and-connector.md) |
| Statement Scope | 单条语句内共享并管理资源的作用域，不等于全局缓存 | [22](../chapters/22-catalog-and-connector.md) |
| Snapshot / Scan Range | 外表版本视图与可调度读取范围，不能互换 | [23](../chapters/23-external-table-query.md) |
| Equality / Position Delete | 按字段值或文件位置表达的删除语义 | [23](../chapters/23-external-table-query.md) |
| FlightInfo / DoGet | 结果描述与后续取流，具有跨请求生命周期 | [24](../chapters/24-integration-and-extension.md) |
| SPI / Loader | 扩展契约与运行时加载职责 | [24](../chapters/24-integration-and-extension.md) |
| Meta Service / TxnKv | 存储元数据业务服务与底层事务 KV 抽象 | [25](../chapters/25-object-storage-and-meta-service.md) |
| File Cache | 计算节点的文件块缓存，不能替代事务权威状态 | [25](../chapters/25-object-storage-and-meta-service.md) |
| commit_rowset / commit_txn | Rowset 登记与事务提交两个不同层次 | [26](../chapters/26-cloud-read-write-and-maintenance.md) |
| Recycler | 按元数据生命周期判断并清理数据的服务逻辑 | [26](../chapters/26-cloud-read-write-and-maintenance.md) |

## 本轮补充术语索引

| 术语 | 关键区别 | 深读 |
|---|---|---|
| ExprId | 列身份，不是列名 | [专题 2](../deep-dives/02-optimizer-statistics-and-mv.md) |
| Colocate / Bucket Shuffle | 放置相容与利用一侧桶布局的不同分布策略 | [专题 2](../deep-dives/02-optimizer-statistics-and-mv.md) |
| Short Key | 稀疏范围定位，非逐行完整主键映射 | [专题 3](../deep-dives/03-storage-updates-and-indexes.md) |
| Sequence / Delete Sign / Delete Bitmap | 覆盖顺序、逻辑删除、物理行过滤 | [专题 3](../deep-dives/03-storage-updates-and-indexes.md) |
| 背压 / Spill | 限制生产速率与转移中间状态到磁盘 | [专题 6](../deep-dives/06-memory-operators-and-caches.md) |
