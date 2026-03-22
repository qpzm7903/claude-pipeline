# LiteLLM Proxy 部署文档

## 概述

LiteLLM 是一个统一的 LLM API 网关，提供 OpenAI 兼容的 API 接口，支持多种 LLM 提供商：
- DashScope Apps (GLM-5, 等)
- DashScope Compatible Mode (Qwen-Plus, 等)
- OpenAI (GPT-4o, GPT-4o-mini)
- Anthropic (Claude Sonnet, Claude Opus)
- 其他 100+ 模型

## 部署状态

| 组件 | 说明 |
|------|------|
| LiteLLM Proxy | API 网关，端口 4000 |
| PostgreSQL | 数据库，用于 UI 登录和密钥管理 |
| Web UI | http://localhost:4000/ui/ |

## 访问 Web UI

1. 打开 http://localhost:4000/ui/
2. 使用 `LITELLM_MASTER_KEY` 登录（默认：`sk-litellm-local-dev`）

### UI 功能

| 功能 | 说明 |
|------|------|
| API Playground | 在线测试模型调用 |
| 模型管理 | 查看已配置的模型 |
| API Key 管理 | 创建/管理虚拟密钥 |
| 用量统计 | 查看请求量和费用 |

## 快速部署

### 1. 创建环境变量文件

```bash
cat > .env.litellm << 'EOF'
LITELLM_MASTER_KEY=sk-your-master-key
DASHSCOPE_APPS_API_KEY=sk-xxx    # DashScope Apps API Key (用于 glm-5)
DASHSCOPE_API_KEY=sk-xxx         # DashScope Compatible Mode API Key (用于 qwen-plus)
OPENAI_API_KEY=sk-xxx
ANTHROPIC_API_KEY=sk-ant-xxx
EOF
```

> **注意**: DashScope 有两种 API Key：
> - `DASHSCOPE_APPS_API_KEY`: 用于 Apps API (coding.dashscope.aliyuncs.com/apps/anthropic)
> - `DASHSCOPE_API_KEY`: 用于 Compatible Mode (dashscope.aliyuncs.com/compatible-mode/v1)

### 2. 部署

```bash
./k8s/setup-litellm.sh .env.litellm
```

### 3. 访问

```bash
# LoadBalancer 自动分配 localhost
curl http://localhost:4000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer sk-your-master-key" \
  -d '{
    "model": "glm-5",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
```

## 配置说明

### 预配置模型

| 模型名称 | 后端 | API Key | 说明 |
|---------|------|---------|------|
| `glm-5` | DashScope Apps | `DASHSCOPE_APPS_API_KEY` | GLM-5 模型 |
| `qwen-plus` | DashScope Compatible | `DASHSCOPE_API_KEY` | 通义千问 Plus |
| `gpt-4o` | OpenAI | `OPENAI_API_KEY` | GPT-4 Omni |
| `claude-sonnet` | Anthropic | `ANTHROPIC_API_KEY` | Claude Sonnet 4 |

### 添加新模型

编辑 `k8s/litellm.yaml` 中的 ConfigMap：

```yaml
model_list:
  - model_name: my-custom-model
    litellm_params:
      model: openai/my-model
      api_key: os.environ/MY_API_KEY
```

然后更新 Secret 添加 `MY_API_KEY`。

## 配置更新

### 方式一：修改 YAML 文件（推荐）

编辑 `k8s/litellm.yaml`：

```yaml
# 1. 添加模型到 ConfigMap
data:
  config.yaml: |
    model_list:
      # 现有模型...
      - model_name: deepseek-chat      # 新模型
        litellm_params:
          model: openai/deepseek-chat
          api_key: os.environ/DEEPSEEK_API_KEY
          api_base: https://api.deepseek.com/v1

# 2. 添加 API Key 到 Secret
stringData:
  DEEPSEEK_API_KEY: "sk-xxx"
```

应用并重启：

