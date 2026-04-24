# Claude Pipeline 真实项目使用说明

> 这份说明的目标：明天你拿一个真实 Java 仓就能跑。如果已经按本项目走过 OAuth2 样例验证（`k8s/smoke-tests/oauth2-*.yaml`），本文只是把流程剥离成**可直接复用的模板**。

---

## 零、阅读顺序

1. 先看 §1 **前置清单**，确认环境就绪（JDK 镜像、LiteLLM、GIT_TOKEN、DeepSeek Key）
2. 跑 §2 **冒烟三件套** 确保 K8s 侧通路正常（15 分钟）
3. 根据任务性质选 §3~§6 对应模板，改四个变量（仓库、分支、提示词、限额）就能跑
4. §7 **真实项目首跑检查清单** 一定要过一遍
5. §8 是**踩坑速查**

---

## 一、前置清单

### 1.1 基础设施

| 资源 | 是否已就绪 | 验证命令 |
|------|-----------|---------|
| K8s 集群可用 | ✅（Rancher Desktop 本地即可） | `kubectl get ns` |
| namespace `litellm` | ✅（已由 `k8s/litellm.yaml` 建好） | `kubectl -n litellm get deploy litellm` |
| namespace `claude-pipeline` | ✅ | `kubectl get ns claude-pipeline` |
| LiteLLM 集群内地址 | `http://litellm.litellm:4000`（K8s Service DNS） | `kubectl -n litellm get svc litellm` |
| DeepSeek API Key | 写入 `litellm-secrets.DEEPSEEK_API_KEY` | `kubectl -n litellm get secret litellm-secrets -o yaml` |

### 1.2 agent 镜像

Java 类任务必须用 `java-claude-pipeline:latest`（含 JDK 17 + Maven 3.9.9）。一次性构建两层：

```bash
# 基础层（含 git / claude CLI / Node / Python），很少需要重建
docker build -t general-claude-base:latest -f agent/Dockerfile.general-base ./agent/

# Java 基础层（+ JDK 17 + Maven）
docker build -t java-claude-base:latest -f agent/Dockerfile.java-base ./agent/

# agent 层（含 entrypoint + lib），改 lib/*.sh 后必须重建
docker build -t java-claude-pipeline:latest -f agent/Dockerfile.java-agent ./agent/
```

重建后验证：

```bash
docker run --rm --entrypoint bash java-claude-pipeline:latest \
  -c 'java --version; mvn --version | head -2; claude --version'
```

预期输出：`openjdk 17.0.x` / `Apache Maven 3.9.9` / `2.1.x (Claude Code)` 三行。

### 1.3 Secret

两条都必须提前建好：

```bash
# GitHub Token（需 repo 写权限；复用本项目已有流程）
TOKEN=$(grep '^GIT_TOKEN=' .env | cut -d= -f2-)
kubectl -n claude-pipeline create secret generic github-token \
  --from-literal=GIT_TOKEN="$TOKEN" --dry-run=client -o yaml | kubectl apply -f -

# LiteLLM 桥接 Key（把 master-key 搬到 claude-pipeline ns 供 Job 引用）
kubectl -n claude-pipeline create secret generic litellm-bridge \
  --from-literal=ANTHROPIC_API_KEY="sk-1234" --dry-run=client -o yaml | kubectl apply -f -
```

---

## 二、冒烟三件套（首次或换环境后必跑）

按顺序跑，全绿再继续。每个都是独立 K8s Job，跑完自动或手动清理。

```bash
# 1) LiteLLM 端点 + 模型路由
kubectl apply -f k8s/smoke-tests/litellm-smoke.yaml
kubectl -n litellm logs -f job/litellm-smoke-test   # 预期 4/4 通过
kubectl -n litellm delete -f k8s/smoke-tests/litellm-smoke.yaml

# 2) agent 镜像 -> LiteLLM 链路（返回"你好！..."即通）
kubectl apply -f k8s/smoke-tests/agent-smoke.yaml
kubectl -n claude-pipeline logs -f -l job-name=agent-smoke-test
kubectl -n claude-pipeline delete -f k8s/smoke-tests/agent-smoke.yaml

# 3) 真仓只读冒烟（验证 clone + Claude + LiteLLM 整条链）
kubectl apply -f k8s/smoke-tests/agent-real-repo.yaml
kubectl -n claude-pipeline logs -f -l job-name=agent-real-repo-test
kubectl -n claude-pipeline delete -f k8s/smoke-tests/agent-real-repo.yaml
```

