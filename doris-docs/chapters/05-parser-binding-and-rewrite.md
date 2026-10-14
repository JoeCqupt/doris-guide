# 第 5 章　Nereids：从 SQL 列身份到一条改写规则

[全书导航](../README.md) · [术语表](../appendices/A-glossary.md) · [本章源码来源记录](../examples/05-filter-project/source-map.json)

> 教学结构修订：2026-10-14。每章先沿一个问题阅读代码，再做实验、观察结果，最后解释对象和分支。历史正文基线为 `a53b182f810be2b3731c7dfdf6f40ff5a0ad63bd`；本次摘录取自当前本地文件，完整文件 SHA-256 与行号保存在[源码摘录清单](../examples/08-chapter-workshops/source-manifest.json)。运行证据来自报告版本 `doris-0.0.0-a53b182f810` 的二进制，不能仅凭版本前缀认定当前工作目录与二进制逐文件相同。

**本章问题：过滤为什么能穿过别名投影，却不能随意穿过 LIMIT？**

本章验证方式：已归档运行证据 + 源码走查；扩展分支见本章边界。建议先用 20—40 分钟完成主案例，第四部分的扩展阅读可分次完成；这不是新增的每日必交任务。

## 一、源码讲解：先找到决定行为的对象和分支

这次只盯住一棵局部计划树：Filter(revenue > 100) → Project(amount AS revenue)。规则要先判断能否移动，再把输出 Slot 替换为生产表达式。名字相同不是身份相同；LIMIT 又让“先选哪些行”成为可观察语义。

### 先读这段真实代码

文件：`fe/fe-core/src/main/java/org/apache/doris/nereids/rules/rewrite/PushDownFilterThroughProject.java`，当前文件第 54—70 行。下面是连续原文摘录，局部片段省略了方法的其他部分；不要把片段当完整实现。

```java
    @Override
    public List<Rule> buildRules() {
        return ImmutableList.of(
                logicalFilter(logicalProject().whenNot(LogicalProject::containsNoneMovableFunction))
                        .whenNot(filter -> ExpressionUtils.containsWindowExpression(filter.child().getProjects()))
                        .then(PushDownFilterThroughProject::pushDownFilterThroughProject)
                        .toRule(RuleType.PUSH_DOWN_FILTER_THROUGH_PROJECT),
                // filter(project(limit)) will change to filter(limit(project)) by PushdownProjectThroughLimit,
                // then we should change filter(limit(project)) to project(filter(limit))
                // TODO maybe we could remove this rule, because translator already support filter(limit(project))
                logicalFilter(logicalLimit(logicalProject().whenNot(LogicalProject::containsNoneMovableFunction)))
                        .whenNot(filter ->
                                ExpressionUtils.containsWindowExpression(filter.child().child().getProjects())
                        )
                        .then(PushDownFilterThroughProject::pushDownFilterThroughLimitProject)
                        .toRule(RuleType.PUSH_DOWN_FILTER_THROUGH_PROJECT_UNDER_LIMIT)
        );
```

### 这几行应该怎样读

第一条模式匹配普通 Filter→Project，第二条匹配含 LIMIT 的形状。两个 `whenNot` 先拒绝不适合移动的函数/窗口情况，再进入具体转换。`toRule` 给转换命名，真正替换表达式和重建树发生在后续方法。

### 固定 SQL：过滤引用了投影后的别名

使用第 3 章的教学表，先看这一条 SQL：

```sql
SELECT city, revenue
FROM (
    SELECT city, amount AS revenue
    FROM doris_book.orders_intro_v1
) t
WHERE revenue > 100;
```

`amount` 是基表列，`revenue` 是内层投影产生的输出名。外层 WHERE 能使用 revenue，是因为它引用子查询的输出，不是在同一 SELECT 层任意引用刚定义的别名。

取三行简化数据，只用于推演，不是重新执行数据库：

