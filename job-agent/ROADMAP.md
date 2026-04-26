# Job-Agent 后续优化路线图

本文档记录已识别但尚未实施的优化方向草案，作为后续迭代的参考。

---

## ✅ 已完成（本期）

| 方向 | 内容 | 状态 |
|------|------|------|
| 方向 1 | 多任务类型支持（ut-gen / feature-dev / refactor / perf-optimize / bug-fix） | ✅ 已完成 |
| 方向 7 | 可观测性（`.agent-progress.md` 结构化进度日志） | ✅ 已完成 |
| 方向 9 | 文档治理（CHANGELOG / ADR / README 维护规则） | ✅ 已完成 |
| 方向 11 | Prompt 工程（分层结构 / 思维链 / 失败处理 / 输出控制） | ✅ 已完成 |
| 方向 12 | 单一组装入口（删除 build.sh，全部走 assemble.sh） | ✅ 已完成 |
| 方向 13 | 三大中心配置集中（`config/centers.yaml`：镜像 / LiteLLM / namespace） | ✅ 已完成 |

---

## ⏳ 后续方向草案

### 方向 2: 结构化状态机 — 可持续迭代

**目标**：Agent 跨 session 能记住"做到哪了"，断点续传。

**设计草案**：
- 在仓库中维护 `.agent-state.yaml`：
  ```yaml
  current_phase: development  # planning / development / testing / release / documentation
  current_version: 0.3.0
  last_session: 15
  last_action: "完成 UserService.login() 的 UT"
  next_action: "为 UserService.logout() 补充 UT"
  blocked: false
  blocked_reason: ""
  ```
- Agent 启动时先读取 `.agent-state.yaml` 恢复上下文
- 每个阶段完成后更新状态文件并 commit
- 状态转换规则明确：Planning → Development → Testing → Release → Documentation → Planning

**依赖**：方向 11（已完成，分层 prompt 结构可扩展）

---

### 方向 3: 上下文工程 — 精准信息注入

**目标**：大型项目中，Agent 不需要"看完所有代码"就能精准工作。

**设计草案**：
- 在 `run.sh`（ConfigMap 中的启动脚本）或 prompt 中增加仓库预扫描步骤：
  ```bash
  # 生成模块概览
  find . -name "pom.xml" -exec dirname {} \; > .repo-modules.txt
  # 生成注解类索引
  grep -rl "@RestController\|@Service\|@Component" --include="*.java" src/ > .repo-annotated-classes.txt
  # 生成目录树
  tree -L 3 -I 'target|node_modules' > .repo-tree.txt
  ```
- Agent 优先阅读 `.repo-modules.txt` + `.repo-tree.txt`，而非 `find` 整个仓库
- 为每个任务类型定义"需要的上下文"（UT 任务只需 annotated classes，重构任务需要依赖图）

**依赖**：可独立实施，建议在 `build.sh` 中为 `run.sh` 增加预扫描步骤

---

### 方向 4: 多 Agent 编排 — 专业分工

**目标**：Planner → Coder → Reviewer 三步流水线，提升代码质量。

**设计草案**：
- **Phase 1（最小 MVP）**：同一个 Job 内串行执行两轮
  - 第 1 轮：Coder Agent（使用 task prompt 开发代码）
  - 第 2 轮：Reviewer Agent（使用 review prompt 审查 `git diff`）
  - 通过环境变量 `AGENT_ROLE=coder|reviewer` 控制
- **Phase 2（进阶）**：使用 Claude Code SDK / qwen-code API 实现编程式编排
  - Python 脚本作为 orchestrator
  - 子 Agent 有独立的 system prompt 和工具权限
- **Phase 3（高级）**：并行多 Agent
  - 不同 Maven 模块分配给不同 Pod
  - 通过 Git 分支隔离，最后合并

**依赖**：需确认 qwen-code CLI 是否支持 SDK 模式或 API 调用

---

### 方向 5: 质量门禁 — 多维质量保障

**目标**：从"能编译就行"升级为"编译 + 测试 + 静态分析 + 自我审查"。

**设计草案**：
- **Level 1（prompt 层面）**：在 base-system.md 的验证步骤中增加：
  ```bash
  # 静态分析
  mvn spotbugs:check -U -B -gs settings.xml -s settings.xml > /tmp/spotbugs.log 2>&1
  tail -20 /tmp/spotbugs.log
  
  # 代码风格
  mvn checkstyle:check -U -B -gs settings.xml -s settings.xml > /tmp/checkstyle.log 2>&1
  tail -20 /tmp/checkstyle.log
  ```
- **Level 2（自我审查）**：Agent 开发完成后，切换到 "Reviewer 角色" 审查自己的 `git diff`
  ```
  请以代码审查者的视角，审查以下 diff：
  1. 是否有安全风险？
  2. 是否有性能问题？
  3. 命名是否合理？
  4. 错误处理是否完整？
  ```
- **Level 3（外部工具）**：集成 SonarQube 分析结果

**依赖**：Level 1 可立即在 prompt 中添加；Level 2 需方向 4 的基础

---

### 方向 6: 知识积累与学习 — 持续进化

**目标**：Agent 越做越聪明，不重复犯同样的错误。

**设计草案**：
- 在仓库中维护 `.knowledge/` 目录：
  ```
  .knowledge/
  ├── patterns.md      # 项目特有的代码模式（如 DAO 层的标准写法）
  ├── pitfalls.md      # 已踩过的坑（如某个依赖的兼容性问题）
  ├── decisions.md     # 架构决策摘要（从 docs/adr/ 自动提取）
  └── style-guide.md   # 代码风格指南（从已有代码中归纳）
  ```
- 每次 session 结束时，Agent 判断是否有新发现需要记录：
  - 遇到了新的编译错误模式 → 追加到 `pitfalls.md`
  - 发现了项目的代码约定 → 追加到 `patterns.md`
  - 做了架构决策 → 已有 ADR 覆盖
- 下次 session 启动时，在 `.repo-summary` 阶段读取 `.knowledge/`
- **增长控制**：每个文件最多 200 行，超过后 Agent 需要压缩/合并旧条目

**依赖**：方向 2（状态机，用于触发"session 结束"时的知识抽取）

---

## ❌ 不实施

| 方向 | 原因 |
|------|------|
| 方向 8: 安全与权限控制 | 容器环境运行，不需要权限控制 |
| 方向 10: 调度优化 | 当前 Job completions 模式够用 |

---

## 建议实施顺序

```
方向 2（状态机）→ 方向 3（上下文工程）→ 方向 5（质量门禁 L1）→ 方向 6（知识积累）→ 方向 4（多 Agent）
```

每个方向建议先在一个仓库上验证效果，再推广到其他仓库。
