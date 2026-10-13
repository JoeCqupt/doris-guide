# 专题 1　从真实 EXPLAIN 走到 FE/BE 协议与取消

[全书导航](../README.md) · [补充专题导航](README.md)

> 2026-10-13；源码基线 `a53b182f810be2b3731c7dfdf6f40ff5a0ad63bd`。方法链按当前本地源码核对。历史记录另列版本和来源；示意事件不冒充实测。本专题不修改 Doris 源码。

## 1. 先用已经发生的查询

你在 Step 11 执行过 `doris_learning.step11_orders` 的城市聚合，保存了 8 行输入、INSERT 返回的 VISIBLE 和查询结果。Step 12 进一步保存了带 DISTINCT 与不带 DISTINCT 的两份 EXPLAIN。原文副本及来源摘要见[历史查询证据](../examples/02-recorded-query/README.md)。

这份数据与第 3 章的中文城市表不同：日期是 2026-10-08，城市为 Beijing/Shanghai，过滤后的金额是 470，用户是 3 人。不要拿第 3 章的 580、4 人与它比较。记录来自旧运行环境；邻近 Step 10 的 FE/BE 版本分别是 024e7779fef、b306a0b1b4b，不能据此保证 Step 12 执行时版本完全没变，更不能冒称为当前 HEAD 实测。

带 DISTINCT 的 A 查询保存了四个 Fragment。按数据流自底向上理解：

| 原记录节点 | 负责什么 | 为什么需要 |
|---|---|---|
| 0 VOlapScanNode | 扫描并按日期、状态过滤 | 只留下当日已支付订单 |
| 1 VAGGREGATE，update serialize | 按 city、user_id 组织局部状态 | 同一城市同一用户可能多笔订单 |
| 2 VEXCHANGE / 3、4 聚合阶段 | 汇合同一 city、user_id，进一步按 city 形成状态 | 跨扫描范围的重复需要合并，订单数与金额仍要保留 |
| 5 VEXCHANGE / 6 merge finalize | 按 city 汇合最终城市指标 | 每个城市得到一个最终组 |
| 7 VSORT / 8 VMERGING-EXCHANGE | 局部排序与合并返回 | 满足金额倒序、城市升序的结果要求 |

节点编号来自已保存计划，不是永久的 Doris 算子编号。原记录的单 Tablet/单 BE 环境仍有 Exchange：逻辑分布边界存在，并不证明发生跨机器流量。B 查询不含 DISTINCT，分组一直围绕 city，少了 city/user_id 的去重阶段。

## 2. 从逻辑身份到执行身份

`city[#25]` 中的列身份、计划节点 ID、Fragment ID、实例 ID、BE ID 分别对应列、算子、片段、运行实例和节点。把它们都叫“节点”会失去映射关系。

一条能落到源码的链路是：

```text
StmtExecutor → NereidsPlanner
  → PhysicalPlanTranslator（物理计划翻译）
  → Coordinator（扫描范围、实例和发送/接收关系）
  → TPipelineFragmentParamsList（按目标 BE 组织）
  → BackendServiceProxy.execPlanFragmentsAsync
  → PInternalService::_exec_plan_fragment_impl
  → FragmentMgr::exec_plan_fragment
  → PipelineFragmentContext::prepare / _build_pipelines / _create_operator
  → PipelineTask::execute
```

这不是说各方法在一条线程里直接相邻调用。计划翻译、异步 RPC 和任务调度是明确的接缝。关键是每一步传递的对象可以对照下面的字段表。

## 3. 一次 RPC 内可以同时出现 Protobuf 和 Thrift

`Coordinator.FragmentExecParams.toThrift()` 建立片段与实例参数。`PipelineExecContexts.execRemoteFragmentsAsync()` 交给代理异步发送。外层 `PExecPlanFragmentRequest` 是 Protobuf，`request` 字节里放序列化的 Thrift `TPipelineFragmentParamsList`。

BE `_exec_plan_fragment_impl()` 检查请求版本，调用 `deserialize_thrift_msg`，遍历列表并进入 FragmentMgr。当前入口要求 VERSION_3；proto 字段仍保留旧默认值，说明仅读协议默认值无法判断发送方实际传什么。

| 字段与定义位置 | FE 填入的含义 | BE 的使用问题 |
|---|---|---|
| `query_id` | 这次查询的身份 | 如何查找/创建 QueryContext？ |
| `fragment` / `fragment_id` | 计划片段及身份 | 哪些 TPlanNode 要创建为算子？ |
| `desc_tbl` | 元组、Slot 等描述 | 如何解释列引用和数据类型？ |
| `local_params[].fragment_instance_id` | 本 BE 上某实例的身份 | 报告与取结果如何关联？ |
| `local_params[].per_node_scan_ranges` | 每个扫描节点的读取范围 | Tablet、版本或文件范围是什么？ |
| `local_params[].sender_id` | 发送者编号 | EOS 与包序号属于哪个发送者？ |
| `destinations`、`per_exch_num_senders` | 目的地及 Exchange 的发送者数 | 接收队列何时才能结束？ |
| `query_options` | 执行选项，包含内存限制等 | 哪些选项决定创建哪类算子？ |

