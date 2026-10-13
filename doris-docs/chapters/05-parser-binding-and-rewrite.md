# 第 5 章　Nereids：语法、绑定和逻辑改写

[全书导航](../README.md) · [术语表](../appendices/A-glossary.md)

> 日期：2026-10-12。源码基线：`a53b182f810be2b3731c7dfdf6f40ff5a0ad63bd`。本章是源码阅读版 v1：关键入口与文中明确标出的分支已核对，未运行 Doris SQL、单测或性能实验。图和算例为教学示意；测试文件仅为后续验证入口，不代表已运行或完整覆盖。

## 5.1 SQL 文本距离执行还有多远

前一章追到了 `StmtExecutor`。现在进入它交给规划器的对象：一棵描述查询意图的计划树。考虑下面这条只读示例，它使用第 3 章的订单表：

```sql
SELECT city, revenue
FROM (
    SELECT city, amount AS revenue
    FROM doris_book.orders_intro_v1
) t
WHERE revenue > 100;
```

程序可以认出 SELECT、别名和比较表达式，却还需要确定 `amount` 是哪张表的列、它的类型是什么、外层 `revenue` 与内层表达式是什么关系。接下来还要判断哪些转换不改变结果。

这分别引出三个问题：**Parse 认识结构，Analyze 解决语义引用，Rewrite 寻找适用的等价形态。** 它们不是三个完全隔绝的世界，实际有检查、类型处理及上下文交互，但这个划分比把所有步骤都叫“解析 SQL”更有用。

## 5.2 计划节点与表达式是两层对象

可以把上面的结构粗略画为：

```text
Project(city, revenue)
└── Filter(revenue > 100)
    └── Project(city, amount AS revenue)
        └── Relation(orders_intro_v1)
```

这是语义示意，不是实际 EXPLAIN 原文；解析和后续改写可能引入别名包装或消除节点。

Project、Filter、Relation 是计划节点，描述一组行上的工作。`revenue > 100`、`amount`、常量 100 是表达式。改动某个谓词时，既要考虑表达式含义，也要考虑它放在哪个计划节点上。

一个业务 Java 类中的字段名通常在编译时已经确定；SQL 的列名需要在查询作用域里解析。同名列、表别名、子查询和外部作用域使得纯字符串替换不可靠。读 Nereids 时会看到 Unbound 与已经关联语义信息的对象，列的身份也不只靠显示名称。

## 5.3 三个入口把流程连起来

`NereidsParser.parseSQL()` 是文本进入语句表示的入口之一，`LogicalPlanBuilder` 把语法结构组织为逻辑计划。到 `NereidsPlanner.analyze()`，当前实现调用 `cascadesContext.newAnalyzer().analyze()`。`rewrite()` 则调用 `Rewriter.getWholeTreeRewriter(cascadesContext).execute()`。

这两处调用说明：规划器负责组织阶段，具体分析与改写由下面的规则和任务体系完成。不要在 `NereidsPlanner` 一个文件里寻找每条 SQL 规则的全部实现。

绑定过程的首要成果是消除歧义并建立类型、对象和作用域关系。如果 SQL 引用了不存在的列，问题发生在“这句话是什么意思”，还没有到“哪种执行计划最快”。相反，一条绑定正确但估计行数不准的查询，应转到下一章的统计与代价阶段。

## 5.4 精读一条规则：Filter 穿过 Project

当前 `nereids/rules/rewrite/PushDownFilterThroughProject.java` 给出了非常适合入门的例子。它的基本转换是：把对投影结果的过滤，转换为投影之前、对原表达式的过滤。

对上面的别名而言，外层 `revenue > 100` 可以改写为 `amount > 100`。如果提前过滤减少了后续工作量，就可能提高执行效率。不过，“更早过滤”只是目的，**保证语义不变才是规则成立的前提**。

当前实现不仅匹配 Filter(Project)，还检查投影中是否包含不能移动的函数、是否涉及窗口表达式。其 `splitConjunctsByChildOutput()` 会区分能下推和必须保留的条件：检查所需列是否来自子节点输出，并核对别名对应表达式是否包含不可随意移动的内容；可移动部分才经别名映射替换。

为什么不能随便替换？假设投影产生 `amount + 随机值 AS x`，外层使用 `x > 100`。若下推时复制随机表达式，而输出投影又计算一次，筛选和返回值可能使用不同随机结果，行为就变了。规则源码中的相关检查体现的正是这种约束。

文件还有 Filter(Limit(Project)) 的专门形状处理，但这并不允许将过滤随意推到 LIMIT 之下。先取若干行再过滤，与先过滤再取若干行，可能返回不同数据；阅读时要检查变换后的树，不能只看方法名带有“push down”。

## 5.5 Join 是更容易破坏语义的边界

内连接、左外连接和半连接对未匹配行的处理不同。一个右表条件放在 LEFT JOIN 的 ON 中，和放在整个查询的 WHERE 中，可能决定左侧未匹配行是否被保留。优化器只有满足条件时才可移动或改写它。

因此，“把过滤越早放越好”不是普遍算法。规则应回答：适用于哪种树形、哪种 Join 类型、哪些表达式，什么情况必须保持原状。第 6 章会讨论如何在合法候选里挑计划；非法候选不能因为代价低就被选择。

## 5.6 代码、测试和一次有效观察

路径相对仓库根目录：

| 入口 | 阅读重点 |
|---|---|
| `fe/fe-core/src/main/java/org/apache/doris/nereids/parser/NereidsParser.java` | `parseSQL()` |
| `fe/fe-core/src/main/java/org/apache/doris/nereids/parser/LogicalPlanBuilder.java` | 语法结构到计划对象的构造 |
| `fe/fe-core/src/main/java/org/apache/doris/nereids/NereidsPlanner.java` | `analyze()`、`rewrite()` |
| `fe/fe-core/src/main/java/org/apache/doris/nereids/rules/rewrite/PushDownFilterThroughProject.java` | 形状匹配、别名替换、保留谓词 |
| `fe/fe-core/src/main/java/org/apache/doris/nereids/rules/rewrite/PushDownFilterThroughJoin.java` | 不同 Join 语义的处理入口 |

现有规则测试入口是 `fe/fe-core/src/test/java/org/apache/doris/nereids/rules/rewrite/PushDowFilterThroughProjectTest.java`，文件名里的 `PushDow` 是当前实际拼写。不要混淆另一个 `postprocess/PushDownFilterThroughProjectTest.java`，它面向不同阶段。

后续可用上面的只读 SQL 观察实际计划，但不能要求它保留示意图里的全部节点：多条规则会共同工作。若验证某一条规则，应选择对应规则测试，检查转换前后结构以及不能转换的情况。这样才能区分“最终计划不同”和“某条规则错误”。


---

[上一章：第 4 章](04-request-session-and-command.md) · [全书导航](../README.md) · [下一章：第 6 章](06-memo-statistics-and-cost.md)

## 源码深读补充（2026-10-13）

- [专题 2　列身份、统计、分布属性与增量物化视图](../deep-dives/02-optimizer-statistics-and-mv.md)
