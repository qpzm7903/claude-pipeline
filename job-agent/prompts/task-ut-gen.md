# 任务: 单元测试补充 (ut-gen)

## 任务目标

为 Maven 工程按模块补充 Java 类中方法的单元测试（UT），使用 JUnit5 + Mockito。

---

## 任务特定规则

- 补充 UT 的粒度是 **Java 类的方法**
- 每个新版本**最多为 5 个 Java 方法**补充 UT
- **禁止修改 `src/main/java` 下的源码**
- 除非修复编译报错和 UT 报错，否则**禁止修改 git 远程仓库中已有的 UT 测试类文件**
- 每次任务必须**新建 UT 测试类**，如果与已有文件同名，使用序号命名（如 `XXX2Test`、`XXX3Test`）
- **禁止为枚举类和 POJO 类补充 UT**
- 仅为有以下注解的 Java 类中的方法补充 UT：
  - `@RestController`
  - `@Controller`
  - `@Service`
  - `@Component`
  - `@Configuration`

---

## 参考示例

典型的 UT 测试用例可参考此文件：
```
adapter/xdm-f-security/xdm-f-security-wsf/src/test/java/com/huawei/iit/sdk/common/wsf/csrf/error/CSRFAccessDeniedHandlerTest.java
```

---

## 构建与测试命令

```bash
# 构建（不执行测试）
mvn clean package -am -T1C -DskipTests=true -Dmaven.compiler.fork=true -U -B -gs settings.xml -s settings.xml

# 对某个模块执行 UT
mvn clean test -pl <模块名称> -am -U -B -gs settings.xml -s settings.xml

# 对整个工程执行 UT
mvn clean test -U -B -gs settings.xml -s settings.xml
```

---

## 任务执行流程

1. **扫描**：列出所有 Maven 模块，找到有注解标记的 Java 类
2. **选择**：从 plan.md 确定本轮要覆盖的模块和类（最多 5 个方法）
3. **编写**：为选定的方法编写 UT，遵循 Arrange-Act-Assert 模式
4. **验证**：运行 UT 确保全部通过
5. **提交**：每个 UT 文件单独 commit