定义见 `gensrc/thrift/PaloInternalService.thrift` 的 `TPipelineInstanceParams`、`TPipelineFragmentParams`、`TPipelineFragmentParamsList`，外层见 `gensrc/proto/internal_service.proto`。这填补了“Java 类型在哪里变成 C++ 输入”的空白。

## 4. BE 怎样建出 Pipeline

`FragmentMgr::exec_plan_fragment()` 先取得 QueryContext，创建 PipelineFragmentContext 并 prepare；准备失败会取消查询。成功后登记片段上下文，按是否等待执行触发设置就绪依赖，再 submit。多阶段 prepare/start 让“准备好接收”与“开始执行”可以分开。

`PipelineFragmentContext::_create_operator()` 根据 `TPlanNodeType` 分派。普通扫描创建对应 Scan Operator，EXCHANGE_NODE 使用发送者数量创建 ExchangeSourceOperatorX；AGGREGATION_NODE 又按 streaming、grouping、spill、缓存等条件选择具体算子。一个 EXPLAIN 聚合节点未必就是一个 C++ 对象：阻塞聚合可能拆为 Sink 写状态、Source 读状态，并形成两段 Pipeline。

所以从 `VAGGREGATE` 往下读应同时记录：是否消费中间状态、是否输出中间状态、分组键、是否阻塞、共享状态由谁持有。这比把界面名称硬匹配到某个文件更可靠。

## 5. 读取版本：修正原文的模式混用

当前 `OlapScanNode.addScanRangeLocations()` 在普通存算一体路径读取 `partition.getVisibleVersion()`，写入扫描范围。`updateScanRangeVersions()` 是 Cloud 版本批量更新的入口，不能把它作为普通内表取版本的唯一证据。

`NereidsPlanner` 先收集表再规划；`StatementContext.lock()` 按表 ID 顺序对需要锁的表取得读锁，并登记释放资源，规划的 finally 经 `releasePlannerResources()` 释放。这解释了规划期间对相关元数据访问的同步条件。

读锁不是持有到查询结束。BE 用扫描范围携带的版本捕获 Rowset Reader，然后靠版本路径与对象生命周期继续读取。这里证明的是代表性规划/扫描路径，不等价于为所有事务语法建立全库快照隔离保证；外表快照与 Cloud 取版本另有机制。

## 6. 结果怎样回到客户端

`Coordinator.getNext()` 从 ResultReceiver 取得批次；`ResultReceiver.getNext()` 等待 `fetchDataAsync` 返回并处理状态、包序与结束信息。BE `PInternalService::fetch_data()` 把请求交给结果缓冲管理：没有数据时可以保留请求等待生产者，而非让处理线程持续忙等。

结果来自执行的 Result Sink，经结果缓冲与 RPC 回到 FE，再由协议层发送给客户端。结果缓存、FE 本地结果和 Flight SQL 有特殊路径；它们不改变“计算、缓冲、传输的生命周期必须分别管理”这个原则。

## 7. 取消不是只改一个布尔值

`Coordinator.cancelInternal()` 取消 ResultReceiver，向各 BE 发取消请求，并释放完成等待 latch。BE 查询取消由 QueryContext 传播到片段；`QueryContext::cancel()` 使执行/内存依赖可继续收尾，通知相关 Pipeline 上下文。片段取消还会取消适用的 Stream Load pipe，让等待读取的任务不再永久阻塞。

| 事件 | 必须同时处理的对象 | 遗漏后的表现 |
|---|---|---|
| FE 超时/取消 | 状态、取结果 Future、远端片段、等待 latch | 客户端已结束但远端仍计算 |
| BE 内存或算子失败 | QueryContext、Pipeline 依赖、下游结果通道 | 其他任务等待不存在的新数据 |
| Exchange 被关闭 | 数据队列、回调、内存计数、依赖 | 队列已空但发送方仍等待确认 |
| EOS 到达 | 对应 sender 的完成计数 | 一个 sender 完成被误判为全流完成 |

取消释放资源不等于回滚已提交事务。预处理语句还要区分 prepare 的语句身份、每次 execute 的参数/查询身份，以及 close statement 清理；不能用上一次文本查询的 query ID 代表所有执行。

## 8. 可验证边界

历史 EXPLAIN 支持节点、分组键与 Exchange 的分析，没有 Profile、抓包或对象地址证据。本专题新增的方法映射来自当前源码，二者标注为不同层证据。要收集当前运行材料，使用[只读采集说明](../examples/03-observation-kit/README.md)，不要复制示意图当真实调用栈。

具体源码：`fe/fe-core/src/main/java/org/apache/doris/qe/Coordinator.java`、`fe/fe-core/src/main/java/org/apache/doris/qe/ResultReceiver.java`、`be/src/service/internal_service.cpp`、`be/src/runtime/fragment_mgr.cpp`、`be/src/runtime/query_context.cpp`、`be/src/exec/pipeline/pipeline_fragment_context.cpp`。测试从 `be/test/exec/pipeline/pipeline_task_test.cpp` 以及协议两端对应测试选取；本次没有运行这些测试。
