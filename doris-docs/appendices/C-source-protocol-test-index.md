# 附录 C　源码、协议、配置与测试索引

[全书导航](../README.md)

> 整理日期：2026-10-13；对应正文源码基线 `a53b182f810be2b3731c7dfdf6f40ff5a0ad63bd`。

本索引路径相对 `/Users/jiangyuan/open/doris`。目录入口用于缩小搜索范围；精读方法与状态边界见对应章节。路径存在不代表目录内每个实现都已核验。

## C.1 按行为找源码

| 行为 | 首选入口 | 正文 |
|---|---|---|
| 收到一条 SQL | `fe/fe-core/src/main/java/org/apache/doris/qe/ConnectProcessor.java` | [4](../chapters/04-request-session-and-command.md) |
| 选择查询计划 | `fe/fe-core/src/main/java/org/apache/doris/nereids/NereidsPlanner.java` | [5—6](../chapters/06-memo-statistics-and-cost.md) |
| 协调分布式查询 | `fe/fe-core/src/main/java/org/apache/doris/qe/Coordinator.java` | [7](../chapters/07-fragments-scheduling-and-exchange.md) |
| 执行 Pipeline | `be/src/exec/pipeline/pipeline_task.cpp` | [8](../chapters/08-pipeline-and-vectorized-execution.md) |
| 读取内表数据 | `be/src/storage/` | [11](../chapters/11-tablet-rowset-and-segment.md) |
| 导入与事务 | `fe/fe-core/src/main/java/org/apache/doris/load/`、`fe/fe-core/src/main/java/org/apache/doris/transaction/` | [14—16](../chapters/16-transaction-commit-publish-visible.md) |
| FE 日志与恢复 | `fe/fe-core/src/main/java/org/apache/doris/persist/` | [18](../chapters/18-metadata-journal-and-fe-ha.md) |
| 访问外表 | `fe/fe-connector/`、`be/src/format_v2/` | [22—23](../chapters/23-external-table-query.md) |
| 插件契约与加载 | `fe/fe-extension-spi/`、`fe/fe-extension-loader/` | [24](../chapters/24-integration-and-extension.md) |
| Cloud 提交与回收 | `cloud/src/meta-service/`、`cloud/src/recycler/` | [25—26](../chapters/26-cloud-read-write-and-maintenance.md) |

## C.2 协议与生成代码

`gensrc/thrift/` 和 `gensrc/proto/` 是协议定义入口。先用消息名定位定义，再查发送者如何赋值和接收者如何解释；不能只凭字段名称推断默认值、可选字段兼容性或业务完成状态。

生成代码是协议的构建产物，不应作为手工修复协议的主要入口。跨 FE/BE/Cloud 的变更需要同时检查生产者、消费者及旧版本缺失字段时的行为。具体生成与构建流程使用仓库脚本，避免手动生成一份与实际构建不一致的代码。

## C.3 配置与运行产物

`conf/` 是配置入口，`output/` 是构建产物入口；正在运行的进程可能使用另外一份复制后的配置。排查时记录进程启动目录、配置文件和服务版本，不能仅查看仓库中的模板就认定它已经生效。

配置名可从实际错误、日志或代码中的读取位置反查。区分全局配置、Session 参数、Catalog 属性、表属性，它们的修改时机和作用域不同。不要在本索引固定一份随版本变化的默认参数清单。

## C.4 测试入口

| 层次 | 路径 / 脚本 | 能帮助回答 |
|---|---|---|
| FE 单测 | `fe/fe-core/src/test/`；`run-fe-ut.sh` | 方法、状态或规则的局部行为 |
| Connector 单测 | `fe/fe-connector/` 各模块的 src/test | 接口契约、转换和生命周期 |
| BE 单测 | `be/test/`；`run-be-ut.sh` | 存储与执行数据结构的局部行为 |
| Cloud 测试 | `cloud/test/` | Meta Service、KV 适配与回收行为 |
| SQL 回归 | `regression-test/`；`run-regression-test.sh` | 用户可观察的端到端语义 |

运行前阅读所在目录 AGENTS.md 和脚本帮助；不是所有模块都能套用同一组参数。构建统一从 `build.sh` 进入。索引列出测试位置，不表示这些测试已运行或足以覆盖一个新修改。

## 深读定位索引

| 接缝 | 类型/方法 | 对应材料 |
|---|---|---|
| FE → BE | PExecPlanFragmentRequest / TPipelineFragmentParamsList；query_id、fragment、desc_tbl、local_params | [专题 1](../deep-dives/01-query-rpc-and-cancellation.md) |
| 统计任务 → 缓存 | AnalysisJob.flushBuffer / StatisticsCache.doGetColumnStatistics | [专题 2](../deep-dives/02-optimizer-statistics-and-mv.md) |
| IVM 验证 | regression-test/suites/mtmv_p0/ivm | [专题 2](../deep-dives/02-optimizer-statistics-and-mv.md) |
| 写入发送 → 接收 | VNodeChannel / LoadChannel / TabletsChannel；packet_seq、EOS、tablet_errors | [专题 4](../deep-dives/04-load-replicas-and-recovery.md) |
| 查询采集设置 | enable_profile（Session）；实际阈值另查服务变量 | [观测清单](../examples/03-observation-kit/README.md) |
| Iceberg 范围 | IcebergScanRange.populateRangeParams / DeleteFile.toThrift | [专题 7](../deep-dives/07-connectors-udf-and-ecosystem.md) |
| 恢复测试实例 | test_insert_statistic_after_fe_restart.groovy（历史合入补丁） | [专题 9](../deep-dives/09-historical-fe-fix.md) |

这些测试入口经过文件/历史补丁核对，本轮未运行；不要把索引视为通过清单。
