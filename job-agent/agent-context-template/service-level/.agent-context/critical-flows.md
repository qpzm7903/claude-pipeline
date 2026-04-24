# 关键业务流程（服务内）

本服务的 **3-5 个** 核心业务流程的调用链 + 前置条件 + 失败场景。

> 为什么只 3-5 个：写多了没人维护，也失去"关键"的意义。agent 需要的不是流程手册，是"最容易出事的那几条路径"。

## 字段规范

每个流程必须填：
- `流程名`
- `触发条件`：何时进入此流程
- `前置条件`：数据/状态层面的要求
- `主干步骤`：序号 + 每步对应的类/方法锚点
- `关键分支`：主干以外的分支（幂等检查、权限检查、缓存命中）
- `失败场景`：每一步失败时如何处理
- `副作用`：DB 写入、MQ 发送、缓存变更
- `已知脆弱点`：容易出 bug 的地方

---

## 示例

### 用户登录（示例 ✅）

- **触发**：`POST /api/v1/auth/login`
- **前置**：用户存在且未被锁定
- **主干步骤**：
  1. `AuthController#login` 接收请求 → `LoginCommand`
  2. `RateLimiter#check` 按 IP + username 限流（失败 → 返回 429）
  3. `UserCredentialService#verify` 校验用户名密码
  4. `CaptchaService#verifyIfNeeded` 连续失败 ≥3 次时校验验证码
  5. `UserServiceClient#getProfile` 调 service-b 取档案（失败降级，见 consumes.md）
  6. `SessionFactory#create` 生成 session 写 Redis
  7. `JwtSigner#sign` 签发 AccessToken + RefreshToken
  8. `AuditLogger#logLogin` 异步写审计日志（失败只告警，不阻断）
- **关键分支**：
  - 步骤 3 失败 → 记录失败次数，触发步骤 4
  - 步骤 5 失败 → 降级为不含档案的 session
- **失败场景**：
  - 步骤 1-4 失败 → 返回对应错误码（见 `api-contracts.md`）
  - 步骤 6 失败（Redis 不可用）→ 登录失败，返回 503
  - 步骤 7 失败（签名密钥缺失）→ 返回 500 + 告警
- **副作用**：
  - Redis 写入 `session:<sessionId>`
  - MQ 发送 `user.login.succeeded` 事件
  - MySQL 写 `login_audit` 表
- **已知脆弱点**：
  - 步骤 5 超时配置必须严格，曾因此阻断登录（见 `pitfalls.md`）
  - 步骤 4 的验证码判定条件和失败计数器 TTL 对齐（5 分钟）

---

## ❌ 反例

- ❌ 用自然语言讲流程不给代码锚点 —— agent 无法定位
- ❌ 罗列 10+ 个流程 —— 稀释了"关键"的含义
- ❌ 不写失败场景 —— agent 改代码时容易破坏降级路径
- ❌ 不写副作用 —— agent 无法评估改动影响面
