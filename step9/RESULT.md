# Step 9 结果

- 状态：构建成功
- 日期：2026-10-08
- 主动用时 / 构建等待：待补充

## 前置检查

架构、JDK、磁盘与依赖检查结果：

- macOS arm64，JDK 17 可用。
- 增量构建中发现并补齐了 `arrow_adbc`、`lance_c` 和 `simdutf` 第三方依赖。

## 构建证据

- 日志路径：`/Users/jiangyuan/doris-guide/step9/build-be-20261008-182739.log`
- 退出码及状态文件：`0`；`/Users/jiangyuan/doris-guide/step9/build-status-20261008-182739.txt`
- 成功标志与产物：日志包含 `Built target doris_be` 与 Maven `BUILD SUCCESS`。产物位于 `output/be/lib/doris_be`，为 1.5G 的 `Mach-O 64-bit executable arm64`；当前安装布局不在文档预期的 `output/be/bin/doris_be`。
- 排障链路：
1.  Apple Clang 探测 OpenMP 时找不到 omp.h，本机缺少 libomp
2.  CMake 把 -Xclang -fopenmp 错当成一个参数；我修正了两处参数分组。
3.  缺失的 AWS SDK 头文件
4.  环境脚本指定了 llvm@20，但本机没安装，实际回退到了 Apple Clang 17。
5. 发现缺少 Hadoop 3.4 的 libhdfs 头文件，而本机只有旧的 libhdfs3
6. Boost.Process 为什么在 macOS 上选用了 sigtimedwait，以及已有兼容配置为什么没生效， 原因找到了：仓库已经有 Boost 1.81 的 macOS 兼容补丁，但本机安装的 Boost 头文件没有应用它。编译参数里的 -U 也挡不住头文件随后重新定义这个宏。
7。 本机 Arrow 是 17.0.0，当前源码要求 24.0.0，并带 Doris 的 INT96 写入补丁。报错的方法正是补丁新增的
8. 缺失 `arrow-adbc/adbc.h`，随后链接阶段依次缺失 `liblance_c.a`、`libsimdutf.a`；三个依赖均通过 `thirdparty/build-thirdparty.sh <package>` 增量构建补齐，未执行 clean。

## 理解

为什么 BE 构建成功不等于已加入集群且 Alive=true：

BE 仍需以正确配置启动，并通过 `ALTER SYSTEM ADD BACKEND` 注册到 FE；FE 与 BE 的网络、心跳端口、地址和身份配置也必须可达且一致。仅有本地二进制不能证明节点已加入或能正常心跳。

## 助手反馈

BE 构建与产物验证完成；尚未启动或注册 BE。
