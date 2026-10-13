# OpenMP 配置排障 — 2026-10-08

根因：be/build_ASAN/CMakeCache.txt 显示 C/C++ 编译器为 /usr/bin/clang 与 clang++，OpenMP 探测失败。CMakeFiles/CMakeConfigureLog.yaml 中实际错误为 omp.h file not found。本机未安装 libomp，OpenBLAS 的 USE_OPENMP=TRUE 要求 find_package(OpenMP COMPONENTS C REQUIRED)。

助手已执行：

1. brew install libomp，安装成功（23.1.3）。它是 keg-only 包，不会默认链接到 Homebrew 公共前缀。官方说明：https://formulae.brew.sh/formula/libomp 。
2. 备份 custom_env.sh 至本目录 custom_env.before-openmp.sh，随后在仓库本地 custom_env.sh 追加：

```bash
export CMAKE_PREFIX_PATH="/opt/homebrew/opt/libomp${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
```

该文件被 Git 忽略，未修改或提交源码，未更改全局 shell 环境，也未编辑自动生成的 custom_env_mac.sh。

3. 在本目录 openmp-probe 建立独立最小 C/C++ 探测项目，使用相同 AppleClang 17 与 CMake、读取相同 custom_env.sh。FindOpenMP 的 C 和 CXX 均成功（5.1），两个程序均成功编译、链接和运行，打印 OpenMP workers=2，退出 0。这是独立依赖验证，不是 Doris 完整构建验证。

下一步：重新执行 TASK.md 第 2 步的 build.sh --be -j 2，保留新日志，不加 --clean。build.sh 会重新运行 CMake。未重新执行整个 BE 构建，后续是否有其他配置或编译阻塞仍待日志确认。