| city | amount | 投影的 revenue | revenue > 100 |
|---|---:|---:|---|
| 北京 | 80.00 | 80.00 | false |
| 上海 | 120.00 | 120.00 | true |
| 杭州 | 200.00 | 200.00 | true |

先投影再按 revenue 过滤，与先按 amount 过滤再投影，这个例子结果相同。接下来源码需要证明：引用对应哪个表达式、这个表达式能否被移动、移动后输出身份是否仍然正确。

这里选定绑定已完成后的逻辑改写阶段，主例中没有窗口、随机表达式和 LIMIT，也不包含压缩物化的 Encode/Decode 包装。暂时忽略最外层只做输出选择的 Project，考察局部子树：

```text
Filter(revenue#20 > 100)
└── Project(city#8, Alias(amount#7 AS revenue)#20)
    └── Child：输出至少包含 city#8、amount#7
```

`#7/#8/#20` 是本章人为固定的 ExprId，用来追踪对象身份，不是实际 EXPLAIN 输出，也不是内存地址。解析器可能先生成额外包装节点，最终优化也可能合并投影；这棵树表示规则收到的局部形状。

### Parse、Analyze、Rewrite 分别交付什么

| 阶段 | 核心输入与产物 | 本章相关入口 |
|---|---|---|
| Parse | SQL 文本 → 语法结构及逻辑计划表达 | `NereidsParser.parseSQL()`、解析器侧 `LogicalPlanBuilder` |
| Analyze | 未解析引用 → 表/列身份、作用域、类型及分析后的计划 | `NereidsPlanner.analyze()`、Analyzer 的规则与任务 |
| Rewrite | 已有计划 → 满足前提的替代计划 | `NereidsPlanner.rewrite()`、`Rewriter` |
| Optimize | 合法候选及其物理需求 → 代价选择 | 第 6 章 |

例如列不存在首先是绑定/分析问题；两种合法 Join 哪种更便宜属于优化选择。当前 `NereidsPlanner` 把分析交给 `cascadesContext.newAnalyzer().analyze()`，把改写交给 `Rewriter.getWholeTreeRewriter(cascadesContext).execute()`。具体规则不都在 Planner 一个类里实现。

本章规则属于 `RewriteRuleFactory`。`RuleSet.PUSH_DOWN_FILTERS` 包含 `new PushDownFilterThroughProject()`；`Rewriter` 在多处组合使用这些规则，子查询处理阶段也会直接使用它。因而它不是“每条 SQL 只运行一次的固定第 N 步”。测试中只应用这条规则，与生产中运行整个规则序列的范围不同。

### 先认识五种对象：名字不是身份

| 对象 | 主例中的内容 | 在这条规则中的用途 |
|---|---|---|
| `SlotReference` | amount#7、city#8、revenue#20 | 引用某个已确定的输出 |
| `Alias` | 输入是 amount#7，输出 ExprId 是 #20，显示名 revenue | 连接生产表达式与投影输出身份 |
| `LogicalProject.projects` | city#8 与 Alias(amount#7 AS revenue)#20 | 定义子树向上提供什么列 |
| `LogicalFilter.conjuncts` | `{revenue#20 > 100}` | 保存 AND 分解后的谓词集合 |
| `Map<Slot, Expression>` | `{revenue#20 → amount#7}` | 下推时将投影输出替换成其生产表达式 |

普通 `Alias(child,name)` 构造方法会分配新的 ExprId；另有显式接收 ExprId 的构造方法，测试经常使用它。`Alias.toSlot()` 以 Alias 自己的 ExprId/name 构造输出 Slot，同时从 child 取类型与 nullable 等信息。它不是简单返回原 child。

`SlotReference.equals()` 先检查实际类，再比较 ExprId，`hashCode()` 也基于 ExprId。对同类 SlotReference，相同显示名而不同 ExprId 的两个列不是同一引用；显示名或 qualifier 不同但 ExprId 相同，也不能只按字符串认定它们无关。这正是 Set.containsAll 和 Map.get 在本规则里能按身份工作的基础。

