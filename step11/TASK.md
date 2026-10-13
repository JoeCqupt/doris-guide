# Step 11：第一张订单表与真实分析查询

发布日期：2026-10-09。预计主动投入 40–55 分钟；服务等待另计，可分两次完成。

目标：把 Step 1–4 的统计和架构理解放到实际 Doris 上验证，完成建表、写入、分析查询和一次 EXPLAIN。
系统位置：FE 接收 SQL、生成计划；BE 存储并执行。联系：你熟悉 CRUD，已经验证 FE/BE 心跳，现在补齐数据读写证据。
调整原因：环境准备完成，先做小型使用闭环，再进入 FE Java 调用链。只使用 8 行数据，不增加编译任务。

## 1. 确认节点并准备 8 行订单（10–15 分钟）

在终端连接（已设置密码则加 -p 交互输入）：

```bash
mysql --protocol=TCP -h 127.0.0.1 -P 9030 -u root
```

执行 SHOW FRONTENDS;、SHOW BACKENDS;，确认需要的 FE/BE 仍 Alive=true。若已停机，沿 Step 10 用已有配置和存储目录恢复；不要重新注册已有节点或初始化元数据。实际 BE 存储路径是 `/Users/jiangyuan/doris-guide/be-storage`，保留它。

在 MySQL 客户端执行：

```sql
SHOW TABLES FROM doris_learning;
```

数据库尚不存在时出现 Unknown database 是正常的初始情况。确认此前未建 step11_orders，再执行：

```sql
SOURCE /Users/jiangyuan/doris-guide/step11/seed.sql;
```

只执行一次。脚本不删除表；若表已存在或中途失败，先停下查看现有数据，记录错误，不重新 SOURCE。Duplicate 表重复 INSERT 会追加行；表存在错误不会保证客户端停止执行后面的语句。

保留 CREATE/INSERT 的实际返回和按顺序展示的 8 行数据。脚本提供建表语法，是教学材料；下一步统计 SQL 由你完成。

小提示：DUPLICATE KEY 指定排序列，不是 MySQL 唯一主键。本步按明细保存每行；单 BE 使用 replication_num=1。BUCKETS=1 是微型实验设置，不是生产推荐。

## 2. 先预测，再独立写统计 SQL（15–20 分钟）

需求：统计 **2026-10-08、status='PAID'** 的订单，按 city 输出订单数、支付总额、去重用户数；按总额降序、city 升序排序。

先根据 seed.sql 手算每个城市的三个结果，写入 RESULT.md，再执行自己编写的 SQL。保存 SQL、实际结果、预测是否一致。不要求用 Bitmap，COUNT(DISTINCT ...) 即可。

再用同一过滤条件求全局去重用户数，比较它与各城市去重用户数之和。解释是否相等，以及哪一行/哪个用户支持你的结论。

## 3. 看执行计划并补齐证据边界（10–20 分钟）

把自己写的分城市查询前加 EXPLAIN，保存实际完整输出。只尝试标出“扫描订单表”和“聚合”的节点；名称与层数以实际版本输出为准，找不到可标疑问，不需要解释所有算子，也不假定本机一定有两阶段聚合或网络交换。

用自己的话回答三句话：

- BE 端口监听证明了什么？
- SHOW BACKENDS 的 Alive=true 又证明了什么？
- 本次成功 INSERT 加表查询，比心跳额外验证了什么？

## 交付与验收

RESULT.md 记录实际用时、节点状态摘要、数据准备结果、预测/统计 SQL/实际结果、EXPLAIN 输出及三句话；较长输出可放附件并链接。
通过标准：过滤/分组/排序正确；能区分订单数、城市去重与全局去重；实际执行证据完整；能初步辨认扫描和聚合。EXPLAIN 小疑问可融入下一步，不因术语遗漏重复整个任务。

如果节点或读写报错，交付首个错误及其上下文即可，先处理阻塞。当前磁盘约余 20 GiB，仅做本任务的小数据；遇到容量拒绝不调低保护阈值，不删除元数据或数据目录。无需维持服务整夜运行；若停止，记录并保留数据。

资料入口（按需阅读，语法以本地返回为准）：
- [Duplicate Key 官方说明](https://doris.apache.org/docs/4.x/table-design/data-model/duplicate/)
- [CREATE TABLE 官方语法](https://doris.apache.org/docs/4.x/sql-manual/sql-statements/table-and-view/table/CREATE-TABLE/)
