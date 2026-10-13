# Step 11 成果

- 状态：待开始
- 日期：
- 主动用时 / 等待用时： 40 min

## 1. 节点与数据准备

FE/BE 状态、CREATE/INSERT 返回、8 行数据或附件：

MySQL [mysql]> SOURCE /Users/jiangyuan/doris-guide/step11/seed.sql;
Query OK, 0 rows affected (0.027 sec)

Database changed
Query OK, 0 rows affected (0.082 sec)

Query OK, 8 rows affected (0.192 sec)
{'label':'label_e8e8ed80e4d24602_94933f1a2aa8180a', 'status':'VISIBLE', 'txnId':'1008'}

+------------+----------+---------+----------+--------+--------+
| order_date | order_id | user_id | city     | amount | status |
+------------+----------+---------+----------+--------+--------+
| 2026-10-07 |     1008 |     105 | Shanghai | 500.00 | PAID   |
| 2026-10-08 |     1001 |     101 | Beijing  | 100.00 | PAID   |
| 2026-10-08 |     1002 |     101 | Beijing  |  50.00 | PAID   |
| 2026-10-08 |     1003 |     102 | Beijing  |  80.00 | PAID   |
| 2026-10-08 |     1004 |     103 | Shanghai | 120.00 | PAID   |
| 2026-10-08 |     1005 |     103 | Shanghai |  30.00 | PAID   |
| 2026-10-08 |     1006 |     101 | Shanghai |  90.00 | PAID   |
| 2026-10-08 |     1007 |     104 | Beijing  | 999.00 | UNPAID |
+------------+----------+---------+----------+--------+--------+
8 rows in set (0.102 sec)

## 2. 先预测再执行

执行前按城市预测（订单数/金额/去重用户数）：

Shanghai:3/240/2
Beijing:3/230/2

自己写的 SQL 和实际结果：


MySQL [doris_learning]> select city, count(1) as city_order_cnt, sum(amount) as city_total_amount,  count(distinct user_id) as city_user_cnt from step11_orders where order_date = "2026-10-08" and status='PAID'  group by city  order by city_total_amount desc, city asc;
+----------+----------------+-------------------+---------------+
| city     | city_order_cnt | city_total_amount | city_user_cnt |
+----------+----------------+-------------------+---------------+
| Shanghai |              3 |            240.00 |             2 |
| Beijing  |              3 |            230.00 |             2 |
+----------+----------------+-------------------+---------------+
2 rows in set (0.217 sec)


全局去重结果、与城市去重之和的比较及证据：

MySQL [doris_learning]> select count(1) as city_order_cnt, sum(amount) as city_total_amount,  count(distinct user_id) as city_user_cnt from step11_orders where order_date = "2026-10-08" and status='PAID'    order by city_total_amount desc;
+----------------+-------------------+---------------+
| city_order_cnt | city_total_amount | city_user_cnt |
+----------------+-------------------+---------------+
|              6 |            470.00 |             3 |
+----------------+-------------------+---------------+
1 row in set (0.322 sec)

不相等  因为不同城市之间有 101 这个重复用户 ， 在全局去重的时候： 全局去重用户数 不等于 各城市去重用户数之和

## 3. 执行计划与理解

EXPLAIN 输出或附件：

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


扫描/聚合节点辨认及疑问：

scan算子：0
|   0:VOlapScanNode(50)                                                                                                                 |
|      TABLE: doris_learning.step11_orders(step11_orders), PREAGGREGATION: ON                                                           |
|      PREDICATES: ((order_date[#0] = '2026-10-08') AND (status[#5] = 'PAID'))                                                          |
|      partitions=1/1 (step11_orders)                                                                                                   |
|      tablets=1/1, tabletList=1791514214328                                                                                            |
|      cardinality=8, avgRowSize=969.375, numNodes=1                                                                                    |
|      pushAggOp=NONE                                                                                                                   |
|      POOLING-SCAN                                                                                                                     |
|      final projections: city[#3], user_id[#2], amount[#4]                                                                             |
|      final project output tuple id: 1   

聚合算子： 1 / 3/ 4 / 6


端口监听证明：FE/BE 进程运行成功

Alive=true 证明： fe/be 心跳成功

实际写入与查询额外证明： select 数据返回成功

任务结束时服务状态： 正常运行

## 助手反馈

待验收。


### 2026-10-09 助手验收

通过，详见 [REVIEW.md](REVIEW.md)。自报 40 分钟；原作答保留。进入 Step 12。