对于 Java 开发者，可以把 Alias 想成“一个带独立身份的输出定义”，把 toSlot 看成“引用这个输出的句柄”。ExprId 是查询计划中的身份，不是表的永久 column ID。

#### 输出集合与别名映射分别从哪里来

`LogicalProject.computeOutput()` 对每个 NamedExpression 调用 `toSlot()`，因此主例 Project 的输出是 `{city#8,revenue#20}`。规则里变量名虽然叫 `childOutputs`，取值却是 **Filter 的 child（Project）的输出集合**，不是 Project 下方 Child 的原始输出集合。把这层关系看错，会误以为 revenue#20 不在集合里而永远不能下推。

`Project.getAliasToProducer()` 委托给 `ExpressionUtils.generateReplaceMap()`：

```java
public static Map<Slot, Expression> generateReplaceMap(List<? extends NamedExpression> namedExpressions) {
    Map<Slot, Expression> replaceMap = Maps.newLinkedHashMapWithExpectedSize(namedExpressions.size());
    for (NamedExpression namedExpression : namedExpressions) {
        if (namedExpression instanceof Alias) {
            // Avoid cast to alias, retrieving the first child expression.
            Slot slot = namedExpression.toSlot();
            replaceMap.putIfAbsent(slot, namedExpression.child(0));
        }
    }
    return replaceMap;
}
```

出处：`fe/fe-core/src/main/java/org/apache/doris/nereids/util/ExpressionUtils.java`，本次读取行 435 起（原文节选）。

只有 Alias 被放进映射。直接透传的 city#8 不需要变成另一个表达式，因此 Map 中没有 city#8 完全正常。`putIfAbsent` 保留已存在映射；它不是从列名寻找任意同名表达式。

## 二、动手实验：先预测，再核对

默认使用已保存的实验材料或只读源码，不需要启动服务。运行环境已停止；若选择重新执行 SQL，先按[实验复现说明](../examples/07-live-lab-20261014/REPRODUCE.md)确认服务、版本与数据状态。初始化、导入和更新脚本不可在现有表上盲目重放。

1. 运行下方只读的两条等价查询，或比较 05-filter-equivalence 的前两段结果，确认别名消除不改变金额集合。
2. 阅读同一文件的两条 LIMIT 查询，先预测 COUNT 为何一个 0、一个 2，再打开输出。
3. 进入 buildRules 和 pushDownFilterThroughProject，逐项对应窗口/不可移动表达式门槛、谓词拆分和 withChildren 重建；不要把任意全局计划变化都归功于这一条规则。

```sql
SELECT city,revenue FROM
 (SELECT city,amount AS revenue FROM doris_book.orders_intro_v1)t
 WHERE revenue>100 ORDER BY revenue;
SELECT city,amount FROM doris_book.orders_intro_v1
 WHERE amount>100 ORDER BY amount;
```

本章实验材料：[04-filter-project.out.txt](../examples/07-live-lab-20261014/04-filter-project.out.txt) · [05-filter-equivalence.sql](../examples/07-live-lab-20261014/05-filter-equivalence.sql) · [05-filter-equivalence.out.txt](../examples/07-live-lab-20261014/05-filter-equivalence.out.txt)。

## 三、观察结果：先陈述事实，再划清证据范围

实测两条别名/直接过滤都返回上海 120.00、杭州 200.00。先按 order_id 取两行再过滤得到 0 行；先过滤再 LIMIT 得到 2 行。

**本章边界：** SQL 等价结果不独自证明某条规则实际触发；观察规则需结合计划或规则级测试。现有 Java 测试未运行。

## 四、回到源码解释：把现象还原成执行过程

别名可以通过表达式替换保持语义；LIMIT 选择的集合却会随过滤位置改变。规则的限制条件承担正确性责任，return null 表示本次不做转换，不是返回 SQL 空集。下面保留的原码案例逐个解释 Slot、条件拆分及四个已有测试。

### 用自己的话走完这条链

