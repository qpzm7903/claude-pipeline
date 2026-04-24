# 服务间集成契约

所有服务间的调用协议、兼容规则、失败语义。**事故高发区，必须写清楚。**

## 字段规范

每条契约必须包含：
- `id`：契约唯一标识（推荐格式 `<consumer>->-><provider>:<operation>`）
- `类型`：REST / MQ / RPC / 共享 DB / 共享缓存
- `生产者/提供方`：哪个服务 + 代码锚点
- `消费者/调用方`：哪个服务 + 代码锚点
- `语义`：同步/异步、幂等性、重试策略、超时
- `失败行为`：调用失败时消费者做什么（降级/重试/熔断/抛错）
- `版本兼容规则`：提供方如何演进（新增字段/废弃字段/路径变更）

---

## 契约清单

### auth->user:getProfile（示例 ✅）

- **类型**：REST 同步
- **提供方**：service-b，`UserController.getUserById`（`service-b/src/main/java/.../UserController.java`）
- **调用方**：service-a，`AuthService.enrichSession`（`service-a/src/main/java/.../AuthService.java:88`）
- **语义**：同步 GET，幂等，超时 500ms，无重试（快速失败）
- **失败行为**：service-a 降级为返回不含档案的会话，记录 WARN 日志，不阻断登录
- **版本兼容**：响应字段只增不删；删除字段必须先标 `@Deprecated` 一个版本
- **变更历史**：
  - 2025-10 新增 `department` 字段
  - 2024-06 初版

### user.profile.changed（示例 ✅）

- **类型**：MQ 异步（Kafka topic: `user.profile.changed`）
- **生产者**：service-b，`UserService.updateProfile` 事务提交后发送
- **消费者**：service-a，`SessionInvalidator`（订阅后使对应 session 失效）
- **语义**：至少一次，消费者必须幂等（按 `userId + version` 去重）
- **失败行为**：消费失败进 DLQ，人工介入
- **版本兼容**：字段只增不删，通过 `schemaVersion` 字段标识

---

## ❌ 反例（不要这样写）

- ❌ 只写"service-a 调用 service-b 的用户接口" —— 没有锚点、没有语义、没有失败行为
- ❌ "失败时重试" —— 没写重试几次、间隔多久、是否幂等
- ❌ "字段可能变更" —— 没写变更协议

## 代码锚点要求

- REST 契约必须指向 Controller 方法（类名 + 方法名）
- MQ 契约必须指向生产者的发送点和消费者的 `@KafkaListener`/`@RabbitListener` 方法
- 缺锚点的条目在 CI 里会被 `validate_context.py` 判失败