```bash
kubectl apply -f k8s/litellm.yaml
kubectl rollout restart deployment/litellm -n litellm
```

### 方式二：直接修改 K8s 资源

```bash
# 编辑模型配置
kubectl edit configmap litellm-config -n litellm

# 编辑 API Key（需要 base64 编码）
kubectl edit secret litellm-secrets -n litellm
# 获取 base64: echo -n 'sk-your-key' | base64

# 重启生效
kubectl rollout restart deployment/litellm -n litellm
```

### 方式三：通过 UI 配置

登录 UI 后可直接管理模型和 API Key。

### 常用模型配置示例

```yaml
# DeepSeek
- model_name: deepseek-chat
  litellm_params:
    model: openai/deepseek-chat
    api_key: os.environ/DEEPSEEK_API_KEY
    api_base: https://api.deepseek.com/v1

# Moonshot (Kimi)
- model_name: moonshot-v1-8k
  litellm_params:
    model: openai/moonshot-v1-8k
    api_key: os.environ/MOONSHOT_API_KEY
    api_base: https://api.moonshot.cn/v1

# Zhipu (智谱)
- model_name: glm-4
  litellm_params:
    model: openai/glm-4
    api_key: os.environ/ZHIPU_API_KEY
    api_base: https://open.bigmodel.cn/api/paas/v4

# Azure OpenAI
- model_name: azure-gpt-4
  litellm_params:
    model: azure/gpt-4
    api_key: os.environ/AZURE_API_KEY
    api_base: os.environ/AZURE_API_BASE

# 自定义 OpenAI 兼容端点
- model_name: my-custom-model
  litellm_params:
    model: openai/my-model
    api_key: os.environ/MY_API_KEY
    api_base: https://my-endpoint.com/v1
```

## 与 Claude Pipeline 集成

### 方式一：直接使用 LiteLLM 地址

```bash
# .env 文件
ANTHROPIC_BASE_URL=http://litellm.litellm.svc.cluster.local:4000
ANTHROPIC_MODEL=gpt-4o-mini  # 或 claude-sonnet 等
ANTHROPIC_AUTH_TOKEN=sk-your-litellm-master-key
```

### 方式二：Port-forward 本地访问

```bash
# 启动 port-forward
kubectl port-forward svc/litellm -n litellm 4000:4000 &

# .env 文件
ANTHROPIC_BASE_URL=http://localhost:4000
ANTHROPIC_MODEL=gpt-4o-mini
ANTHROPIC_AUTH_TOKEN=sk-your-litellm-master-key
```

## 架构

```
Claude Pipeline Agent
        │
        ▼
   LiteLLM Proxy (K8s Service)
        │
        ├─► OpenAI API
        ├─► Anthropic API
        └─► DashScope API
```

## 常用命令

```bash
# 查看状态
kubectl get all -n litellm

# 查看日志
kubectl logs -f deployment/litellm -n litellm

# 重启服务
kubectl rollout restart deployment/litellm -n litellm

# 更新配置
kubectl edit configmap litellm-config -n litellm
kubectl rollout restart deployment/litellm -n litellm

# 更新密钥
kubectl edit secret litellm-secrets -n litellm
kubectl rollout restart deployment/litellm -n litellm
```

## 生产环境建议

### 1. 使用数据库

添加 PostgreSQL 用于持久化密钥和日志：

```yaml
env:
  - name: DATABASE_URL
    value: "postgresql://user:pass@host:5432/litellm"
```

### 2. 高可用部署

```yaml
spec:
  replicas: 3
```

### 3. 添加 Redis

用于多实例间的速率限制共享：

```yaml
router_settings:
  redis_host: redis-service
  redis_port: 6379
```

## 卸载

```bash
kubectl delete -f k8s/litellm.yaml
```

## 参考链接

- [LiteLLM 官方文档](https://docs.litellm.ai/)
- [支持的模型列表](https://docs.litellm.ai/docs/providers)
- [配置参考](https://docs.litellm.ai/docs/proxy/configs)