# Doris 持续贡献路线（2026-10-10 调整）

目标是理解 Doris 的实际数据生命周期，逐步具备独立定位、复现、测试和修复问题的能力。学习不以背诵源码路径或完成题目数量为目标；每一段都必须先有实际 SQL 行为，再进入对应源码和测试。

## 当前定位

已具备：本机 FE/BE 构建与运行、基本查询与 EXPLAIN 入门、订单表写入和聚合查询经验、7 年 Java 业务开发经验。

当前缺口：还没有把一次完整的“建库 → 建表 → INSERT → 查询”操作，与 FE 元数据、事务、规划和 BE 执行边界串成证据链；尚未独立运行目标 FE 测试并从测试反向定位代码。

主线调整为：**先理解单机 OLAP 表的数据生命周期，再进入批量导入和 SHOW LOAD。** 暂不把 Cloud、FoundationDB 或 C++ 构建兼容问题作为学习主线。

## 学习顺序与源码入口

### 阶段 A：创建数据库与表元数据

先实际执行 `CREATE DATABASE`、`CREATE TABLE`，特别观察 Duplicate Key、分桶数和副本数的含义。

按下列顺序读：

1. `fe/fe-core/src/main/java/org/apache/doris/qe/StmtExecutor.java`：Nereids 语句执行分流。
2. `fe/fe-core/src/main/java/org/apache/doris/nereids/parser/LogicalPlanBuilder.java`：SQL 被构造为 Command 的位置。
3. `fe/fe-core/src/main/java/org/apache/doris/nereids/trees/plans/commands/CreateDatabaseCommand.java`：`run()` → `Env.createDb()`；先看名称、权限校验。
4. `fe/fe-core/src/main/java/org/apache/doris/nereids/trees/plans/commands/CreateTableCommand.java`：`run()` → `CreateTableInfo.validate()` → `Env.createTable()`。
5. `fe/fe-core/src/main/java/org/apache/doris/catalog/Env.java` 与 `datasource/InternalCatalog.java`：数据库/表对象写入内存元数据和 EditLog 的边界。

先看测试：

- `fe/fe-core/src/test/java/org/apache/doris/nereids/trees/plans/commands/CreateDatabaseCommandTest.java`
- `fe/fe-core/src/test/java/org/apache/doris/nereids/trees/plans/CreateTableCommandTest.java`：优先 `testDuplicateCreateTable()`、`testNormal()`、`testAbnormal()`。

完成标准：能用自己的话解释“SQL 校验完成后，谁创建数据库/表元数据；分桶和副本配置属于哪一层”。

### 阶段 B：INSERT INTO VALUES 与事务可见性

用 `INSERT INTO ... VALUES` 写少量订单，记录返回状态；随后查询验证何时可见。不要先研究批量导入。

按下列顺序读：

1. `LogicalPlanBuilder.java` 的 INSERT 构造路径。
2. `fe/fe-core/src/main/java/org/apache/doris/nereids/trees/plans/commands/insert/InsertIntoTableCommand.java`：从 `run()` 到执行器选择。
3. `fe/fe-core/src/main/java/org/apache/doris/nereids/trees/plans/commands/insert/OlapInsertExecutor.java`：`beginTransaction()`、写入 sink 初始化、提交/发布边界。
4. `GlobalTransactionMgr`：只在需要理解事务状态时进入；先不展开全部事务恢复逻辑。

先看测试：

- `fe/fe-core/src/test/java/org/apache/doris/nereids/trees/plans/ExplainInsertCommandTest.java` 的 `testInsertIntoValues()`。
- `regression-test/suites/query_p0/insert_into_table/insert_values.groovy`：观察建表、VALUES 写入和查询如何组成端到端行为。

完成标准：能区分“FE 创建事务和下发计划”与“BE 实际接收、写入数据”的职责，并解释为什么写入完成后才对查询可见。

### 阶段 C：SELECT 与 EXPLAIN 的 FE/BE 边界

基于同一张订单表执行 `SELECT`、聚合和 `EXPLAIN`，将此前学过的扫描、局部/全局聚合放回完整链路。

按下列顺序读：

1. `StmtExecutor.java`：普通查询进入 `NereidsPlanner` 的分支。
2. `fe/fe-core/src/main/java/org/apache/doris/nereids/NereidsPlanner.java`：逻辑计划到物理计划。
3. `fe/fe-core/src/main/java/org/apache/doris/nereids/trees/plans/commands/ExplainCommand.java`：EXPLAIN 为什么只返回计划文本。
4. 到 Plan Fragment / BE 的交界即止；BE 算子实现按实际问题再深入。

先看测试：

- `regression-test/suites/nereids_syntax_p0/explain.groovy`。

完成标准：能标出“FE 到哪里为止、BE 从哪里开始扫描/聚合”，并解释 EXPLAIN 不是执行结果。

### 阶段 D：批量导入与 SHOW LOAD

只有在完成 A–C 后，才用 CSV/Stream Load 或其他批量导入方式制造一个导入任务，再查看 `SHOW LOAD`。此时再进入 `ShowLoadCommand`、`LoadManager` 和导入状态管理。

## 贡献成长里程碑

1. 跑通阶段 A 的行为 → 源码 → 单测映射。
2. 跑通阶段 B 的最小事务写入链路。
3. 以阶段 C 的实际计划为依据定位一段 FE 规划代码。
4. 进入阶段 D 后，在导入状态管理区域选择一个小而可复现的问题；先核实上游状态、已有 issue 与 PR。
5. 形成带测试的修复并参与社区 review。对外创建 issue、PR 或发送消息前均由用户明确授权。

## 助手协作规则

- 每次最多推进一个数据生命周期阶段，先运行和观察，再读源码。
- 源码位置与测试名称必须基于当前分支核实；不把历史补丁或构建问题默认当成贡献候选。
- 构建环境问题由助手集中排障，不能挤占核心学习目标。
- 未实际执行、未实际阅读或未实际运行的测试不视为掌握证据。
