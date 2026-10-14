# 实验报告：从教学预期到实际结果

[材料入口](README.md) · [Profile 解读](PROFILE_ANALYSIS.md)

## 1. 环境与配置

运行目录：`/Users/jiangyuan/doris-run`。JDK 为 `/Users/jiangyuan/dev/jdk-17.0.17.jdk/Contents/Home`。FE/BE 的 priority_networks 都设为 `127.0.0.1/32`；FE 与 BE 内嵌 JVM 都配置 `-Xmx4096m`。BE 的原生内存限制另设 `mem_limit=4G`，不把 JVM 堆上限误当作整个 BE 的内存上限。ASAN、缓存及 JVM/原生资源共同影响进程实际内存，4G 不是进程 RSS 的硬上限。

BE 存储目录显式设为 `/Users/jiangyuan/doris-run/be/storage`，原 FE 元数据保留。原配置保存在运行目录 `config-backup-20261014/`，未复制包含运行身份信息的元数据到书中。端口启动前无冲突，沿用 FE 9030/8030/9010/9020/8070，BE 9050/9060/8040/8060/8050。注册了 `127.0.0.1:9050`，SHOW BACKENDS 确认 Alive=true。

priority_networks 决定节点选用/通告的地址，本报告没有把它宣称为所有监听器仅接受 loopback 的访问控制设置。SQL 连接与本轮 HTTP 请求均使用本机地址。

FE 与 BE 报告版本均为 `a53b182f810`；`SELECT VERSION()` 返回的 5.7.99 是协议兼容展示，不能拿它当 Doris 构建版本。环境证据见 `00-environment.out.txt`、`34-restarted-environment.out.txt`。

## 2. 场景结果与覆盖边界

| 场景 | 实际结果 | 证据与限制 |
|---|---|---|
| 八行订单 | 全表 8 行；当日已支付 6 单、580.00、4 位用户 | 01—03；正式验证原 examples/01-orders SQL |
| 城市聚合排序 | 上海 2/180.00/2；北京 3/200.00/2；杭州 1/200.00/1 | 03；顺序对应当前实现的 ORDER BY city |
| 别名过滤 | revenue>100 与直接 amount>100 返回相同两行 | 04—05；最终计划受完整优化器影响，不能隔离证明仅某一规则触发 |
| LIMIT 边界 | 先取 order_id 最小两行再过滤返回 0；先过滤再取两行返回 2 | 05；实际 ORDER BY 固定行选择，区别于无序教学流 |
| Window | ROW_NUMBER 的前两行为 order_id 6、3 | 06 的实际输出；本轮不是所有窗口 frame 测试 |
| NULL 聚合 | COUNT(*)=4、COUNT(v)=3、SUM=120、AVG=40、DISTINCT=3 | 07 初始文本断言失配，25 数值断言通过 |
| Join 与子查询 | Inner=2，Semi=1，Left=3；NOT IN(含 NULL)=NULL，NOT EXISTS=true | 08；验证最小语义，不穷尽所有 Join |
| Sequence | seq=90 后到没有覆盖 seq=100，仍为 A/10/100 | 09—10；指定 Unique Key MOW+Sequence 配置 |
| 部分更新 | 仅更新 score/seq 后，name 保留 A，值为 A/30/110 | 11—12；不是所有灵活更新/新 Key 模式 |
| 删除与重插 | 删除后 0 行，再插入 C/40/120 可见 | 27；不等价于观察 Delete Bitmap 内存布局 |
| Schema Change | 增加 note 默认值 book，SHOW ALTER 为 FINISHED | 28、32；本次是实际选中路径，不据此证明影子索引重写全流程 |
| Stream Load | 3 行加载成功，读取为 3/60 | 16—17；HTTP 响应原文保留 |
| 同 Label 重试 | Label Already Exists，仍为 3/60 | 18—19；仅证明同库该 Label 机制，不推广所有外部 exactly-once |
| Stream Load 2PC | Txn 10 为 PRECOMMITTED 时仍 3/60；最终 commit 后 6/120 | 20—24；预提交状态与不可见性均有证据 |
| 双分区写入 | Txn 16 返回 VISIBLE，p1/p2 可见版本均由 1 到 2 | 26；没有制造前序版本阻塞或多副本失败 |
| 同步统计 | ANALYZE WITH SYNC 成功并保存 SHOW TABLE STATS 和计划 | 15；没有同条件前后代价比较，不称统计提升了性能 |
| 十万行聚合/Join | 聚合前五组 k=999..995 各 50 行；Join 结果 100 | 29—31；有 EXPLAIN、真实 Profile 与独立数值期望 |
| FE/BE 重启 | 5 张表的关键结果、Schema、两条 Type=INSERT 记录的统计保持 | 33、restart-results；优雅重启，不是掉电或网络故障模拟 |

