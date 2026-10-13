# Step 4 验收报告

## 补交验收：核心目标通过（2026-09-23）

正确给出北京 2 人、上海 2 人，并明确丢失城市后不能恢复每城统计；合并伪代码按城市 key 组织，流程中也已加入 Aggregate 和全局排序。足以通过本步概念验收，发布 Step 5。补交额外用时未提供，仍记录原先报告的 40 分钟。

有三个实现/表达细节需反馈，但不要求反复重交架构练习：

1. `getOrDefault(k, new BitSet())` 不会在缺键时把默认值写入 Map。当前示例的 nodeA、nodeB 会一直为空。应使用 `computeIfAbsent`，例如：

   ```java
   nodeA.computeIfAbsent("beijing", k -> new BitSet()).set(1);
   Map<String, BitSet> merged = new HashMap<>();
   nodeA.forEach((city, bits) ->
       merged.computeIfAbsent(city, k -> new BitSet()).or(bits));
   nodeB.forEach((city, bits) ->
       merged.computeIfAbsent(city, k -> new BitSet()).or(bits));
   ```

   `final` 还是 Java 关键字，不能作为变量名。本题允许伪代码，按 key 合并的思路已通过，但这段原文不能作为可执行 Java 的验证证据。
2. 补充图中 Gather 与 Aggregate 之间缺少连线，补上 `Gather → Aggregate` 才是连通的流程。无需据此认定真实 Doris 的排序一定单独占一个 Fragment；真实边界仍待 EXPLAIN 验证。
3. 丢掉城市全合并后得到 `{U1,U2}`、人数 2，虽然碰巧与各城市人数相等，仍丢失了“两条城市结果及其归属”。数字相等不意味着查询语义相同。

本次为文档和伪代码语义验收，未运行该伪代码，也未启动 Doris。环境准备只读检查确认：本地存在可执行 protoc（3.21.11），存在 macOS 构建脚本检查的 libbrotlienc.a，可找到 Maven；默认 output/fe、output/be 暂未发现。不能据此断言全部依赖完备，也不能排除其他位置已有产物。以下保留初次验收记录，以本节为最新结论。

---

- 日期：2026-09-23
- 实际用时：40 分钟（本人报告）
- 结论：FE/BE 主线基本通过，分组信息与最终聚合仍需补齐。保持 Step 4，补一个约 10 分钟的具体例子，不要求重画整套流程。
- 依据：RESULT.md 中的流程与解释；未启动 Doris，未生成真实 EXPLAIN。

## 逐项验收

| 项目 | 结论 | 反馈 |
| --- | --- | --- |
| FE 规划、BE 执行 | 基本通过 | 已区分 SQL 分析规划、下发执行片段和 BE 执行 |
| FE 的职责范围 | 需补充 | FE 不仅是查询规划，还承担请求接入、执行协调、元数据及集群管理；避免把“主要不扫描订单行”理解成“只规划” |
| 分布式执行流程 | 部分通过 | 能画出两侧扫描与局部聚合，但 GATHER 后缺少合并聚合及最终化的含义 |
| Bitmap 所处位置 | 通过类比 | 属于执行时可合并的聚合状态；这不表示所有 COUNT(DISTINCT) 都采用 Bitmap |
| 按城市合并 | 未通过解释项 | “只传 Bitmap 就够了”遗漏了聚合状态与分组的对应关系，需一个具体反例巩固 |
| 环境记录 | 通过 | 已确认有源码、没有完整启动过 FE+BE；完整编译情况仍未知，不推测已编译成功 |

## 1. 为什么还要知道城市

把 Bitmap 理解成 Map 的 value，把城市理解成 key：

```text
局部聚合结果：Map<City, Bitmap>
合并操作：对同一个 City 的 Bitmap 求并集
```

如果接收端只收到 `{U1}`、`{U2,U3}` 两份集合，没有标签或其他分组对应信息，它无法知道哪个属于北京、哪个属于上海，也就不能可靠地输出每座城市的人数。