三件套任意一条失败，**不要**继续往下跑——先修。

---

## 三、四种任务类型与对应模板

| 任务 | 模板文件 | 何时用 | 产出 |
|------|---------|-------|------|
| **开发**（greenfield / 新 MINOR） | `oauth2-greenfield-build.yaml` | 从 0 建或按路线图推进版本 | 多个 commit + tag |
| **重构** | `oauth2-refactor.yaml` | 小范围代码质量改进 | 1 个 refactor commit 或无改动评估 |
| **性能优化** | `oauth2-perf.yaml` | 指标明确、可测量的热点优化 | 1 个 perf commit + 新测试 |
| **只读问答 / 评审** | `oauth2-qa.yaml` | 验证 `.agent-context/` 质量、代码走读 | 仅控制台输出，不落 commit |

### 3.1 共性结构（看完这一节，每个模板自然会改）

每个模板分三部分：

1. **ConfigMap** —— 里面是 prompt.md，**这是改动最多的地方**
2. **Job** —— 指定镜像、环境变量、资源、挂载
3. `env` 里 5 个你可能要改的位置：
   - `REPO_URL` —— 目标仓库
   - `ANTHROPIC_MODEL` —— 可换 `deepseek-chat` / `deepseek-reasoner` / `claude-sonnet-4-6`（后者会被 LiteLLM 别名路由到 deepseek）
   - `ROUND_TIMEOUT` —— 单轮秒数，开发类 900、优化类 600、只读类 400
   - `MAX_ITERATIONS` —— 上限 8（开发）/ 3（改动类）/ 1（只读）
   - `MAX_NOCHANGE` —— 连续几轮无 commit 就退出；**只读任务设 1 且必须配 `ALLOW_NO_COMMIT=true`**

---

## 四、在真实仓库上套模板（以重构任务为例）

假设你明天要在 `https://github.com/YOUR_ORG/YOUR_REPO`（Spring Boot 3 + Maven）上跑一次代码重构。

### 4.1 复制模板并改 4 处

```bash
cp k8s/smoke-tests/oauth2-refactor.yaml k8s/smoke-tests/myrepo-refactor.yaml
```

改 `myrepo-refactor.yaml`：

| 位置 | 原值 | 改为 |
|------|-----|------|
| `metadata.name`（ConfigMap） | `oauth2-refactor-prompt` | `myrepo-refactor-prompt` |
| `metadata.name`（Job） | `oauth2-refactor` | `myrepo-refactor` |
| `REPO_URL` | `https://github.com/qpzm7903/job-demo` | 你的仓 |
| `GIT_AUTHOR_NAME` / `GIT_AUTHOR_EMAIL` | `qpzm7903` / ... | 你的 git 署名 |
| ConfigMap `data.prompt.md` 里的 **"禁止改动 Spring Authorization Server ..."** 一行 | 针对 OAuth2 | 换成你仓库的领域红线（比如 "禁止改动支付网关调用代码"） |

### 4.2 按需调 prompt 的"本轮目标范围"

如果你的仓库庞大（几十万行），**必须在 prompt 里额外加两条**：

```
## 作用域硬约束
- 本轮只允许修改：<具体模块路径，如 common-utils/>
- 禁止修改：<其它模块>
- 禁止跨模块重构（即使发现了跨模块异味，也只记录在 docs/，不改动）
```

这是防 agent 跑偏的关键——否则它会自己决定动哪里。

### 4.3 跑 + 观察

```bash
kubectl apply -f k8s/smoke-tests/myrepo-refactor.yaml
kubectl -n claude-pipeline get pods -l job-name=myrepo-refactor -w    # 看状态
kubectl -n claude-pipeline logs -f -l job-name=myrepo-refactor        # 跟日志
```

