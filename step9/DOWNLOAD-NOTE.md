# BE 子模块下载排障 — 2026-10-08

## 结论与实际操作

原构建卡在 contrib/clucene 的 GitHub clone，不是 C++ 编译。apache-orc 已成功下载；clucene、openblas、faiss 与它来自同一仓库 apache/doris-thirdparty。

GitClone 镜像 https://gitclone.com/github.com/apache/doris-thirdparty.git 的 ls-remote 实测 25 秒超时；ghfast.top 实测返回网络策略拦截 403。没有配置这些未验证可用的外部镜像，也没有修改全局 Git 配置。GitClone 官方用法参考：https://gitclone.com/ 。

助手停止了原 build.sh 及下载子进程；未完成的 clucene 下载保存在 download-backup-20261008-153255/，没有删除。随后以本地 .git/modules/contrib/apache-orc 为对象来源，通过 git clone --shared 初始化三个模块，检出主仓库锁定的 commit：

- clucene：08d45e541fef1e48dc4ab00d2d5fde9569b49ee3
- openblas：77986e49425532bf8f651db74cbe1579bcb4a5bf
- faiss：032afe95f671cd50b82d52d901345600776d7855

三个模块 HEAD 均与主仓库 gitlink 一致，origin 保持官方 GitHub 地址；没有修改源码或 .gitmodules。原有 datasketches-cpp 工作区变化未处理。当前共享对象依赖 .git/modules/contrib/apache-orc/objects，请保留它；需要将模块独立移动或清理该对象库前，先在对应模块执行 git repack -a 解除共享依赖。

## 继续构建

原构建已停止，需重新执行 Step 9 TASK.md 的构建代码块（生成新时间戳日志），不加 --clean。已有产物会参与增量构建。这次处理只解决已发现的子模块重复下载，不代表 BE 整体构建成功，也不保证其他下载站点均可用。
