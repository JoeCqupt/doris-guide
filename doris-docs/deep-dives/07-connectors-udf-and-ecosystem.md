# 专题 7　外部范围、缓存失效与 UDF 生命周期

[全书导航](../README.md) · [专题导航](README.md)

> 源码基线：`a53b182f810be2b3731c7dfdf6f40ff5a0ad63bd`；补写日期：2026-10-13。以下为源码分析与标明的教学推演，未运行对应功能测试。仓库路径均相对 `/Users/jiangyuan/open/doris`。

## 1. 集成先按数据方向分类

| 方向 | 例子 | 本书核实范围 |
|---|---|---|
| 外部系统向 Doris 写入 | Flink/Spark 等写入连接器 | Doris 接收侧见导入与事务章节；独立连接器具体版本未审计 |
| Doris 读取外部数据 | Iceberg/JDBC Catalog | 当前仓库 Connector SPI、扫描范围和元数据缓存 |
| 客户端访问 Doris | MySQL 协议、Flight SQL | Doris 服务端入口；客户端驱动兼容矩阵需按部署版本核实 |
| 在查询中扩展计算 | Java/Python UDF | 代表性执行与资源释放路径 |

“支持 Flink”不能推出任意 Flink 版本、任意写入模式都具备相同恢复语义。独立项目应固定 connector release、Doris release、checkpoint/事务模式后再验证。此处不编造一张未经核实的版本兼容表。

## 2. Iceberg 的范围不只是路径

当前源码入口：`fe/fe-connector/fe-connector-iceberg/src/main/java/org/apache/doris/connector/iceberg/IcebergScanRange.java` 的 `populateRangeParams()` 及内嵌 `DeleteFile.toThrift()`。

| 字段组 | 含义与读取后果 |
|---|---|
| path / originalPath | 前者可为存储访问规范化路径，后者保留数据文件原路径供位置删除匹配 |
| start / length / fileSize / fileFormat | 范围、文件长度与实际读取格式，不能只凭扩展名猜 Reader |
| partitionSpecId / partitionDataJson / partitionValues | 分区演进与路径列所需信息 |
| formatVersion / firstRowId / lastUpdatedSequenceNumber | 格式与相应版本语义 |
| deleteFiles | 位置删除、相等删除、删除向量等描述，含各自需要的字段 |
| pushDownRowCount | 特定 COUNT 下推范围；普通扫描路径使用不同标识 |

这些信息进入 `TFileRangeDesc` 和 `TTableFormatFileDesc.iceberg_params`。位置删除需要匹配文件与行位置；相等删除需要字段身份与值；删除向量还涉及对象内偏移和长度。把 delete file 当普通数据文件扫描会改变结果。

System Table 还有 JNI serialized split 与原生 position-delete 表等不同形态。当前类显式分支构造描述，不能用普通数据文件字段覆盖全部范围。第 23 章的 BE Reader 链应从这份范围实际选择的格式继续跟踪。

## 3. REFRESH 为什么要有作用域

`fe/fe-core/src/main/java/org/apache/doris/datasource/ExternalMetaCacheMgr.java` 提供 `invalidateCatalog()`、`invalidateDbMetadataCache()`、`invalidateDb()` 以及表级失效路径。Catalog ID 隔离不同实例；数据库、表进一步限定作用域。上游元数据失效与 row-count 缓存之间还存在顺序要求，源码用屏障处理相关路径。

例子：两个 Catalog 都有 db.orders，连接的却是两个外部系统。若缓存键只有表名，刷新或读取就可能混淆对象。再考虑表被删除重建，即使名字相同，旧 Schema/文件列表也不能永远复用。

观测 REFRESH 后行为时同时保存 Catalog 身份、外部 snapshot/schema、刷新范围与下一次计划。远端数据文件已经更新，并不意味着当前 FE 已抛弃旧元信息；本地文件缓存命中也不意味着快照选择错误。

## 4. Java UDF：注册信息如何成为一次批量计算

注册阶段保存函数签名、类型及实现信息，查询绑定函数后，BE 的 `be/src/exprs/function/function_java_udf.cpp` 执行代表性生命周期：

1. `JavaFunctionCall::open()` 在 THREAD_LOCAL 范围建立 JniContext；准备构造参数，创建 Java executor，绑定 close/evaluate 方法。
2. `execute_impl()` 通过 JniDataBridge 把 Block 的参数列、类型和地址信息交给 Java evaluate，再把输出填回结果列。
3. `close()` 释放执行器资源；在 bthread 场景转交 close worker pthread 池处理。

close 方法在 evaluate 查找完成之前绑定，是为了让部分初始化失败也能关闭已创建的 executor。资源生命周期因此应从“对象何时创建”开始检查，而不是只从 open_successes=true 开始。

一批数据进入 UDF 并不等于每行都发生一次独立远程 RPC。JNI、Java 对象、输入输出列的类型与 NULL 约定共同构成边界。测试至少包含空批、NULL、不同长度字符串、初始化失败和执行异常后的关闭。这里只分析现有加载路径，不新增或修改任何下载/加载能力。

## 5. Python UDF 的另一个生命周期

`be/src/udf/python/python_udf_runtime.cpp` 中 `PythonUDFProcess::shutdown()`、`enqueue_child_for_reap()`、`remove_unix_socket()` 提示这里还涉及进程与 socket 资源。Java executor 的 close 不能直接套成 Python 进程的退出模型。

定位“查询已结束但资源还在”时，要分别观察 QueryContext 是否结束、客户端调用是否返回、子进程是否退出、是否已回收、socket 是否清理。任何一项完成都不足以替代其他项。本次没有启动外部 Catalog 或 UDF 运行环境。
