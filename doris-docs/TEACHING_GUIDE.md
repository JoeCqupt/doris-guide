# 怎样用这本书读懂 Doris 源码

[全书目录](README.md) · [逐章源码摘录](examples/08-chapter-workshops/README.md)

全书 28 章现在按同一种阅读过程展开，但每章追踪不同的具体问题：

1. **源码讲解**：先认识输入、对象和关键分支。真实摘录附文件、行号与文件摘要，原有深入分析保留在主案例前后。
2. **动手实验**：先预测，再用已有记录核对；也可以在确认环境后执行给出的只读 SQL。写入/重启案例按归档时间线回放，不要求把所有初始化脚本再跑一次。
3. **观察结果**：说明本次实际得到什么、哪个结论仍缺证据。没有外部环境的章节用源码状态推演，明确不等同集群运行。
4. **回到源码解释**：将观察到的行为逐步对应到对象、调用、条件和状态变化，再进入本章剩余的实现细节。

## 从你的 Java 经验开始

第一次推荐顺序：**第 3 → 4 → 14 → 16 → 18 → 27 → 28 章**。这条线从一行数据可读，走到 Java 命令、导入事务、恢复和测试，能较快建立 FE 贡献所需的输入输出意识。

第二条线读 **第 5 → 6 → 7 → 8 → 9 → 21 章**：同一个订单过滤案例与 10 万行聚合串起规则、计划、分布、任务、算子和 Profile。不要把“完整读过一个大类”作为进度；先能解释一次行为，再补相关分支。

存储线为第 10—13、15、17 章，外部系统线为第 22—26 章。第一轮可只完成每章四部分中的主案例，第四部分的细节分次阅读。书是参考和实验材料，不会自动替你增加每日 step 作业。

## 每章只记录一张行为卡

```text
问题：本次要解释什么用户行为？
输入：SQL / 请求 / 对象初始状态是什么？
预测：哪个分支应该执行，输出或状态怎样变化？
观察：实际输出文件 / 源码行 / 测试断言在哪里？
解释：输入 → 对象 → 条件 → 状态 → 输出。
边界：哪些只是源码推演，哪些仍未实测？
```

观察与预测不同，先核对版本、数据状态、命令及断言方式，再判断是不是源码问题。AVG 的 40/40.0 就是测试比较方式的问题；本地参数问题也不能自动转化为产品缺陷。

## 逐章主案例

