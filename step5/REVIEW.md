# Step 5 验收：有效构建尝试已完成，FE 实际未构建

- 日期：2026-09-23
- 结论：本步“提交真实构建证据并识别阻塞”的目标通过；不能记为 FE 构建成功。
- 本人主动用时和等待时间：均未提供。
- 证据：RESULT.md、build-fe.log、build-status.txt，以及助手只读检查和参数解析复现。助手未重跑构建、未安装软件、未修改 Doris 代码。

## 关键证据

1. 状态文件确实记录 `exit_code=0`，日志最后也有 `Successfully build Doris`。
2. 但日志第 15 行明确显示 `BUILD_FE -- 0`，BE、Cloud 等构建目标也为 0；没有 FE Maven 构建过程，只有生成代码等公共步骤。
3. 默认 output/fe 不存在，与本人观察一致。
4. env.sh 为 macOS 生成的工具路径包含 `/opt/homebrew/opt/gnu-getopt/bin`，但该目录下的 getopt 不存在。加载已有 custom_env_mac.sh 后，实际命中的是 `/usr/bin/getopt`。

因此，退出码 0 只能证明脚本所执行的路径未以错误码结束，不能证明预期目标被选中或产物存在。你没有盲信成功文字，而是检查产物，这个观察是正确的。

## 根因：参数解析工具不兼容

build.sh 使用 GNU getopt 的长选项接口解析 `--fe`。助手在与脚本一致的 macOS 路径配置下执行了以下最小复现，只解析参数，不构建：

```bash
bash -c 'source ./custom_env_mac.sh; command -v getopt; getopt -n probe -o "" -l fe -l be -o "hj:" -- --fe'
```

实际输出：

```text
/usr/bin/getopt
 -- probe -o  -l fe -l be -o hj: -- --fe
```

错误解析结果以 `--` 开头。build.sh 执行 `eval set --` 后，参数循环立即进入 `--)` 分支并停止；于是 BUILD_FE 保持初始值 0。后续脚本完成公共步骤，并在结尾打印成功文字，解释了为何“退出码 0 但没有 FE 产物”。

源码依据：build.sh 的 getopt 调用、参数初始化与循环（约 258–449 行），env.sh 的 macOS 工具路径生成（约 44–100 行）。这是一条由本机证据支持的环境问题链条，不是 JDK 或业务源码编译失败。

## 两个附加反馈

- 原任务给出的 `BUILD_TYPE=ASAN bash build.sh --fe` 是单条命令。本人记录成先赋值再单独执行，若变量未 export，子进程不一定能继承；请恢复单行写法。这不是本次 BUILD_FE=0 的原因，但应顺手修正。
- 日志中的 `find ... Permission denied` 不是这次未选择 FE 的直接原因，不需要先围绕它修改权限。

## 下一步

Step 6 安装并验证 GNU getopt，再重新构建 FE。先验证参数被正确解析，再投入编译等待时间；保留本次日志，新的日志放到 step6。

Homebrew 官方安装命令为 `brew install gnu-getopt`；该包是 keg-only，因为 macOS 已提供 BSD getopt，安装后还应验证 Doris 构建环境命中的实际路径。[官方 Formula](https://formulae.brew.sh/formula/gnu-getopt)

这是一个潜在的构建体验改进线索：依赖未满足时没有及时失败、构建目标为空却显示成功。后续可核实上游版本与已有 issue/PR；本次未检索认领状态，不把它记录成已确认的可贡献任务，也未向社区发送消息。
