# Step 6：修正参数解析环境，再构建 FE

- 发布日期：2026-09-23
- 主动投入：20–30 分钟；安装和编译等待另计。
- 系统位置：开发工具链。先确保 FE 目标真正被选中，再观察 Java 编译与产物。
- 前置：Step 5 已完成证据收集，但 BUILD_FE=0，因此没有 FE 构建产物。

## 1. 补齐并验证 GNU getopt（约 5–10 分钟）

```bash
brew install gnu-getopt
```

然后从仓库目录测试构建所用的路径环境：

```bash
cd /Users/jiangyuan/open/doris
bash -c 'source ./custom_env_mac.sh; command -v getopt; getopt -n probe -o "" -l fe -l be -o "hj:" -- --fe'
```

预期命中 Homebrew 的 gnu-getopt，而非 `/usr/bin/getopt`；解析结果应保留 `--fe`，类似 ` --fe --`。若不符合预期，提交实际输出，不要进入构建。无需强制链接覆盖系统 getopt，也无需修改系统目录。

依据：[Homebrew gnu-getopt](https://formulae.brew.sh/formula/gnu-getopt)。本机 env.sh 已将其标准 Homebrew 路径加入构建环境，仍以实际探针输出为准。

## 2. 重试一次 FE 构建（主动操作约 5 分钟）

确认 Step 5 的依赖检查仍成立，然后执行：

```bash
cd /Users/jiangyuan/open/doris
BUILD_TYPE=ASAN bash build.sh --fe > /Users/jiangyuan/doris-guide/step6/build-fe.log 2>&1
build_exit=$?
printf 'exit_code=%s\n' "$build_exit" > /Users/jiangyuan/doris-guide/step6/build-status.txt
```

`BUILD_TYPE=ASAN` 与 bash 命令写在同一行，确保传给构建子进程。不加 --clean，不改 Doris 业务代码，也不直接改用 Maven 构建。

在另一个终端查看参数摘要：

```bash
rg 'BUILD_FE|BUILD SUCCESS|BUILD FAILURE|OUTPUT DIR' /Users/jiangyuan/doris-guide/step6/build-fe.log
```

参数摘要出现后，应看到 BUILD_FE 为 1。如果仍为 0，先保留证据并反馈，不把末尾成功文字当作 FE 成功。若仍在构建，只记“构建中”，不要启动第二次构建。

## 3. 用三层证据判断结果（约 10 分钟）

1. 目标：BUILD_FE 是否为 1？
2. 过程：有没有实际的 FE Maven 构建，以及其成功或失败信息？
3. 产物：output/fe 是否存在，里面有哪些主要目录和启动脚本？

同时记录退出码。若失败，提取第一处关键错误的上下文并说明它与上一轮是否相同；不要为了验收跳过检查。若成功，记录产物路径即可，下一步再安排 BE 和集群启动，不在本步直接启动服务。

## 交付与验收

在 RESULT.md 记录安装与解析探针输出、新构建日志、退出码或运行状态、三层证据、主动用时和等待时间。完整构建被新问题阻塞也可以提交，只要区分“参数修好了”与“FE 构建成功”。

一句话思考：为什么 Step 5 的退出码 0 不足以证明 FE 构建成功？不要求长篇总结。