| 章 | 贯穿问题 | 主案例验证方式 |
|---|---|---|
| [01](chapters/01-from-crud-to-olap.md) | 为什么只返回三个城市，却需要处理多笔订单？ | 实测回放＋源码走查 |
| [02](chapters/02-system-and-source-map.md) | 一次 SQL 跨过 FE/BE 边界时，真正传递的是什么？ | 实测回放＋源码走查 |
| [03](chapters/03-table-read-write-cycle.md) | INSERT 成功以后，下一次 SELECT 为什么能读到它？ | 实测回放＋源码走查 |
| [04](chapters/04-request-session-and-command.md) | SHOW LOAD 和 SELECT 都返回表格，为什么执行路径不同？ | 实测回放＋源码走查 |
| [05](chapters/05-parser-binding-and-rewrite.md) | 过滤为什么能穿过别名投影，却不能随意穿过 LIMIT？ | 实测回放＋源码走查 |
| [06](chapters/06-memo-statistics-and-cost.md) | 优化器知道“估计多少行”，与 BE 实际读了多少行，有什么区别？ | 实测回放＋源码走查 |
| [07](chapters/07-fragments-scheduling-and-exchange.md) | 为什么一台 BE 上也能出现 Exchange 和多个执行实例？ | 实测回放＋源码走查 |
| [08](chapters/08-pipeline-and-vectorized-execution.md) | 流水线在等待数据时，为什么不应该一直占用线程？ | 实测回放＋源码走查 |
| [09](chapters/09-aggregation-join-and-runtime-optimization.md) | AVG 和 Join 为什么不能只看最后一个数字？ | 实测回放＋源码走查 |
| [10](chapters/10-data-model-and-distribution.md) | 相同 Key 的更新和写入哪个分区，是同一个决定吗？ | 实测回放＋源码走查 |
| [11](chapters/11-tablet-rowset-and-segment.md) | 查询能返回行，磁盘上的 Segment 是怎样被解释的？ | 实测回放＋源码走查 |
| [12](chapters/12-index-pruning-and-complex-types.md) | 过滤掉一行与通过索引跳过一页，怎样区分？ | 实测回放＋源码走查 |
| [13](chapters/13-updates-compaction-and-schema-evolution.md) | 部分更新为什么能保留旧列，ALTER 为什么不总是重写全表？ | 实测回放＋源码走查 |
| [14](chapters/14-load-entry-and-lifecycle.md) | 客户端重复发送一个导入请求，会不会重复追加数据？ | 实测回放＋源码走查 |
| [15](chapters/15-physical-write-path.md) | 数据写到 Rowset 后，为什么还需要 Publish？ | 实测回放＋源码走查 |
| [16](chapters/16-transaction-commit-publish-visible.md) | PRECOMMITTED、COMMITTED、VISIBLE 分别允许我们得出什么结论？ | 实测回放＋源码走查 |
| [17](chapters/17-mvcc-snapshots-and-rowset-lifetime.md) | Compaction 产生覆盖版本的新 Rowset，查询怎样避免重复读？ | 版本推演＋运行对照 |
| [18](chapters/18-metadata-journal-and-fe-ha.md) | FE 重启后，为什么还认识原来的表和导入统计？ | 实测回放＋源码走查 |
| [19](chapters/19-node-management-and-maintenance.md) | BE 显示 Alive=true，是否足以说明每个 Tablet 都可读？ | 实测回放＋源码走查 |
| [20](chapters/20-authentication-authorization-and-entrypoints.md) | 登录身份是怎样变成一次表访问的权限判断的？ | 源码走查 |
| [21](chapters/21-resource-governance-observability-and-ui.md) | 查询慢的 17ms，究竟应该从哪里开始解释？ | 实测回放＋源码走查 |
| [22](chapters/22-catalog-and-connector.md) | 同一条 SQL 两次访问同一个 Catalog，会创建两份元数据对象吗？ | 源码走查 |
| [23](chapters/23-external-table-query.md) | Iceberg 文件都找到了，为什么还不等于正确读到表？ | 源码走查 |
| [24](chapters/24-integration-and-extension.md) | Doris 侧 2PC 成功，为什么不能直接宣布 Flink exactly-once？ | 实测回放＋源码走查 |
| [25](chapters/25-object-storage-and-meta-service.md) | 对象文件上传成功，为什么还不能判断事务是否提交？ | 源码走查 |
| [26](chapters/26-cloud-read-write-and-maintenance.md) | 两个线程都发现元数据落后，为什么只有一个需要拉取？ | 源码走查 |
| [27](chapters/27-from-symptom-to-module.md) | SHOW LOAD 少了一项统计，怎样判断该查展示还是持久化？ | 实测回放＋源码走查 |
| [28](chapters/28-testing-fixes-and-sustained-contribution.md) | 怎样把“我看懂了”变成维护者能核验的贡献？ | 实测回放＋源码走查 |

## 复用实验时避免三个混淆

- **过去与现在**：Unique Key 的 A/10/100 是中途状态，当前保留数据已是 C/40/120、note=book。旧 INSERT 脚本重放会改变数据；第 13 章按历史时间线阅读。
- **推演与实测**：Cloud、外表、普通用户权限尚无对应运行环境/矩阵；检索命令和纸面状态表是源码实验，不是服务端测试通过。
- **计划与执行**：EXPLAIN 描述安排；Profile 描述某一次运行；Java/C++ 代码解释实现。三者相互对照，不能用其中一个替代全部证据。

本轮重写未启动 FE/BE，也没有新增运行测试。既有 2026-10-14 实验仍可从[原始证据](examples/07-live-lab-20261014/README.md)复查。摘录的文件摘要用于识别当前本地源码，不能当作编译二进制逐文件一致的证明。
