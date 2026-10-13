# 查询观测采集清单

[查询专题](../../deep-dives/01-query-rpc-and-cancellation.md) · [内存与 Profile](../../deep-dives/06-memory-operators-and-caches.md)

状态：尚未采集新的 Profile。历史 Step 11/12 的真实结果在相邻证据目录；它们不是本次重跑。以下三步在已有 Doris 环境中执行，不需要重新构建，也不自动启动服务。

## 1. 固定本次环境

保存 FE/BE 实际版本、连接地址、时间、`SHOW FRONTENDS`、`SHOW BACKENDS` 和目标表的 `SHOW CREATE TABLE`。如果服务版本与书中 HEAD 不同，记录差异即可，不能用本地 git HEAD 替代服务版本。不要保存密码或无关配置。

## 2. 同一会话保留计划与运行信息

先检查 `SHOW VARIABLES LIKE 'enable_profile'`，当前源码支持该会话变量。适配实际版本启用 `SET enable_profile=true`，然后执行并保存同一条查询的 EXPLAIN 与 SELECT。同时检查 `SHOW VARIABLES LIKE 'auto_profile_threshold_ms'`；短查询可能受采集阈值影响，以服务实际支持的设置为准。

优先重放 Step 12 已保存的 SQL；先确认 `doris_learning.step11_orders` 仍是当时的数据。不要把新建的中文城市教学表输出混入同一记录。EXPLAIN 的输出不等于执行 Profile。

从当前 FE 的 Profile 页面导出对应查询的原始文本，保留 query ID。已有第 21 章说明页面与 Controller 路径；端口以运行配置为准。缺少权限或入口不支持时，记录实际错误，不用教学表格代替 Profile。

## 3. 写一页解释

保存 `environment.md`、`explain.txt`、`result.txt`、`profile.txt` 与 `analysis.md`（建议另建以时间命名的观测目录，避免覆盖旧输出）。解释：扫描多少行、聚合减少多少行、哪些 Exchange 改变分布、哪个实例最慢、主要是计算还是等待、是否有 Spill。字段不存在就标记未提供，不猜数值。

验收以结果、计划、Profile 的 query ID/环境关联和解释证据为准。单 BE 查询无法验证多副本修复或跨节点流量；小数据查询也不能代表生产性能。这里提供观察工具，不额外增加必交 step。
