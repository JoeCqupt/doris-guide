# Step 8 验收报告

验收日期：2026-10-08。结论：核心目标通过，进入 Step 9。实际用时待补充。

## 证据与结论

- 本人提交 SHOW FRONTENDS 输出：Alive=true、Join=true、CurrentConnected=Yes、IsMaster=true，证明当时 FE 可连接并返回节点状态。助手未重新启动或连接服务。
- SHOW BACKENDS 返回 Empty set：当时没有已注册 BE。
- 正确说明 FE 的元数据/规划职责与 BE 的存储/执行职责，理解连接 FE 不等于订单扫描可用。
- 本人报告已手动停止 FE；助手没有把历史 Alive=true 当成当前仍在运行。
- RESULT.md 顶部仍为“未开始”，属于模板遗留，不影响根据实际交付验收；保留本人原文。

## 本次疑问

1. 统计表不存在：已读取实际 `output/fe/log/fe.log`，发现内部建表的“no available disk capacity or no available BE nodes”。结合空 BE 列表，本次缺少 BE 是已知阻塞。`InternalSchemaInitializer.run()/createTbl()` 尝试创建内部表；`StatisticsUtil.statsTblAvailable()` 检查失败返回 false；`StatisticsJobAppender.runAfterCatalogReady()` 记录 skip。无需手工创建统计表或删除元数据。BE 就绪后再验证初始化结果。
2. `Role=FOLLOWER` 与 `IsMaster=true` 不矛盾：SHOW FRONTENDS 的 Role 来自节点角色，IsMaster 单独判断当前主节点，不能只看 Role 判断是否主节点。源码入口：`fe/fe-core/src/main/java/org/apache/doris/common/proc/FrontendsProcNode.java`。
3. `SHOW FRONTENDS \G;` 已返回有效结果，后面的 `No query specified` 不影响本次验收；以后使用 `SHOW FRONTENDS\G`（不再追加分号）或 `SHOW FRONTENDS;` 即可。
4. 作答中的日志路径写成 `output/fe/logs/fe.log`；本次实际读取的是 `output/fe/log/fe.log`。

## 下一步依据

已有真实 FE 接入证据，下一步准备 BE，补齐数据存储与执行端。先收集一次 BE 构建证据，不把漫长构建等待计入主动学习时间，也不要求同时完成节点注册和建表。
