# 源码深读补充专题

[返回全书](../README.md) · [原始检查与补齐记录](../BOOK_REVIEW.md)

这九篇接续原有 28 章，补入方法链、字段、事件与反例。按下表选读即可，不必重新从头学习。源码基线与原书一致；历史运行记录明确保留其旧版本边界。

| 专题 | 对应原章 |
|---|---|
| [专题 1　从真实 EXPLAIN 走到 FE/BE 协议与取消](01-query-rpc-and-cancellation.md) | 2—8、17、21 |
| [专题 2　列身份、统计、分布属性与增量物化视图](02-optimizer-statistics-and-mv.md) | 5—7 |
| [专题 3　从一列读取到更新、索引与 Schema Change](03-storage-updates-and-indexes.md) | 10—13、17 |
| [专题 4　副本写入、导入确认与恢复](04-load-replicas-and-recovery.md) | 14—16 |
| [专题 5　元数据持久化、维护作业与正常授权链](05-metadata-maintenance-and-access.md) | 18—20 |
| [专题 6　算子内存、背压、Spill 与缓存分层](06-memory-operators-and-caches.md) | 7—9、21 |
| [专题 7　外部范围、缓存失效与 UDF 生命周期](07-connectors-udf-and-ecosystem.md) | 22—24 |
| [专题 8　Cloud 元数据提交、Compaction 与回收](08-cloud-compaction-and-recycler.md) | 25—26 |
| [专题 9　真实 FE 修复复盘：SHOW LOAD 统计为什么在重启后消失](09-historical-fe-fix.md) | 27—28 |

## 证据入口

- [用户历史 SQL / EXPLAIN 原始副本](../examples/02-recorded-query/README.md)：有真实结果，非当前 HEAD 重跑。
- [Profile 与运行观测采集清单](../examples/03-observation-kit/README.md)：待运行，不填虚构数值。
- [历史 FE 修复](09-historical-fe-fix.md)：本地合入补丁、测试内容与公开 review 分开核对。

当前补齐的是代表性实现分析。真实 Profile、多副本故障、Cloud、外部系统与 UDF 实验仍待环境验证；各功能的全部模式和发布版本兼容矩阵不在本轮穷尽范围内。
