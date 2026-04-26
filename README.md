# Claude Pipeline

> 用一次性 K8s Job 让 Claude / qwen-code agent 持续迭代完成开发任务（补单测、特性开发、重构、性能优化、bug 修复、SDD 流程等）。

## 三大中心

| 中心 | 目录 | 职责 |
|------|------|------|
| 一：Agent 镜像 | `agent/` | Claude CLI 运行环境（general / java / rust 三栈，base + agent 两层） |
| 二：LiteLLM 网关 | `k8s/litellm.yaml` | 模型协议转换 + 多供应商路由（claude-* → glm/deepseek/kimi） |
| 三：Job-Agent | `job-agent/` | 一次性任务执行（assemble → kubectl apply → agent 多轮迭代） |

任何改动先确认涉及哪一层；详见 [CLAUDE.md](./CLAUDE.md)。

## 快速开始

```bash
# 0. 准备：构建镜像 + 部署 LiteLLM
docker build -t general-claude-base:latest    -f agent/Dockerfile.general-base   ./agent/
docker build -t general-claude-pipeline:latest -f agent/Dockerfile.general-agent ./agent/
cp k8s/secret.yaml.example k8s/secret.yaml   # 填入各供应商 API key
kubectl apply -f k8s/secret.yaml -f k8s/litellm.yaml
bash k8s/setup-litellm.sh                    # 等待就绪

# 1. 维护中心配置（镜像、LiteLLM endpoint、namespace 默认值）
$EDITOR config/centers.yaml

# 2. 编写任务（参考 job-agent/tasks/xdm-ut）
mkdir -p job-agent/tasks/my-task
cat > job-agent/tasks/my-task/prompt.md <<'EOF'
# 任务说明（自包含或在 job.yml 中用 prompts/base-*.md+ 拼接）
...
EOF
cat > job-agent/tasks/my-task/job.yml <<'EOF'
# assemble: prompt.md=prompts/base-system.md+tasks/my-task/prompt.md
---
apiVersion: batch/v1
kind: Job
metadata:
  name: my-task
spec:
  completions: 5
  parallelism: 1
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: agent
          image: general:__from_centers__   # 由 centers.yaml 回填
          command: ["/bin/bash"]
          args: ["-c", "bash /pipeline/run.sh"]
          env:
            - name: REPO_URL
              value: "https://x-access-token:TOKEN@github.com/owner/repo.git"
          volumeMounts:
            - name: pipeline-config
              subPath: run.sh
              mountPath: /pipeline/run.sh
            - name: pipeline-config
              subPath: prompt.md
              mountPath: /pipeline/prompt.md
      volumes:
        - name: pipeline-config
          configMap:
            name: my-task-config
            defaultMode: 0755
EOF

# 3. 组装并部署
bash job-agent/assemble.sh job-agent/tasks/my-task/job.yml --apply
kubectl -n claude-pipeline logs -f -l job-name=my-task
```

## 验证

```bash
pip install -r requirements.txt
python3 verify_local.py
```

## 文档

- [CLAUDE.md](./CLAUDE.md)：架构与开发规范（必读）
- [docs/litellm-deployment.md](./docs/litellm-deployment.md)：LiteLLM 部署细节
- [docs/rancher-installation.md](./docs/rancher-installation.md) / [docs/rancher-dashboard.md](./docs/rancher-dashboard.md)：Rancher K8s 环境
- [job-agent/ROADMAP.md](./job-agent/ROADMAP.md)：后续优化方向
