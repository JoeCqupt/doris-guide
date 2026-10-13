# 专题 8　Cloud 元数据提交、Compaction 与回收

[全书导航](../README.md) · [专题导航](README.md)

> 源码基线：`a53b182f810be2b3731c7dfdf6f40ff5a0ad63bd`；补写日期：2026-10-13。以下为源码分析与标明的教学推演，未运行对应功能测试。仓库路径均相对 `/Users/jiangyuan/open/doris`。

## 1. 文件、权威元数据和缓存三个位置

对象存储保存数据对象，Meta Service 通过 TxnKv 管理权威元数据，BE 保留本地 Tablet/Rowset 视图与文件缓存。一次对象上传成功只完成文件侧工作；没有相应可见元数据，查询不能仅凭发现文件就把它算入结果。

资源关系可按 instance → storage vault / 资源配置 → 数据对象定位来读；Tablet 的 Rowset 元数据记录读取需要的信息。对象路径是定位手段，不是事务提交状态。FE/BE 中看到的缓存状态必须与 Meta Service 的权威记录区分。

## 2. 一个具体的 KV 事务例子

`cloud/src/recycler/recycler.cpp` 的 `batch_mark_rowsets_as_recycled` 路径读取 Rowset 元数据，设置 `is_recycled=true`，序列化后 `txn->put(key,val)`，再 `txn->commit()` 并检查返回码。

这里的 put 先属于当前 TxnKv 事务，commit 才决定修改是否成功提交。提交失败时不能把本地 PB 已经改值当成全局状态已生效。这个例子直接展示：C++ 对象修改、KV 写集和已提交的元数据是三个阶段。

同一文件 `InstanceRecycler::recycle_rowsets()` 先判断是否采用 versioned keys 路径，否则构造 RecycleRowsetKeyInfo 的范围扫描。当前存在两套分支，不能把传统 key 扫描步骤无条件套到版本化元数据。

## 3. Compaction 需要协调的不是只有文件写入

入口为 `cloud/src/meta-service/meta_service_job.cpp` 的 `MetaServiceImpl::start_tablet_job()` 与结束作业处理。文件中对 compaction 输入版本范围、compaction count、expiration、并发作业的范围冲突进行检查，并处理输出版本与累计点。

教学事件：

| 事件 | 状态含义 |
|---|---|
| BE 基于本地 Tablet 视图选择输入范围 | 尚未获得权威元数据认可 |
| 向 Meta Service 申请作业 | 校验缓存是否过期、范围与其他作业是否冲突 |
| 读取输入、写出合并对象 | 新文件存在，但不能独立决定查询版本图 |
| 完成作业的元数据提交 | 输入/输出关系、统计及回收信息进入对应提交路径 |
| 其他 BE 同步 Tablet | 更新本地 Rowset 视图；不同于所有文件立即下载到本地 |
| Recycler 处理旧对象 | 按回收协议和相关保留条件推进物理清理 |

因此排查“合并完成后读不到”要分别核对 BE 写文件、作业完成响应、权威 Rowset 信息和读取 BE 的同步结果。

## 4. 三个失败窗口

**写出对象后、完成元数据前失败。** 对象可能成为未完成作业的残留；不能让查询自动采纳，也不能按文件年龄随便删除，需要沿作业及回收记录处理。

**完成请求已提交，响应丢失。** 重试必须识别已完成或发生冲突的作业状态，不能再次无条件推进统计与版本。具体状态以返回码和已记录作业为准。

**旧输入已被替换，但旧读者或保留机制仍相关。** 元数据替换与物理删除存在时间差。云端快照/版本化元数据的保留规则也会影响回收，不能沿用“本地 shared_ptr 为零就可以删除远端对象”的推断。

## 5. Recycler 的删除协议

该目录约定的检查重点是先标记、后续轮次物理删除；按来源对导入事务或 compaction/schema-change 作业执行相应终止协调；Packed File 还涉及元数据修正、对象删除、重读 KV，再确认仍可回收后删除 KV。

这解释了重读的意义：最初看到可回收，并不保证期间没有并发元数据变化。对象删除与 KV 提交也不是一个存储系统内的原子操作，需要可重试的阶段设计。

读 `recycler.cpp` 时先确定对象种类和 versioned/non-versioned 分支，再追踪过滤条件、标记、删除与元数据清理。不要从 `is_recycled` 字段名字推断文件已经物理不存在。

## 6. 与普通部署的查询版本区别

普通内表路径由 `OlapScanNode.addScanRangeLocations()` 把分区 visibleVersion 放入扫描范围。`updateScanRangeVersions()` 的批量更新路径属于 Cloud 模式，不能把它作为普通部署的唯一版本获取入口。规划期表锁与资源释放又是另一个维度，见[专题 1](01-query-rpc-and-cancellation.md)。

本专题补全了代表性协作与失败窗口，未搭建 Meta Service/对象存储环境，也未运行 Cloud 故障注入。当前源码中的版本化元数据、快照和 Packed File 分支不能未经发布核实就宣称为所有 Doris 版本的统一行为。
