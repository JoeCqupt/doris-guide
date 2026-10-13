# Step 12 验收反馈

日期：2026-10-09。首次验收结论：查询计划对比与逻辑推导通过，FE 表示待补充。最新结论见文末补交验收。用时未填写，不推测。

## 已通过的部分

- A 有 4 个聚合节点（1/3/4/6），B 有 2 个（1/3）；正确指出 A 先按 city,user_id，随后按 city；B 只按 city。
- 两者扫描同一张表、过滤条件相同。不过并非扫描输出完全相同：A 投影 city,user_id,amount，B 投影 city,amount。这是补充观察，不要求返工。
- 手工小表正确：Beijing/101 金额150订单2；Beijing/102 金额80订单1；Shanghai/101 金额90订单1；Shanghai/103 金额150订单2。
- 城市结果写成 2/230/3、2/240/3，按“去重人数/金额/订单数”解释是正确的；字段顺序没有标明，补列名即可，不能直接认定算错。
- 正确说明丢失城市维度的问题，以及局部去重数不能直接相加。

## 需要修正的表述

“订单数丢失了/压缩了”不够准确：原始行合并了，但订单数保存在聚合状态/你的小表订单数字段中，并未丢失。下一层要累加它。小表按 city,user_id 唯一且本例 user_id 非空，所以每个城市数小表行数可得到去重人数；不要推广到含 NULL 的 COUNT(DISTINCT) 而忽略 NULL 语义。

物理计划也描述“如何执行”，例如使用 HashAggregate、分发方式及阶段；它不是只包含业务目标。应区分“FE 用 Java 对象描述执行方式”与“BE 按计划处理实际数据”。

## 对 count(partial_count(...)) 疑问的核验

你的解释正确：这是 COUNT 状态的合并，不是对普通数值再执行 SQL COUNT。当前源码 `be/src/exprs/aggregate/aggregate_function_count.h` 中：

- `AggregateFunctionCount::add()` 对状态计数加一。
- `AggregateFunctionCount::merge()` 执行 `data(place).count += data(rhs).count`（约第 80 行）。
- `deserialize_and_merge_from_column_range()` 同样累加各状态计数。

因此两个 COUNT 状态分别表示 2 与 1 时，合并得到 3；对普通两行数值执行 SQL COUNT 则得到 2。这里核验的是语义依据，未对本次运行做断点或证明一定调用单行 merge 而非批量合并路径。

## FE Java 阅读：明确原问题

原任务想让你把术语对应到 Java 字段，不是让你追完整调用链。例如 `getGroupByExpressions()` 返回 `groupByExpressions`，它表达按哪些表达式分组。

你对 productAggregateBuffer 的 true/false 判断正确；consumeAggregateBuffer 及四种模式尚未提交。`getAggMode()` 返回 `aggregateParam.aggMode` 是另一个可观察入口。以上是教学反馈，不记为你已独立掌握。

## 补交（只在 RESULT.md 末尾追加，5–10 分钟）

1. 给城市统计补上列名；用一句话把“订单数丢失”改成准确描述。
2. 按源码补四行：INPUT_TO_BUFFER、INPUT_TO_RESULT、BUFFER_TO_BUFFER、BUFFER_TO_RESULT 各自“消费什么 → 产出什么”，并说明 consumeAggregateBuffer=true 的含义。
3. 假设只把 GROUP BY city 改成 GROUP BY city,user_id：PhysicalHashAggregate 中你预计哪个字段对应变化？这是否意味着这个 Java getter 自己执行了数据分组？说明理由。

不需要重复贴 EXPLAIN 或重新跑数据。B 普通 SELECT 实际结果尚未提交（A 结果可沿用 Step 11），这是证据记录缺口，不阻塞此次概念补交。可顺手补贴但不要求为此重启集群。用时可一起补充。

1. “订单数丢失了“不够准确：原始行合并了，但订单数保存在聚合状态/你的小表订单数字段中，并未丢失。下一层要累加它。
2. 不同的聚合模型
/** AggregateMode */
public enum AggMode {
    INPUT_TO_BUFFER(true, false),
    INPUT_TO_RESULT(false, false),
    BUFFER_TO_BUFFER(true, true),
    BUFFER_TO_RESULT(false, true);

    public final boolean productAggregateBuffer;
    public final boolean consumeAggregateBuffer;

    AggMode(boolean productAggregateBuffer, boolean consumeAggregateBuffer) {
        this.productAggregateBuffer = productAggregateBuffer;
        this.consumeAggregateBuffer = consumeAggregateBuffer;
    }
}
3. PhysicalHashAggregate  groupByExpressions 字段会变，  不意味着 Java会执行数据分组， 应该是be执行数据查询/分组/聚合等操作

## 2026-10-09 补交验收（助手）

本人补充位于本文件前段末尾，保留原文，不要求搬到 RESULT.md。

结论：核心目标通过，进入 Step 13；AggMode 消费侧独立应用仍待验证。

- 订单数保存在聚合状态、下一层累加的表述已更正。不过与反馈文字一致，暂不把这条单独视为迁移能力证据。
- 正确定位 groupByExpressions，正确区分 Java 计划表示与 BE 实际执行。
- 提交了 AggMode 枚举，但尚无四种输入/输出的独立解释，不能把贴源码等同于掌握。改用 Step 13 的具体 AVG 状态流转验证，不再重复定义填空。
- 不新增独立缺陷门槛：城市结果列名、B 普通查询输出的小缺口保留为记录，不阻止推进。实际用时未知。
