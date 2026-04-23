# 任务: 代码重构 (refactor)

## 任务目标

改善代码的内部结构，提高可维护性和可读性，同时**不改变外部行为**。

---

## 重构不变量（不可违反）

- **所有现有测试必须全部通过**（重构前后）
- **Public API 不变**：方法签名、返回值、异常类型不变
- **功能行为不变**：用户可见的行为不改变

---

## 任务执行流程

### 1. Map — 绘制地图

分析目标代码区域：
- 识别代码异味（Code Smell）：重复代码、过长方法、过大类、过深嵌套
- 画出模块/类/方法的依赖关系
- 确定重构的"接缝"（Seam）——可以安全修改的边界

### 2. Plan — 制定计划

输出重构决策：
```
## 决策: 重构 <目标>
- 异味: <识别到的代码异味>
- 手法: <使用的重构手法，如 Extract Method / Move Class / Replace Inheritance>
- 影响: <涉及哪些文件>
- 风险: <可能的风险>
```

### 3. Verify — 建立基线

在重构之前，先运行测试建立基线：
```bash
<test_command> > /tmp/baseline.log 2>&1
echo "EXIT: $?" >> /tmp/baseline.log
tail -5 /tmp/baseline.log
```

### 4. Execute — 执行重构

- **每轮只做一个重构手法**
- 常见重构手法：
  - **提取方法 (Extract Method)**：过长方法拆分
  - **提取类 (Extract Class)**：过大类拆分
  - **内联 (Inline)**：移除不必要的间接层
  - **移动 (Move)**：将方法/类移到更合理的位置
  - **重命名 (Rename)**：改善命名可读性
  - **消除重复 (Remove Duplication)**：合并重复代码

### 5. Review — 验证结果

重构后立即运行测试：
```bash
<test_command> > /tmp/after-refactor.log 2>&1
echo "EXIT: $?" >> /tmp/after-refactor.log
tail -5 /tmp/after-refactor.log
```

测试全部通过 → 提交
测试失败 → 立即回滚（`git checkout -- .`）

---

## 注意事项

- 重构使用 `refactor(<范围>): <描述>` 作为 commit 类型
- 重构不应该增加新功能（那是 feature-dev 的事）
- 大范围重构（涉及 3+ 文件结构变更）必须创建 ADR
- 宁可做 3 个小重构，也不要做 1 个大重构
