# 附录 B　Java 开发者的 C++ 阅读工具箱

[全书导航](../README.md)

> 整理日期：2026-10-13；对应正文源码基线 `a53b182f810be2b3731c7dfdf6f40ff5a0ad63bd`。

## B.1 先判断谁拥有对象

读 BE 时，先问“谁创建、谁持有、什么时候销毁”，再研究模板语法。Java 引用可以让对象继续存活；C++ 裸指针和引用通常只表示访问关系，不自动延长对象生命周期。

| 写法 | 阅读要点 | 不应推断 |
|---|---|---|
| `T*`、`T&` | 查所有者和有效时间；引用也可能悬空 | 指针存在就一定能访问 |
| `std::unique_ptr<T>` | 独占所有权，移动可转移所有权 | `get()` 返回值拥有对象 |
| `std::shared_ptr<T>` | 多个持有者共同维持存活 | 对象内部字段自动线程安全 |
| `std::weak_ptr<T>` | 非拥有观察，使用前取得有效强引用 | 观察者会阻止销毁 |
| `std::string_view` | 对已有字符的视图 | 自己复制并保存了字符 |

Rowset Reader 持有数据对象、异步任务捕获上下文时，这些区别直接影响正确性。引用计数、锁、数据库版本保护分别解决不同问题，不能互相替代。

## B.2 RAII 与退出路径

局部对象离开作用域会执行析构。锁守卫、文件句柄包装、智能指针利用这一机制清理资源，提前 `return` 也会销毁已构造的局部对象。它在表达资源释放上类似 Java 的 try-with-resources，但 C++ 用于更多普通对象。

以下只是语言示意，不是 Doris 补丁：

```cpp
{
    std::unique_lock lock(mutex);
    update_state();
} // lock 析构并解锁
```

不要只找显式 `unlock()` 判断锁范围。`std::move` 也不是物理搬运的函数；它允许后续操作选择移动语义。移动之后能怎样使用源对象取决于类型契约，不能继续假定原资源仍归它所有。

## B.3 Status、宏与失败传播

Doris 的 `be/src/common/status.h` 是错误表示和相关宏的阅读入口。看到 `RETURN_IF_ERROR(...)` 时，应理解它可能立即从当前函数返回错误；想知道返回类型或额外行为，展开当前基线中的宏定义。

断言表达不变量，Status 表达调用需要处理的失败。调试断言是否生效还与构建配置有关；不能把 DCHECK 当作所有构建都执行的输入验证。修改代码时遵守相应 AGENTS.md，先参考同一模块已有处理方式。

宏可能隐藏控制流，模板可能把错误位置展开到另一个文件。编译错误应从最靠近自己调用处的实例化链阅读，不必一开始理解所有展开细节。

## B.4 模板、虚函数与批处理

模板常用来让不同数据类型共享实现，并在编译期生成具体代码；虚函数用于运行期多态。看向量化表达式时，先确认输入 Column 类型、是否 nullable/constant、输出长度与 NULL 规则，再研究类型分派细节。

Block 可以类比一批同长度列组成的数据容器，但它不是 Java 的 `List<Map<String,Object>>`。列式布局让同一运算批量处理同类型值，也让常量列、可空列等拥有特殊表示。不要把包装层剥离后丢掉 NULL 或常量语义。

## B.5 并发必须结合生命周期

`shared_lock` 常用于共享读，`unique_lock` 常用于独占访问；实际语义取决于底层 mutex。拿到一把锁，只能保护约定由它保护的状态。锁顺序、网络请求是否位于锁内、回调能否重入，都要结合上下文判断。

第 26 章 `CloudTablet::sync_rowsets` 提供了可读例子：读锁检查版本，取得同步锁，再复查版本，最后同步。先画锁范围和字段读写，再想优化，避免凭 Java 经验机械替换。

阅读异步 lambda 时特别标记 `[this]`、引用捕获和移动捕获。排队成功不代表调用者还会存活到执行结束；共享指针延长生命周期也不代表取消后可以继续修改状态。

## B.6 最小阅读顺序

从一个函数的输入、返回值和成员字段出发，标出所有权、锁、可能提前返回的宏，再追踪一个实际调用方。遇到模板先选择一个具体类型实例。目标是解释一个行为及其边界，不是先学完整门 C++ 才能读 Doris。

可配合[第 8 章](../chapters/08-pipeline-and-vectorized-execution.md)、[第 11 章](../chapters/11-tablet-rowset-and-segment.md)和[第 26 章](../chapters/26-cloud-read-write-and-maintenance.md)。本附录未编译示例。

## 真实生命周期：Java UDF 的 C++ 外壳

`JavaFunctionCall::open()` 创建 JniContext 并放入 THREAD_LOCAL 函数状态；它持有 executor 及 Java 方法引用。`execute_impl()` 暂时持有输入表地址与 JNI 局部对象；`close()` 调用 context 的关闭逻辑。读代码时把这三层寿命分别标注：函数状态、一次批量调用、跨语言对象。

```text
FunctionContext 的 THREAD_LOCAL 状态 → JniContext → Java executor
一次 execute_impl 作用域 → 输入地址数组 / JNI 局部对象
close → 释放 executor 资源；bthread 场景转到关闭线程池
```

这个持有关系图不是互斥关系图。对象用 shared_ptr 保存不代表多个线程可以同时修改其字段；RAII 作用域退出也不代表异步任务一定完成。锁范围对照可看专题 5 的 Catalog 锁内再取 Database 写锁，两层均通过 finally 释放；Java finally 与 C++ RAII 都需要结合实际取得资源的时点理解。详见[专题 7](../deep-dives/07-connectors-udf-and-ecosystem.md)。
