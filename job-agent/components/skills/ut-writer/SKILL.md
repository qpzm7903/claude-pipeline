---
name: ut-writer
description: Generate JUnit 5 unit tests for Java/Spring Boot methods based on a test plan. Use when asked to "write unit tests", "generate tests", or "implement test plan". Only modifies files under src/test/java/. Follows Mockito + AssertJ patterns with Chinese comments.
---

# UT Writer — 单测代码生成器

根据 `plan.md` 编写 JUnit 5 单元测试。

## 决策树

```
读取 plan.md → 识别目标方法
    ├─ 有 plan.md → 按优先级顺序处理
    └─ 无 plan.md → 先调用 ut-planner Skill 生成计划

对每个方法 → 分析依赖
    ├─ 有外部依赖 → 使用 @Mock + @InjectMocks
    ├─ 纯逻辑方法 → 直接测试，不 mock
    └─ 涉及数据库 → Mock Repository 层

编写测试 → 验证编译
    ├─ mvn test-compile 成功 → 继续下一个方法
    └─ 编译失败 → 修复后重试（最多 3 次）
```

## 技术规范

- **JDK**: 17+
- **框架**: Spring Boot 3 + `jakarta.*` 命名空间
- **测试**: JUnit 5 (`@Test`, `@DisplayName`, `@Nested`)
- **Mock**: Mockito (`@Mock`, `@InjectMocks`, `@ExtendWith(MockitoExtension.class)`)
- **断言**: AssertJ 风格 (`assertThat(...).isEqualTo(...)`)

## 测试模板

```java
@ExtendWith(MockitoExtension.class)
class XxxServiceTest {

    @Mock
    private YyyRepository yyyRepository;

    @InjectMocks
    private XxxService xxxService;

    @Nested
    @DisplayName("doSomething 方法")
    class DoSomethingTest {

        @Test
        @DisplayName("正常路径: 有效输入应返回预期结果")
        void shouldReturnResult_whenValidInput() {
            // 准备 mock 数据
            when(yyyRepository.findById(1L)).thenReturn(Optional.of(new Yyy()));

            // 执行
            var result = xxxService.doSomething(1L);

            // 验证结果
            assertThat(result).isNotNull();
            verify(yyyRepository).findById(1L);
        }

        @Test
        @DisplayName("异常路径: 空输入应抛出 IllegalArgumentException")
        void shouldThrowException_whenNullInput() {
            assertThatThrownBy(() -> xxxService.doSomething(null))
                .isInstanceOf(IllegalArgumentException.class);
        }
    }
}
```

## 编码规范

1. 所有 mock setup 上方写**简体中文注释**说明目的
2. 测试方法名: `shouldXxx_whenYyy` 风格
3. 使用 `assertThatThrownBy()` 验证异常（不用 `assertThrows`）
4. 复杂参数使用 `ArgumentCaptor` 验证
5. 每个 `@Nested` 类对应一个被测方法

## 验证步骤

每写完一个测试类后执行：

```bash
mvn test-compile -pl {module} -q 2>&1 | tail -5
```

## 约束

- **严禁修改** `src/main/java/**` 下的任何文件
- **严禁修改** `prompt.md`、`plan.md`
- 仅在 `src/test/java/` 下创建或修改文件
- 如发现生产代码 bug，在测试文件注释中标注，不要修复
