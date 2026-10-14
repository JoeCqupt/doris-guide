# 第 20 章　身份、权限与访问入口

[全书导航](../README.md) · [术语表](../appendices/A-glossary.md)

> 教学结构修订：2026-10-14。每章先沿一个问题阅读代码，再做实验、观察结果，最后解释对象和分支。历史正文基线为 `a53b182f810be2b3731c7dfdf6f40ff5a0ad63bd`；本次摘录取自当前本地文件，完整文件 SHA-256 与行号保存在[源码摘录清单](../examples/08-chapter-workshops/source-manifest.json)。运行证据来自报告版本 `doris-0.0.0-a53b182f810` 的二进制，不能仅凭版本前缀认定当前工作目录与二进制逐文件相同。

**本章问题：登录身份是怎样变成一次表访问的权限判断的？**

本章验证方式：源码走查与状态推演；无该主题的集群实测。建议先用 20—40 分钟完成主案例，第四部分的扩展阅读可分次完成；这不是新增的每日必交任务。

## 一、源码讲解：先找到决定行为的对象和分支

把认证结果与授权请求分开：前者建立身份，后者带着 subject、resource、requirement、context 进入 AccessControllerManager.ask。源码摘录中 controllerOf 选择实现，checkPrivilege 执行判断，finally 恢复检查上下文。这里研究正常行为，不开展安全审计。

### 先读这段真实代码

文件：`fe/fe-core/src/main/java/org/apache/doris/mysql/privilege/AccessControllerManager.java`，当前文件第 1014—1024 行。下面是连续原文摘录，局部片段省略了方法的其他部分；不要把片段当完整实现。

```java
    private void ask(UserIdentity subject, AuthorizedResource resource, AccessRequirement requirement,
            AccessContext context) throws AccessDeniedException {
        AuthorizationPlugin controller = controllerOf(resource);
        AccessContext outer = enterCheck(context);
        try {
            checkInClassLoaderOf(controller, () -> controller.checkPrivilege(
                    AccessTranslation.subjectOf(subject), resource, requirement, context));
        } finally {
            leaveCheck(outer);
        }
    }
```

### 这几行应该怎样读

`controllerOf(resource)` 根据资源找授权实现；`checkInClassLoaderOf` 在相应实现上下文中调用 `checkPrivilege`；`finally` 调用 `leaveCheck` 恢复外层检查。认证身份如何建立仍在另一条链，这个方法消费身份而不是处理登录密码。

### 登录成功之后，仍有另一个问题

认证回答“请求者是谁”，授权回答“这个身份能否对这个对象执行这个动作”。一个用户能建立会话，并不意味着能查询所有表；同一个用户对不同 Catalog 的访问，也可能由不同授权来源决定。

本章只解释正常功能的接口与职责。读取了仓库的安全政策和威胁模型作为范围背景，没有进行安全审计、攻击测试或漏洞结论。网络隔离、服务配置、身份来源与授权来源不能用其中一层替代其他层。

### 认证插件与配置实例

当前 `AuthenticationPlugin` 接口提供 `supports()`、`authenticate()` 以及配置验证、初始化、重载、关闭等生命周期方法。请求以 `AuthenticationRequest` 表达，配置实例以 `AuthenticationIntegration` 传入。

这种组织方式把协议适配与认证实现分开：协议入口处理具体握手或凭据形式，插件对它支持的认证请求作出结果。接口注释中的插件名称例子不是“本发行包已安装这些插件”的证明，应核对实际实现、装载和配置。

`authenticate()` 的契约也区分预期的凭据失败与内部/插件错误：前者通过失败结果表达，后者可抛认证异常。对调用者而言，失败类型影响诊断；不能把所有失败统一解释为密码错误。

生命周期方法意味着“配置对象已创建”和“运行时插件已初始化可用”是不同阶段。配置重载后既要观察新请求行为，也要关注资源释放和已有状态，但本章不推断各插件都采用同一种缓存机制。

### 用户、角色、资源与动作

授权可以看成一组输入：主体身份、目标资源、所需动作/要求及请求上下文。角色帮助组织授权关系，资源则可能是实例级对象、Catalog、数据库、表或列。

业务系统里常见的 `if (isAdmin)` 不能直接迁移成所有 Doris 模块的授权规则。当前实现有专门的授权来源路由和兼容行为，应使用已有入口，不在业务命令旁复制另一套规则。

## 二、动手实验：先预测，再核对

