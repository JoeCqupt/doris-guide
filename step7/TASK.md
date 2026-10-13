# Step 7：对齐 Thrift 编译器与运行库版本

- 日期：2026-09-23
- 主动投入：20–30 分钟，下载和编译等待另计。
- 目标：把实际使用的 Thrift 工具升级到当前仓库要求的 0.24.0，再观察 FE 构建能否继续。
- 系统位置：RPC 接口代码生成的构建环节。尚未启动网络服务。

## 1. 记录旧版本并更新 Thrift

从仓库根目录执行：

```bash
cd /Users/jiangyuan/open/doris
thirdparty/installed/bin/thrift --version
bash thirdparty/build-thirdparty.sh -j 2 thrift > /Users/jiangyuan/doris-guide/step7/build-thrift.log 2>&1
thrift_exit=$?
printf 'exit_code=%s\n' "$thrift_exit" > /Users/jiangyuan/doris-guide/step7/thrift-status.txt
```

这是仓库支持的第三方依赖构建入口，显式只选 thrift，避免发起全量第三方重建。不加 --clean，不删除 installed 目录。脚本会下载/准备所需源包，更新本地 Thrift 编译器及相关头文件和库；其中会移除旧 Thrift 头文件以避免版本遮蔽，失败时也应保留日志，不用手动复制不同版本的头文件补救。

若下载或编译失败，先提交第一个关键错误及上下文，本步停在这里，不继续 FE 构建或盲目安装其他包。等待超出可用时间可记录“仍在构建”。

## 2. 验证新版本，再重试 FE

仅当依赖构建成功时执行：

```bash
cd /Users/jiangyuan/open/doris
thirdparty/installed/bin/thrift --version
```

应显示 `Thrift version 0.24.0`。务必检查仓库里的这个路径，不能用 PATH 中另一个 thrift 版本代替。

版本正确后运行：

```bash
BUILD_TYPE=ASAN MVN_OPT="${MVN_OPT:+$MVN_OPT }-Dmaven.build.cache.enabled=false" \
  bash build.sh --fe --clean  > /Users/jiangyuan/doris-guide/step7/build-fe.log 2>&1
build_exit=$?
printf 'exit_code=%s\n' "$build_exit" > /Users/jiangyuan/doris-guide/step7/build-status.txt
```

保持版本门禁与 Checkstyle，不降低 POM 版本，不直接使用错误日志推荐的 Maven resume 命令绕开仓库构建入口。

## 3. 记录结果与一个概念

- Thrift 更新是否成功，实际版本是多少？
- 新 FE 日志是否越过 check-thrift-compiler-version？是否出现新的首要错误？
- 若构建成功，核对 output/fe 的实际产物；若失败保留上下文，不把部分模块 SUCCESS 当作完整成功。
- 用一句话说明：Thrift 编译器、生成的 Java 类和 libthrift 运行库各自做什么？可联系你的 RPC 开发经验。

## 验收

有旧/新版本、第三方构建退出码和日志；满足版本前置后才进行 FE 重试；有准确的成功或阻塞判断。不保证一次消除全部环境问题，新的可定位阻塞也是有效成果。

日志分别保存在 step7，保留 step5、step6 的历史证据。无需改业务源码，也不启动 FE/BE。记录主动用时和等待时间。

## 最新进展：HDFS 测试编译阻塞

FE 日志显示 fe-thrift 已成功，新错误由旧模块同名 class 残留引起。助手已隔离该模块 target，下一次重试与新日志命名见 [HDFS-BUILD-NOTE.md](HDFS-BUILD-NOTE.md)。本 step 继续，不新增编号。
