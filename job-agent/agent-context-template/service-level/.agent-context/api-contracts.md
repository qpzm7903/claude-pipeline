# 对外 API 契约（服务内）

本服务**对外暴露**的接口清单。骨架由 `scripts/extract_api_contracts.py` 从 `@RestController` 自动生成，业务含义人工补。

## 字段规范

每个 API 必须填：
- `path + method`
- `Controller 锚点`：类全限定名 + 方法名
- `业务含义`：**必须人工补**（≤2 行）
- `请求参数`：关键业务字段（审计字段略）
- `响应结构`：关键业务字段
- `鉴权要求`：需要哪些角色/权限
- `幂等性`：是 / 否（写操作必填）
- `限流策略`：QPS 阈值、用户维度/IP 维度
- `错误码`：业务错误码清单
- `版本演进规则`

## 硬约束

- 所有接口必须有 `业务含义` 字段，缺失判不合格
- 写操作必须标注幂等性，缺失判不合格
- 被其他服务调用的接口**必须同时登记到根级 `integration-contracts.md`**

---

## 示例

### `POST /api/v1/auth/login`（示例 ✅）

- **Controller 锚点**：`com.example.auth.web.AuthController#login`
- **业务含义**：用户名密码登录，校验通过后签发 AccessToken + RefreshToken
- **请求参数**：
  - `username`：string，必填
  - `password`：string，必填，前端 SHA256 预哈希
  - `captchaToken`：string，连续失败 3 次后必填
- **响应结构**：
  - `accessToken`、`refreshToken`、`expiresIn`、`userProfile`（精简版）
- **鉴权**：无（公开）
- **幂等性**：否（每次登录都签发新 token）
- **限流**：按 IP 5 QPS，按 username 0.5 QPS
- **错误码**：
  - `AUTH-LOGIN-001` 用户不存在
  - `AUTH-LOGIN-002` 密码错误（不区分 001 和 002 对外返回，日志区分）
  - `AUTH-LOGIN-003` 需要验证码
  - `AUTH-LOGIN-004` 账号被锁定
- **版本演进**：响应字段只增不删

### `GET /api/v1/users/{id}`（示例 ✅）

- **Controller 锚点**：`com.example.user.web.UserController#getUserById`
- **业务含义**：查询用户档案，支持被 service-a 在会话签发时调用
- **请求参数**：`id`（path）、`fields`（query，可选，投影字段）
- **响应结构**：`UserProfileDTO`（见 `com.example.user.dto.UserProfileDTO`）
- **鉴权**：需 `user:read` 权限；service-a 走内部服务间凭证（`X-Service-Token`）
- **幂等性**：是（只读）
- **限流**：默认 100 QPS/service
- **错误码**：`USER-QUERY-001` 用户不存在、`USER-QUERY-002` 无权查看
- **版本演进**：字段只增不删；删字段走 `@Deprecated` + 一版本过渡期
- **跨服务契约**：同步登记到 `repo-root/.agent-context/integration-contracts.md` 的 `auth->user:getProfile`

---

## 自动生成区

<!-- BEGIN AUTO-GENERATED -->
<!-- 运行 scripts/extract_api_contracts.py 刷新 -->
<!-- END AUTO-GENERATED -->

## 人工增补区

<!-- BEGIN HUMAN-CURATED -->
<!-- 在此区补充业务含义、幂等性、限流、错误码 -->
<!-- END HUMAN-CURATED -->

---

## ❌ 反例

- ❌ 只列 path 和参数 —— 这是 Swagger 的活，不是上下文的活
- ❌ "需要登录"作为鉴权说明 —— 没说需要什么权限
- ❌ 没有错误码清单 —— agent 改接口时不知道已有错误码的坑
