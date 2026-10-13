# 构建结果核验：FE 编译成功，部署收尾仍失败

核验日期：2026-09-23。最新证据来自 build-fe.log 和 build-status.txt；建议的独立 nocache 日志名并未生成，以实际文件为准。

## 已通过

- Maven reactor 的 fe-grpc、fe-core 均为 SUCCESS，并有最终 BUILD SUCCESS。
- output/fe/bin/start_fe.sh 与 output/fe/lib/doris-fe.jar 已存在。
- 实际 proto 依赖名为 output/fe/lib/fe-grpc-1.2-SNAPSHOT.jar；jar tf 已确认包含 org/apache/doris/cloud/proto/Cloud.class 和 org/apache/doris/proto/InternalService.class。

## 尚未通过

- build-status.txt 为 exit_code=1。
- 顶层脚本最终 Successfully build Doris 未出现；日志止于 JDBC 插件解压。
- 因此 FE Java 编译与主要 JAR 生成已成功，但 output 的完整插件部署不能认定完成，尚未验证服务可启动。

## 收尾失败点

build.sh 在 JDBC 插件解压后，用 cp -n 从 jdbc.conf.template 初始化 jdbc.conf。实际目标 jdbc.conf 已存在。构建环境命中 /bin/cp（macOS BSD cp）；助手在临时目录以两份无敏感测试文件复现：目标已存在时 cp -n 不覆盖，静默返回 1。

build.sh 开启 set -e，因此“保留已有配置”这条正常路径会使脚本提前退出。日志位置、目标文件状态和最小复现一致，支持这是本次部署收尾失败的原因；尚未通过完整脚本 trace 重跑确认。

后续修复方向：仅在目标配置不存在时执行复制，已存在时正常继续，保留已有配置。不要删除真实配置或改成强制覆盖来消除报错。本次仅诊断，未修改 build.sh，也未启动 FE。

学习里程碑：FE 编译通过；Step 7 暂保留到顶层部署完成，再进入服务启动。