默认使用已保存的实验材料或只读源码，不需要启动服务。运行环境已停止；若选择重新执行 SQL，先按[实验复现说明](../examples/07-live-lab-20261014/REPRODUCE.md)确认服务、版本与数据状态。初始化、导入和更新脚本不可在现有表上盲目重放。

1. 在本地打开 AccessControlBehaviorBaselineTest.java，选一个正常表访问案例，抄下身份、资源、动作、授权来源和断言；不要把管理员运行 SQL 的结果当普通用户权限测试。
2. 沿 ask → controllerOf → checkPrivilege 追踪这一例，说明它与 MySQL 握手认证分属哪两个阶段。
3. 画允许/拒绝两行行为表，并给每行注明证据层级“现有测试源码 / 尚未运行”。可选执行方式沿第 28 章的仓库脚本；本轮不创建用户或修改授权。

本地只读入口（不连接外部服务、不修改配置）：

```bash
cd /Users/jiangyuan/open/doris
rg -n 'ask|controllerOf|checkPrivilege' 'fe/fe-core/src/main/java/org/apache/doris/mysql/privilege/AccessControllerManager.java'
```

## 三、观察结果：先陈述事实，再划清证据范围

本章可观察的是源码中的授权分派与既有测试断言。当前运行实验使用本地 root，没有采集普通账号允许/拒绝矩阵，因此没有可引用的真实授权通过结果。

**本章边界：** 源码走查不是已运行测试，也不是漏洞结论；外部授权来源和数据策略未实测。

## 四、回到源码解释：把现象还原成执行过程

ask 的 finally 恢复上下文，说明权限检查可能嵌套且必须正确收尾；它不能替代认证。定位正常行为时，先问请求中资源与动作是否正确，再查控制器选择，最后读具体决策实现。

### 用自己的话走完这条链

合上结果后，按“输入 → 关键对象/状态 → 分支条件 → 可观察结果”的顺序回答本章问题：**登录身份是怎样变成一次表访问的权限判断的？** 再指出一项尚不能从现有实验得出的结论。能把每个箭头落到本章的方法或证据，比记住术语更接近读懂源码。

### 当前授权管理器如何选择来源

`AccessControllerManager.ask()` 先通过 `controllerOf(resource)` 选择来源，再调用相应 `AuthorizationPlugin.checkPrivilege()`。本次读取到的路由中，实例级资源和 Catalog 级授权交给系统范围来源；数据库、表、列交给相关 Catalog 的来源或默认来源。

```text
主体 + 资源 + 权限要求 + 上下文
  → AccessControllerManager 路由
  → 被选中的授权来源作出判断
  → 返回允许，或以约定异常拒绝
```

这里描述的是 `ask()` 的主路径。模块 README 记录了已有兼容例外，不能据此声称全部历史入口在所有情况下都无例外经过插件；同样，也不能把来源选择理解为“多个插件投票，只要一个允许就放行”。

老的 `checkTblPriv()` 等适配入口与新的插件契约还会转换返回或异常形式。阅读某个命令的检查时，必须连同适配层一起看，不能仅凭一个 boolean 返回推断底层协议。

### 行过滤与列掩码不等于普通准入判断

表级访问决定是否允许相应操作；行过滤和列掩码还会影响用户最终看到的数据。它们与查询计划、表达式语义和缓存之间存在联系，应沿相应策略入口单独追踪。

当前授权模块文档明确区分权限检查和数据策略接口。没有返回数据策略，不能被解读为“授予全部访问”。另一方面，授予表权限也不意味着一定没有行列策略。

本章仅建立这些概念及框架边界，没有逐项验证外部策略服务，也不提供会改变本机权限的 GRANT/REVOKE 操作。

### SQL、HTTP 与外部数据访问

同一个业务动作可能通过 SQL 或 HTTP 触发。协议入口负责建立适用的身份和上下文，后续业务路径使用这些信息进行检查。Web UI 隐藏按钮不是服务端授权的替代品；真正允许什么需要看服务端接口。

外部 Catalog 还涉及外部系统自己的凭据与权限。Doris 允许用户访问某个外表，与外部存储接受 Doris 使用的连接身份，是不同边界。排查失败时应区分哪个系统拒绝、拒绝哪个动作，避免在错误层修改权限。

### 如何验证正常权限行为

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

### 延伸源码专题

- [专题 5　元数据持久化、维护作业与正常授权链](../deep-dives/05-metadata-maintenance-and-access.md)

---

[全书导航](../README.md) · [术语表](../appendices/A-glossary.md)
