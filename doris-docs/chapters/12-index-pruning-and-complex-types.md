# 第 12 章　索引、裁剪与复杂类型

[全书导航](../README.md) · [术语表](../appendices/A-glossary.md)

> 教学结构修订：2026-10-14。每章先沿一个问题阅读代码，再做实验、观察结果，最后解释对象和分支。历史正文基线为 `a53b182f810be2b3731c7dfdf6f40ff5a0ad63bd`；本次摘录取自当前本地文件，完整文件 SHA-256 与行号保存在[源码摘录清单](../examples/08-chapter-workshops/source-manifest.json)。运行证据来自报告版本 `doris-0.0.0-a53b182f810` 的二进制，不能仅凭版本前缀认定当前工作目录与二进制逐文件相同。

**本章问题：过滤掉一行与通过索引跳过一页，怎样区分？**

本章验证方式：已归档运行证据 + 源码走查；扩展分支见本章边界。建议先用 20—40 分钟完成主案例，第四部分的扩展阅读可分次完成；这不是新增的每日必交任务。

## 一、源码讲解：先找到决定行为的对象和分支

ColumnReader.get_row_ranges_by_zone_map 先找候选页，再换算行范围。它产出“需要继续读哪些范围”，不是最终 SQL 结果；精确谓词、NULL 语义和其他索引仍可能在后面参与。

### 先读这段真实代码

文件：`be/src/storage/segment/column_reader.cpp`，当前文件第 703—712 行。下面是连续原文摘录，局部片段省略了方法的其他部分；不要把片段当完整实现。

```cpp
Status ColumnReader::get_row_ranges_by_zone_map(
        const AndBlockColumnPredicate* col_predicates,
        const std::vector<std::shared_ptr<const ColumnPredicate>>* delete_predicates,
        RowRanges* row_ranges, const ColumnIteratorOptions& iter_opts) {
    std::vector<uint32_t> page_indexes;
    RETURN_IF_ERROR(
            _get_filtered_pages(col_predicates, delete_predicates, &page_indexes, iter_opts));
    RETURN_IF_ERROR(_calculate_row_ranges(page_indexes, row_ranges, iter_opts));
    return Status::OK();
}
```

### 这几行应该怎样读

`_get_filtered_pages` 产出 page_indexes，`_calculate_row_ranges` 再转为 RowRanges。`RETURN_IF_ERROR` 使失败直接返回，不继续拿不完整范围读取；成功返回的仍是候选范围，最终谓词语义要由整条读取链保证。

### 少读数据有多个层级

过滤订单金额大于 100，可能在分区层排除范围，也可能在 Segment/页层跳过数据，还可能先通过索引得到候选行，再读取对应列。不能把所有减少扫描的工作都称为“走了索引”。

先区分三种结果：证明某个范围不可能匹配，得到可能匹配的候选，或者在满足语义条件时直接完成某个谓词判断。不同索引的能力和返回对象不同，后续是否仍需精确过滤也不同。

### Zone Map：用摘要排除不可能的范围

假设某个数据范围内金额最小值为 10、最大值为 80，条件是 `amount > 100`，这个范围可被排除。若最大值是 200，只能说明不能根据这个摘要排除；不代表每行都匹配。

这是 Zone Map 的基本直觉。实际还要处理 NULL、数据类型、比较语义和可支持表达式。当前 `ColumnReader::get_row_ranges_by_zone_map()` 调用页过滤，再计算行范围，给出了从摘要判断到读取范围的代码入口。

排序影响相邻数据的分布，从而影响摘要能排除多少范围。若每页都混有极小值和极大值，min/max 区间重叠很大，摘要可能保留许多候选。是否高效应看数据分布，不能仅看“索引存在”。

## 二、动手实验：先预测，再核对

默认使用已保存的实验材料或只读源码，不需要启动服务。运行环境已停止；若选择重新执行 SQL，先按[实验复现说明](../examples/07-live-lab-20261014/REPRODUCE.md)确认服务、版本与数据状态。初始化、导入和更新脚本不可在现有表上盲目重放。

1. 执行下方只读查询或查看 13-null-filter 的 SQL/输出，先证明过滤语义。
2. 阅读 get_row_ranges_by_zone_map → _get_filtered_pages → _calculate_row_ranges，分别标出页编号与行范围的类型。
3. 尝试在已有 Profile 中寻找 Zone Map/过滤页计数；若不能按当前计数口径确认命中，就在观察卡写“未证明索引命中”，保留结果正确这一独立结论。

```sql
SELECT COUNT(*) FROM doris_book.orders_intro_v1 WHERE amount IS NULL;
SELECT COUNT(*) FROM doris_book.orders_intro_v1 WHERE amount>100 AND amount<200;
```

本章实验材料：[13-null-filter.sql](../examples/07-live-lab-20261014/13-null-filter.sql) · [13-null-filter.out.txt](../examples/07-live-lab-20261014/13-null-filter.out.txt)。

## 三、观察结果：先陈述事实，再划清证据范围

