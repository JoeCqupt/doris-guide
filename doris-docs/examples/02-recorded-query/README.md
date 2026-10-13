# 已保存的真实查询与 EXPLAIN

[全书导航](../../README.md) · [方法级解读](../../deep-dives/01-query-rpc-and-cancellation.md)

来源是用户此前提交的 Step 10—12 RESULT.md，本次逐字复制并记录 SHA-256，没有改写其“状态：待开始”等历史模板字段或用户回答。它们属于**用户保存的历史运行记录**，不是助手本次重新执行。

- [Step 10 原始记录](step10-result.original.md)：FE/BE 注册及版本；仅能证明当时观察。
- [Step 11 原始记录](step11-result.original.md)：8 行数据、INSERT VISIBLE、城市统计、全局去重、EXPLAIN。
- [Step 12 原始记录](step12-result.original.md)：带/不带 DISTINCT 的 A/B 计划与手工解释。
- [来源校验](provenance.json)：原文件绝对路径和副本哈希。

Step 11 数据在 2026-10-08 条件下返回 Shanghai 3 笔/240/2 人、Beijing 3 笔/230/2 人；总计 6 笔/470/3 人。它不是本书 examples/01-orders 的中文城市数据。

相邻记录包含 FE 024e7779fef、BE b306a0b1b4b；Step 12 没有重新记录版本，所以不把该版本推定为其精确环境。没有原始 Profile，不从终端总耗时制造算子耗时。正文使用当前 HEAD 解释对应机制，不能宣称旧计划就是当前 HEAD 的输出。
