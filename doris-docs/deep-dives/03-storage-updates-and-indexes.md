# 专题 3　从一列读取到更新、索引与 Schema Change

[全书导航](../README.md) · [专题导航](README.md)

> 源码基线：`a53b182f810be2b3731c7dfdf6f40ff5a0ad63bd`；补写日期：2026-10-13。以下为源码分析与标明的教学推演，未运行对应功能测试。仓库路径均相对 `/Users/jiangyuan/open/doris`。

## 1. 从行号范围进入列页

入口依次是 `be/src/storage/segment/segment_iterator.cpp`、`column_reader.cpp` 和 `page_io.cpp`。`SegmentIterator::_lookup_ordinal()` 选择相应索引定位；Short Key 分支 `_lookup_ordinal_from_sk_index()` 缩小查找范围，再通过 `_seek_and_peek()` 检查实际键。Column Iterator 定位到行号后，ColumnReader 才沿页信息取数据。

Short Key 是稀疏的有序定位信息，代码在 `be/src/storage/index/short_key_index.cpp`。它的工作类似先翻书目录找到附近页，再看正文确认位置；它并不为每个完整主键保存唯一行地址。相同前缀可能对应很多行，仍需精确比较。

一列的一页包含编码后的值及读取所需元信息，逻辑 NULL 与压缩数据也需按格式解释。比如读取第 1000—1100 行的金额，并不等于文件里第 1000—1100 个字节。页边界、编码、压缩决定真正的 IO 单位。`ColumnReader::read_page()` 与 PageIO 是区分“列裁剪减少读取列”和“页缓存减少物理读取”的关键接缝。

## 2. 索引一起工作，而不是互相替代

| 机制 | 先排除什么 | 仍需确认什么 |
|---|---|---|
| 分区/桶裁剪 | 不相关分区或 Tablet | 剩余 Tablet 内的行 |
| Short Key | 排序键范围之外的行号区域 | 前缀相同区间中的完整条件 |
| Zone Map | min/max 不可能满足谓词的区域 | 区间相交不表示每行命中 |
| Bloom Filter | 确定不存在的值 | 可能存在的值还需核对 |
| 倒排索引 | 不含目标 term 的行集合 | 分词、NULL、组合谓词和必要的残余条件 |

全文检索中的分词结果属于查询语义的一部分。“包含一个词”不等于字符串相等或任意子串包含。测试应选词边界、大小写、空串、NULL 和多条件组合，不能只测一条命中数据。

## 3. Array、Map、Variant 不是一个 JSON 字符串列

数组 `[10,20]`、`[]`、`NULL` 分别是两个元素、零个元素和空值。元素流需要 offsets 表示每行边界，空数组与 NULL 还要由相应空值信息区分。`column_reader.cpp` 中 `OffsetFileColumnIterator::next_batch()`、`MapFileColumnIterator` 和 `StructFileColumnIterator` 展示了这种组合读取。

对于 Map，键和值必须按同一行的范围对应；只推进键 Iterator、不推进值 Iterator 会破坏配对。对于 Struct，父行和各子字段的 NULL/行数关系同样需要保持。

Variant 可能把热点路径作为子列处理，并存在不同格式版本。入口是 `be/src/storage/segment/variant/variant_column_reader.cpp` 及其 `v2/` 实现。教学例子 `{a:1}`、`{a:"x"}`、`{b:2}` 包含同路径不同类型和路径缺失；不能把缺失字段、显式 JSON null 和普通 SQL NULL 无条件合并为一个概念。性能实验也应区分读取一个路径和物化整个对象。

## 4. Sequence、Delete Sign 与部分更新

以 Unique Key 用户表为例，Key=7，保存 `(name=A, score=10, seq=100)`。之后到达 `(name=B, score=20, seq=90)`；启用并正确映射 Sequence 的模式应按 Sequence 决定覆盖顺序，而不是简单按网络到达顺序。相同 Sequence 的行为还要按具体模式核对，不把它当全局事务时钟。

Delete Sign 表达这条逻辑记录的删除状态；MOW Delete Bitmap 标识具体 Rowset/Segment/行位置的不可见记录。一个是记录语义，一个是物理行过滤结构，名称相近但不是同一个字段。

部分更新若只携带 score=30，未携带的 name 要按该模式的补全规则处理。缺失列与显式写 NULL 不同；新 Key、默认值、严格模式、Sequence 映射、灵活部分更新都有分支。不能把所有缺失列统一填 NULL。

源码接缝在 `be/src/storage/rowset_builder.cpp`：`init_mow_context()` 建立 MOW 上下文，`submit_calc_delete_bitmap_task()` 区分部分更新等路径，`wait_calc_delete_bitmap()` 等待结果，`RowsetBuilder::commit_txn()` 把相关信息交给事务管理。`be/src/storage/tablet/tablet.cpp` 还处理并发加入的 Rowset 与位图补算。只在初始快照上算一次，会漏掉计算期间新提交的同键记录。

## 5. Compaction 如何保持语义

假设两个 Rowset 各包含 Key=7 的版本。合并不能简单把两行复制到新文件后宣布完成：需要保持模型的聚合或覆盖规则，并正确转换与行位置相关的信息。旧行号不等于新行号，位图不能原封不动套在新布局上。

Compaction 选择与执行分开：Cumulative 策略决定候选范围与触发，合并器负责具体读写；源码入口 `be/src/storage/compaction/cumulative_compaction_policy.cpp`。读放大、候选大小、资源限制和版本连续性影响选择，不能笼统地写成“版本多就全部合并”。旧 Rowset 进入回收流程时，还要考虑已有 Reader 的持有关系，见第 17 章。

## 6. FE 作业如何落到 BE 转换

第 13 章的 SchemaChangeJobV2 负责作业状态、影子索引及事务分界。BE 入口在 `be/src/storage/schema_change/schema_change.cpp` 的 `SchemaChangeJob::process_alter_tablet()` 与 `_do_process_alter_tablet()`。其策略分为：

| 策略 | 主要工作 |
|---|---|
| `LinkedSchemaChange::process()` | 在满足条件时复用数据布局，避免完整重写 |
| `VSchemaChangeDirectly::_inner_process()` | 逐批转换写出，不需要重新排序 |
| `VLocalSchemaChangeWithSorting::_inner_process()` | 转换后重排，成本与资源需求更高 |

因此同是 ALTER，增加可兼容元信息与改变排序要求不是同一代价。MOW 转换还涉及双写 Rowset、位图追赶、发布协调和新 Tablet 状态切换；该目录 AGENTS 明确了这些阶段与锁顺序。读者应沿当前分类与分派代码确认命中哪条策略，再设计测试。

建议边界数据：重复 Key、乱序 Sequence、显式 NULL、缺失列、删除后更新、Schema Change 期间持续写入。上述是测试设计，未在本次运行。