合上结果后，按“输入 → 关键对象/状态 → 分支条件 → 可观察结果”的顺序回答本章问题：**过滤为什么能穿过别名投影，却不能随意穿过 LIMIT？** 再指出一项尚不能从现有实验得出的结论。能把每个箭头落到本章的方法或证据，比记住术语更接近读懂源码。

### 第一层条件：整棵局部树是否允许进入规则

`buildRules()` 的普通分支是：

```java
logicalFilter(logicalProject().whenNot(LogicalProject::containsNoneMovableFunction))
        .whenNot(filter -> ExpressionUtils.containsWindowExpression(filter.child().getProjects()))
        .then(PushDownFilterThroughProject::pushDownFilterThroughProject)
        .toRule(RuleType.PUSH_DOWN_FILTER_THROUGH_PROJECT),
```

出处：`fe/fe-core/src/main/java/org/apache/doris/nereids/rules/rewrite/PushDownFilterThroughProject.java`，本次读取行 57 起（原文节选）。

从外到内解释：

1. 匹配 `LogicalFilter(LogicalProject(...))` 的局部结构。
2. `Project.containsNoneMovableFunction()` 遍历投影表达式，存在 `NoneMovableFunction` 时不进入该分支。
3. 投影列表含窗口表达式时，不进入该分支。
4. 前提成立才执行 `pushDownFilterThroughProject()`，并以固定 RuleType 标识该规则。

这些是整条规则的入口条件，后面还有对每个谓词的条件，不能混成一个总开关。Random 在当前实现中继承 UniqueFunction；不应仅凭“随机”就把它等同于这里所有的 NoneMovableFunction。实际可移动性由相应表达式 trait 和规则层次共同决定。

窗口的拒绝有直接语义原因：如果先算 rank 再筛选 rank，不能随便改成先删除行再算 rank。当前规则对投影中含窗口采取整体拒绝，哪怕某个谓词看起来只引用别的列；本章不推导实现之外的更强优化。

### 第二层条件：拆分每个 AND 谓词

普通分支先取得三个输入，再调用拆分方法：

```text
filter.getConjuncts()       → 待处理的谓词集合
project.getOutputSet()     → 允许引用的当前输出身份
project.getAliasToProducer() → 输出身份到生产表达式的映射
```

`splitConjunctsByChildOutput()` 为每个谓词取得 `getInputSlots()`，执行下面的原码：

```java
if (childOutputs.containsAll(conjunctSlots)
        && conjunctSlots.stream().map(childAlias::get).filter(Objects::nonNull)
                .noneMatch(Expression::containsVolatileOrNoneMovableExpression)) {
    pushDownPredicates.add(conjunct);
} else {
    remainPredicates.add(conjunct);
}
```

出处：`fe/fe-core/src/main/java/org/apache/doris/nereids/rules/rewrite/PushDownFilterThroughProject.java`，本次读取行 126 起（原文节选）。

**第一个条件检查作用域。** 谓词用到的全部 Slot 都必须能由当前 Project 提供。规则会用于子查询处理，谓词中可能含外层查询的 Slot；不能把这些引用当成当前局部输入。

**第二个条件检查替换的后果。** 先把谓词引用的 Slot 映射到 producer；没有映射的直接透传列会被 `filter(Objects::nonNull)` 去掉；其余 producer 不能含 trait 判定的 volatile 或不可移动表达式。检查对象是 *被引用别名的生产表达式*，不是简单扫描谓词文本有没有 `random`。

`ExpressionTrait.containsVolatileOrNoneMovableExpression()` 结合表达式类型、`isVolatile()` 和 `NoneMovableFunction` 判断。它是当前实现的具体条件，不宜直接改写为“任何非确定函数都一概禁止”的更宽泛规则。

两个 Set 使用 LinkedHashSet，保存判定后的谓词集合与插入顺序。它们位于本次规则调用中，不是某个全局、跨查询的过滤器注册表。

#### 三个谓词的逐项推演

扩展主例的 Project，让它还输出 `Alias(random(...) AS noise)#21`。取三个输入谓词：

