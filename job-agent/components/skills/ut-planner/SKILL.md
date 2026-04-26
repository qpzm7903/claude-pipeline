---
name: ut-planner
description: Analyze a Java/Spring Boot module to identify high-value methods for unit testing and generate a structured test plan. Use when asked to "plan unit tests", "analyze test coverage gaps", or "find methods that need testing". Outputs plan.md with prioritized method list and testing strategy.
---

# UT Planner — 单测计划生成器

扫描 Java 模块，识别高价值业务方法，输出结构化测试计划。

## 决策树

```
扫描 src/main/java/ → 过滤候选类
    ├─ Service / Manager / Facade / Handler → 保留
    ├─ Controller → 保留（集成测试候选）
    └─ DTO / VO / Entity / Config / Constant → 跳过

对每个候选类 → 分析方法
    ├─ 分支数 ≥ 3 且有异常路径 → 高优先级
    ├─ 外部依赖调用 ≥ 2 → 中优先级
    └─ 纯 getter/setter/toString → 跳过
```

## 执行步骤

### 1. 扫描模块结构

```bash
# 找到所有业务类
find src/main/java -name '*.java' | grep -E '(Service|Manager|Facade|Handler|Controller)\.java$'

# 检查已有测试
find src/test/java -name '*Test.java' -o -name '*Tests.java' 2>/dev/null
```

### 2. 分析方法复杂度

对每个候选方法评估以下指标：

| 指标 | 权重 | 说明 |
|------|------|------|
| 分支数 | 高 | if/else, switch, 三元运算符数量 |
| 异常路径 | 高 | try/catch, throws 声明 |
| 依赖调用 | 中 | 注入依赖的方法调用次数 |
| 返回路径 | 低 | 不同 return 语句数量 |

### 3. 输出 plan.md

输出格式遵循以下模板：

```markdown
# 单测计划 — {模块名}

## 扫描摘要
- 扫描日期: YYYY-MM-DD
- 候选类数: N
- 候选方法数: M
- 已有测试: K 个文件

## 高优先级方法

| # | 类名 | 方法名 | 分支 | 异常 | 依赖 | 测试策略 |
|---|------|--------|------|------|------|---------|
| 1 | XxxService | doSomething | 5 | 2 | 3 | 正常+异常+边界 |

## 中优先级方法
...

## 建议的测试顺序
1. 先覆盖高优先级中依赖最少的方法（快速见效）
2. 再处理依赖多但分支多的方法
3. 最后补充 Controller 层集成测试
```

## 约束

- **只读操作**：不修改任何 Java 源码或测试文件
- 仅输出 `plan.md` 文档
- 如果发现已有测试类，在 plan 中标注避免重复
