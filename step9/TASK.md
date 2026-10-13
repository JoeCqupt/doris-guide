# Step 9：准备 BE，收集第一次构建证据

发布日期：2026-10-08。主动投入约 30–45 分钟；编译等待另计，可跨天。

目标：尝试构建 BE，区分环境阻塞、编译失败与完整成功。系统位置：数据存储与查询执行端。联系：Step 8 已证明 FE 可接入；空 BE 列表与内部统计表初始化失败说明数据端仍待准备。

本步仅构建，不要求启动 BE、注册节点或建表。调整原因：先补齐实际可执行产物，再单独处理运行配置，避免一次任务混入太多变量。

## 1. 检查起点（5–10 分钟）

```bash
cd /Users/jiangyuan/open/doris
export JAVA_HOME=/Users/jiangyuan/dev/jdk-17.0.17.jdk/Contents/Home
uname -m
file "$JAVA_HOME/lib/server/libjvm.dylib"
df -h .
ls -l thirdparty/installed/lib/libbrotlienc.a
```

JDK 的 libjvm 应包含 arm64 架构。记录可用磁盘空间。本次发布时未发现 output/be/bin/doris_be；第三方 libbrotlienc.a 已存在。若检查发现该库缺失，先提交检查结果：当前 build.sh 在缺失这一标志文件时会删除并重建 installed 依赖目录，不要直接继续触发整套依赖重建。

FE 可以保持停止状态。保留 output/fe 的配置与元数据。无需重新构建 FE。

## 2. 进行一次构建（约 10 分钟操作，等待另计）

当前仓库 build.sh 支持 macOS BE 构建与 -j 参数。使用 ASAN、2 个并行任务作为本机首次尝试，不保证所有依赖已就绪；先不 clean。

在同一个终端执行，日志按时间命名，避免覆盖前一次证据：

```bash
cd /Users/jiangyuan/open/doris
build_stamp=$(date +%Y%m%d-%H%M%S)
be_log="/Users/jiangyuan/doris-guide/step9/build-be-${build_stamp}.log"
BUILD_TYPE=ASAN bash build.sh --be -j 2 > "$be_log" 2>&1
build_exit=$?
printf 'exit_code=%s\nlog=%s\n' "$build_exit" "$be_log" > "/Users/jiangyuan/doris-guide/step9/build-status-${build_stamp}.txt"
tail -n 60 "$be_log"
```

无需一直盯着等待。若失败，保留首个有意义的错误及上下文，不反复 clean、不自行切换依赖版本。若内存压力影响正常使用，可中断并如实记录，不把中断等同于源码编译错误。

## 3. 留下证据与一个解释（10–15 分钟）

- 在 RESULT.md 记录日志路径、退出码、主动用时与等待时间。
- 成功时记录顶层结束标志，并执行 `ls -lh output/be/bin/doris_be` 与 `file output/be/bin/doris_be` 保存产物证据；只有部分 C++ 目标成功还不等于整体成功。
- 失败时摘录第一个有效错误，写出你判断的阶段：第三方依赖 / CMake 配置 / 编译 / 链接 / 打包（不确定也可写）。
- 用自己的话回答：即使 BE 二进制构建成功，为什么还不能断言 SHOW BACKENDS 会出现 Alive=true 的节点？

验收：证据足以判断本次构建结果，能区分“构建产物”和“加入集群”；遇到明确环境阻塞同样可以提交，我们按证据调整。无需提前阅读 C++ 全部源码。

## 2026-10-08 下载调整

GitHub 子模块下载阻塞已通过复用本地仓库解决，三个所需 commit 已核对。原构建已停止，请重新执行第 2 步代码块，不加 --clean。详见 [下载排障记录](DOWNLOAD-NOTE.md)。

## 2026-10-08 OpenMP 环境修复

已安装 libomp，并在本地 custom_env.sh 配置 CMAKE_PREFIX_PATH；独立 C/C++ OpenMP 探测与运行通过。继续使用第 2 步构建命令，无需 clean。见 [OpenMP 排障记录](OPENMP-NOTE.md)。
