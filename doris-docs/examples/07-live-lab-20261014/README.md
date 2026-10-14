# 2026-10-14 本地 FE/BE 实验与原始证据

[全书入口](../../README.md) · [结果解释](REPORT.md) · [Profile 解读](PROFILE_ANALYSIS.md) · [复现方法](REPRODUCE.md)

本轮在用户提供的 `/Users/jiangyuan/doris-run` 运行已有二进制，完成 SQL、HTTP Stream Load、Profile 采集及一次 FE/BE 优雅重启验证。FE 和 BE 均报告 `doris-0.0.0-a53b182f810`。这是服务报告的构建标识，不是对整个编译目录与源码文件逐一比对。

## 材料如何阅读

| 文件组 | 内容 |
|---|---|
| `00-environment.*`、`34-restarted-environment.out.txt` | 首次及重启后 FE/BE 身份、版本与状态 |
| `01—15` 开头的 SQL/输出 | 订单、规则、窗口、聚合 NULL、Join、Sequence、部分更新和统计 |
| `16—25` 开头的响应/SQL/输出 | Stream Load、同 Label 重试、2PC 和数值断言纠正 |
| `26—32` | 双分区写入、删除/重插、Schema Change、10 万行查询与重启前状态 |
| `33-after-restart.*`、`load-*-restart.tsv` | 数据/Schema/SHOW LOAD 统计的重启前后证据 |
| `results.json`、`extended-results.json`、`stream-and-numeric-results.json`、`restart-results.json` | 执行器记录的断言与退出码 |
| `profiles-index.raw.json`、`profiles/` | 11 份原始 Profile，其中 9 份业务查询、2 份客户端 SELECT DATABASE() |
| `fe-effective-settings.txt`、`be-effective-settings.txt` | 本轮修改的关键配置 |
| `shutdown-status.json` | 最终进程和监听端口核查，以实际生成内容为准 |
| `runner-*.executed.py.txt` | 已执行采集脚本存档，供审阅；不是可对已有库直接重跑的安全入口 |

原始失败不删除：`07-aggregation-null` 是文本格式断言不符（40 与 40.0），由 `25-average-numeric-assert` 补充数值验证；首次 Stream Load 缺 Expect 请求头被服务拒绝，保存在 `16-stream-load-initial-no-expect.response.json`，修正后的成功响应另存。

本目录是独立实验记录，不替代用户原 step 作答。所有结果归属于本次指定二进制、单 FE/单 BE、单副本的配置。测试数据保留在 doris_book 库，便于下次复查。

最终收尾：FE/BE 已优雅关闭，进程与上述集群端口均已核查为空。见 [停机证据](shutdown-status.json) 与 [文档及结果检查](validation-summary.json)。