amount IS NULL 得到 0 行；100 < amount < 200 得到 1 行。已归档输出没有构成“本次由某一种索引排除了多少页”的完整证据。

**本章边界：** 倒排、Bloom Filter、复杂类型的运行矩阵未完成；不要把这个范围过滤案例标成所有索引实测。

## 四、回到源码解释：把现象还原成执行过程

区间谓词可以让摘要排除不可能满足条件的页，但保留的页仍需精确读取与判断。Zone Map 的 min/max、Bloom Filter 的可能存在和倒排候选行承担不同职责。返回一行不能推出只读了一行。

### 用自己的话走完这条链

合上结果后，按“输入 → 关键对象/状态 → 分支条件 → 可观察结果”的顺序回答本章问题：**过滤掉一行与通过索引跳过一页，怎样区分？** 再指出一项尚不能从现有实验得出的结论。能把每个箭头落到本章的方法或证据，比记住术语更接近读懂源码。

### Bloom Filter：可能存在与确定不存在

Bloom Filter 可用于判断某个值是否可能出现。符合其正确构造和使用前提时，否定结果可以排除；肯定结果仍可能是假阳性，需要后续保证精确结果。

它不能用来枚举全部匹配行，也不能自动替代任意范围查询。对于 Doris 的具体列类型、操作符和表达式支持，应核对对应版本的索引实现。

将多个过滤条件组合时，还要保持 NULL 和逻辑运算语义。不能因为“某个过滤器能排除行”就随意把它用于 OR 的每个分支并取交集，那会丢掉合法结果。

### 倒排索引：从值或词项找到候选行

倒排索引把值/词项与相应位置建立联系。对于选择性较高的条件，它可能先缩小候选集合，再读取其他列，避免大范围解码。

全文检索还涉及分词与文本匹配语义。字符串相等、LIKE 子串匹配与 MATCH 不是同一种操作，不能因为都处理文本就使用相同的语义预期。索引也会增加写入、存储和合并成本，需要结合实际查询衡量。

官方[索引概览](https://doris.apache.org/docs/4.x/table-design/index/index-overview/)列出了类型和操作符支持，适合做能力入口；本章不复制其全部支持矩阵，也不把在线文档当成本地 HEAD 的逐项验证。

### 多种过滤如何进入读取过程

当前 `SegmentIterator` 中有 `_apply_inverted_index()` 等入口，并记录相关过滤统计。`ColumnReader` 则加载 Zone Map、Bloom Filter 相关元信息并提供列级读取能力。它们共同说明：索引处理与后续列读取之间存在结果传递，不是完全独立的两个模块。

不要把教学顺序写成固定执行顺序。不同表达式、索引可用性、数据模型与运行条件可能选择不同路径。验证时应查具体分支及实际计数：哪些谓词成功使用索引，候选行减少了多少，哪些条件仍由后续表达式处理。

EXPLAIN 可以提供计划线索，但“索引确实减少了本次读入数据”需要运行证据。把配置打开、建表成功和索引实际生效混为一谈，会让性能分析失去依据。

### 复杂类型改变了什么

数组、JSON/Variant 等把“一个列值”扩展为可能包含嵌套结构的对象。路径缺失、显式 NULL、类型差异、数组元素等语义，会影响提取、过滤和索引。

当前仓库存在 `be/src/storage/segment/variant/` 及不同读取实现。这里仅确认入口，尚未逐项核对各模式的物理布局与支持范围。不能只看到一个 JSON 字符串就断言所有路径都按普通 VARCHAR 列处理，也不能承诺任意嵌套路径都可索引。

对 Java 开发者，先明确 SQL 对缺失值和类型转换的约定，再看存储和索引如何保持它，会比从复杂模板入口盲目向下追踪更有效。

### 源码与验证

| 路径（相对仓库根目录） | 用途 |
|---|---|
| `be/src/storage/segment/column_reader.cpp` | Zone Map 行范围、索引元信息 |
| `be/src/storage/segment/segment_iterator.cpp` | 索引与读取的组合 |
| `be/src/storage/index/zone_map/` | 摘要索引实现入口 |
| `be/src/storage/index/bloom_filter/` | Bloom 索引实现入口 |
| `be/src/storage/index/inverted/` | 倒排索引专题入口，未在本章逐项分析 |
| `be/src/storage/segment/variant/` | 复杂类型读取专题入口 |

可参考 `be/test/storage/segment/zone_map_index_test.cpp`、`be/test/storage/segment/bloom_filter_test.cpp`、`be/test/storage/segment/segment_iterator_candidate_pushdown_test.cpp`。这些测试本次未运行。

有效验证应包含匹配与不匹配数据、适用的空值/边界，并比较结果是否一致，再比较读取量。候选越少不是唯一目标：不能漏掉任何本应匹配的数据。

### 延伸源码专题

- [专题 3　从一列读取到更新、索引与 Schema Change](../deep-dives/03-storage-updates-and-indexes.md)

---

[全书导航](../README.md) · [术语表](../appendices/A-glossary.md)
