# PCH OpenMP 参数修复 — 2026-10-08

根因：be/CMakeLists.txt 两处把 OpenMP_CXX_FLAGS 的空格分隔字符串直接传给编译选项。AppleClang 返回 -Xclang -fopenmp，最终生成一个带空格的 argv 元素，编译器拒绝它。将两处改为带引号的 SHELL: 分组，保留参数边界及分组，保持原有 PCH 和 OpenMP 设置。

依据：https://cmake.org/cmake/help/latest/command/target_compile_options.html#option-de-duplication

## 验证

- 从修改前/后的实际 CMake 文件提取完整 OpenMP/PCH 配置块，建立独立最小项目（pch-flags-probe）。修改前复现 unknown argument，退出 2；修改后 PCH、复用 PCH 的程序编译链接及运行成功，退出 0。
- 实际执行 BUILD_TYPE=ASAN bash build.sh --be -j 2，日志 build-be-openmp-flags-fix.log。CMake 成功、Built target pch。本轮整体退出 2，因为 common/cpp/aws_common.cpp 缺少 aws/core/auth/GeneralHTTPCredentialsProvider.h；没有宣称完整构建通过。
- git diff --check 通过。仅修改 CMake，无 C++ 格式修改，无头文件/包含图修改。没有执行全量 UT、Linux 构建或 ELF ABI 检查。

## code-review Part 1.3 自查

- 目标：修复多参数字符串；复现和实际 PCH 构建支持结论。
- 最小性：两处同类选项修改、一行原因注释。
- 并发/线程上下文/锁/原子序：不涉及运行时代码。
- 生命周期/静态初始化：不涉及。
- 配置：无新增用户配置，PCH 条件保持不变。
- 兼容性：不修改存储格式、协议、函数符号或 glibc 基线；Linux 未实测，不声称跨平台全量通过。
- 平行路径：全局 C++ 选项及 PCH PUBLIC 选项均已修复。
- 条件分支/断言：没有新增检查或绕过失败路径。
- 测试覆盖：原始失败、修复成功、实际 BE PCH；完整 BE 被独立 AWS 依赖阻塞。
- 测试结果：保留实际日志，未手写 SQL regression 输出。
- 可观测性：沿用构建日志，无新增运行路径或分布式追踪要求。
- 事务/持久化/EditLog/数据写入/版本/MoW：不涉及。
- FE/BE 参数传递：不涉及。
- 性能/内存/所有权：仅配置时参数解析，无新增运行时分配或热路径。
- Status/异常转换/错误上下文：未修改运行时错误处理；编译错误继续正常失败。
- Null/Nullable 六项检查：均不涉及列处理代码。
- 其他问题：AWS SDK 头文件缺失仍需后续定位。助手修复，不作为用户独立贡献或已合并 PR。


## 2026-10-09 撤销记录

按用户要求，已从当前本地分支撤销 PCH 提交 b306a0b1b4b，并恢复 be/CMakeLists.txt；当前 HEAD 为 024e7779fef。用户其他未提交改动保留；未重编译、未改运行产物。补丁仅作历史备份保存在 step9/reverted-pch-change.patch，不作为待提交贡献。此前直接推荐此问题作为贡献候选判断不足，应先按官方 macOS 工具链说明排查环境并核实上游。
