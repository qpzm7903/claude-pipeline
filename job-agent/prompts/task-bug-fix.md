# 任务: Bug 修复 (bug-fix)

## 任务目标

从 `issues.md` 中找到未关闭的 Bug，完成复现、定位、修复和验证。

---

## 任务执行流程

### 1. 选择 Bug

- 阅读 `issues.md`，找到标记为 Bug 的未关闭 issue
- 优先修复：严重度高的 > 影响面广的 > 最近报告的
- 每轮只修复 **1 个 Bug**

### 2. 复现

- 理解 Bug 描述中的复现步骤
- 编写一个**失败的测试用例**来验证 Bug 存在
  ```bash
  # 运行刚写的失败测试
  <test_command_for_specific_test> > /tmp/reproduce.log 2>&1
  tail -10 /tmp/reproduce.log
  # 预期：测试失败（RED）
  ```
- 如果无法复现，在 issue 中记录原因并标记为"无法复现"

### 3. 定位

分析 Bug 的根因：
```
## 决策: 修复 <Bug 标题>
- 症状: <用户看到的问题>
- 根因: <代码层面的原因>
- 位置: <具体的类/方法/行>
- 方案: <修复思路>
```

### 4. 修复

- **最小化修复**：只改导致 Bug 的代码，不顺手重构
- 在修改处添加注释说明为什么这样改
- 修复后运行之前写的失败测试，确认变绿
  ```bash
  <test_command_for_specific_test> > /tmp/fix-verify.log 2>&1
  tail -10 /tmp/fix-verify.log
  # 预期：测试通过（GREEN）
  ```

### 5. 回归验证

运行全量测试，确保修复没有引入新问题：
```bash
<full_test_command> > /tmp/regression.log 2>&1
echo "EXIT: $?" >> /tmp/regression.log
tail -10 /tmp/regression.log
```

### 6. 关闭 Issue

在 `issues.md` 中关闭已修复的 issue：
- 标记修复版本
- 描述修复方案
- 提醒用户验证

---

## 注意事项

- Bug 修复使用 `fix(<范围>): <描述>` 作为 commit 类型
- 修复 commit 中必须包含回归测试文件
- 如果修复涉及多个模块，拆分为多个 commit
- 如果 Bug 根因是设计缺陷，记录到 issues.md 中作为后续重构任务
