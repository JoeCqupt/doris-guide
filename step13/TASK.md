# Step 13：从建库建表进入 FE 源码

- 发布日期：2026-10-10
- 参考主动投入：45–60 分钟；测试等待另计，可跨天。
- 目标：把一段最小 OLAP 建表操作，与 FE 的命令校验、元数据创建和现有单测对应起来。
- 系统位置：这是数据生命周期的起点。下一步才是 INSERT 事务与数据可见性；暂不进入 SHOW LOAD、Cloud 或 BE C++ 算子。

## 1. 运行最小建库建表操作（10–15 分钟）

在已连接本地 FE 的 MySQL 客户端执行。若 `doris_learn` 已存在，可改用未使用的名字；不要删除已有订单表。

```sql
CREATE DATABASE IF NOT EXISTS doris_learn;
USE doris_learn;

CREATE TABLE IF NOT EXISTS orders_lifecycle (
  order_id BIGINT,
  user_id BIGINT,
  city VARCHAR(32),
  amount DECIMAL(10, 2),
  created_at DATETIME
)
DUPLICATE KEY(order_id)
DISTRIBUTED BY HASH(order_id) BUCKETS 1
PROPERTIES ("replication_num" = "1");

SHOW CREATE TABLE orders_lifecycle;
```

记录命令输出，并用一句话回答：Duplicate Key、`BUCKETS 1`、`replication_num = 1` 分别约束什么？本机单 BE 为什么需要一副本？

## 2. 从命令入口读到元数据边界（20–25 分钟）

源码根目录：`/Users/jiangyuan/open/doris`。

> 入口全景（MySQL / Flight SQL / forward / HTTP / 内部入口，含 `文件:行`）见同目录 `NOTES-CREATE-DATABASE-ENTRY.md`。
>
> 元数据写入背后的 FE HA 机制（BDBJE 的 Environment/Database/journal、选主状态机、fencing + epoch、旧 master 写为何被阻止）见同目录 `NOTES-BDBJE-HA.md`。

按顺序只读以下方法：

1. `fe/fe-core/src/main/java/org/apache/doris/nereids/trees/plans/commands/CreateDatabaseCommand.java` 的 `run()`、`validate()`。
2. `fe/fe-core/src/main/java/org/apache/doris/nereids/trees/plans/commands/CreateTableCommand.java` 的 `run()`。
3. `CreateTableInfo.validate()`：只关注列、Key、分桶/副本配置的校验入口。
4. `fe/fe-core/src/main/java/org/apache/doris/catalog/Env.java` 的 `createDb()`、`createTable()`：确认 Command 将工作交给哪一层。
5. `fe/fe-core/src/main/java/org/apache/doris/datasource/InternalCatalog.java` 的对应创建方法：确认元数据对象安装与 EditLog 的位置。

交付一张四列表即可：SQL 操作 / Command 类与方法 / 下一跳方法 / 该层职责。不要尝试读完整个 `InternalCatalog`。

## 3. 从现有测试校验行为（15–20 分钟）

先阅读：

- `fe/fe-core/src/test/java/org/apache/doris/nereids/trees/plans/commands/CreateDatabaseCommandTest.java`
- `fe/fe-core/src/test/java/org/apache/doris/nereids/trees/plans/CreateTableCommandTest.java` 中的 `testDuplicateCreateTable()`、`testNormal()`、`testAbnormal()`。

从中任选一条正常建表与一条非法建表输入，记录：测试输入、预期、它覆盖的校验点。

如环境允许，运行目标测试类；若脚本或依赖阻塞，只提交第一个有因果意义的错误和日志路径，不清理缓存、不改业务源码：

```bash
cd /Users/jiangyuan/open/doris
export JAVA_HOME=/Users/jiangyuan/dev/jdk-17.0.17.jdk/Contents/Home
export PATH="/opt/homebrew/opt/gnu-getopt/bin:$PATH"
bash run-fe-ut.sh --run org.apache.doris.nereids.trees.plans.commands.CreateDatabaseCommandTest
bash run-fe-ut.sh --run org.apache.doris.nereids.trees.plans.CreateTableCommandTest
```

## 验收与下一步

在 `RESULT.md` 中提交：SQL 输出或首个错误、三个表属性的理解、行为到源码的四列表、两条测试映射、测试结果或首个阻塞、实际用时。

验收通过后发布下一步：同一张表执行 `INSERT INTO ... VALUES`，再追踪 FE 事务与 BE 写入边界。