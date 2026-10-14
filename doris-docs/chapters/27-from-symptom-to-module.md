# 第 27 章　从用户现象定位到一个模块

[全书导航](../README.md) · [前置：请求入口](04-request-session-and-command.md) · [前置：导入生命周期](14-load-entry-and-lifecycle.md)

> 教学结构修订：2026-10-14。每章先沿一个问题阅读代码，再做实验、观察结果，最后解释对象和分支。历史正文基线为 `a53b182f810be2b3731c7dfdf6f40ff5a0ad63bd`；本次摘录取自当前本地文件，完整文件 SHA-256 与行号保存在[源码摘录清单](../examples/08-chapter-workshops/source-manifest.json)。运行证据来自报告版本 `doris-0.0.0-a53b182f810` 的二进制，不能仅凭版本前缀认定当前工作目录与二进制逐文件相同。

**本章问题：SHOW LOAD 少了一项统计，怎样判断该查展示还是持久化？**

本章验证方式：已归档运行证据 + 源码走查；扩展分支见本章边界。建议先用 20—40 分钟完成主案例，第四部分的扩展阅读可分次完成；这不是新增的每日必交任务。

## 一、源码讲解：先找到决定行为的对象和分支

从 ShowLoadCommand.handleShowLoad 的四步读：校验输入、取得记录、排序转换、分页。再把第 18 章的重启证据作为定位分界：运行中就错与仅重启后错，需要追不同对象生命周期。

### 先读这段真实代码

文件：`fe/fe-core/src/main/java/org/apache/doris/nereids/trees/plans/commands/ShowLoadCommand.java`，当前文件第 192—209 行。下面是连续原文摘录，局部片段省略了方法的其他部分；不要把片段当完整实现。

```java
    private ShowResultSet handleShowLoad(ConnectContext ctx, StmtExecutor executor) throws Exception {
        // first validate the where
        boolean valid = validate(ctx);
        if (!valid) {
            throw new AnalysisException("Where clause should looks like: LABEL = \"your_load_label\","
                    + " or LABEL LIKE \"matcher\", " + " or STATE = \"PENDING|ETL|LOADING|FINISHED|CANCELLED\", "
                    + " or compound predicate with operator AND");
        }

        // then process the order by
        ImmutableList<String> titles = isStreamLoad ? STREAM_LOAD_TITLE_NAMES : LOAD_TITLE_NAMES;
        orderByPairs = getOrderByPairs(orderKeys, titles);

        Set<EtlJobType> jobTypes = Sets.newHashSet(EnumSet.allOf(EtlJobType.class));
        jobTypes.remove(EtlJobType.COPY);

        // get the load info
        Util.prohibitExternalCatalog(ctx.getDefaultCatalog(), this.getClass().getSimpleName());
```

### 这几行应该怎样读

`validate` 失败先转成带提示的 AnalysisException；排序列名映射在获取记录之前准备；后面才查询管理器并整理结果。应把“某输入不被接受”和“记录被错误分页”作为两类行为分别验证。

### 从一个可观察行为开始

“我想读懂导入模块”范围太大，很容易一路追到存储层而忘记目标。把它缩成：“SHOW LOAD 的 WHERE 条件在哪里校验，结果如何排序和分页？”你就有了输入、输出和边界。

这个题目适合 Java 业务开发者：它涉及请求参数、表达式、数据获取和结果整理，同时接触 Doris 的语句入口、导入状态和测试方式。它是学习案例，不代表已经找到有价值的待修复问题。

下面保留一张新的条件查询行为卡模板（示例 Label 不是本轮实测 Label）：

```text
操作：SHOW LOAD FROM doris_book WHERE LABEL = 'book_batch_01'
预期：按指定数据库和 Label 查询适用的导入记录
实际：待运行，不能填想象中的输出
服务版本/源码版本：分别记录
范围：先研究普通 SHOW LOAD，不混入 SHOW STREAM LOAD
```

没有对应作业时，空结果可能完全正确。若要调查校验行为，甚至不必先制造大量数据；但从直接调用 Java 校验方法得到的结果，也不能替代真正 SQL 路径的验证。

### 把问题落到四段代码

根据第 4 章的入口，可把主线压缩成：

```text
ShowCommand.run()
  → ShowLoadCommand.doRun()
  → handleShowLoad()
      1. validate()：数据库与 WHERE 条件
      2. 相关管理器：获取记录
      3. 排序与结果行转换
      4. applyLimit()：LIMIT/OFFSET
  → 发送或保存代理结果
```

每段都应该有一个明确问题。校验失败看第 1 段，记录来源看第 2 段，返回行数不对再看第 3—4 段。不要因为症状出现在 SHOW LOAD，就立即改 LoadManager 的事务状态。

### 读校验方法：输入形状和输出状态

