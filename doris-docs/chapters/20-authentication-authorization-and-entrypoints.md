# 第 20 章　身份、权限与访问入口

[全书导航](../README.md) · [术语表](../appendices/A-glossary.md)

> 日期：2026-10-13。源码基线：`a53b182f810be2b3731c7dfdf6f40ff5a0ad63bd`。正文 v1；已核对文中明确分析的关键方法和入口，未启动集群、执行 SQL、运行测试或进行故障实验。示意图不代表本机实测拓扑。

## 20.1 登录成功之后，仍有另一个问题

认证回答“请求者是谁”，授权回答“这个身份能否对这个对象执行这个动作”。一个用户能建立会话，并不意味着能查询所有表；同一个用户对不同 Catalog 的访问，也可能由不同授权来源决定。

本章只解释正常功能的接口与职责。读取了仓库的安全政策和威胁模型作为范围背景，没有进行安全审计、攻击测试或漏洞结论。网络隔离、服务配置、身份来源与授权来源不能用其中一层替代其他层。

## 20.2 认证插件与配置实例

当前 `AuthenticationPlugin` 接口提供 `supports()`、`authenticate()` 以及配置验证、初始化、重载、关闭等生命周期方法。请求以 `AuthenticationRequest` 表达，配置实例以 `AuthenticationIntegration` 传入。

这种组织方式把协议适配与认证实现分开：协议入口处理具体握手或凭据形式，插件对它支持的认证请求作出结果。接口注释中的插件名称例子不是“本发行包已安装这些插件”的证明，应核对实际实现、装载和配置。

`authenticate()` 的契约也区分预期的凭据失败与内部/插件错误：前者通过失败结果表达，后者可抛认证异常。对调用者而言，失败类型影响诊断；不能把所有失败统一解释为密码错误。

生命周期方法意味着“配置对象已创建”和“运行时插件已初始化可用”是不同阶段。配置重载后既要观察新请求行为，也要关注资源释放和已有状态，但本章不推断各插件都采用同一种缓存机制。

## 20.3 用户、角色、资源与动作

授权可以看成一组输入：主体身份、目标资源、所需动作/要求及请求上下文。角色帮助组织授权关系，资源则可能是实例级对象、Catalog、数据库、表或列。

业务系统里常见的 `if (isAdmin)` 不能直接迁移成所有 Doris 模块的授权规则。当前实现有专门的授权来源路由和兼容行为，应使用已有入口，不在业务命令旁复制另一套规则。

## 20.4 当前授权管理器如何选择来源

`AccessControllerManager.ask()` 先通过 `controllerOf(resource)` 选择来源，再调用相应 `AuthorizationPlugin.checkPrivilege()`。本次读取到的路由中，实例级资源和 Catalog 级授权交给系统范围来源；数据库、表、列交给相关 Catalog 的来源或默认来源。

```text
主体 + 资源 + 权限要求 + 上下文
  → AccessControllerManager 路由
  → 被选中的授权来源作出判断
  → 返回允许，或以约定异常拒绝
```

这里描述的是 `ask()` 的主路径。模块 README 记录了已有兼容例外，不能据此声称全部历史入口在所有情况下都无例外经过插件；同样，也不能把来源选择理解为“多个插件投票，只要一个允许就放行”。

老的 `checkTblPriv()` 等适配入口与新的插件契约还会转换返回或异常形式。阅读某个命令的检查时，必须连同适配层一起看，不能仅凭一个 boolean 返回推断底层协议。

## 20.5 行过滤与列掩码不等于普通准入判断

表级访问决定是否允许相应操作；行过滤和列掩码还会影响用户最终看到的数据。它们与查询计划、表达式语义和缓存之间存在联系，应沿相应策略入口单独追踪。

当前授权模块文档明确区分权限检查和数据策略接口。没有返回数据策略，不能被解读为“授予全部访问”。另一方面，授予表权限也不意味着一定没有行列策略。

本章仅建立这些概念及框架边界，没有逐项验证外部策略服务，也不提供会改变本机权限的 GRANT/REVOKE 操作。

## 20.6 SQL、HTTP 与外部数据访问

同一个业务动作可能通过 SQL 或 HTTP 触发。协议入口负责建立适用的身份和上下文，后续业务路径使用这些信息进行检查。Web UI 隐藏按钮不是服务端授权的替代品；真正允许什么需要看服务端接口。

外部 Catalog 还涉及外部系统自己的凭据与权限。Doris 允许用户访问某个外表，与外部存储接受 Doris 使用的连接身份，是不同边界。排查失败时应区分哪个系统拒绝、拒绝哪个动作，避免在错误层修改权限。

## 20.7 如何验证正常权限行为

一个结构化案例至少记录：身份、资源、动作、适用授权来源、允许或拒绝的预期以及实际结果。管理员成功访问，不能证明普通用户边界正确；只测拒绝，也不能证明原有合法访问仍然可用。

当前 `AccessControlBehaviorBaselineTest` 用于记录相关决策矩阵。行为基线不是为了让 CI 变绿就可以重生成的答案：预期改变时，必须解释哪些正常行为发生了变化。插件接口改变还要考虑旧实现能否加载及 API 兼容性，相关约束见模块自身说明。

| 路径（相对仓库根目录） | 阅读重点 |
|---|---|
| `fe/fe-authentication/fe-authentication-spi/src/main/java/org/apache/doris/authentication/spi/AuthenticationPlugin.java` | 认证请求、结果与生命周期契约 |
| `fe/fe-core/src/main/java/org/apache/doris/mysql/authenticate/` | MySQL 认证适配入口 |
| `fe/fe-core/src/main/java/org/apache/doris/authentication/` | Integration 等运行时管理入口 |
| `fe/fe-core/src/main/java/org/apache/doris/mysql/privilege/AccessControllerManager.java` | `ask()`、`controllerOf()` 及适配检查 |
| `fe/fe-authorization/README.md` | 来源路由、接口与兼容例外说明 |
| `fe/fe-core/src/test/java/org/apache/doris/mysql/privilege/AccessControlBehaviorBaselineTest.java` | 授权行为基线入口 |

本章未运行这些测试。初次阅读应先追一个正常身份对一张表的授权路径，再扩展到外部来源和数据策略，不需要同时掌握所有认证协议。


---

[上一章：第 19 章](19-node-management-and-maintenance.md) · [全书导航](../README.md) · [下一章：第 21 章](21-resource-governance-observability-and-ui.md)

## 源码深读补充（2026-10-13）

- [专题 5　元数据持久化、维护作业与正常授权链](../deep-dives/05-metadata-maintenance-and-access.md)
