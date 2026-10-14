# 一份真实 Profile：10 万行如何变成 5 行

[实验入口](README.md) · [原始 Profile](profiles/649b1cb4d6f9437e-8a036223d38609b7.txt) · [SQL 与 EXPLAIN](30-scale-profile.out.txt)

## 1. SQL、数据与查询身份

表 scale_numbers 有 100000 行，id 为 0..99999，k=id%1000。查询：

```sql
SELECT k, COUNT(*) n, SUM(id) total
FROM doris_book.scale_numbers
WHERE id >= 50000
GROUP BY k
ORDER BY total DESC, k
LIMIT 5;
```

Profile ID：`649b1cb4d6f9437e-8a036223d38609b7`，状态 OK，完成状态 COMPLETE，实际构建标识 a53b182f810，时间 2026-10-14 13:47:34。原始总耗时 17ms，仅代表这一轮单机运行。

每个 k 有 50 个符合条件的 id。k=999 的和为 50×999 + (50+...+99)×1000 = 3774950，后续 k 每减 1，总和少 50。原始断言 31 验证前五行，没有从 Profile 反向编造 SQL 结果。

## 2. 将节点与实际计数相连

只读原始文件的合并视图，避免再把下方 DetailProfile 相同实例重复累加：

| 节点/位置 | 原始指标 | 对应数据变化 |
|---|---|---|
| OLAP_SCAN_OPERATOR，id=0 | ScanRows=50000；RowsProduced=50000；ScanBytes=808.38 KB | 实际产出满足过滤的五万行；不能把该计数当完整底层磁盘行访问数 |
| LOCAL_HASH_SHUFFLE，id=7 | RowsProduced 总和 50000 | 本机按 k 重分布；不是跨机器流量证据 |
| STREAMING_AGGREGATION_OPERATOR，id=1 | RowsProduced 总和 1000 | 五万行归并成一千个 k 的中间状态 |
| 合并聚合后的排序 Sink | InputRows 总和 1000 | 排序候选一千组 |
| LOCAL_MERGE_SORT_SOURCE | RowsProduced 总和 5 | 本轮 TopN 最终只需五行 |
| RESULT_SINK | InputRows=5 | 结果返回五行 |

该 Profile 还展示 avg/max/min 及 instance_num=6 的 Pipeline。本地只有一个 BE，但同一个 BE 中可以有多个任务实例；不应把 instance_num 读作 BE 数量。

## 3. 内存与等待怎样解释

Streaming 聚合的 MemoryUsagePeak 总和为 1.59 MB，其中 MemoryUsageSerializeKeyArenaPeak 总和为 1.57 MB。它们属于该算子的计数口径，不是整个进程 RSS，也不是“全查询所有峰值相加”的精确上限。

结果 Exchange 的 WaitForData0 为 2.603ms；LOCAL_MERGE_SORT_SOURCE 的依赖等待平均 2.531ms。它们说明存在等待数据/依赖的阶段，不代表 CPU 忙算了同样时间。各 Pipeline 可以重叠执行，不能把每行耗时相加得出总耗时。

FE Summary 中 Plan Time=4ms、Schedule Time=8ms、Wait and Fetch Result Time=4ms，Fragment RPC Count=2。这为“规划、调度、执行等待是不同阶段”提供了实际例子；小数据样例不能用于生产性能选型或推断网络瓶颈。

本次未强制触发 Spill。不要把没有对应落盘证据写成“Spill 测试通过”。

## 4. 对照 Hash Join

[Join 原始 Profile](profiles/64ff366ed74b4013-a025dddfde100f32.txt) 对应 scale_numbers.k 与 unique_updates.id=7 的连接，最终 COUNT 为 100。HASH_JOIN_OPERATOR id=3 的 RowsProduced 总和为 100。

Profile 中一些 RuntimeFilterInfo 字段为空，且大表相关路径可见 100000 行计数。这里只解释已有计数，不宣称某个 Runtime Filter 已生效或减少了扫描；若要证明过滤收益，需要专门设计对照与生成/到达/应用证据。

## 5. 回到源码书

本例连接第 7—9 章的 Exchange、Pipeline、聚合状态与排序，以及第 21 章的 Profile。它证明这些实际算子与计数出现在本轮运行中；对象创建、状态所有权和取消正确性仍需要源码与专门测试分别支持。
