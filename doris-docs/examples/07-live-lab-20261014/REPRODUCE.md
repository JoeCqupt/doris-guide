# 如何复查与重放

[材料入口](README.md)

本轮数据保留，服务完成后关闭。再次启动应使用运行目录的 start_fe.sh/start_be.sh --daemon，等待至少 30 秒并检查 SHOW FRONTENDS / SHOW BACKENDS。BE 已注册，正常重启不再 ADD BACKEND。

配置和 JDK 路径见有效设置文件；不需要重新编译。Profile 在本轮会话使用 `SET enable_profile=true; SET auto_profile_threshold_ms=0`，通过 FE `/rest/v1/query_profile` 与 `/rest/v1/query_profile/text/<ID>` 保存原文。

## 只读复查

可执行 03、05、08、13、25、31、33 的只读 SQL。10/12 的断言对应更新过程中的中间状态，现在已执行删除/重插和加列，不能拿当前表去套早期预期。

01、09、14、26、29 是初始化脚本，27、28、11 会修改数据/Schema，不要在保留的库上整批盲跑。需要完整重放时，先为新实验选择独立数据库并统一替换 SQL 中的 doris_book，以及 HTTP 路径和全新的 Label。不要为重跑而删除用户旧数据。

## Stream Load 正确请求形状

下面是本轮请求形式示例；同 Label 已执行，重发会用于验证去重，而不会重新插入三行：

```bash
curl --location-trusted -u root: \
  -H 'Expect: 100-continue' \
  -H 'label:book_lab_20261014_stream_01' \
  -H 'column_separator:,' -H 'columns:id,v' -H 'format:csv' \
  -T stream-input.csv \
  http://127.0.0.1:8030/api/doris_book/stream_events/_stream_load
```

这里只使用 localhost。2PC 请求额外带 `two_phase_commit:true`，预提交响应保存 TxnId；最终向 `/api/doris_book/_stream_load_2pc` PUT，头含 `txn_id:<实际ID>` 与 `txn_operation:commit`。不要将本轮 TxnId=10 复制到新事务。

本轮恢复验证先保存 SELECT 和 SHOW LOAD，再通过 stop_be.sh --grace、stop_fe.sh --grace 优雅停止，随后重启并比较。停止脚本不传 --grace 时默认信号不同，本轮明确使用优雅模式。最终记得再次关闭两项服务并核对进程/端口。

已执行脚本保留为 .py.txt，仅供检查实际采集过程。原始输出、失败和修正记录不覆盖成“全绿”。
