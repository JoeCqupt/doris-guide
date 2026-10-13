# Step 6 验收：参数解析已修复，进入真实 Maven 构建

- 日期：2026-09-23
- 结论：本步排障与证据收集通过；完整 FE 构建尚未成功。
- 用时：本人未提供，日志中的 Maven 耗时不能替代本人学习用时。
- 依据：RESULT.md、build-fe.log、build-status.txt、本地 POM 与脚本、实际 thrift --version。助手未重试构建或修改依赖。

## 已验证的进展

- getopt 命中 Homebrew GNU 版本，探针正确输出 `--fe --`。
- BUILD_FE=1，参数问题关闭。
- Maven 实际构建多个模块；部分成功，fe-thrift 失败，下游模块跳过。
- 状态文件 exit_code=1 与 BUILD FAILURE 一致。
- 本人独立指出“thrift 版本对不上”，定位正确。

## 当前根因

实际 `/Users/jiangyuan/open/doris/thirdparty/installed/bin/thrift --version` 为 0.16.0；当前仓库 fe/pom.xml 的 thrift.version 是 0.24.0，thirdparty/vars.sh 同样指定 0.24.0。

fe/fe-thrift/pom.xml 的 check-thrift-compiler-version 在生成 Java RPC 代码前检查编译器版本与运行库版本；该检查发现不一致并主动终止。这是构建期工具版本不匹配，尚未进入 RPC 网络运行问题。

概念链：Thrift IDL → Thrift 编译器生成 Java 类 → Java 类依赖 libthrift 运行库。升级源码后，之前安装的工具不一定同步升级；“工具存在且可运行”不等于“版本满足当前源码”。此次有明确版本门禁，应该对齐版本，而不是移除检查或把 POM 降回旧版本。

注意：终端 PATH 中还存在 thrift@0.13，但此次构建选用的是仓库 thirdparty 下的 0.16.0。仅调整 PATH 中的 thrift 不足以修改本次使用的绝对路径。

## 下一步依据

仓库 thirdparty/build-thirdparty.sh 支持传入单个 package，build_thrift() 会安装编译器及相应 C++ 库/头文件；thirdparty/vars.sh 已固定所需版本。Step 7 使用 `bash thirdparty/build-thirdparty.sh -j 2 thrift` 更新该依赖，再通过 build.sh --fe 重试。

这会更新本地 thirdparty 中的 Thrift 工具、头文件和库，不是 Doris 源码修改。第三方其他依赖或下载环境是否满足仍需运行验证，不保证此次更新就消除全部构建问题。

代码依据：fe/pom.xml 的 thrift.version；fe/fe-thrift/pom.xml 的 check-thrift-compiler-version；thirdparty/vars.sh 的 THRIFT_*；thirdparty/build-thirdparty.sh 的 usage、build_thrift。