看到 `流水线完成 ✓` 再去 GitHub 看 commit；看到 `Pipeline 失败` 不要盲目重跑，先看日志找根因。

### 4.4 收工

```bash
kubectl -n claude-pipeline delete -f k8s/smoke-tests/myrepo-refactor.yaml
```

---

## 五、最推荐的首日实操顺序

首日**不要直接上开发任务**。按这个顺序逐步提升信心：

1. **D+0 只读问答**（`oauth2-qa.yaml` 改造版）
   - 用法：让 agent 对你的真实仓做"3 个核心流程解释 + 业务术语核对"
   - 为什么：零破坏性，验证 clone / 读写权限 / 模型回答质量
   - 耗时：~5 分钟
2. **D+1 小重构**（`oauth2-refactor.yaml`）
   - 用法：限定一个最小模块，让 agent 做 1 次小范围重构
   - 为什么：有测试兜底，commit 可撤销
   - 耗时：~15 分钟
3. **D+2 性能优化**（`oauth2-perf.yaml`）
   - 用法：选一个**你自己已知可以优化**的点，让 agent 去实现
   - 为什么：你能客观判断 agent 做得对不对
4. **D+3 greenfield / 新 MINOR 开发**
   - 用法：最复杂，放在你对 agent 行为已有感觉之后

---

## 六、上下文工程（可选但建议）

真实项目的效果上限取决于 `.agent-context/` 的质量。步骤：

### 6.1 本地跑抽取脚本

```bash
# 先克隆目标仓到本地
git clone https://github.com/YOUR_ORG/YOUR_REPO /tmp/target-repo

# 初始化 .agent-context/
mkdir -p /tmp/target-repo/.agent-context
cp job-agent/agent-context-template/service-level/.agent-context/*.md /tmp/target-repo/.agent-context/

# 抽取 JPA / MyBatis / Controller
job-agent/agent-context-template/scripts/generate_entity_graph.sh \
  /tmp/target-repo /tmp/target-repo/.agent-context
```

### 6.2 **必须**人工补业务语义（10~30 分钟）

HUMAN-CURATED 区是脚本填不出来的。至少要补：

- `module-map.md` —— 每个 Maven 子模块一行职责
- `domain-glossary.md` —— 5~10 个核心术语对应的代码锚点
- `api-contracts.md` —— 凡是被其它服务调用的接口都要写"业务含义 + 鉴权要求"
- `consumes.md` —— 你调用的每个外部系统的失败降级策略

**偷懒代价**：`.agent-context/` 内容越贫瘠，agent 探索越长，代价越高，结果越不稳定。

### 6.3 Push 回仓库

```bash
cd /tmp/target-repo
git add .agent-context/
git commit -m "docs(context): 新增 .agent-context 业务地图"
git push
```

### 6.4 用 `oauth2-qa.yaml` 验证 context 质量

改 `REPO_URL` 重跑一次——agent 会按"先读 context 再看源码"的顺序作答，能直接暴露 context 里的缺失或错误。

---

## 七、真实项目首跑检查清单

在 `kubectl apply` 之前逐项打钩：

- [ ] 目标仓已存在且你有 write 权限
- [ ] 目标仓 **有默认分支**（不是空仓）—— 否则 agent 的"无 commit 守门"会误判
- [ ] 目标仓 **有 CI 保护**（GitHub Actions / 其他）—— agent 的 `mvn test` 在镜像里能跑，但 CI 是最后一道防线
- [ ] `GIT_TOKEN` 对目标仓有 write 权限（同一个 token 可能对老仓有权、对新仓没有）
- [ ] prompt 里的 **"禁止改动"一节** 已经针对你的仓定制（默认值是 OAuth2，不适用于你的项目）
- [ ] `MAX_ITERATIONS` 不超过 8，第一次跑建议 3
- [ ] `ROUND_TIMEOUT` 对大工程不够用：Maven 首次下载依赖可能 5 分钟，至少给 900
- [ ] 如果是只读任务：设置了 `ALLOW_NO_COMMIT: "true"` 且 `EXEC_MODE: single`
- [ ] Job `metadata.name` **唯一**（同名会冲突，K8s 会拒绝 apply）
- [ ] 手边打开了 `kubectl logs -f`，看到异常立刻 `delete job` 止损

