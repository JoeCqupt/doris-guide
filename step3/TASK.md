# Step 3：用 Java BitSet 理解 Bitmap 去重

- 发布日期：2026-09-22
- 预计用时：30–45 分钟，可随时开始或分次完成。
- 来源：你在 Step 2 主动提出 Bitmap，并询问其原理。
- 系统位置：查询执行中的聚合中间状态、节点间合并及传输成本。这里是 Java 教学实验，不是 Doris 内部实现或性能测试。

## 先读这个小例子

```java
BitSet seen = new BitSet();
seen.set(7);
seen.set(7);
System.out.println(seen.cardinality()); // 1，重复设置不会新增元素
```

本题固定全局映射 U1→1、U2→2、…、U5→5，每城分别维护一份 BitSet。不要为不同节点各自重新编号。

API 提示：`set(i)` 表示元素存在，`or(other)` 把并集写回接收者，`cardinality()` 返回置为 1 的位数。若要保留原集合，可先 `clone()`。`length()` 表示最高置位位置加 1，不是元素个数。`toByteArray().length` 只表示这种字节表示的长度，不是 Java 对象的实际堆占用，也不是 Doris 的传输字节数。

## 三个步骤

1. **实现并集，10–15 分钟。** 自行在本目录创建 `BitmapLab.java`，只用 JDK 的 `java.util.BitSet`。使用 Step 2 的四组局部用户集合，分别打印各城市 A/B 的局部人数、合并后的集合和人数；再把 B 合并一次，观察人数是否改变。说明为什么该性质只描述集合合并，不能直接推导整个导入系统具备 exactly-once 保证。
2. **验证空间假设，10 分钟。** 分别创建 `{1,2,3}` 和 `{1,1000000}` 两个 BitSet，打印每个的 `cardinality()`、`length()` 和 `toByteArray().length`。运行前先预测哪一个的字节表示更大，运行后说明“元素少”为什么不等于“位图小”。不需要申请十亿位或做性能压测。
3. **连回 SQL 和分布式计算，10 分钟。** 写一段简短说明：为什么先合并 Bitmap 再数位能去重，而先数位再相加会失去信息？两个节点的用户编号映射不一致会有什么问题？补写按城市总金额排序的 ORDER BY，使用聚合别名或表达式。

## 运行方式

在本目录中使用现有 JDK：

```bash
cd /Users/jiangyuan/doris-guide/step3
javac BitmapLab.java
java BitmapLab
```

这仅编译你的独立学习程序，不构建 Doris。若 JDK 不可用，记录报错并交付代码或伪代码，后续再处理环境。

## 与 Doris 的联系及边界

Doris 的 `BITMAP_UNION_COUNT` 表达对 Bitmap 求并集后的基数；具体 Bitmap 类型、输入转换与执行计划需要后续在 Doris 中验证。Java BitSet 用来解释集合语义；Doris 的 RoaringBitmap 相关实现针对数据分布采取不同表示，不能由本实验直接推断 Doris 的内存或速度。普通 COUNT(DISTINCT) 也不能一概认为会使用此处的实现。

参考：[BitSet API](https://docs.oracle.com/en/java/javase/26/docs/api/java.base/java/util/BitSet.html)、[Doris Bitmap 精确去重](https://doris.apache.org/docs/dev/query-acceleration/distinct-counts/bitmap-precise-deduplication/)、[BITMAP_UNION_COUNT](https://doris.apache.org/docs/dev/sql-manual/sql-functions/aggregate-functions/bitmap-union-count)。API 链接版本不意味着必须安装 JDK 26。

## 交付与验收

提交本目录下的代码、实际输出（写在 RESULT.md 或 output.txt）、预测与解释、实际用时。验收看：并集结果正确，重复 OR 行为解释正确，区分人数与位范围，理解全局编号一致性，排序使用聚合值。运行失败可先验收理解，执行能力单独记录。

完成后即可请求验收并继续，不需等待次日。后续将回到 Doris 实际使用和 FE/BE 职责。

## 2026-09-23 复盘提示

本次检查尚未发现作答、代码或运行输出，保持 Step 3，不新增 Step 4，也不据此判断你是否已在线下练习。

如果今天只有 15 分钟，先做一个城市的最小实验：取 Step 2 北京的 A/B 用户集合，构造两份 BitSet，打印局部人数、合并人数，以及重复合并 B 后的人数。先写预测，再运行，保留原集合以方便比较。把代码、输出或报错放在本目录即可，其余部分下次继续。

`exactly-once` 的讨论暂时只需一句话表达你的理解；不熟悉可以标记疑问，不必为此额外学习完整消息或事务协议。

## 2026-09-23 验收后的当前任务

首次作答已验收，空间实验和 SQL 排序通过。目前仅需按 [REVIEW.md](REVIEW.md) 的“最小补交”修正按城市合并、追加运行输出和解释。预计 10–15 分钟，无需重做完整任务。
