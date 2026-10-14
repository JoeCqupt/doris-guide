# 第 5 章源码精读材料

[返回第 5 章](../../chapters/05-parser-binding-and-rewrite.md)

`source-map.json` 固定 2026-10-14 实际读取的文件 SHA-256，以及正文八段关键 Java 摘录的原文与位置。来源是本地工作区，不把历史提交号当作当前文件未变的保证。

本轮验证：八段摘录与源文件匹配；文档链接与围栏检查；教学数据与 LIMIT 反例独立计算；四个已有 Java 测试的输入与断言已阅读。未运行 Doris SQL、Java 单测或性能测试。

Slot 编号 #7/#8/#20/#21/#99 是教学编号。三行金额示例和 LIMIT 示例是静态推演，不是 EXPLAIN 或执行日志。主章内的源码和教学树分别标明。

现有测试类为 `PushDowFilterThroughProjectTest`，测试名和断言详情见正文 5.10。本材料不往 Doris 仓库增加教学测试，也不修改任何既有用户 step 记录。
