# 第 11 章　从 Tablet 到 Segment

[全书导航](../README.md) · [术语表](../appendices/A-glossary.md)

> 教学结构修订：2026-10-14。每章先沿一个问题阅读代码，再做实验、观察结果，最后解释对象和分支。历史正文基线为 `a53b182f810be2b3731c7dfdf6f40ff5a0ad63bd`；本次摘录取自当前本地文件，完整文件 SHA-256 与行号保存在[源码摘录清单](../examples/08-chapter-workshops/source-manifest.json)。运行证据来自报告版本 `doris-0.0.0-a53b182f810` 的二进制，不能仅凭版本前缀认定当前工作目录与二进制逐文件相同。

**本章问题：查询能返回行，磁盘上的 Segment 是怎样被解释的？**

本章验证方式：已归档运行证据 + 源码走查；扩展分支见本章边界。建议先用 20—40 分钟完成主案例，第四部分的扩展阅读可分次完成；这不是新增的每日必交任务。

## 一、源码讲解：先找到决定行为的对象和分支

从 Segment::_open 的 footer 读取开始。文件系统提供字节，footer 提供行数、索引页等结构描述；ColumnReader 和 SegmentIterator 才继续完成按列读取。这个边界类似读取序列化文件时先读格式描述，再按格式解码。

### 先读这段真实代码

文件：`be/src/storage/segment/segment.cpp`，当前文件第 378—390 行。下面是连续原文摘录，局部片段省略了方法的其他部分；不要把片段当完整实现。

```cpp
Status Segment::_open(OlapReaderStatistics* stats, const io::IOContext* source_io_ctx) {
    std::shared_ptr<SegmentFooterPB> footer_pb_shared;
    RETURN_IF_ERROR(_get_segment_footer(footer_pb_shared, stats, source_io_ctx));

    _pk_index_meta.reset(
            footer_pb_shared->has_primary_key_index_meta()
                    ? new PrimaryKeyIndexMetaPB(footer_pb_shared->primary_key_index_meta())
                    : nullptr);
    // delete_bitmap_calculator_test.cpp
    // DCHECK(footer.has_short_key_index_page());
    _sk_index_page = footer_pb_shared->short_key_index_page();
    _num_rows = footer_pb_shared->num_rows();

```

### 这几行应该怎样读

`_get_segment_footer` 先取得 footer；`has_primary_key_index_meta` 决定是否构造主键索引元信息；`_num_rows` 从 footer 取得。这里的 `shared_ptr` 表示共享拥有关系，`reset` 则替换对象持有的索引元信息；不是逐行把业务数据装进 Java 风格 List。

### 数据最终不是一张 Java List

第 10 章解决了数据放到哪些分片。现在继续看 BE 上某个 Tablet 副本：它包含随写入和合并形成的 Rowset，Rowset 再组织 Segment 等物理产物。查询必须先选择合适的 Rowset，再从文件中读出需要的列和行。

```text
扫描范围与版本
  → Tablet 中选择 Rowset
  → Rowset Reader / 分段读取
  → Segment Iterator
  → Column Iterator / Page 读取与解码
  → 批量列数据交给执行算子
```

这张图表达职责层级，不是一条固定的直接函数调用链。缓存、特殊计数路径、不同 Key 模型和文件布局会改变实际经过的步骤。

### Rowset 的意义：把文件与版本联系起来

一份 Rowset 不只代表“几个文件”。它带有与 Tablet、版本范围、行数和 Segment 等相关的元数据，使发布、读取和 Compaction 能围绕同一对象工作。

同一 Tablet 可以同时存在多份 Rowset；一次查询不应把当前目录里所有文件都读一遍。版本选择将在第 17 章展开，这里先区分“找到哪些 Rowset”与“怎样读其中的列”。

本章主要讲存算一体本地布局。Segment 的列表位置与物理 ID 是不同概念，尤其不能把本地模式下的连续编号假设复制到 Cloud 的所有布局。阅读共享代码时，应确认参数表示序号还是文件身份。

## 二、动手实验：先预测，再核对

默认使用已保存的实验材料或只读源码，不需要启动服务。运行环境已停止；若选择重新执行 SQL，先按[实验复现说明](../examples/07-live-lab-20261014/REPRODUCE.md)确认服务、版本与数据状态。初始化、导入和更新脚本不可在现有表上盲目重放。

1. 阅读本章 Segment::_open 摘录，圈出 _get_segment_footer、_num_rows、_sk_index_page；把它们区分为结构信息与业务列值。
2. 从聚合 Profile 找 ScanRows 与 ScanBytes，并与 31-scale-assert 的结果核对：扫描活动确实发生，但输出没有列出每个 Segment 文件。
3. 继续查看 column_reader.cpp 的 read_page 与 segment_iterator.cpp 的读取入口，画出 Tablet → Rowset → Segment → 列页；不手动更改 storage 中的数据文件。

