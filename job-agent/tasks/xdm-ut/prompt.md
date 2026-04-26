# xdm-f-core 单测生成指令

## 任务目标
为 xdm-f-core 仓库中指定模块补充高质量的单元测试。

## 技术规范
- JDK 17 + Spring Boot 3 + `jakarta.*` 命名空间
- JUnit 5 + Mockito + AssertJ
- 禁止修改 `src/main/java/**` 下的生产代码
- 仅允许修改/新建 `src/test/java/**` 下的测试文件

## 测试设计要求
- 每个方法至少覆盖：正常路径、异常路径、边界/null 值
- 使用 `assertThrows()` 验证异常
- 使用 `verify()` 验证关键 mock 交互
- 复杂参数场景使用 `ArgumentCaptor`
- 所有 mock setup 上方写简体中文注释

## 执行流程
1. 扫描目标模块的 Service/Manager/Facade 等业务类
2. 优先选择分支多、异常路径多、依赖协作多的方法
3. 编写高质量单测
4. 运行 `mvn clean test` 确保通过
5. 提交代码（Conventional Commits，简体中文）

## Git 提交规范
- 格式：`test(模块名): 补充 XxxService 单测`
- 禁止提交信息中出现 AI 相关字眼
