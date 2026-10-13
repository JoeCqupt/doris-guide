# 第 24 章　三种集成方向与扩展接口

[全书导航](../README.md) · [术语表](../appendices/A-glossary.md)

> 日期：2026-10-13。源码基线：`a53b182f810be2b3731c7dfdf6f40ff5a0ad63bd`。正文 v1；已核对代表性源码与模块说明，未启动集群、执行 SQL 或运行测试。图为职责示意，不是本机实测拓扑。

## 24.1 先画箭头，再讨论连接器

“Doris 接了一个系统”至少包含三种含义：

| 方向 | 例子 | 首先追踪 |
|---|---|---|
| Doris 读取外部数据 | 查询 Iceberg 外表 | Catalog、快照、Scan Range、Reader |
| 外部系统写入 Doris | Flink/Spark 作业、CDC 数据链路 | 记录转换、批次、导入协议与事务 |
| 客户端消费 Doris | JDBC 应用、BI、Flight SQL 客户端 | 会话、SQL 兼容性、结果类型与传输 |

第一行属于第 22—23 章。后两行经常也叫 Connector，却不使用同一套 FE Connector SPI。名称相同不代表代码归属相同。

## 24.2 从消息记录到一次可见写入

从业务开发经验看，外部写入像批量调用服务；但重试和恢复需要额外约定。以一个持续产生订单变更的作业为例，至少有四种状态：上游已读到记录、连接器已发送批次、Doris 已接受或提交事务、上游已持久化恢复位置。

它们之间的确认顺序决定失败后是否重复或丢失。网络超时只能说明客户端没有得到确定结果，不能直接认定 Doris 没有提交。需要用导入返回值、Label/事务标识以及对应协议的查询机制继续判断。

Flink checkpoint、Spark 批次与 Doris 事务属于不同系统的概念。某个版本的连接器是否把它们对齐，必须阅读该连接器的提交和恢复实现；仅仅调用支持事务的 Doris API 不足以证明端到端 exactly-once。CDC 还涉及删除、更新顺序与表模型映射，不能只验证 INSERT 到达。

阅读一条集成链路时，建议画出“批次身份在哪里产生、重试是否复用、恢复后如何获知状态”三个位置，然后回到第 14—16 章验证 Doris 侧行为。

## 24.3 独立仓库与本仓库的证据边界

本仓库有 `extension/` 和 `samples/doris-demo/`，它们是寻找适配与示例的入口；不能从样例能表达某个 API 调用推断生产连接器的完整恢复语义。

Flink、Spark、CDC 相关组件往往独立发布，调查时应记录连接器仓库、版本/commit、运行框架版本、Doris 服务版本和对应配置。本书未对这些独立项目做源码核验，不列“全部兼容”的版本矩阵。

若要贡献 Java 代码，可以在 Doris 服务端接口和外部连接器之间选择一侧。重现问题后用协议响应定位归属：服务端状态错误、客户端误判结果、序列化字段不匹配，分别需要不同的测试位置。

## 24.4 消费查询结果：控制请求与数据传输

MySQL 协议客户端经过第 4 章的会话与命令入口。JDBC 是 Java 客户端接口，BI 是使用场景；不能把二者都理解成 Doris 内部独立执行引擎。

Arrow Flight SQL 则需要关注获取结果描述和真正取流之间的边界。`DorisFlightSqlProducer` 有 `getFlightInfoStatement`、`getStreamStatement` 等入口；请求与后续 DoGet 的生命周期并不重合。源码特别保留某些查询资源跨越 GetFlightInfo → DoGet，完成后再回收。

由此可以理解一个常见设计问题：如果在“返回结果地址”时就关闭外表扫描资源，后续取数据可能失败。反过来，取流结束或取消后不释放会累积资源。FE 本地结果与分布式结果路径也要分别阅读。

当前类还明确存在返回 UNIMPLEMENTED 的方法，例如 `acceptPutStatement`。实现了 Flight SQL Producer 并不意味着实现了协议中的每一种操作；判断客户端兼容性应精确到调用的方法、类型和错误行为。

## 24.5 UDF、SPI 与加载器

UDF 把用户计算接到表达式求值，Connector 把外部数据能力接到引擎，扩展 SPI 则定义插件契约。三者可能共同涉及实例化和关闭，但运行频率、线程模型与资源所有权不同。

`fe-extension-spi` 只定义 `Plugin`、`PluginFactory`、`PluginContext` 等契约，其中 `initialize(context)` 与 `close()` 表达生命周期。它不负责扫描目录或创建 ClassLoader。

`fe-extension-loader` 实现目录扫描、jar 解析、ClassLoader、ServiceLoader 工厂发现和失败阶段汇总。业务模块在其上定义具体能力及适配，不能因使用通用加载器就省略业务协议校验。此处仅分析现有模块职责，不提供安装不可信代码或新增远程加载路径的方案。

UDF 的源码入口位于 `be/src/udf/` 等模块；不同语言的执行方式需要分别追踪，不能用 Java 插件生命周期替代所有 BE UDF 的生命周期。后续专题应从一个实际函数的注册、准备、逐批求值与关闭切入。

## 24.6 源码索引与一个阅读方法

| 路径（相对仓库根目录） | 本章用途 |
|---|---|
| `extension/`、`samples/doris-demo/` | 集成代码与示例范围，具体项目单独核实 |
| `fe/fe-core/src/main/java/org/apache/doris/arrowflight/DorisFlightSqlProducer.java` | Flight SQL 请求、取流及未实现接口 |
| `fe/fe-extension-spi/README.md` | 契约与能力边界 |
| `fe/fe-extension-loader/README.md` | 加载步骤和资源生命周期 |
| `be/src/udf/` | BE 用户函数相关实现入口 |

面对新的集成需求，先写清一条记录或一批结果的方向，再标明两个进程之间的协议和确认点。做到这一步，通常就能判断应该阅读 Doris 内核、连接器独立仓库还是客户端驱动。下一篇讨论数据仍由 Doris 管理、持久化位置却改变的存算分离。


---

[上一章：第 23 章](23-external-table-query.md) · [全书导航](../README.md) · [下一章：第 25 章](25-object-storage-and-meta-service.md)

## 源码深读补充（2026-10-13）

- [专题 4　副本写入、导入确认与恢复](../deep-dives/04-load-replicas-and-recovery.md)
- [专题 7　外部范围、缓存失效与 UDF 生命周期](../deep-dives/07-connectors-udf-and-ecosystem.md)