本章实验材料：[31-scale-assert.out.txt](../examples/07-live-lab-20261014/31-scale-assert.out.txt) · [PROFILE_ANALYSIS.md](../examples/07-live-lab-20261014/PROFILE_ANALYSIS.md)。

## 三、观察结果：先陈述事实，再划清证据范围

实测 ScanRows/RowsProduced=50000、ScanBytes 约 808.38KB（算子计数，不等同完整底层磁盘访问量），最终聚合结果通过断言。这些是运行计数；没有归档每一个 Segment footer 的解析结果。

**本章边界：** 物理页布局与具体文件数量仍是源码走查，未做文件取证或冷热缓存对照。

## 四、回到源码解释：把现象还原成执行过程

footer 是进入文件结构的入口，不是把所有列数据一次性加载入内存。查询结果正确支撑读路径端到端可用，不能据此计算“一次 INSERT 恰好产生一个 Segment”，也不能把 ScanBytes 无条件解释为物理磁盘字节。

### 用自己的话走完这条链

合上结果后，按“输入 → 关键对象/状态 → 分支条件 → 可观察结果”的顺序回答本章问题：**查询能返回行，磁盘上的 Segment 是怎样被解释的？** 再指出一项尚不能从现有实验得出的结论。能把每个箭头落到本章的方法或证据，比记住术语更接近读懂源码。

### Segment 打开时先获得什么

当前 `Segment::open()` 及内部 `_open()` 会获取 Segment footer，并从中建立读取需要的元信息，例如行数、索引页信息等。Footer 帮助定位和解释文件内容，不等于打开文件时把所有业务列数据读入内存。

列数据通常按页组织，并涉及编码和压缩。编码描述如何表达值，压缩进一步减少字节，两者概念不同。读取需要相应的元信息、页定位、解压与解码，缓存也可能作用在不同层。

因此，“文件已在缓存里”应继续问缓存的是哪一层：文件字节、页、解码后的对象还是其他结构。命中一种缓存并不意味着后续没有 CPU 成本。

### ColumnReader 与 SegmentIterator 分别负责什么

`ColumnReader` 是理解列级读取的入口。当前 `read_page()` 构造读取选项，再调用 `PageIO::read_and_decompress_page()`；这给出了从列读取进入页 I/O 的明确位置。

`SegmentIterator` 更接近本次读取的执行上下文：有哪些列、哪些谓词、哪些行还需要读、哪些索引可以参与。它不是只负责从文件头到尾移动一个指针。当前文件中存在索引过滤、候选行和延迟读取相关路径，意味着实际工作可以被逐步缩小。

以 `SELECT city WHERE amount > 100` 为例，业务输出只需要 city，但过滤还需要 amount 的信息。所谓列裁剪不能只留下 SELECT 列；谓词、排序、连接等使用的列同样可能是必需输入。

### 读路径会有哪些成本

| 工作 | 可能的影响因素 |
|---|---|
| 打开与读取元数据 | Segment 数量、缓存、文件系统延迟 |
| 页读取 | 实际需读列与行范围、压缩后字节数 |
| 解压和解码 | 编码类型、数据类型、CPU、缓存层次 |
| 过滤与合并 | 谓词选择性、Key 模型、版本和删除信息 |
| 形成输出 Block | 列表示、物化和复制成本 |

这些工作可以重叠或被优化路径绕过，不是一个固定相加公式。大量小 Rowset/Segment 可能增加管理和打开成本；这也是 Compaction 的价值之一，但合并本身也消耗资源。

### 源码与验证入口

| 路径（相对仓库根目录） | 阅读位置 |
|---|---|
| `be/src/storage/tablet/base_tablet.cpp` | Reader 与版本对象的关联 |
| `be/src/storage/tablet/tablet_reader.cpp` | Tablet 读取组织 |
| `be/src/storage/segment/segment.cpp` | `open()`、`_open()`、footer |
| `be/src/storage/segment/column_reader.cpp` | `read_page()` 与列级元信息 |
| `be/src/storage/segment/segment_iterator.cpp` | 候选范围、索引与批量读取 |

测试入口包括 `be/test/storage/segment/column_reader_writer_test.cpp`、`be/test/storage/segment/segment_corruption_test.cpp`。它们分别提供读写和损坏处理相关的阅读方向，不表示本章验证了所有文件格式。

后续实验可固定表和数据，只改变投影列及过滤条件，对比实际读字节、扫描行数与时间。返回列少不必然线性变快，应该通过证据判断瓶颈是在 I/O、解码还是上层算子。下一章继续解释哪些索引能让读取更早跳过无关数据。

### 延伸源码专题

- [专题 3　从一列读取到更新、索引与 Schema Change](../deep-dives/03-storage-updates-and-indexes.md)
- [专题 6　算子内存、背压、Spill 与缓存分层](../deep-dives/06-memory-operators-and-caches.md)

---

[全书导航](../README.md) · [术语表](../appendices/A-glossary.md)
