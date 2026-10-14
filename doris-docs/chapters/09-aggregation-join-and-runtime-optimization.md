# 第 9 章　典型算子与执行优化

[全书导航](../README.md) · [术语表](../appendices/A-glossary.md)

> 教学结构修订：2026-10-14。每章先沿一个问题阅读代码，再做实验、观察结果，最后解释对象和分支。历史正文基线为 `a53b182f810be2b3731c7dfdf6f40ff5a0ad63bd`；本次摘录取自当前本地文件，完整文件 SHA-256 与行号保存在[源码摘录清单](../examples/08-chapter-workshops/source-manifest.json)。运行证据来自报告版本 `doris-0.0.0-a53b182f810` 的二进制，不能仅凭版本前缀认定当前工作目录与二进制逐文件相同。

**本章问题：AVG 和 Join 为什么不能只看最后一个数字？**

本章验证方式：已归档运行证据 + 源码走查；扩展分支见本章边界。建议先用 20—40 分钟完成主案例，第四部分的扩展阅读可分次完成；这不是新增的每日必交任务。

## 一、源码讲解：先找到决定行为的对象和分支

AVG 的 merge 同时合并 sum 与 count，而不是平均两个局部均值。Hash Join 则要区分匹配产生的行数与存在性判断。它们共同说明：算子状态与 SQL 结果不是同一种对象。

### 先读这段真实代码

文件：`be/src/exprs/aggregate/aggregate_function_avg.h`，当前文件第 220—230 行。下面是连续原文摘录，局部片段省略了方法的其他部分；不要把片段当完整实现。

```cpp
    NO_SANITIZE_UNDEFINED void merge(AggregateDataPtr __restrict place, ConstAggregateDataPtr rhs,
                                     Arena&) const override {
        if constexpr (T == TYPE_DECIMALV2) {
            this->data(place).sum += this->data(rhs).sum;
        } else if constexpr (is_decimal(T)) {
            this->data(place).sum += this->data(rhs).sum.value;
        } else {
            this->data(place).sum += this->data(rhs).sum;
        }
        this->data(place).count += this->data(rhs).count;
    }
```

### 这几行应该怎样读

`if constexpr` 在 C++ 模板实例化时选择类型分支，可先把它理解为不同数值表示的编译期适配。无论分支如何取得 sum，末尾都把 count 累加；这个计数必须与 sum 一起合并才能得到正确 AVG。

### 聚合有输入、状态和结果三种形态

`COUNT(*)` 返回一个整数，但执行过程并不是每处理一行就产生一行最终结果。算子按分组维护状态，消费输入或合并其他状态，最后才能输出用户需要的值。

当前 `AggregateFunctionCount` 的状态包含 `UInt64 count`。`add()` 增一，批量添加可直接累加批大小，`merge()` 合并另一个状态的计数，序列化/反序列化负责传递，`insert_result_into()` 写出结果列。

这些方法是一个很好的接口切片：同一聚合函数既要处理原始输入，也要参与分布式合并。可空输入的 COUNT、COUNT(*) 与不同包装方式还需另看适配层，不能从这个基础实现推导所有 NULL 行都被计数。

### AVG 为什么不能平均局部平均值

设一侧输入为 10、20，另一侧只有 90。两侧平均值分别是 15 和 90，再平均得到 52.5；正确全局平均值却是 40。

原因是局部平均值丢掉了样本数。若保存 `(sum,count)`，两侧状态分别为 `(30,2)` 和 `(90,1)`，合并得到 `(120,3)`，最终才相除。

`aggregate_function_avg.h` 中可以看到 sum、count、更新、合并和最终结果处理。类型和 Decimal 缩放等细节另有分支；本例只用非空精确整数解释状态含义，不推广浮点相加顺序或溢出语义。

聚合阶段因此可以是“原始输入到状态”“状态到状态”“状态到最终结果”等。第 7 章的 Exchange 可能传输中间状态，而不是界面上看到的最终金额或人数。

## 二、动手实验：先预测，再核对

默认使用已保存的实验材料或只读源码，不需要启动服务。运行环境已停止；若选择重新执行 SQL，先按[实验复现说明](../examples/07-live-lab-20261014/REPRODUCE.md)确认服务、版本与数据状态。初始化、导入和更新脚本不可在现有表上盲目重放。

1. 读 07-aggregation-null.sql，手算 10、20、90、NULL 的 COUNT(*)、COUNT(v)、SUM、AVG；再对照 25 的数值断言。
2. 查看 08-join-semantics.sql/out.txt，解释 INNER、SEMI、LEFT 的 2、1、3，以及 NOT IN 的 NULL。
3. 对照 AVG merge 的两行累加，再打开真实 Join Profile，找 HashJoin 的 RowsProduced=100，避免从查询 COUNT 的一行结果推测内部只处理一行。

```sql
SELECT COUNT(*),COUNT(v),SUM(v),AVG(v),COUNT(DISTINCT v)
FROM (SELECT 10 AS v UNION ALL SELECT 20 UNION ALL SELECT 90
      UNION ALL SELECT CAST(NULL AS INT)) t;
```

本章实验材料：[07-aggregation-null.sql](../examples/07-live-lab-20261014/07-aggregation-null.sql) · [07-aggregation-null.out.txt](../examples/07-live-lab-20261014/07-aggregation-null.out.txt) · [25-average-numeric-assert.out.txt](../examples/07-live-lab-20261014/25-average-numeric-assert.out.txt) · [08-join-semantics.sql](../examples/07-live-lab-20261014/08-join-semantics.sql) · [08-join-semantics.out.txt](../examples/07-live-lab-20261014/08-join-semantics.out.txt) · [PROFILE_ANALYSIS.md](../examples/07-live-lab-20261014/PROFILE_ANALYSIS.md)。