| 谓词 | 输入 Slot | 是否属于 Project 输出 | 引用的 producer | 去向 |
|---|---|---|---|---|
| P1: revenue#20 > 100 | {#20} | 是 | amount#7 | 可下推集合 |
| P2: noise#21 > 0.5 | {#21} | 是 | random(...) | 保留集合 |
| P3: revenue#20 > outer#99 | {#20,#99} | 否，#99 来自外层 | 不需要继续靠第二条件放行 | 保留集合 |

这是模拟已分析计划的教学案例，不是声称 P3 能单独作为当前主例 SQL 执行。拆分刚完成时，P1 仍是 `revenue#20 > 100`，尚未替换成 amount。**判定是否可移动在前，表达式替换在后。**

### 别名替换：改的是表达式树

拆分后，规则对可下推集合调用 `ExpressionUtils.replace(pushDownPredicates, childAlias)`。Set 重载逐个处理表达式，单表达式方法如下：

```java
public static Expression replace(Expression expr, Map<? extends Expression, ? extends Expression> replaceMap) {
    return expr.rewriteDownShortCircuit(e -> {
        Expression replacedExpr = replaceMap.get(e);
        return replacedExpr == null ? e : replacedExpr;
    });
}
```

出处：`fe/fe-core/src/main/java/org/apache/doris/nereids/util/ExpressionUtils.java`，本次读取行 530 起（原文节选）。

主例表达式树变化为：

```text
替换前                         替换后
GreaterThan                    GreaterThan
├── Slot(revenue#20)            ├── Slot(amount#7)
└── Literal(100)                └── Literal(100)
```

GreaterThan 和字面量没有命中 Map，不被替换；revenue#20 命中，替换为 producer amount#7。如果 Alias 的 producer 是 `amount#7 + fee#9`，替换位置将放入这棵计算表达式，而非改一个字符串字段。

Map 未提供映射的 city#8 原样保留。当前调用使用自顶向下短路改写；不要擅自解释成对替换结果不断应用映射直到不变的全局定点算法。嵌套 Project 的继续下推，依赖规则调度再次处理后续树形。

#### 压缩物化分支为何需要单独说明

规则在有 ConnectContext 且 `enableCompressMaterialize` 为真时，先调用 `eliminateDecodeAndEncode()`，再执行 alias replacement。该 helper 递归检查表达式，将匹配的 `DecodeAsVarchar(EncodeString(x))` 包装化简为 x；子节点改变时用 withChildren 重建。

本章主例没有这种包装，两条分支在这一点上没有可展示的差异。正文不把这个教学选择写成该变量的默认值，也没有为分析而修改运行配置。

### 重建计划：哪些对象改变，哪些身份保留

普通分支结束部分：

```java
if (pushDownPredicates.isEmpty()) {
    return null;
}
project = (LogicalProject<? extends Plan>) project.withChildren(
        new LogicalFilter<>(pushDownPredicates, project.child()));
return PlanUtils.filterOrSelf(remainPredicates, project);
```

出处：`fe/fe-core/src/main/java/org/apache/doris/nereids/rules/rewrite/PushDownFilterThroughProject.java`，本次读取行 88 起（原文节选）。

首先处理没有可下推项的情况：返回 null。它不是“删除这条 SQL”，也不是 SQL NULL。`PatternMatcher.toRule()` 的 `transform()` 会将 null 替换结果转为原 originPlan，即保留原计划。

有可下推项时，代码先创建下层 LogicalFilter，再用 `project.withChildren(...)` 创建新的 Project。`LogicalProject.withChildren()` 保留 projects 等信息并复制相应计划身份，不是就地修改旧对象的 children。**输出 Alias 的 ExprId 仍为 #20**，因此上层消费者不必改成直接引用 amount#7。

最后由 `PlanUtils.filterOrSelf()` 决定是否保留外层 Filter：

