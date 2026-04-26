# job-demo · 单元测试补充任务

## 项目上下文

仓库：https://github.com/qpzm7903/job-demo
技术栈：JDK 17 / Maven / Spring Boot 3.2.x / Spring Authorization Server / H2 / JUnit 5 + Mockito + AssertJ

## 本任务目标

为 `src/main/java` 下的 **Service / Config / Controller** 补充高质量单元测试，目标覆盖率 ≥ 70%（jacoco 报告）。

## 选择优先级（每轮 1~5 个方法）

按以下顺序挑未覆盖或覆盖不足的方法：

1. 配置类 `@Bean` 方法（如 `SecurityConfig`、`AuthorizationServerConfig`）—— 用 `@SpringBootTest` 验证 bean 装配
2. Controller 端点 —— 用 `MockMvc` + `@WebMvcTest` 验证状态码、响应头、JSON 结构
3. Service / 组件类 —— 用 `Mockito` mock 依赖，覆盖正常路径 / 异常路径 / 边界值

## 严格规则（红线）

- **禁止修改 `src/main/java/**` 下的生产代码**
- 仅允许修改/新建 `src/test/java/**`
- 每个新测试类至少包含：正常路径 + 异常路径 + 边界/null 值
- mock 设置上方加简体中文注释说明意图
- 用 `assertThrows()` 验证异常、`verify()` 验证关键 mock 交互、`ArgumentCaptor` 验证复杂参数

## 每轮严格流程

1. **Baseline**：`mvn test > /tmp/baseline.log 2>&1; echo "EXIT=$?" >> /tmp/baseline.log; tail -10 /tmp/baseline.log`
   - EXIT≠0 → 本轮目标改为"修复已有失败测试"，用 `fix(test): ...` 提交，**不**新增测试
2. **挑方法**：用 `find src/main/java -name "*.java"` + 简单关键字定位本轮目标方法（最多 5 个）
3. **写 UT**：每个方法对应一个 `@Test`；测试类命名 `<原类名>Test`，已有则改用 `<原类名>2Test` `<原类名>3Test` 等
4. **跑测试**：`mvn test -Dtest=<新增测试类> > /tmp/new.log 2>&1; tail -20 /tmp/new.log` 必须 EXIT=0
5. **跑全量**：`mvn test > /tmp/full.log 2>&1; tail -10 /tmp/full.log` 必须 EXIT=0
6. **Commit & Push**：`test(<模块>): 补充 XxxService 单测` —— **简体中文，禁 AI 署名**

## 输出控制

- Maven 输出一律重定向到 `/tmp/*.log` 后 tail
- 禁止 `cat target/`、`find` 整个 target

## 收敛条件

- 连续 2 轮没有可补的测试方法（`MAX_NOCHANGE=2`）→ 视为完成
- 或达到 `MAX_ITERATIONS=5`

## 禁止事项

- 禁止改生产代码（即便发现 bug 也只在本轮 commit message 里写"发现 bug：xxx"，不修）
- 禁止引入 Power Mock / JMockit 等重依赖
- 禁止用 `@Ignore` / `@Disabled` 跳过失败测试
