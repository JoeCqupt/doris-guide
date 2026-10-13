# 专题 9　真实 FE 修复复盘：SHOW LOAD 统计为什么在重启后消失

[全书导航](../README.md) · [补充专题导航](README.md)

> 2026-10-13；源码基线 `a53b182f810be2b3731c7dfdf6f40ff5a0ad63bd`。方法链按当前本地源码核对。历史记录另列版本和来源；示意事件不冒充实测。本专题不修改 Doris 源码。

## 1. 历史对象与证据

案例是 [Apache Doris PR #62331](https://github.com/apache/doris/pull/62331)。页面显示该 PR 已合入，存在人工批准记录，也存在机器人对其他配置路径的覆盖质疑。下面的实现分析以本地合入 diff 为准，不把 PR 描述、机器人意见或合入状态当作所有模式正确的证明。

| 对象 | 固定版本 |
|---|---|
| 修复前父提交 | `7a7e70795de3f9e7be1e84a2e1a5a8a608921888` |
| 本地合入提交 | `b6178dc4dd38dd403d15d3a5cd40a443cc0f2161` |
| 本书当前源码 | `a53b182f810be2b3731c7dfdf6f40ff5a0ad63bd` |

没有检出或修改上述版本。本次用 `git show` 比较历史代码，并保存[合入补丁](../examples/04-historical-fix/merged.patch)；没有重新运行历史 Docker 测试。

## 2. 从现象选对层次

用户现象是 INSERT 作业的 JobDetails 统计在 FE 重启前有值、重启后归零。它与“订单没写入”不同：先看被查询的数据，再看 SHOW LOAD 的作业对象和恢复来源。

最小因果链是：

```text
执行时 loadStatistic 有值
 → getShowInfoUnderLock 展示统计
 → 作业状态持久化
 → FE 重启并恢复 InsertLoadJob
 → 再次生成 SHOW LOAD 的 JobDetails
```

如果执行时正确而恢复后丢失，优先检查字段是否进入序列化、恢复是否读取它、展示是否选择了恢复值。修改 Scan、聚合或 SQL 排序通常不对应这个根因。

## 3. 修复前后逐点比较

合入 diff 修改两个 Java 文件，并增加一个重启回归：

| 位置 | 修复前 | 修复后 | 设计目的 |
|---|---|---|---|
| LoadJob 展示统计 | 直接调用 `loadStatistic.toJson()` | 调用 `getJobDetailsJson()` | 给子类一个小范围覆盖点 |
| InsertLoadJob 字段 | 未保存这份终态 JSON 快照 | 新增 `@SerializedName("jdj") jobDetailsJson` | 让展示所需快照参与持久化 |
| 设置终态作业属性 | 设置状态、时间等 | 同时保存当时的 `loadStatistic.toJson()` | 冻结终态展示信息 |
| 子类读取统计 | 依赖恢复后运行时统计对象 | 有快照用快照，无快照回退运行时对象 | 兼顾执行期及旧记录缺字段 |

这不是把整个运行期 `loadStatistic` 对象原样持久化。作者选择持久化展示快照，并通过父类钩子让 INSERT 作业单独处理，其他作业仍走默认实现。代码改动很小，但连接了对象生命周期、恢复格式与用户可见信息。

旧记录没有 `jdj` 时会回退，不意味着能凭空恢复历史上从未保存的统计。兼容性需要区分“旧记录能读”和“旧记录所有丢失信息都被补回”。

## 4. 测试为什么需要重启

历史新增文件 `regression-test/suites/load_p0/insert/test_insert_statistic_after_fe_restart.groovy` 属于 Docker suite。它建源表和目标表，生成 1000 行，执行 INSERT SELECT，取得 SHOW LOAD 的 JobDetails，确认 ScannedRows/LoadBytes 非零，重启 FE 并重连，再比较 ScannedRows、LoadBytes、FileNumber、FileSize。

比较前后相等之外，先要求部分统计非零十分关键：若重启前后都是零，“相等”并不能复现或检验这个问题。这是比镜像实现分支更好的测试契约。

这个测试依赖重启和恢复环境，直接调用 getter 的单测无法覆盖持久化断点。另一方面，一个 Docker 测试也不会自动覆盖所有 INSERT 路由、配置和历史格式。这里分析了测试代码，不宣称本机跑过或全部 CI 成功。

## 5. review 中最值得学的矛盾

公开 PR 描述提到了执行器的配置门控调整，机器人也追问相应路径；但本地最终合入 diff 只有两个作业类和一个测试，没有执行器改动。这个差异可以通过 `git show --stat` 直接核实，不能照抄描述宣布全部完成。[讨论来源](https://github.com/apache/doris/pull/62331)

这不是本书对当前 HEAD 提出新 bug 结论。要判断质疑今天是否仍成立，还需核对当前路由、配置、后续提交及可复现条件。对历史案例，准确结论是“最终补丁解决了已进入该作业持久化路径的统计快照问题；其他路径的覆盖不能由这份 diff 单独证明”。

一份适合 review 的说明应围绕最终实际改动重写：什么条件下信息丢失、快照在哪里捕获、旧记录如何处理、重启测试覆盖了哪条路。PR 状态与代码证据需要一起读，不能以批准人数替代自己的理解。

## 6. 可重现阅读命令与贡献迁移

```bash
# 只读，不检出旧分支、不改工作区。
git show --stat b6178dc4dd38dd403d15d3a5cd40a443cc0f2161
git diff 7a7e70795de3f9e7be1e84a2e1a5a8a608921888 b6178dc4dd38dd403d15d3a5cd40a443cc0f2161 -- fe/fe-core/src/main/java/org/apache/doris/load/loadv2/InsertLoadJob.java fe/fe-core/src/main/java/org/apache/doris/load/loadv2/LoadJob.java
```

若真要运行历史重现，应在隔离环境分别验证修复前后，不用当前学习集群做重启/删库实验；脚本参数按对应 checkout 核实。历史测试风格也不自动成为今天新增测试的规范。

把方法迁移到你自己的 FE 贡献：先找到正常执行与异常生命周期之间的断点，再选择最小持久化/恢复契约，最后用能跨过该断点的测试证明。无需先实现数据库新算法，也无需制造一个本地构建补丁来凑贡献。本案例是已有他人贡献的学习复盘，不计作你的新贡献。
