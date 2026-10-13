# Step 12 成果

- 状态：待开始
- 日期：
- 主动用时 / 等待用时：

## 1. A/B 查询与计划对比

SQL、结果与 EXPLAIN 输出或附件：

A查询的Explain输出：

MySQL [doris_learning]> explain select city, count(1) as city_order_cnt, sum(amount) as city_total_amount,  count(distinct user_id) as city_user_cnt from step11_orders where order_date = "2026-10-08" and status='PAID'  group by city  order by city_total_amount desc, city asc;
+---------------------------------------------------------------------------------------------------------------------------------------+
| Explain String(Nereids Planner)                                                                                                       |
+---------------------------------------------------------------------------------------------------------------------------------------+
| PLAN FRAGMENT 0                                                                                                                       |
|   OUTPUT EXPRS:                                                                                                                       |
|     city[#25]                                                                                                                         |
|     city_order_cnt[#26]                                                                                                               |
|     city_total_amount[#27]                                                                                                            |
|     city_user_cnt[#28]                                                                                                                |
|   PARTITION: UNPARTITIONED                                                                                                            |
|                                                                                                                                       |
|   HAS_COLO_PLAN_NODE: false                                                                                                           |
|                                                                                                                                       |
|   VRESULT SINK                                                                                                                        |
|      MYSQL_PROTOCOL                                                                                                                   |
|                                                                                                                                       |
|   8:VMERGING-EXCHANGE                                                                                                                 |
|      offset: 0                                                                                                                        |
|      distribute expr lists: city[#25]                                                                                                 |
|                                                                                                                                       |
| PLAN FRAGMENT 1                                                                                                                       |
|   OUTPUT EXPRS:                                                                                                                       |
|     city[#17]                                                                                                                         |
|     partial_count(user_id)[#18]                                                                                                       |
|     partial_sum0(count(*))[#19]                                                                                                       |
|     partial_sum(sum(amount))[#20]                                                                                                     |
|   PARTITION: HASH_PARTITIONED: city[#17]                                                                                              |
|                                                                                                                                       |
|   HAS_COLO_PLAN_NODE: true                                                                                                            |
|                                                                                                                                       |
|   STREAM DATA SINK                                                                                                                    |
|     EXCHANGE ID: 08                                                                                                                   |
|     UNPARTITIONED                                                                                                                     |
| IS_MERGE: true                                                                                                                        |
|                                                                                                                                       |
|   7:VSORT(76)                                                                                                                         |
|   |  order by: city_total_amount[#27] DESC, city[#25] ASC                                                                             |
|   |  algorithm: full sort                                                                                                             |
|   |  local merge sort                                                                                                                 |
|   |  merge by exchange                                                                                                                |
|   |  offset: 0                                                                                                                        |
|   |  distribute expr lists:                                                                                                           |
|   |                                                                                                                                   |
|   6:VAGGREGATE (merge finalize)(75)                                                                                                   |
|   |  output: sum0(partial_sum0(count(*))[#19])[#22], sum(partial_sum(sum(amount))[#20])[#23], count(partial_count(user_id)[#18])[#24] |
|   |  group by: city[#17]                                                                                                              |
|   |  sortByGroupKey:false                                                                                                             |
|   |  cardinality=2                                                                                                                    |
|   |  distribute expr lists: city[#17]                                                                                                 |
|   |                                                                                                                                   |
|   5:VEXCHANGE                                                                                                                         |
|      offset: 0                                                                                                                        |
|      distribute expr lists: city[#17]                                                                                                 |
|                                                                                                                                       |
| PLAN FRAGMENT 2                                                                                                                       |
|   OUTPUT EXPRS:                                                                                                                       |
|     city[#9]                                                                                                                          |
|     user_id[#10]                                                                                                                      |
|     partial_sum(amount)[#11]                                                                                                          |
|     partial_count(*)[#12]                                                                                                             |
|   PARTITION: HASH_PARTITIONED: city[#9], user_id[#10]                                                                                 |
|                                                                                                                                       |
|   HAS_COLO_PLAN_NODE: true                                                                                                            |
|                                                                                                                                       |
|   STREAM DATA SINK                                                                                                                    |
|     EXCHANGE ID: 05                                                                                                                   |
|     HASH_PARTITIONED: city[#17]                                                                                                       |
|                                                                                                                                       |
|   4:VAGGREGATE (update serialize)(73)                                                                                                 |
|   |  STREAMING                                                                                                                        |
|   |  output: partial_count(user_id[#14])[#18], partial_sum0(count(*)[#16])[#19], partial_sum(sum(amount)[#15])[#20]                   |
|   |  group by: city[#13]                                                                                                              |
|   |  sortByGroupKey:false                                                                                                             |
|   |  cardinality=2                                                                                                                    |
|   |  distribute expr lists: city[#13], user_id[#14]                                                                                   |
|   |                                                                                                                                   |
|   3:VAGGREGATE (merge finalize)(72)                                                                                                   |
|   |  output: sum(partial_sum(amount)[#11])[#15], count(partial_count(*)[#12])[#16]                                                    |
|   |  group by: city[#9], user_id[#10]                                                                                                 |
|   |  sortByGroupKey:false                                                                                                             |
|   |  cardinality=5                                                                                                                    |
|   |  distribute expr lists: city[#9], user_id[#10]                                                                                    |
|   |                                                                                                                                   |
|   2:VEXCHANGE                                                                                                                         |
|      offset: 0                                                                                                                        |
|      distribute expr lists:                                                                                                           |
|                                                                                                                                       |
| PLAN FRAGMENT 3                                                                                                                       |
|                                                                                                                                       |
|   PARTITION: HASH_PARTITIONED: order_id[#1]                                                                                           |
|                                                                                                                                       |
|   HAS_COLO_PLAN_NODE: false                                                                                                           |
|                                                                                                                                       |
|   STREAM DATA SINK                                                                                                                    |
|     EXCHANGE ID: 02                                                                                                                   |
|     HASH_PARTITIONED: city[#9], user_id[#10]                                                                                          |
|                                                                                                                                       |
|   1:VAGGREGATE (update serialize)(70)                                                                                                 |
|   |  STREAMING                                                                                                                        |
|   |  output: partial_sum(amount[#8])[#11], partial_count(*)[#12]                                                                      |
|   |  group by: city[#6], user_id[#7]                                                                                                  |
|   |  sortByGroupKey:false                                                                                                             |
|   |  cardinality=5                                                                                                                    |
|   |  distribute expr lists:                                                                                                           |
|   |                                                                                                                                   |
|   0:VOlapScanNode(50)                                                                                                                 |
|      TABLE: doris_learning.step11_orders(step11_orders), PREAGGREGATION: ON                                                           |
|      PREDICATES: ((order_date[#0] = '2026-10-08') AND (status[#5] = 'PAID'))                                                          |
|      partitions=1/1 (step11_orders)                                                                                                   |
|      tablets=1/1, tabletList=1791514214328                                                                                            |
|      cardinality=8, avgRowSize=969.375, numNodes=1                                                                                    |
|      pushAggOp=NONE                                                                                                                   |
|      POOLING-SCAN                                                                                                                     |
|      final projections: city[#3], user_id[#2], amount[#4]                                                                             |
|      final project output tuple id: 1                                                                                                 |
|                                                                                                                                       |
|                                                                                                                                       |
|                                                                                                                                       |
| ========== STATISTICS ==========                                                                                                      |
+---------------------------------------------------------------------------------------------------------------------------------------+
116 rows in set (0.091 sec)


B查询的Explain输出：

MySQL [doris_learning]> explain select city, count(1) as city_order_cnt, sum(amount) as city_total_amount from step11_orders where order_date = "2026-10-08" and status='PAID'  group by city  order by city_total_amount desc, city asc;
+-----------------------------------------------------------------------------------+
| Explain String(Nereids Planner)                                                   |
+-----------------------------------------------------------------------------------+
| PLAN FRAGMENT 0                                                                   |
|   OUTPUT EXPRS:                                                                   |
|     city[#14]                                                                     |
|     city_order_cnt[#15]                                                           |
|     city_total_amount[#16]                                                        |
|   PARTITION: UNPARTITIONED                                                        |
|                                                                                   |
|   HAS_COLO_PLAN_NODE: false                                                       |
|                                                                                   |
|   VRESULT SINK                                                                    |
|      MYSQL_PROTOCOL                                                               |
|                                                                                   |
|   5:VMERGING-EXCHANGE                                                             |
|      offset: 0                                                                    |
|      distribute expr lists: city[#14]                                             |
|                                                                                   |
| PLAN FRAGMENT 1                                                                   |
|   OUTPUT EXPRS:                                                                   |
|     city[#8]                                                                      |
|     partial_sum(amount)[#9]                                                       |
|     partial_count(*)[#10]                                                         |
|   PARTITION: HASH_PARTITIONED: city[#8]                                           |
|                                                                                   |
|   HAS_COLO_PLAN_NODE: true                                                        |
|                                                                                   |
|   STREAM DATA SINK                                                                |
|     EXCHANGE ID: 05                                                               |
|     UNPARTITIONED                                                                 |
| IS_MERGE: true                                                                    |
|                                                                                   |
|   4:VSORT(60)                                                                     |
|   |  order by: city_total_amount[#16] DESC, city[#14] ASC                         |
|   |  algorithm: full sort                                                         |
|   |  local merge sort                                                             |
|   |  merge by exchange                                                            |
|   |  offset: 0                                                                    |
|   |  distribute expr lists:                                                       |
|   |                                                                               |
|   3:VAGGREGATE (merge finalize)(59)                                               |
|   |  output: count(partial_count(*)[#10])[#12], sum(partial_sum(amount)[#9])[#13] |
|   |  group by: city[#8]                                                           |
|   |  sortByGroupKey:false                                                         |
|   |  cardinality=2                                                                |
|   |  distribute expr lists: city[#8]                                              |
|   |                                                                               |
|   2:VEXCHANGE                                                                     |
|      offset: 0                                                                    |
|      distribute expr lists:                                                       |
|                                                                                   |
| PLAN FRAGMENT 2                                                                   |
|                                                                                   |
|   PARTITION: HASH_PARTITIONED: order_id[#1]                                       |
|                                                                                   |
|   HAS_COLO_PLAN_NODE: false                                                       |
|                                                                                   |
|   STREAM DATA SINK                                                                |
|     EXCHANGE ID: 02                                                               |
|     HASH_PARTITIONED: city[#8]                                                    |
|                                                                                   |
|   1:VAGGREGATE (update serialize)(57)                                             |
|   |  STREAMING                                                                    |
|   |  output: partial_sum(amount[#7])[#9], partial_count(*)[#10]                   |
|   |  group by: city[#6]                                                           |
|   |  sortByGroupKey:false                                                         |
|   |  cardinality=2                                                                |
|   |  distribute expr lists:                                                       |
|   |                                                                               |
|   0:VOlapScanNode(41)                                                             |
|      TABLE: doris_learning.step11_orders(step11_orders), PREAGGREGATION: ON       |
|      PREDICATES: ((order_date[#0] = '2026-10-08') AND (status[#5] = 'PAID'))      |
|      partitions=1/1 (step11_orders)                                               |
|      tablets=1/1, tabletList=1791514214328                                        |
|      cardinality=8, avgRowSize=969.375, numNodes=1                                |
|      pushAggOp=NONE                                                               |
|      POOLING-SCAN                                                                 |
|      final projections: city[#3], amount[#4]                                      |
|      final project output tuple id: 1                                             |
|                                                                                   |
|                                                                                   |
|                                                                                   |
| ========== STATISTICS ==========                                                  |
+-----------------------------------------------------------------------------------+
81 rows in set (0.160 sec)


节点/分组键/分发键对比及观察：

A/B执行片段不同， 但是基本的scan 还是一样的。 
分组键不同， 因为A查询需要去重user_id, 所以查询规划器在早起分组中通过 user_id, city 进行分组。 B则只按照city进行分组




## 2. 手工推导

按 (city,user_id) 合并的逻辑小表：
Beijing, 101  : 150 / 2
Beijing, 102  : 80 / 1
Shanghai, 101 : 90 / 1
Shanghai, 103 : 150/ 2


由小表得到的城市统计：
Beijing: 2/ 230/ 3
Shanghai: 2/ 240 / 3


三个问题的解释：
1. 只按照user_id 分组会丢失最重要的城市信息
2. 因为订单数已经被 user_id , city 两个条件group by的时候丢失了/压缩了，不能简单的数行小表的行
3. 会重复统计， 局部与局部之间可能会有重复所以不能简单的相加

## 3. FE Java 阅读

四种 AggMode 的输入与输出：


有一点规律：
1. productAggregateBuffer 为false 就是产出result
2. productAggregateBuffer 为true 就是产出buffer

PhysicalHashAggregate 中的对应字段/方法：

不太理解这个问题想问什么？

计划描述与实际扫描计算的区别，以及源码依据：

我按照我的理解来说： 物理计划只是描述了要做什么？ 实际扫描计算是 如何做？ 

疑问：

在b的查询计划中 ：我没搞懂这个查询的 3:VAGGREGATE  为什么会是   count(partial_count(*)[#10])[#12] 来计算订单数？ 不应该是sum么？

我查阅资料后的结果是： 不是 SQL 语义上的“对中间数值做 COUNT”。partial_count(*) 是 Doris 在聚合阶段间传输的 COUNT 聚合状态；在 merge finalize 阶段，count(...) 的 merge 实现会把状态中的计数值累加。EXPLAIN 保留逻辑函数名 count，没有将它美化显示成 sum，所以读起来像“数一数 [2, 1] 有两个元素”，实际并非如此。

## 助手反馈

待验收。


### 2026-10-09 助手验收反馈

计划对比与推导通过；FE Java 部分待小补充，详见 [REVIEW.md](REVIEW.md)。原文全部保留。请在下面追加，不必重做前面任务。

### 本人补充（待填写）

1. 城市结果列名与订单数如何保留：

2. 四种 AggMode 的消费 → 产出，以及 consumeAggregateBuffer=true 含义：

3. 分组键变动对应的 Java 字段，以及 getter 是否执行数据分组：

本步实际用时：


### 2026-10-09 补交验收（助手）

已读取本人追加在 REVIEW.md 的补充。核心目标通过；AggMode 消费侧在 Step 13 实验验证，用时待补充。上方空补充栏不再要求填写。
