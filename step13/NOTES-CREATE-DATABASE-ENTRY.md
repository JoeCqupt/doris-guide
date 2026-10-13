# Step 13 附注：CREATE DATABASE 的入口梳理

- 记录日期：2026-10-11
- 源码根：`/Users/jiangyuan/open/doris`
- 用途：为 Step 13 第 2 节「从命令入口读到元数据边界」提供一张入口全景图。
- 结论一句话：**面向客户端的入口有 4 个，但真正独立的执行路径只有 2 条**（MySQL、Arrow Flight SQL）；`FrontendServiceImpl#forward` 和 HTTP `/api/query` 都是复用，不是并列路径。另有 2 个只对内、绕过解析器的入口。

## 一、面向客户端的入口（4 个）

| # | 入口 | 位置（文件:行） | 是否独立执行路径 |
|---|---|---|---|
| 1 | MySQL 协议 | `mysql/MysqlServer.java` → `mysql/AcceptListener.java:136` `new MysqlConnectProcessor(context)` → `ConnectProcessor.dispatch/handleQuery` | 是 |
| 2 | Arrow Flight SQL | `arrowflight/DorisFlightSqlProducer.java:219,229` → `FlightSqlConnectProcessor`（`arrowflight/FlightSqlConnectProcessor.java:60`） | 是（另一套协议适配，同样落到 StmtExecutor） |
| 3 | Thrift 转发 | `service/FrontendServiceImpl.java:1156` `forward()` → `MysqlConnectProcessor.proxyExecute()`（`qe/ConnectProcessor.java:543`） | 否（复用 MySQL 路径） |
| 4 | HTTP REST | `httpv2/rest/StmtExecutionAction.java:84` `/api/query/{ns}/{db}` | 否（通过 JDBC 绕回本机 MySQL 端口） |

协议处理器（`extends ConnectProcessor`）目前只有两个实现：
- `qe/MysqlConnectProcessor.java:66`（MySQL）
- `arrowflight/FlightSqlConnectProcessor.java:60`（Arrow Flight SQL）

#4 的注释（`StmtExecutionAction.java:91-96`）明确说明：它不自己执行 SQL，而是用 `StatementSubmitter` 开一条 **JDBC 连接到本 FE 的 MySQL 端口**，最终绕回 #1。

## 二、MysqlServer 与 forward 的区别（重点）

两者**不是两条并列路径，而是同一条 MySQL 路径的两个位置**。

**MysqlServer（#1）—— 客户端直连的 FE 入口**
- 客户端连到哪个 FE，就在哪个 FE 上处理。
- 该 FE 是 **master** → 本地直接 `StmtExecutor` 解析执行；
- 该 FE 是 **follower** → follower 通过 Thrift 把请求 **forward 给 master**（forward 由此而来）。

**`FrontendServiceImpl#forward`（#3）—— master 侧收转发请求**
- 携带的是**原始 SQL 字符串，不是解析后的 plan**。证据 `FrontendServiceImpl.java:585`：
  ```java
  executor = new StmtExecutor(ctx, new OriginStatement(request.getSql(), idx), true);
  ```
- `forward()` 注释（`FrontendServiceImpl.java:1164-1166`）说明 master 会 over a `ProxyMysqlChannel` 把转发来的语句**重放**一遍；执行体是 `proxyExecute`（`ConnectProcessor.java:543`）→ 重新解析 → 判别 Nereids → 同一个 `CreateDatabaseCommand.run()`。

结论：forward 不是"另一种建库逻辑"，而是 **master 替 follower 把这条 SQL 再走一遍标准 MySQL 执行链**。

## 三、只对内、绕过解析器的入口（2 个）

直接 `new CreateDatabaseCommand(...)` 然后 `Env.createDb(command)`，**不经过 SQL 解析器 / StmtExecutor**：

| 入口 | 位置（文件:行） | 用途 |
|---|---|---|
| 系统内置库初始化 | `catalog/InternalSchemaInitializer.java:524-528` | 启动时建 `__internal_schema` |
| Cloud 缓存热点内部库 | `cloud/CacheHotspotManagerUtils.java:196-206` | cloud 模式内部建 db |

## 四、所有入口的收敛点

```
[协议入口] MysqlServer / Flight SQL / forward / HTTP
      → ConnectProcessor.dispatch → StmtExecutor
      → Nereids: LogicalPlanBuilder.visitCreateDatabase()   nereids/parser/LogicalPlanBuilder.java:8680
      → CreateDatabaseCommand.run()                         nereids/trees/plans/commands/CreateDatabaseCommand.java:69
      → Env.createDb(command)                               catalog/Env.java:3709
      → InternalCatalog.createDb(...)                       datasource/InternalCatalog.java:409
```

内部入口（#5/#6）从 `Env.createDb(command)` 这一步插入，跳过前面所有环节。

## 五、还差的一步（Step 13 主任务）

本文只覆盖"到 `Env.createDb` 为止"的入口问题。**真正落元数据**的链（`Env.createDb → InternalCatalog.createDb → EditLog.logCreateDb`）留给 Step 13 主任务按 TASK.md 第 2 节顺序阅读。
