# Step 5：完成一次有证据的 FE 构建尝试

- 发布日期：2026-09-23
- 主动投入：30–45 分钟；编译等待另计，首次构建不保证在一小时内完成。
- 目标：从概念进入真实工程环境，得到 FE 产物或可定位的构建阻塞，为启动 FE+BE 和观察 EXPLAIN 做准备。
- 系统位置：FE 是查询接入、规划协调及元数据管理所在。构建成功不等于集群可用，也不等于已经可以查询内部订单表。

## 已确认与未知

助手只读检查发现：本地 protoc 可运行，版本为 3.21.11；thirdparty/installed/lib/libbrotlienc.a 存在；Maven 可找到。默认 output/fe 和 output/be 未发现。完整依赖、FE/BE 构建及启动仍未验证。

本步先构建 FE，不同时展开 BE 全量构建和服务启动。遵守仓库要求，构建只用 build.sh，保持 ASAN，不用直接 Maven 构建替代，也不执行 --clean。已有工作目录变更 .idea/vcs.xml 不要覆盖或提交。

## 三个步骤

### 1. 记录环境，约 5–10 分钟

在终端执行并把输出贴到 RESULT.md：

```bash
cd /Users/jiangyuan/open/doris
git rev-parse --short HEAD
uname -sm
java -version
mvn -version
test -x thirdparty/installed/bin/protoc && thirdparty/installed/bin/protoc --version
ls -l thirdparty/installed/lib/libbrotlienc.a
```

若 protoc 不能执行或上述静态库不存在，先记录问题，不运行构建。当前 macOS 构建脚本在该库缺失时会进入重建第三方依赖路径，本任务不需要触发它。不要把凭证、完整环境变量或私有仓库密码放入日志。

### 2. 一次 FE 构建，主动操作约 10 分钟

在同一个终端执行：

```bash
cd /Users/jiangyuan/open/doris
BUILD_TYPE=ASAN bash build.sh --fe > /Users/jiangyuan/doris-guide/step5/build-fe.log 2>&1
build_exit=$?
printf 'exit_code=%s\n' "$build_exit" > /Users/jiangyuan/doris-guide/step5/build-status.txt
```

等待期间可在另一个终端用 `tail -n 60 /Users/jiangyuan/doris-guide/step5/build-fe.log` 查看进展，不要启动第二次并发构建。如果已有 DORIS_THIRDPARTY 等自定义路径，请先记录实际路径并确认依赖，不要盲目重置个人配置。

若因缺依赖、JDK、下载或 Checkstyle 等原因失败，保留退出码和第一处有上下文的错误。先不要随意改业务代码、跳过检查或反复重试。等待超过可用时间可标记“构建中”；中断则如实记录中断，不能记作构建失败根因或成功。

### 3. 核对结果，约 10–15 分钟

- 成功：检查 output/fe 的实际内容，记录启动脚本及主要产物路径；解释“FE 已构建”还缺什么才能完成订单查询。
- 失败：指出日志中第一处你认为有因果意义的错误，并区分原始事实与自己的猜测。
- 进行中：报告最后进展与等待时长即可，下次接续，不重复启动。

本步不启动服务，不修改端口或网络配置。后续启动前会按实际产物、依赖与端口情况准备 FE/BE 配置。

## 验收标准

有代码版本与工具版本记录；有真实构建日志和完成退出码（或明确仍在运行/已中断）；能说明目前达到了哪一阶段。环境阻塞不算学习失败，定位清楚后下一步可以专门解决阻塞，而不是堆积新任务。

日志是本人的实验成果，助手不会提前代跑本步。完成后提交实际主动用时与等待时长，告诉我“Step 5 已完成”或具体阻塞即可。
