# Qwen Code 指令

- 使用JUnit5+mockito为这个Maven工程按模块补充Java类中方法的UT

- 补充UT的粒度是Java类的方法

- 必须按照prompt.md文件中的开发流程完成新版本的开发





# 注意事项

- prompt.md文件用于下达指令给Qwen Code, 禁止AI修改prompt.md文件

- 隐私秘钥等文件禁止上传到Git仓库

- 授权Qwen Code自动执行命令和计划, 无需批准确认

- 必须使用`dev`分支开发新版本

- `git`命令必须在代码仓目录下执行

- 首个版本号必须从0.1.0开始

- 每个新版本最多为5个Java方法补充UT

- 禁止为枚举类和pojo类补充UT

- 禁止修改src/main/java下的源码

- 除非修复编译报错和UT报错, 否则禁止修改git远程仓库中已有的UT测试类文件

- 每次任务都必须新建UT测试类来补充Java方法的UT, 如果新建的UT测试类和已有的文件同名, 可以使用序号命名, 例如XXX2Test, XXX3Test

- 必须只能为有@RestController, @Controller, @Service, @Component, @Configuration注解的Java类中的方法补充UT

- 典型的UT测试用例可以参考此文件`adapter/xdm-f-security/xdm-f-security-wsf/src/test/java/com/huawei/iit/sdk/common/wsf/csrf/error/CSRFAccessDeniedHandlerTest.java`





# 开发流程



每次任务的执行遵循新版本迭代开发全流程, 使用小步快跑的策略, 及时提交和推送代码到Git仓库。



## **规划与准备 (Planning)**



在写代码之前，先明确新版本的目标。



- **创建或更新项目规划**：根据prompt.md文件中的要求, 对总体目标进行任务分解, 按照Maven模块数量和Java文件数量在plan.md文件中创建或者更新项目短期、中期、长期版本规划, 确保可以长期迭代演进。

- **确定新版本需求范围原则**：按照以下约束条件优先级顺序规划新版本需求范围：

  - 如果构建失败 `mvn clean package -am -T1C -DskipTests=true -Dmaven.compiler.fork=true -U -B -gs settings.xml -s settings.xml`, 则必须立即规划一个**PATCH**新版本修复报错

  - 如果issues.md中有未关闭的issue, 则必须立即规划一个**PATCH**新版本修复问题

  - 不在以上场景, 则开发plan.md文件中还未实现的**MINOR**新版本

  - 示例: 0.2.0(新版本)->0.2.1(修复构建)->0.2.2(修复issue)->0.3.0(新版本)->0.4.0(新版本)

- **归档新版本目标**：在plan.md文件中更新新版本的目标和任务。



## **开发与测试 (Development & Testing)**



根据plan.md文件中规划的新版本需求清单, 完成开发与测试。



- **需求开发**：完成plan.md文件中规划的新版本需求清单。

- **测试用例验证**：确保所有UT用例测试通过。

- **构建通过**：确保构建通过 `mvn clean package -am -T1C -DskipTests=true -Dmaven.compiler.fork=true -U -B -gs settings.xml -s settings.xml`。

- **提交代码**：每个UT文件单独提交，保持 Commit 信息清晰, 提交时不要遗漏必要的文件, 也不要多提交不需要的文件, 设置合理的.gitignore。

- **推送代码**：必须确保本次任务的代码已推送到Git仓库。



## **版本发布**



- 使用新版本的版本号创建 Git Tag 并推送到 Git 仓库



## **文档完善**



- 在plan.md文件中更新需求开发进展和状态

- 仓库的最新详细介绍更新到README.md文件

- 最多保留最新5个版本的介绍, 旧版本的介绍合并压缩成1个版本介绍



## **问题闭环**



- 在issues.md文件中关闭已解决的issue, 在issue里使用MarkDown格式回复问题是在哪个新版本解决的并提供新版本下载地址, 提醒用户进行验证.





# 设计规范

- 最小化改动

- 修改的地方添加准确简单易懂的简体中文日志, 方便人类理解





# Git 提交规范



## 行为准则

在生成 Git 提交信息时：

- **严格禁止**：切勿包含任何表明该信息由 AI 生成的文字（例如"Written by Claude"、"AI-generated"等）。

- **无尾部签名**：除非明确指示为特定用户添加，否则不要附加"Signed-off-by"或"Co-authored-by"行。

- **直接输出**：直接给出提交信息，不要包含任何引言性文字（例如跳过“好的，这是提交信息……"这类内容）。

- **禁止额外作者**：使用git默认用户为作者, 绝对禁止添加"claude"为额外作者。

- **使用简体中文**：git提交信息必须以简体中文为主。



## 格式标准

- 采用 Conventional Commits 格式：`<类型>(<范围>): <主题>`

- 允许的类型包括：feat, fix, docs, style, refactor, perf, test, build, ci, chore, revert。

- 首行长度必须控制在 72 个字符以内。





# 版本号规范



**版本号规范**：版本号为 `MAJOR.MINOR.PATCH`, 遵循SemVer语义化版本规范：

- **MAJOR** (重大不兼容更新)

- **MINOR** (新功能，向下兼容)

- **PATCH** (Bug 修复, 代码重构，向下兼容)





# 技能中心(Skills)



- 对某个Maven模块执行UT用例, 在代码仓库所在目录使用命令`mvn clean test -pl 模块名称 -am -U -B -gs settings.xml -s settings.xml`, 例如: `mvn clean test -pl linkx-loginservice -am -U -B -gs settings.xml -s settings.xml`

- 对整个Maven工程执行UT用例, 在代码仓库所在目录使用命令`mvn clean test -U -B -gs settings.xml -s settings.xml`