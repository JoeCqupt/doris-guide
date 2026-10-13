# FE proto 类缺失：clean 后恢复了无类的缓存 JAR

## 已核实的直接原因

最新 step7/build-fe.log 记录：

- 第 827 行：删除 fe/fe-grpc/target，说明 clean 确实执行。
- 第 1955 行：从缓存恢复 org.apache.doris:fe-grpc，checksum 为 106c9dae3ce160b6。
- 第 1995 行：`Skipping plugin execution (cached): protoc-jar:run`，没有重新执行 Java proto 生成。

助手用 `jar tf fe/fe-grpc/target/doris-fe-grpc.jar` 检查实际产物：只有 META-INF、annotations 等条目，没有 org/apache/doris/proto 或 org/apache/doris/cloud/proto 的生成类。target 下也没有对应生成源码和 classes。

fe-core 的 POM 依赖 fe-grpc；fe-grpc 的 POM 在 generate-sources 阶段调用 protoc-jar 插件。因此 fe-core 的缺包错误由上游缺类产物引起，不是要在 Auth.java、Backend.java 或 StmtExecutor.java 中改 import。

## 为什么 clean 没解决

clean 清理模块 target，不等于清理或禁用 Maven build-cache。此次之后又从缓存恢复了无类 JAR，生成和编译被跳过。此前只推荐 --clean 未覆盖这层缓存；本轮证据说明需要补上禁用缓存。

缓存里最初为何存入这个无类 JAR尚未查明。当前可以确认的是它被恢复并导致缺类，不能把缓存最初生成原因当成已确定的源码 bug。

## 重试命令（尚未由助手执行）

build.sh 会把 MVN_OPT 中的参数传入 FE Maven 构建。保持仓库标准入口，一次同时清理并禁用构建缓存：

```bash
cd /Users/jiangyuan/open/doris
BUILD_TYPE=ASAN MVN_OPT="${MVN_OPT:+$MVN_OPT }-Dmaven.build.cache.enabled=false" \
  bash build.sh --fe --clean \
  > /Users/jiangyuan/doris-guide/step7/build-fe-nocache.log 2>&1
build_exit=$?
printf 'exit_code=%s\n' "$build_exit" \
  > /Users/jiangyuan/doris-guide/step7/build-nocache-status.txt
```

这不是跳过 Checkstyle 或测试编译，也不需要删除整个 ~/.m2/repository。日志中应出现实际 protoc 生成过程，而不是其 cached skip；再检查 JAR 内是否存在 Cloud 和 InternalService 等类。若实际生成报出新错误，保留生成阶段的错误继续定位，尚不能承诺完整 FE 构建通过。
