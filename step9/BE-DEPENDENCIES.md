# BE 依赖与工具链排障（2026-10-08）

本次助手代为执行构建排障，不计为用户独立完成源码修复。

## 已验证解决

- AWS SDK：安装目录旧版 1.11.219，与 thirdparty/vars.sh 固定 1.11.221 不一致，缺少 GeneralHTTPCredentialsProvider.h。执行 `bash thirdparty/build-thirdparty.sh -j 2 aws_sdk` 成功（exit 0）；版本和头文件已核实，随后 BE 中 aws_common.cpp 及 AWS 凭据相关文件编译通过。日志 build-aws-sdk.log、build-be-after-aws.log。
- Azure：本机 SDK 未安装。当前学习使用本地存储，已在 Git 忽略的 custom_env.sh 加 `export DISABLE_BUILD_AZURE=ON`，使用仓库正式开关。此构建不支持 Azure Blob/Azure storage vault；需要该功能时应安装 SDK 并重新启用。

## 工具链调整

env.sh 的 macOS 工具列表指定 llvm@20，但本机缺失，先前 CMake 回退为 AppleClang 17。旧构建随后触发 DateV2Value 的 trivially-copyable 断言、bit_cast 约束和 shadow 警告。

已通过 Homebrew 安装 llvm@20（20.1.8），并在 custom_env.sh 设置 `export DORIS_CLANG_HOME=/opt/homebrew/opt/llvm@20`。旧 be/build_ASAN 重命名为 be/build_ASAN.appleclang17-backup；新 CMakeCache 已验证 C/C++ 编译器均为 llvm@20 路径。

继续以 `BUILD_TYPE=ASAN JAVA_HOME=/Users/jiangyuan/dev/jdk-17.0.17.jdk/Contents/Home bash build.sh --be -j 2` 构建，日志 build-be-llvm20.log。当前尚未确认整体构建成功。

## LLVM 20 验证与 Hadoop

LLVM 20 实际 BE 编译中，AppleClang 日期类型断言和 bit_cast 错误不再出现；随后因缺少 hadoop_hdfs_3_4/hdfs.h 失败。旧安装只有 libhdfs3，与当前 JNI libhdfs 不等价。

执行定向构建 hadoop_libs_3_4。首次遇到 CMake 4 不兼容旧 policy minimum；通过 CMAKE_POLICY_VERSION_MINIMUM=3.5 环境变量重试，已越过该错误。日志 build-hadoop.log（失败）和 build-hadoop-cmake-policy.log（重试）。没有改写业务代码或替换 HDFS 接口。