```java
public static Optional<LogicalFilter<? extends Plan>> filter(Set<Expression> predicates, Plan plan) {
    if (predicates.isEmpty()) {
        return Optional.empty();
    }
    return Optional.of(new LogicalFilter<>(predicates, plan));
}

public static Plan filterOrSelf(Set<Expression> predicates, Plan plan) {
    return filter(predicates, plan).map(Plan.class::cast).orElse(plan);
}
```

出处：`fe/fe-core/src/main/java/org/apache/doris/nereids/util/PlanUtils.java`，本次读取行 86 起（原文节选）。

主例全部下推时：

```text
Project(city#8, Alias(amount#7 AS revenue)#20)
└── Filter(amount#7 > 100)
    └── 原 Child
```

“第二层条件：拆分每个 AND 谓词”的混合例子只有 P1 下推时：

```text
Filter(noise#21 > 0.5 AND revenue#20 > outer#99)
└── Project(city#8, Alias(amount#7 AS revenue)#20, Alias(random(...) AS noise)#21)
    └── Filter(amount#7 > 100)
        └── 原 Child
```

| 对象/内容 | 改写前后 |
|---|---|
| 原 Child 子树 | 本次变换复用，后续规则可能继续改写 |
| Project 的输出定义 | 保持原 projects，仍向上输出 revenue#20 等 |
| 下层 Filter | 新建，只包含已替换的可下推谓词 |
| 上层 Filter | 有剩余谓词才构建；否则直接返回新 Project |
| 原始计划对象 | 此方法用新节点组合替代树，不要求调用方就地改字段 |

这一过程处在 FE 规划期，尚未扫描订单或修改表元数据；这里的局部集合和计划对象变化，不是 BE 数据的增删。

### 两种 random 场景：为什么一个留、一个走

场景 A：投影生成随机值并起别名 b，Filter 引用 b。

```text
Filter(b > 0.5)
└── Project(random(...) AS b)
```

若下推为 `Project(random(...) AS b) → Filter(random(...) > 0.5)`，Filter 与 Project 可能各自求一次随机值。筛选依据不再是最后输出的 b。第二层 producer 检查让这个谓词留下，防止复制求值改变语义。

场景 B：Project 只把 id 起别名 a，随机调用本来就在 Filter 中。

```text
Filter((a + random(...)) IS NULL)
└── Project(id AS a)
```

替换 a→id 不需要把某个投影中的随机 producer 再复制出来。当前规则允许这个谓词移动。是否存在更广泛的求值顺序问题需要看具体规则前提；这里陈述的是已读实现与其测试针对的区别，不推广为“所有随机表达式都安全下推”。

这也是阅读源码比记住“非确定函数不能下推”更精确的地方：必须确定函数在树的哪一层，谁持有它，变换是否增加了求值位置。

### LIMIT 分支：移动 Project，不越过行数截断

另一条匹配形状是 Filter(Limit(Project(Child)))。它调用相同拆分 helper，但重建方式不同：

```java
project = project.withProjectsAndChild(project.getProjects(),
        new LogicalFilter<>(pushDownPredicates, limit.withChildren(project.child())));
return PlanUtils.filterOrSelf(remainPredicates, project);
```

出处：`fe/fe-core/src/main/java/org/apache/doris/nereids/rules/rewrite/PushDownFilterThroughProject.java`，本次读取行 110 起（原文节选）。

假设没有保留谓词，改写前后是：

```text
改写前：Filter(p(alias)) → Limit → Project(alias) → Child
改写后：Project(alias) → Filter(p(producer)) → Limit → Child
```

这里箭头指向 child，数据从右向左流动。Filter 在两棵树里都位于 Limit **上方**。规则让 Project 移到外面，并把过滤转换成底层表达式；它没有允许 Filter 提前改变 Limit 选中的行。

取一个已经给定顺序的输入流 `[80,120]`，Limit=1，谓词金额>100。先 Limit 得到 `[80]`，再过滤是空集；若错误地把 Filter 放在 Limit 下方，就先得到 `[120]`，再取一行，结果改变。这是有固定输入顺序的算子反例；SQL 不含 ORDER BY 时也不能据此承诺哪一行被 LIMIT 选中。