当前 `validate()` 先处理数据库名；缺省时从 `ConnectContext` 取当前数据库，仍为空则报告分析错误。有 WHERE 时，按表达式类型进入复合或单个条件分析。

`analyzeSubPredicate()` 对受支持的普通条件检查了这些内容：操作符是否为等号或 LIKE，左侧是否为列名表达式，列名是否属于 Label/State，State 是否使用等号，右侧是否是非空字符串类字面量。

通过检查后，它不仅返回 true，还会更新 `labelValue`、`stateValue`、`isAccurateMatch` 等字段。这是一个带状态的分析过程；测试时应为不同案例构造清晰独立的命令对象，不能把它当作完全无副作用的谓词函数。

还有一个容易被忽略的行为：Label 使用 LIKE 且输入中没有 `%` 时，当前实现会在两侧补 `%`。因此，阅读必须区分“接受这个输入”与“如何把输入变成管理器查询条件”。只断言返回 true 没有验证后者。

复合条件中，当前实现要求 AND，并检查两边列名再分析子条件。对更复杂表达式，正确做法是同时核对解析结果和方法前提。看到强制类型转换或缺少某个分支，只能产生待验证假设；需证明该输入通过前面的 SQL 路径确实能到达这里，并核对预期行为，才能形成问题结论。

## 二、动手实验：先预测，再核对

默认使用已保存的实验材料或只读源码，不需要启动服务。运行环境已停止；若选择重新执行 SQL，先按[实验复现说明](../examples/07-live-lab-20261014/REPRODUCE.md)确认服务、版本与数据状态。初始化、导入和更新脚本不可在现有表上盲目重放。

1. 比较两份 load-*-restart.tsv 中相同 Label 的统计，先写用户可见事实。本次数据未丢，不把历史缺陷自动认定为当前问题。
2. 打开 handleShowLoad，找 validate、getOrderByPairs 与 applyLimit；再读 ShowLoadCommandTest 的 validate/order/limit 断言，标注每项覆盖层级。
3. 假设仅重启后字段归零，画“统计生产 → 记录保存 → 序列化/replay → SHOW 展示”路线；为每一层列一个可以排除它的证据。

本章实验材料：[load-before-restart.tsv](../examples/07-live-lab-20261014/load-before-restart.tsv) · [load-after-restart.tsv](../examples/07-live-lab-20261014/load-after-restart.tsv) · [restart-results.json](../examples/07-live-lab-20261014/restart-results.json)。

## 三、观察结果：先陈述事实，再划清证据范围

当前构建的两条 Type=INSERT 记录统计重启前后相同：100000/1700000 与 1/19（ScannedRows/LoadBytes）。没有发现并确认新的 SHOW LOAD 缺陷。

这里的 INSERT 是 SHOW LOAD 的 Type 字段：第二条 `label_f9562a491d394d6b_9516eec9bb053a86` 对应实验 27 中的 DELETE（txnId=17），不能把展示分类直接当成原始 SQL 动词。证据是 [DELETE 原始输出](../examples/07-live-lab-20261014/27-delete.out.txt) 与两份 SHOW LOAD 记录中的 Label/TransactionId 对照。

**本章边界：** 本章是证据驱动定位练习，不认领 issue、不对外提交，也不声称历史修复已在旧版本复现。

## 四、回到源码解释：把现象还原成执行过程

若过滤/分页导致记录缺失，查公共命令工具；若同 Label 仍在而统计只在重启后变化，优先检查持久化与恢复链。错误层定位会导致把补丁加到展示层，掩盖真正状态丢失。

### 用自己的话走完这条链

合上结果后，按“输入 → 关键对象/状态 → 分支条件 → 可观察结果”的顺序回答本章问题：**SHOW LOAD 少了一项统计，怎样判断该查展示还是持久化？** 再指出一项尚不能从现有实验得出的结论。能把每个箭头落到本章的方法或证据，比记住术语更接近读懂源码。

### 读结果组织：共用工具在哪里

`handleShowLoad()` 在取得记录后排序，未指定排序时使用当前实现的默认比较方式；随后把元素转换成字符串，并调用 `applyLimit()`。

`getOrderByPairs()` 和 `applyLimit()` 定义在 `ShowCommand` 中。它们是共用能力，因此修改可能影响其他 SHOW 命令。当前 `applyLimit()` 还使用公共的 `LimitElement` 处理范围，不能因为只研究 SHOW LOAD 就在子类里重复实现一套分页逻辑。

这个例子展示了一种常见贡献判断：症状出现在 A 命令，但契约可能属于父类或公共工具。提出修改前，应先检索调用方和同类测试，明确改动范围。

### 现有测试到底验证了什么

`ShowLoadCommandTest.java` 当前包含以下测试：

