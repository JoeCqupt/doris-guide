# Job 001 作答与反馈

## 本人完成记录

- 状态：未开始（可改为：进行中 / 部分完成 / 待验收）
- 实际投入：
- 明天可投入时间（如有变化）：

## 1. 业务操作与分析需求

两个 CRUD 操作：

1. 插入数据：  insert into orders(order_id,user_id,city,amount,status,created_at) values ("T123",1, "BEIJING", 20, "PAID", NOW());
2. 修改数据： update orders set status = 'REFUND' where order_id = "T123"

两个统计分析需求：

1.统计最近 30 个完整自然日，每个城市的已支付订单总金额、订单数，以及下单用户去重数:  select city, sum(amount) as city_total_amount, count(order_id), count(distinct(user_id)) from orders where status = 'PAID' and  created_at >= '2026-08-23 00:00:00'  and  created_at < "2026-09-22 00:00:00"  group by city order by city_total_amount desc 
    同金额按城市升序排列 我不知道咋写 
2.统计最近 30 个完整自然日，已支付订单总金额最高的城市
select city , sum(amount) as city_total_amount from orders where status = 'PAID' and  created_at >= '2026-08-23 00:00:00'  and  created_at < "2026-09-22 00:00:00"  group by city  order by city_total_amount desc limit 1

我理解的区别：

## 2. SQL 或伪 SQL

```sql

-- 插入数据： 
 insert into orders(order_id,user_id,city,amount,status,created_at) values ("T123",1, "BEIJING", 20, "PAID", NOW());
-- 修改数据：
 update orders set status = 'REFUND' where order_id = "T123";


-- 1.统计最近 30 个完整自然日，每个城市的已支付订单总金额、订单数，以及下单用户去重数:  
select city, sum(amount) as city_total_amount, count(order_id), count(distinct(user_id)) from orders where status = 'PAID' and  created_at >= '2026-08-23 00:00:00'  and  created_at < "2026-09-22 00:00:00"  group by city order by city_total_amount desc;
-- 同金额按城市升序排列 我不知道咋写
-- 2.统计最近 30 个完整自然日，已支付订单总金额最高的城市
select city , sum(amount) as city_total_amount from orders where status = 'PAID' and  created_at >= '2026-08-23 00:00:00'  and  created_at < "2026-09-22 00:00:00"  group by city  order by city_total_amount desc limit 1;

```

订单数与去重用户数是否总相等？我的解释：
可能相等，也可能不等，取决于  用户有没有重复下单

## 3. 数据处理范围与疑问

与按订单 ID 查一笔订单相比： 
根据订单ID查一笔订单：这个是简单磁盘IO ，根据索引 找到这一行数据就行； 统计查询则更复杂 需要扫描 一个时间范围的数据 ，根据status 过滤 然后进行 group 聚合 然后再进行计算 最后再进行排序  ，整个流程 包含很多步处理和计算

从 1 万到 1 亿订单，可能增加的开销（未验证的请标为猜测）：
根据订单ID查一笔订单，这个有索引其实影响不大，做好分表 很快能完成查询。 
统计查询则需要考虑  扫描的数据量， group 聚合 等操作 中间计算会不会打爆内存， 数据量大查询时长会增加

我不确定的地方（最多两个）：
对于mysql 单表1亿有点多， 按照userID / 日期分表 加速 普通的 根据ID查查询

对不分布式OLAP 这种复杂分析 会有一些常规的优化：谓词下推（status过滤下推），分布式执行， 分布式聚合 等等， 能把这种亿级别查询优化到秒级

## 助手验收反馈

已验收：学习目标通过，SQL 的同金额城市升序要求待补齐。实际用时 30 分钟（根据本人对话反馈记录）；以上本人原文保留，因此顶部的“未开始”不代表当前验收状态。

完整反馈见 [REVIEW.md](REVIEW.md)。主要改进：使用 `ORDER BY city_total_amount DESC, city ASC`；为索引、分表和性能判断说明成立条件。此次为静态语义验收，未运行 SQL。
