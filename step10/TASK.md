# Step 10：启动并注册单机 BE

- 发布日期：2026-10-08
- 主动投入：30–45 分钟；启动等待另计。
- 目标：使用 Step 9 的已构建 BE 产物启动本机节点，注册到 FE，并以心跳证明单机 FE–BE 已接入。
- 系统位置：BE 承担数据存储和查询执行；本步补上 Step 8 中空 `SHOW BACKENDS` 的运行证据。

本步不建表、不导入数据、不删除 `doris-meta`、不删除 BE 存储目录，也不重编译 FE 或 BE。

## 1. 检查当前状态并备份配置

```bash
cd /Users/jiangyuan/open/doris
export JAVA_HOME=/Users/jiangyuan/dev/jdk-17.0.17.jdk/Contents/Home
ls -lh output/be/lib/doris_be
file output/be/lib/doris_be
ipconfig getifaddr en0
lsof -nP -iTCP:8030 -iTCP:8040 -iTCP:8050 -iTCP:8060 -iTCP:9010 -iTCP:9020 -iTCP:9030 -iTCP:9050 -iTCP:9060 -sTCP:LISTEN
cp output/be/conf/be.conf /Users/jiangyuan/doris-guide/step10/be.conf.before
```

记录实际 IPv4。若 `en0` 没有地址、BE 端口已被未知进程占用，或 `doris_be` 不存在，先停止并提交证据；不要结束其他进程。

## 2. 配置并启动 FE 与 BE

确认 `output/fe/conf/fe.conf` 仍保留 Step 8 所用的 `priority_networks` 和 JDK 配置。然后编辑 `output/be/conf/be.conf`：

- 设置 `JAVA_HOME=/Users/jiangyuan/dev/jdk-17.0.17.jdk/Contents/Home`。
- 取消注释并设置 `priority_networks = <本机实际 IPv4>/32`。
- 取消注释并设置 `storage_root_path = /Users/jiangyuan/doris-guide/step10/be-storage`。

创建指定存储目录后，依次启动：

```bash
mkdir -p /Users/jiangyuan/doris-guide/step10/be-storage
cd /Users/jiangyuan/open/doris/output/fe
bash bin/start_fe.sh --daemon
cd /Users/jiangyuan/open/doris/output/be
bash bin/start_be.sh --daemon
```

等待约 30 秒，再收集：

```bash
cd /Users/jiangyuan/open/doris/output/be
lsof -nP -iTCP:8040 -iTCP:8050 -iTCP:8060 -iTCP:9050 -iTCP:9060 -sTCP:LISTEN
tail -n 100 log/be.out
tail -n 100 log/be.INFO
```

若 BE 未监听或日志有异常，记录第一个有因果意义的错误及上下文；不要反复启动。

## 3. 注册并验证心跳

连接 FE：

```bash
mysql --protocol=TCP -h 127.0.0.1 -P 9030 -u root
```

先执行：

```sql
SHOW BACKENDS;
```

若结果没有当前 `<本机实际 IPv4>:9050`，执行：

```sql
ALTER SYSTEM ADD BACKEND "<本机实际 IPv4>:9050";
```

等待 30–60 秒后重复执行：

```sql
SHOW BACKENDS;
```

记录该节点的 Host、HeartbeatPort、BePort、HttpPort、BrpcPort、Alive、LastHeartbeat、Version 和 ErrMsg。`Alive=true` 才表示本步接入目标通过；端口监听本身不足以证明 FE 已收到心跳。

## 4. 交付与收尾

在 `RESULT.md` 中保存：

- 实际 IP、端口检查和非敏感 `be.conf` 配置摘要；
- FE/BE 启动命令、关键日志和 `SHOW BACKENDS` 前后输出；
- 对“BE 端口监听”和“FE 显示 Alive=true”分别证明什么的解释；
- 主动用时与等待时间。

验证完成后服务可继续运行以供后续建表实验；若要释放资源，分别使用 `output/be/bin/stop_be.sh` 和 `output/fe/bin/stop_fe.sh` 停止，并保留 FE 元数据和 `step10/be-storage`。停止不是本步验收条件。