精确要求是“保留足以识别分组的信息”。不意味着每条网络消息一定携带完整城市字符串；实现可以使用编码、批次或协议上下文，但分组对应关系不能消失。特别地，不带 GROUP BY 的全表去重只有一个组，才不需要城市维度。

Step 3 中分别维护 setBeijing 和 setShanghai，变量本身就隐含保存了这个分组关系；变成跨节点的中间结果时，这层关系仍然需要存在。

## 2. SCAN、FILTER 和 GROUPING 能在同一 stage 吗

若你说的是同一个 **PlanFragment（执行片段）**，可以有扫描、过滤和局部聚合。过滤也可能成为扫描节点的谓词，不一定单独显示为一个 FILTER 节点。

但 PlanFragment、运行实例、Pipeline 不是同一层概念：一个 Fragment 可以有多个运行实例，内部也可能因算子依赖拆成多个 Pipeline。现在先掌握 Fragment 与数据交换边界，不必把它们统称为一个 stage 或认为“一片段只对应一台 BE”。

## 3. Gather 不是最终聚合

Gather 表示把多路数据汇集到单一路径。它本身不会自动把相同城市的两条部分统计合并成一条最终统计。某些计划也会先按分组键进行 Hash Exchange，将同组数据送往同一接收实例，而不是直接 Gather 全部中间状态。

下面仅是便于理解的二阶段聚合模型，不是本机真实执行计划，也不承诺原始 COUNT(DISTINCT) 恰好使用这条路径：

```text
片段 A/B（并行执行）：
  扫描 + 过滤 → 按城市局部聚合
                      │
                      │ 交换带分组信息的中间状态
                      ▼
合并侧（仍是执行工作）：
  按城市合并金额、订单数、去重状态 → 得到最终数值
                      │
                      ▼
  全局排序所需处理 → 结果返回客户端（由 FE 协调）
```

片段边界与实例分配由实际计划决定，不能从 SQL 写法或“有两台 BE”直接推导片段个数。最终聚合不应在图中默认为由 FE 用 Java 汇总全部订单。

你画的优化流程也可以先简化为“解析/分析 → 优化与物理计划选择 → 分布式执行计划与调度”。无需认定 RBO、CBO、HBO 在每条 SQL 上都按固定顺序运行。

## 4. 真实计划名的一个入口

本地 `fe/fe-core/src/main/java/org/apache/doris/planner/AggregationNode.java` 的 `updateplanNodeName()` 会依据状态生成包含 `update` 或 `merge`、`serialize` 或 `finalize` 的聚合节点名。大意是区分处理输入/合并状态，以及输出中间状态/最终结果。

这只是源码中的命名依据，不是已经跑出的 EXPLAIN。后续真正运行 Doris 时，再将计划中的节点与这些概念对照。

来源：[官方系统架构](https://doris.apache.org/zh-CN/docs/4.x/features-architecture/system-architecture/)；[本地聚合节点命名方法](/Users/jiangyuan/open/doris/fe/fe-core/src/main/java/org/apache/doris/planner/AggregationNode.java:101)。本次外部查询计划检索失败，没有把网上未知的计划当作实验结果。

## 最小补交（约 10 分钟）

不重画完整架构图，只在 RESULT.md 追加下面这个小练习：

```text
节点 A：北京 → {U1}；上海 → {U2}
节点 B：北京 → {U2}；上海 → {U1}
```

1. 写出正确的各城市去重人数，以及丢掉城市信息、把四份集合全合并后的结果。说明后者为什么不能代替前者。
2. 用一个 Java Map 风格的伪代码片段表达“按城市找到状态，然后合并”，不要求实际运行。
3. 在原计划流程后补一行，指出 Gather 后仍需要哪项计算才能得到每城的一行结果。

通过后进入真实 Doris 环境准备与 EXPLAIN 体验；当前不要求提前安装、启动或运行全量构建。
