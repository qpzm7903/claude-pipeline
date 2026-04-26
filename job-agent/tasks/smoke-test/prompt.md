# 冒烟测试 v2 — Skills + Settings 验证

## 任务目标
验证 Claude Code Pipeline 的 Skills 注入和 settings.json 权限预配置是否正常工作。

## 执行步骤

1. **检查 Skills 发现**
   - 查看 `.claude/skills/` 目录，确认 Skills 是否已正确同步
   - 列出所有可用的 Skills 名称

2. **使用 repo-guard Skill 检查仓库安全**
   - 按照 repo-guard Skill 的指引，检查受保护文件、Git 配置、工作区干净度
   - 输出结构化结果

3. **分析仓库并更新 README**
   - 查看仓库的文件结构
   - 更新 `README.md`，包含项目名称、简要描述、时间戳、文件列表

4. **使用 doc-sync Skill 同步文档**
   - 按照 doc-sync Skill 的指引，更新相关文档

5. **创建测试报告**
   - 创建 `smoke-test-v2-result.md`，记录：
     - Skills 发现情况（列出 `.claude/skills/` 内容）
     - Settings.json 加载状态
     - repo-guard 检查结果
     - doc-sync 执行结果
     - 测试结论

6. **提交并推送**

## Git 提交规范
- 格式：`test: pipeline v2 验证 — Skills + Settings 注入`
