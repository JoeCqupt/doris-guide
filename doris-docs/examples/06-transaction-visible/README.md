# 第 16 章事务精读材料

[返回第 16 章](../../chapters/16-transaction-commit-publish-visible.md)

来源文件及五段原码摘录保存在 `source-map.json`，用实际文件 SHA-256 识别漂移。主例 X/Y、P/Q 的编号与版本来自教学设计，非数据库日志。

已静态核对提交/完成/等待路径，以及 GlobalTransactionMgrTest 中 testFinishTransaction 和 testFinishTransactionWithOneFailed 第一组场景的输入、模拟发布结果与断言。未运行测试；没有实际重启、断网、删除副本或更改发布策略。

可复核的区别：事务 monitor 与外层表锁；COMMITTED 与 visibleVersion；客户端等待超时与发布策略超时；测试模拟目录回放与真实持久化恢复。
