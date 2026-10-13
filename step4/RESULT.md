# Step 4 作答

- 状态：未开始
- 实际用时：
- 完成日期：

## 1. 系统图或箭头链

图或文件路径：
SQL、计划、原始数据、中间结果的流向：

执行流程
```
graph TD
      sql_parser[FE 解析SQL为AST] -->
      sql_analyzer[FE 结合元数据完成SQL分析] -->
      sql_planning[FE 规划SQL执行计划] -->
      sql_optimizer[FE 根据RBO/CBO/HBO去优化SQL执行计划] -->
      sql_physical[FE 逻辑计划转换为物理计划] -->
      sql_binding[FE 把执行计划拆分为不同的stage，
拆分成不同的执行片段绑定到不同的BE节点上] -->
      sql_execute[FE 下发执行计划片段到BE节点] -->
      be_execute[BE 执行计划片段]
```

计划片段执行流程
```
stateDiagram-v2
  [BE1]执行计划片段1>SCAN+FILTER+GROUPING --> [BE1/2]执行片段3>GATHER
  [BE2]执行计划片段2>SCAN+FILTER+GROUPING --> [BE1/2]执行片段3>GATHER
  
  [BE1/2]执行片段3>GATHER --> [FE]最终结果
```

其实的疑问是 SCAN+FILTER 能和 GROUPING 一个state 执行么？ 


## 2. 我的理解

为什么不把所有订单行拉到 FE 用 Java 聚合：

1. 我觉得还是中间结果可能太大了， 全部拉到FE聚合内存不够
2. 全部拉到FE来聚合， 对于FE的计算+内存压力都很大，FE的定位只是一个查询规划


Step 3 的 BitSet 类比的是哪一部分：

类比 查询计划片段 聚合的时候 进行user_id 跨节点去重

为什么合并时仍需保留城市信息：

这个我还真不知道。。。。 我觉得传递Bitmap信息就够了 

哪些位置或步骤目前只是猜测：

查询的stage 怎么分？ 聚合怎么聚合？ 

## 3. 环境与下一步

当前阶段（仅有源码 / 已编译 / 已启动 / 已执行 SQL）：

有源码 : /Users/jiangyuan/open/doris


已有启动方式、版本、输出目录等非敏感信息（没有可留空）：

还没有完整启动过FE 和 BE 


最想通过实际运行解答的问题（至多两个）：

执行计划的片段长什么样子？ 中间聚合数据有哪些？ 

## 助手验收反馈

最新结论（2026-09-23）：补交后核心目标通过，已发布 Step 5。Map 按城市组织的思路正确；原伪代码的 getOrDefault 不会插入默认值，应换 computeIfAbsent，final 不能作 Java 变量名。图需连接 Gather → Aggregate，但不再要求重交。详见 REVIEW.md 顶部；本人原文保留。已报告用时 40 分钟，补交额外用时未知。

尚未验收。

2026-09-23 验收：部分通过，耗时 40 分钟（本人报告）。FE/BE 主线已理解，但“聚合状态必须保留分组对应关系”与 Gather/最终聚合区别仍需补齐。请参考 [REVIEW.md](REVIEW.md) 的最小补交，在此文件末尾追加回答，保留原作答。顶部模板状态及旧文字不代表最新验收结论。


1. 
北京 2
上海 2

丢掉城市信息后确实不知道 每一个城市有多少去重用户数
2. 

```
Map<String,BitSet> nodeA = new HashMap<>();
nodeA.getOrDefault("beijing", new BitSet()).set(1);
nodeA.getOrDefault("shanghai", new BitSet()).set(2);

Map<String,BitSet> nodeB = new HashMap<>();
nodeB.getOrDefault("beijing", new BitSet()).set(2);
nodeB.getOrDefault("shanghai", new BitSet()).set(1);




Map<String,BitSet> final  = new HashMap<>();

nodeA.keySet().stream().forEach(
    k -> {
        final.getOrDefault(k, new BitSet()).or(nodeA.get(k));
    }
)

nodeB.keySet().stream().forEach(
    k -> {
        final.getOrDefault(k, new BitSet()).or(nodeB.get(k));
    }
)

```

3. 


计划片段执行流程
```
stateDiagram-v2
  [BE1]执行计划片段1>SCAN+FILTER+GROUPING --> [BE1/2]执行片段3>GATHER
  [BE2]执行计划片段2>SCAN+FILTER+GROUPING --> [BE1/2]执行片段3>GATHER
  [BE1/2]执行片段3>Aggregate --> [BE1/2]执行片段4>ORDER全局排序
  [BE1/2]执行片段4>ORDER全局排序 --> [FE]最终结果
```