## 3. 恢复实验与历史修复的联系

重启前 SHOW LOAD 有一条 100000 行 INSERT 作业，JobDetails 的 ScannedRows=100000、LoadBytes=1700000；另一条为 1 行、19 字节。优雅关闭 BE、FE 后重新启动，两条作业的 ScannedRows、LoadBytes、FileNumber、FileSize 均保持。

验证同时要求重启前 ScannedRows>0，避免“前后都是零”造成无效通过。原始文件为 `load-before-restart.tsv`、`load-after-restart.tsv`，比较结果在 `restart-results.json`。

这为专题 9 的持久化问题提供了当前构建上的正向恢复证据，但没有检出修复前版本、没有复现旧缺陷，也没有运行 PR 自带 Docker 测试。它不能替代历史修复的完整回归结论。

数据恢复断言包括：订单 8/720.00；更新表一行为 7/C/40/120/book；导入表 6/120；十万行表 100000/4999950000；两个日期分区分别 1/10 与 1/20。实验过程中没有删除原 FE 元数据，也没有清空 BE 存储。

## 4. 已处理的实验问题

第一次 SELECT VERSION 在 BE 尚未注册时失败，注册并等待 Alive 后可用；说明“FE 可连接”与“查询有可用 BE”不同。

AVG 的实际文本输出为 40，采集器最初期望字符串 40.0，导致文本断言失败。原输出保留，后来用 SQL 数值等式检查修正验证方式。数据库计算没有因此被判错。

第一次 Stream Load 返回缺少 100-continue header，补充 `Expect: 100-continue` 后成功。这是客户端请求形式问题，不是 Doris 产品缺陷。重放文档保留正确请求。

本轮服务初次启动后进程退出，之后以保持存活的执行会话托管守护进程继续实验；没有从有限日志推断根因。Mac BE 日志还出现 Linux /proc 指标读取告警，本次 SQL/恢复验证仍完成；不将它们解释为数据正确性失败。

## 5. 哪些仍未验证

单 FE/单 BE 无法证明 FE 选主、多副本 quorum/修复、网络分区、跨机器 Exchange；本轮也没有 Cloud/对象存储、Kafka Routine Load、外部 Catalog、Java/Python UDF 或备份仓库环境。

没有强制触发 Spill、内存超限、取消竞争、Compaction 或影子索引 Schema Change。Profile 中看到依赖等待不等于验证了取消正确性；新增一列成功不等于验证所有 Schema 转换策略。未运行 FE/BE 单测和仓库回归测试脚本；这里是独立 SQL/HTTP 集成实验。

这些边界继续保留在书中。完成这批实验后，可以将相关章节升级为“代表性运行案例已有证据”，不能把全书标记为所有机制实测完成。

## 教学整合时的分类勘误

SHOW LOAD 的两条记录都显示 Type=INSERT，但这不等于原始 SQL 都是 INSERT。`label_f9562a491d394d6b_9516eec9bb053a86`、TxnId=17 来自 [实验 27 的 DELETE](27-delete.out.txt)；其 ScannedRows=1、LoadBytes=19 的重启前后比较仍成立。原始 TSV 和 restart-results.json 保留不改。
