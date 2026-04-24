# 本服务消费的外部依赖（服务内）

本服务**调用**哪些外部（其他服务、第三方、基础设施）的接口 / 事件 / 数据。

> 注意：`api-contracts.md` 是"我提供什么"（生产者视角），本文件是"我消费什么"（消费者视角）。
> 两份视图对称，是 agent 做影响面分析的基础。

## 字段规范

每个消费项必须填：
- `依赖 id`：推荐格式 `<provider>:<operation>`
- `类型`：REST / MQ / DB / Cache / 第三方 SaaS
- `提供方`：服务名或外部系统名
- `调用点锚点`：本服务代码里的调用位置（类 + 方法）
- `用途`：一句话说明"为什么调它"
- `失败降级策略`：**必填**
- `超时/重试/熔断配置`
- `SLA 假设`：我对它的可用性/延迟假设
- `契约位置`：对应根级 `integration-contracts.md` 里的条目 id

---

## 示例

### user:getProfile（示例 ✅）

- **类型**：REST 同步
- **提供方**：service-b
- **调用点锚点**：
  - `com.example.auth.service.AuthService#enrichSession`
  - `com.example.auth.service.SessionRefresher#refresh`
- **用途**：登录成功后/刷新会话时，取用户档案快照嵌入 session
- **失败降级**：返回不含档案的精简 session；记录 WARN；不阻断登录流程
- **超时**：connectTimeout 200ms / readTimeout 500ms
- **重试**：不重试（登录场景下快速失败优先）
- **熔断**：连续 10 次失败熔断 30s，降级路径同上
- **SLA 假设**：service-b 99.9%、P99 200ms
- **契约位置**：`repo-root/.agent-context/integration-contracts.md#auth->user:getProfile`

### user.profile.changed（示例 ✅，订阅事件）

- **类型**：MQ 订阅
- **提供方**：service-b
- **调用点锚点**：`com.example.auth.listener.SessionInvalidator#onProfileChanged`
- **用途**：用户档案变更时失效对应 session
- **失败降级**：消费失败重试 3 次（1s/5s/30s），再失败进 DLQ，人工介入
- **幂等策略**：按 `(userId, version)` 去重，Redis key `session:invalidate:seen:<userId>:<version>`
- **SLA 假设**：事件延迟 P99 ≤ 5s
- **契约位置**：`repo-root/.agent-context/events.md#user.profile.changed`

---

## ❌ 反例

- ❌ 没有失败降级 —— agent 改调用代码时会漏写降级
- ❌ 没写 SLA 假设 —— 上游变慢时 agent 不知道要改超时
- ❌ 没指向根级契约 —— 两侧文档各说各的，迟早漂移