如果还有不可下推的谓词，最外层仍有 Filter：

```text
Filter(remain) → Project → Filter(pushDown) → Limit → Child
```

窗口投影仍在入口被拒绝；LIMIT 专用分支并不跳过那些条件。

### 四个真实测试：看构造与断言，不靠名字猜

测试文件是 `fe/fe-core/src/test/java/org/apache/doris/nereids/rules/rewrite/PushDowFilterThroughProjectTest.java`，实际拼写确实是 **PushDow**。另一个 postprocess 目录下的相似类不属于这里。下面分析静态测试代码，不宣称运行通过。

#### 夹具如何隔离单条规则

类成员使用 `PlanConstructor.student` 构造 `LogicalOlapScan`；每个测试通过 `MemoTestUtils.createConnectContext()` 准备上下文，用测试侧 `LogicalPlanBuilder` 组装已绑定的对象。

注意测试侧 Builder 与生产 Parser 的同名 Builder 不同。这里没有让 SQL 文本完整经过 parser/analyzer，也没有在真实 BE 上扫描 student 表。测试 Builder 的 filter(Expression) 会调用 `ExpressionUtils.extractConjunction()` 将 AND 分解成集合。

`PlanChecker.applyTopDown(new PushDownFilterThroughProject())` 建立只含指定规则的改写任务，之后初始化 Memo 和有效状态检查。因此它更适合隔离规则行为；最终 SQL EXPLAIN 则受多条规则共同影响。

#### 普通别名测试

`pushDownFilterThroughProject()` 连续构建两层 Alias，再对外层别名做 IS NULL。测试显式使用 ExprId(1) 组织这些对象；这是夹具写法，不能推广为所有生产 Alias 都共享身份。

最终断言寻找一个 Filter，其 `getPredicate().toSql()` 为 `id IS NULL`。它证明在这个夹具中别名谓词能还原到底层 id。它没有执行查询，也没有断言所有节点的每个字段。

#### 窗口拒绝测试

`notPushDownFilterThroughWindow()` 构造 Rank 的 WindowExpression 并起别名。先测 Filter→Project，再测 Filter→Limit→Project；断言搜索相应结构仍存在。两个形状都覆盖入口的窗口拒绝场景，但未穷举所有窗口函数、窗口 frame 或旁路条件。

#### 最有价值的混合谓词测试

`notPushDownFilterThroughNonfoldable()` 构造：

```text
Project：a = id，b = random(1,10)
Filter：a IS NULL AND b IS NULL AND (a + random(1,2)) IS NULL
```

代码断言的预期结构和谓词文本为：

```text
Filter：b IS NULL
└── Project：原 a、b
    └── Filter：AND[id IS NULL,(id + random(1, 2)) IS NULL]
```

这一个测试同时验证三件事：a 可以展开；b 的随机 producer 不能复制下去；Filter 自己持有的 random 并不阻止 a→id 的替换。随后它在输入树中加入 Limit，断言下层 Filter 仍位于 Limit 上方。

这正是 “两种 random 场景”的源码证据。简单写“测试非确定函数”会漏掉它最重要的区分。

#### LIMIT 正向测试

`pushDownFilterThroughLimit()` 构造 id AS a、Limit(1)、a IS NULL，断言搜索 Project→Filter→Limit 的结构，Filter 文本为 `id IS NULL`。它验证正确树形，但未通过真实输入行验证 LIMIT 结果；5.9 的两行反例属于独立教学论证。

#### matches 并非整树完全相等

```java
public PlanChecker matches(PatternDescriptor<? extends Plan> patternDesc) {
    Memo memo = cascadesContext.getMemo();
    checkSlotFromChildren(memo);
    assertMatchesWithDiagnostic(memo, patternDesc.pattern,
            () -> MatchingUtils.topDownFindMatching(memo.getRoot(), patternDesc.pattern));
    return this;
}
```

出处：`fe/fe-core/src/test/java/org/apache/doris/nereids/util/PlanChecker.java`，本次读取行 633 起（原文节选）。

