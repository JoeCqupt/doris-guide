# Step 10 运行记录

- 状态：待开始
- 日期： 2026-10-08
- 主动用时 / 启动等待： 30 min

## 前置检查

- 实际 IPv4： 30.78.52.23
- BE 产物与架构： output/be 
- 端口占用： 9050 

## 配置与启动证据

- `be.conf` 配置摘要： 见conf文件
- FE 启动日志： 见log文件
- BE 启动日志： 见log文件
- BE 监听端口： 见log文件

## 注册与心跳证据

- 注册前 `SHOW BACKENDS`：
MySQL [(none)]> SHOW BACKENDS;
Empty set (0.006 sec)


- 是否执行 `ALTER SYSTEM ADD BACKEND`：

是

- 注册后 `SHOW BACKENDS`：

MySQL [(none)]> SHOW BACKENDS \G;
*************************** 1. row ***************************
              BackendId: 1791463841049
                   Host: 30.78.52.23
          HeartbeatPort: 9050
                 BePort: 9060
               HttpPort: 8040
               BrpcPort: 8060
     ArrowFlightSqlPort: 8050
          LastStartTime: 2026-10-08 20:52:30
          LastHeartbeat: 2026-10-08 20:55:21
                  Alive: true
   SystemDecommissioned: false
              TabletNum: 22
       DataUsedCapacity: 0.000 
      TrashUsedCapacity: 0.000 
          AvailCapacity: 26.197 GB
          TotalCapacity: 460.432 GB
                UsedPct: 94.31 %
         MaxDiskUsedPct: 94.31 %
     RemoteUsedCapacity: 0.000 
                    Tag: {"location" : "default"}
                 ErrMsg: 
                Version: doris-0.0.0-b306a0b1b4b
                 Status: {"lastSuccessReportTabletsTime":"2026-10-08 20:55:25","lastStreamLoadTime":-1,"isQueryDisabled":false,"isLoadDisabled":false,"isActive":true,"isShutdown":false,"currentFragmentNum":0,"lastFragmentUpdateTime":1791463949109}
HeartbeatFailureCounter: 0
               CpuCores: 11
                 Memory: 18.00 GB
              LiveSince: 2026-10-08 20:55:21
           RunningTasks: 0
               NodeRole: mix
1 row in set (0.008 sec)

## 理解

BE 端口监听与 FE 显示 `Alive=true` 分别证明什么： 我猜测代表心跳检查是否成功

## 助手反馈



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
 ReplayedJournalId: 136
     LastStartTime: 2026-10-08 20:50:41
     LastHeartbeat: 2026-10-08 20:55:21
          IsHelper: true
            ErrMsg: 
           Version: doris-0.0.0-024e7779fef
  CurrentConnected: Yes
         LiveSince: 2026-10-08 20:50:40
LocalResourceGroup: 
1 row in set (0.018 sec)

ERROR: No query specified

MySQL [(none)]> SHOW BACKENDS \G;
*************************** 1. row ***************************
              BackendId: 1791463841049
                   Host: 30.78.52.23
          HeartbeatPort: 9050
                 BePort: 9060
               HttpPort: 8040
               BrpcPort: 8060
     ArrowFlightSqlPort: 8050
          LastStartTime: 2026-10-08 20:52:30
          LastHeartbeat: 2026-10-08 20:55:21
                  Alive: true
   SystemDecommissioned: false
              TabletNum: 22
       DataUsedCapacity: 0.000 
      TrashUsedCapacity: 0.000 
          AvailCapacity: 26.197 GB
          TotalCapacity: 460.432 GB
                UsedPct: 94.31 %
         MaxDiskUsedPct: 94.31 %
     RemoteUsedCapacity: 0.000 
                    Tag: {"location" : "default"}
                 ErrMsg: 
                Version: doris-0.0.0-b306a0b1b4b
                 Status: {"lastSuccessReportTabletsTime":"2026-10-08 20:55:25","lastStreamLoadTime":-1,"isQueryDisabled":false,"isLoadDisabled":false,"isActive":true,"isShutdown":false,"currentFragmentNum":0,"lastFragmentUpdateTime":1791463949109}
HeartbeatFailureCounter: 0
               CpuCores: 11
                 Memory: 18.00 GB
              LiveSince: 2026-10-08 20:55:21
           RunningTasks: 0
               NodeRole: mix
1 row in set (0.008 sec)

### 2026-10-09 助手验收

运行核心目标通过；自报约 30 分钟，主动/等待未拆分。端口与心跳区别见 [REVIEW.md](REVIEW.md)，下一步用实际读写巩固。保留上方作答原文。
