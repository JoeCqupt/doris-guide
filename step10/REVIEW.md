# Step 10 验收报告

验收日期：2026-10-09。结论：运行核心目标通过；端口与心跳的概念区别在 Step 11 巩固。

## 证据

- 本人提交注册前 SHOW BACKENDS 为空，报告执行 ADD BACKEND；注册后节点 Host=30.78.52.23、HeartbeatPort=9050、Alive=true、HeartbeatFailureCounter=0、ErrMsg 为空。
- FE 输出 Alive=true、IsMaster=true。BE 版本 doris-0.0.0-b306a0b1b4b；FE 版本 doris-0.0.0-024e7779fef。来自同一学习环境，但构建 commit 不同，保留版本记录，不假定已做全面兼容验证。
- 助手只读核验 output/be/log/be.INFO，2026-10-09 的日志仍有来自 FE 的心跳。未代做建表或查询练习。
- 实际 be.conf 存储路径为 /Users/jiangyuan/doris-guide/be-storage，与任务示例 step10/be-storage 不同，以实际配置为准；不迁移或删除。
- 本人填写用时 30 min，位于“主动用时 / 启动等待”合并栏，记为自报总用时约 30 分钟，拆分未知。作答顶部“待开始”是模板遗留，保留原文。

## 概念反馈（教学说明，不算独立掌握）

端口监听证明本机进程在该地址/端口接收连接；不证明 FE 已注册它或能访问它。SHOW BACKENDS 中 Alive=true 表示 FE 当时根据心跳认为该已注册 BE 存活。两者都不能代替一次真实建表、写入与表扫描成功的证据。

TabletNum=22 不等于已做过订单建表练习；没有逐表核实这些 tablet，不能据此推断业务数据已存在。

## 下一步

Step 11 用 8 行数据完成第一条真实分析查询，并辨认 EXPLAIN 中扫描与聚合的位置。用自己的话重新区分“进程监听 / FE 心跳 / 实际读写”，不要求补写长报告。

容量记录：提交的 SHOW 输出约剩 26 GB；本次 df 检查约剩 20 GiB。仅做微型数据实验；若出现容量错误，记录原始信息，不调低保护阈值，不删除 FE 元数据或 BE 数据。