---

## 八、踩坑速查

| 现象 | 常见原因 | 处置 |
|-----|---------|-----|
| Job 起来就 Failed，日志里 `REPO_URL 未设置` | entrypoint.sh 要求必填 | 检查 env 是否拼错字段 |
| Pod 状态 `ImagePullBackOff` | `java-claude-pipeline:latest` 没构建到 K8s 节点 | `docker build` 后确认镜像在集群所在节点（本地 Rancher 自动共享） |
| `Cloning into '/workspace'... warning: empty repository` | 仓库是空的 | 往 main 推一个初始 commit，或把任务改成 greenfield |
| `Pipeline 失败: 代码仓库没有任何新的 commit` | 开发类任务跑完但 agent 没 commit | 看 prompt 最后一段有没有"必须 commit + push"；必要时 `MAX_NOCHANGE=1` 让它快速退出止血 |
| 每轮都报 "git push 失败" | GIT_TOKEN 权限不够 / 仓库启用了 branch protection | 换 token 或在 prompt 里让 agent 改 push 到新分支 |
| agent 声称 `BUILD SUCCESS` 但 CI 是红的 | 用了**不带 JDK/Maven 的旧镜像** | 确认 `image: java-claude-pipeline:latest`，不是 `claude-pipeline-agent` |
| agent 不停打转、8 轮都没收敛 | prompt 里没有明确的"完成标志" | 加硬退出条件，比如"本项目无可优化则直接退出" |
| commit 带 `Co-Authored-By: Claude` | prompt 里没禁 | 在 prompt 的 "Commit 规范" 段加：严格禁止 AI 署名 |
| 日志里 thinking block 被截到 500 字符 | `fmt_stream.py` 格式化限制 | 长答案需要引流到 `/tmp/output.md` 文件，prompt 里明确要求"把完整答案写到 /tmp/answer.md 并 cat 输出" |
| LiteLLM 侧 400 `Invalid model name` | 模型名拼错 | 已注册模型：`deepseek-chat`、`deepseek-reasoner`、`claude-sonnet-4-6`、`claude-opus-4-7`、`claude-3-5-sonnet-20241022`；其它会 400 |

---

## 九、资源与成本

DeepSeek 免费额度有限。单个任务的消耗参考（来自 OAuth2 验证）：

| 任务 | 迭代数 | 约耗 token（input+output） |
|------|-------|---------------------------|
| 冒烟链路 | 1 | < 1K |
| 只读问答（8 问题） | 1 | ~10K |
| 重构（无改动场景） | 2 | ~30K |
| 性能优化（含 mvn test 调试） | 1 | ~80K |
| 开发（greenfield 8 轮） | 8 | ~300K |

建议：
- 首日实验**必须**开着 LiteLLM Dashboard（如果启用）盯 usage
- 大仓重构前先用 only-read 任务让 agent 先"摸一下仓"，出评估报告后再决定跑不跑重构

---

## 十、附录：完整文件索引

- `agent/Dockerfile.java-base` / `Dockerfile.java-agent` —— Java 镜像
- `agent/lib/run.sh` —— 迭代引擎，含 `ALLOW_NO_COMMIT` 开关
- `agent/entrypoint.sh` —— 容器入口
- `k8s/litellm.yaml` —— LiteLLM 部署 + 模型路由
- `k8s/smoke-tests/litellm-smoke.yaml` —— LiteLLM 端点冒烟
- `k8s/smoke-tests/agent-smoke.yaml` —— agent → LiteLLM 链路冒烟
- `k8s/smoke-tests/agent-real-repo.yaml` —— 真仓克隆冒烟
- `k8s/smoke-tests/oauth2-greenfield-build.yaml` —— 开发任务模板
- `k8s/smoke-tests/oauth2-refactor.yaml` —— 重构任务模板
- `k8s/smoke-tests/oauth2-perf.yaml` —— 性能优化任务模板
- `k8s/smoke-tests/oauth2-qa.yaml` —— 只读问答任务模板
- `job-agent/agent-context-template/` —— 上下文模板与抽取脚本