| 测试 | 实际关注点 | 不能据此宣称 |
|---|---|---|
| `testValidate()` | 直接构造表达式，检查部分合法条件、OR 错误、未知列和 Stream Load 分支 | 全部 SQL 语法、全部表达式组合都已覆盖 |
| `testProcessOrderBy()` | Label 对应的结果列下标与排序方向 | 真实管理器返回的多行已经按所有条件正确排序 |
| `testApplyLimit()` | 两行输入上 limit=1、offset=1 的结果 | 所有大数、空集、超界和 SQL 解析行为均已验证 |

测试继承 `TestWithFeService` 并使用测试上下文，仍与真实多节点导入实验不同。最有价值的阅读方式是看“构造了什么输入、调用了哪个层级、断言了什么结果”，而不是只看测试是否存在。

准备新增案例前，先查是否已在父类工具或回归测试中覆盖。没有出现在这个文件里，并不证明整个项目没有测试，也不证明值得新增一个 PR。

### 把假设变成证据的步骤

假设用户报告“某种 WHERE 条件的错误信息不符合预期”。可以按以下顺序推进：

1. 固定最小 SQL、实际服务版本、数据库上下文和完整错误信息。对照该版本文档或同类行为，说明为什么预期合理。
2. 追踪解析后的表达式及校验路径，确认到达条件，寻找最小覆盖层级；先运行现有相关测试作为基线，再构造能区分预期与实际的案例。
3. 核对当前上游状态和已有修复，再决定是解释用法、更新文档、补测试还是修改代码。若确需修改，保留失败前和修改后的验证证据。

这三步不是要求每个小问题都进行全库审计。它们帮助你避免把本地配置、版本差异或未支持语法误当作代码问题，也避免重复修复已解决的问题。

以下为可选验证命令，参数已对照当前 `run-fe-ut.sh` 的帮助格式；**本次没有执行**：

```bash
cd /Users/jiangyuan/open/doris
bash run-fe-ut.sh --run org.apache.doris.nereids.trees.plans.commands.ShowLoadCommandTest
```

运行前按当前仓库要求检查环境；记录退出码和报告中的实际测试结果。命令返回成功不能自动证明运行了预期数量的测试，也不等于所有样式检查都通过。需要端到端 SQL 验证时，应使用仓库回归脚本及规范，不手写期望输出伪装成生成结果。

### 给未来贡献准备一页说明

真正提交问题或修改前，可以把发现写成下面这样的笔记。未完成的项保留“未验证”，不要用推测填满它。

| 项目 | 应记录的证据 |
|---|---|
| 用户可见问题 | 最小 SQL、实际结果、合理预期 |
| 发生条件 | 版本、模式、配置与必要状态 |
| 定位 | 文件/方法、可达路径、违反的具体行为约定 |
| 测试 | 现有基线、新案例、真实运行结果 |
| 修改范围 | 共用代码的调用方、兼容性与影响 |
| 社区状态 | 当前 issue/PR、是否已有认领或修复 |

本章没有挑选一个当前开放 issue，因此没有宣称某个题目可认领。等真正选题时再核实远端状态；本地历史提交可以帮助理解实现，但不是当前社区状态的替代品。

你已经积累的 Java 开发能力在这里非常有用：缩小边界、解释状态、写有意义的测试、对齐用户行为。接下来应把这种工作持续应用到一个模块，逐步形成可信的判断和维护记录，而非为了提交次数制造改动。

### 源码索引与完成边界

以下路径均相对源码根目录：

| 文件 | 本章使用方式 |
|---|---|
| `fe/fe-core/src/main/java/org/apache/doris/nereids/trees/plans/commands/ShowLoadCommand.java` | 输入校验、记录获取、结果组织 |
| `fe/fe-core/src/main/java/org/apache/doris/nereids/trees/plans/commands/ShowCommand.java` | 共用结果发送、排序与分页 |
| `fe/fe-core/src/test/java/org/apache/doris/nereids/trees/plans/commands/ShowLoadCommandTest.java` | 读取现有输入与断言，识别覆盖边界 |
| `run-fe-ut.sh` | 验证可选测试命令的参数格式 |

本章产出是一条可复用的定位方法和一个经过源码核对的阅读案例。没有修改 Doris 代码、没有运行仓库单测，也没有发现并确认新的产品缺陷；SQL/重启证据见本章观察部分。它与前面几章共同构成“用户行为 → FE 入口 → 模块状态 → 测试证据”的第一条贡献阅读路线。

### 延伸源码专题

- [专题 9　真实 FE 修复复盘：SHOW LOAD 统计为什么在重启后消失](../deep-dives/09-historical-fe-fix.md)

---

[全书导航](../README.md) · [前置：请求入口](04-request-session-and-command.md) · [前置：导入生命周期](14-load-entry-and-lifecycle.md)
