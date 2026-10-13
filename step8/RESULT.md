# Step 8 运行记录

- 状态：未开始
- 主动用时：
- 启动等待时间：
- 日期：

## 1. 运行配置

- JAVA_HOME：  JAVA_HOME=/Users/jiangyuan/dev/jdk-17.0.17.jdk/Contents/Home
- Xms / Xmx： `-Xms1024m`、`-Xmx4096m`
- priority_networks：30.78.52.23/32 
- 实际 SQL / HTTP / RPC / EditLog / Flight 端口： 
http_port = 8030
rpc_port = 9020
query_port = 9030
edit_log_port = 9010
arrow_flight_sql_port = 8070

- 启动前是否有端口占用： 否 
 
## 2. 启动证据

- 启动命令：  bash bin/start_fe.sh --daemon
- 日志关键片段或附件路径：
/Users/jiangyuan/open/doris/output/fe/logs/fe.log




- 失败时的首个异常与上下文（若有）：

dynamic_partition.prefix" = "p"). Reason errCode = 2, detailMessage = System has no available disk capacity or no available BE nodes
2026-10-08 14:38:40,964 INFO (STATS_FETCH-0|167) [StatisticsUtil.statsTblAvailable():466] stat table does not exist, db_name: __internal_schema, table_name: column_statistics
2026-10-08 14:38:41,032 INFO (Statistics Job Appender|47) [StatisticsUtil.statsTblAvailable():466] stat table does not exist, db_name: __internal_schema, table_name: column_statistics
2026-10-08 14:38:41,032 INFO (Statistics Job Appender|47) [StatisticsJobAppender.runAfterCatalogReady():77] Stats table not available, skip
2026-10-08 14:38:41,037 INFO (tablet scheduler|35) [TabletScheduler.runAfterCatalogReady():375] finished to tablet scheduler. cost: 0 ms

一直报一个stats 表不存在

## 3. SQL 输出及理解

SHOW FRONTENDS：

MySQL [(none)]> SHOW FRONTENDS \G;
*************************** 1. row ***************************
              Name: fe_cc107086_7a4d_47be_b35d_34ab6605ec1e
              Host: 30.78.52.23
       EditLogPort: 9010
          HttpPort: 8030
         QueryPort: 9030
           RpcPort: 9020
ArrowFlightSqlPort: 8070
              Role: FOLLOWER
          IsMaster: true
         ClusterId: 1806188687
              Join: true
             Alive: true
 ReplayedJournalId: 45
     LastStartTime: 2026-10-08 14:36:24
     LastHeartbeat: 2026-10-08 14:39:25
          IsHelper: true
            ErrMsg: 
           Version: doris-0.0.0-024e7779fef
  CurrentConnected: Yes
         LiveSince: NULL
LocalResourceGroup: 
1 row in set (0.027 sec)

ERROR: No query specified


SHOW BACKENDS：

MySQL [(none)]> SHOW BACKENDS \G;
Empty set (0.003 sec)

为什么连接 FE 成功不等于订单扫描可用：

因为你只启动成功FE部分， FE 只负责 元数据管理， SQL执行规划， 真正的数据保存/读写/查询是在在BE 节点上 

架构图中已验证的部分：

验证了FE部分的启动 和 连接 

任务结束时 FE 是否仍在运行：

我手动关闭了FE， 因为定时任务一直写日志

## 助手验收反馈

尚未验收。

### 2026-10-08 助手验收

核心目标通过，详见 [REVIEW.md](REVIEW.md)。顶部状态保留原文；实际用时待补充。进入 Step 9。