## 三、观察结果：先陈述事实，再划清证据范围

聚合实测为 4、3、120、40、3；合并局部 sum/count 也是 40。最初文本断言将 40 与 40.0 误判不同，后用数值比较通过。Join 语义案例分别为 2、1、3；NOT IN/NOT EXISTS 对照为 NULL 与 1。

**本章边界：** 算子语义已实测；Spill、Runtime Filter 收益未实测。

## 四、回到源码解释：把现象还原成执行过程

局部均值 15 和 90 直接平均得到 52.5，违反总体 AVG=40；merge 的 sum/count 保存了分组大小。SEMI 只需判断存在，不复制右侧匹配行。Runtime Filter 还需单独证据，本次 Join 的 RuntimeFilterInfo 为空，不能宣称它过滤有效。

### 用自己的话走完这条链

合上结果后，按“输入 → 关键对象/状态 → 分支条件 → 可观察结果”的顺序回答本章问题：**AVG 和 Join 为什么不能只看最后一个数字？** 再指出一项尚不能从现有实验得出的结论。能把每个箭头落到本章的方法或证据，比记住术语更接近读懂源码。

### DISTINCT：合并状态不等于相加人数

订单示例里，北京与上海都出现用户 101。分别统计后相加会重复计数。精确去重需要保留可以区分重复值的信息，或通过合适的数据分布把相同值交给同一计算范围。

实际计划可能采用多阶段聚合与重分布，也可能在适用条件下简化。不能看到两个 Aggregate 节点就断言一个去重、一个求和；应该读取分组键、聚合函数及其阶段，再追中间数据。

近似去重函数使用不同的语义契约。用近似结果替换精确 COUNT DISTINCT 不是透明性能优化，必须得到用户需求允许，并明确误差与适用条件。

### Hash Join：构建端与探测端

Hash Join 通常先围绕连接键组织一侧的查找结构，再让另一侧输入探测它。构建侧的大小、键分布和重复程度影响内存；输出规模还取决于同键多行和 Join 类型。

当前 BE 将相关入口拆在 `hashjoin_build_sink.cpp` 和 `hashjoin_probe_operator.cpp` 等文件中。这种拆分提醒我们：构建与探测之间有共享状态和依赖，不能把 Join 当成一个对每行独立计算的纯函数。

Outer/Semi/Anti 等 Join 对未匹配行与 NULL 的处理不同。本章只解释组织方式，具体分支应配合语义测试阅读。更换构建侧、过滤空值或提前终止时，都需要证明适用的 Join 语义允许。

### Runtime Filter：执行期间得到的新信息

优化器在规划时不一定知道构建侧具体有哪些键。运行中产生的过滤信息，可以帮助探测侧或扫描侧跳过不可能匹配的数据，但前提是对相应 Join 语义安全。

Runtime Filter 与建表时创建的持久索引不同：它属于某次执行的信息。生成、合并、传播与等待本身都有成本；若到达太晚、选择性太差或额外等待太长，收益可能有限。性能判断需要过滤行数和等待时间，不能仅看“已开启”。

Bloom 类过滤结构可能保留不匹配候选，后续精确语义仍要保证。不是所有 Runtime Filter 都用同一结构或相同传输路径，具体实现从 `be/src/exec/runtime_filter/` 继续深入。

### 排序、TopN 与 Spill

全排序通常需要处理更大范围的输入；只要求有序前 N 行时，可以考虑保留更少候选。但分布式局部 TopN 仍需与最终排序、LIMIT/OFFSET 及并列键语义配合，不能任意丢弃远端数据。

排序和 Hash 类算子都可能遇到内存压力。Spill 把部分成本转移到磁盘和恢复过程；它可能让查询能够完成，却不保证更快。归因时应分清输入规模、状态规模、数据倾斜和具体落盘量。

### 源码与可验证的例子

| 路径（相对仓库根目录） | 先读什么 |
|---|---|
| `be/src/exprs/aggregate/aggregate_function_count.h` | `add()`、`merge()`、序列化、结果输出 |
| `be/src/exprs/aggregate/aggregate_function_avg.h` | sum/count 的状态生命周期 |
| `be/src/exec/operator/hashjoin_build_sink.cpp` | 构建侧组织 |
| `be/src/exec/operator/hashjoin_probe_operator.cpp` | 探测侧组织 |
| `be/src/exec/runtime_filter/` | 运行时过滤协作 |
| `be/src/exec/sort/` | 排序相关实现 |

已有测试入口：`be/test/exprs/aggregate/agg_count_test.cpp`、`be/test/exprs/aggregate/agg_avg_test.cpp`。本批用独立算术核对 AVG 例子，没有运行 Doris 测试。

一个有意义的聚合验证应检查“分批输入、合并后”的结果与一次性处理的语义是否一致，并覆盖适用的空值、空集及类型边界。只测试 add 三次等于三，不足以证明分布式序列化和合并正确。

### 延伸源码专题

- [专题 6　算子内存、背压、Spill 与缓存分层](../deep-dives/06-memory-operators-and-caches.md)

---

[全书导航](../README.md) · [术语表](../appendices/A-glossary.md)