`MatchingUtils.topDownFindMatching` 从树中寻找匹配结构。这个断言比“结果树的根就是某节点，且所有后代字段完全相同”更弱；不能将一次 matches 解释为穷尽验证。若以后修改规则，需要根据目标决定是否补根级结构、输出身份、不可匹配情况或其他断言。

| 测试 | 支持的判断 | 仍不支持的结论 |
|---|---|---|
| 普通别名 | 谓词还原为 id IS NULL | 任意复杂绑定链都正确 |
| Window | 两种形状的窗口入口不下推 | 所有窗口优化都已验证 |
| 混合随机 | 拆分保留/移动集合，区别随机表达式位置 | 所有不可移动 trait、外层 Slot 都覆盖 |
| LIMIT | 特定 Project/Filter/Limit 结构 | SQL 在真实数据上的执行与性能 |

这份测试没有直接提供本章 outer#99 例子的专门断言，也没有在这四个方法中显式覆盖 Encode/Decode 化简。不能因此认定全仓缺少相应测试，更不能据此直接制造一个补测试 PR。

### 正确性与定位：用变量值回答问题

遇到“Filter 没有下推”的计划，不要先改规则。按代码顺序检查：

| 观察点 | 应记录的具体值 | 能区分的问题 |
|---|---|---|
| buildRules 匹配 | 当前局部树形、Project 表达式 | 根本没进入本规则，还是进入后被分支拒绝 |
| getOutputSet | 每个 Slot 的 ExprId 与名称 | 同名不同列、外层作用域引用 |
| getAliasToProducer | key ExprId → producer 表达式 | 缺少映射还是直接透传列 |
| splitConjuncts | remain 与 pushDown 两集合 | 哪一项因什么条件留下 |
| replace | 单个谓词替换前后树 | 输出引用是否转换到正确输入 |
| filterOrSelf | 返回根类型及 children | 原 Filter 是消除、拆开还是保留 |
| 调度后 | 后续规则和最终计划 | 当前规则结果是否又被下一规则改变 |

本章案例的正确性约束是：保留输出身份、引用可由目标输入提供、避免不允许的 producer 重复求值、保持 LIMIT 的行集合边界。性能收益只在合法变换上讨论；即使少算投影表达式，也不能仅凭这棵树证明磁盘扫描字节减少，真正的扫描过滤还需要后续规则与执行路径。

这些对象是 FE 规划阶段结构，本案例不涉及新建并发任务或修改元数据锁。因此无需为了统一模板臆造一条锁时序；到事务与 Pipeline 章节再展开其真实同步问题。

### 验证材料与下一章的连接

[本章材料说明](../examples/05-filter-project/README.md)保存了源码文件摘要、摘录原文/行号与验证边界。它能检查文字引用是否漂移，不能替代 Java 测试。

如需在已有可用构建环境运行这四个测试，仓库脚本支持按类选择：

```bash
cd /Users/jiangyuan/open/doris
bash run-fe-ut.sh --run org.apache.doris.nereids.rules.rewrite.PushDowFilterThroughProjectTest
```

本次未执行。运行时应保留测试报告的实际数量和结果，不能只凭脚本退出码把测试标为通过；也不需要为了阅读本章重新清理或重建整个 Doris。

本章完成的是一个局部规则的 L3 静态实现案例：确定的输入对象、关键分支、变换过程、反例和测试断言都有落点。整章标题中的 Parser/Binding 仍只作导读，尚未成为完整语法分析专著；SQL 与 EXPLAIN 已有运行证据，但没有逐条规则的运行轨迹和已执行的规则单测，不能宣称所有分支完成动态验证。

下一章回答另一个问题：当多种改写与实现都合法时，优化器怎样选择。看清本章的“合法性判断”，才不会把任何未下推都归咎于代价估计。

---

[全书导航](../README.md) · [术语表](../appendices/A-glossary.md) · [本章源码来源记录](../examples/05-filter-project/source-map.json)
