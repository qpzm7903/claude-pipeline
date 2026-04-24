# 领域事件清单

**条件必填**：如果任何服务通过消息队列（Kafka / RabbitMQ / Pulsar / RocketMQ）与其他服务通信，必须登记所有 topic。

## 字段规范

每个事件必须填：
- `topic / queue 名`
- `类型`：domain event / command / notification
- `生产者`：服务名 + 发送代码锚点
- `消费者`：每个消费者的服务名 + `@*Listener` 方法锚点
- `schema`：Payload 字段，或指向 schema registry / Protobuf / Avro 定义
- `语义`：at-least-once / at-most-once / exactly-once
- `幂等策略`：消费端如何去重
- `失败策略`：重试次数、DLQ、告警
- `版本演进`：字段变更规则

---

## 示例

### `user.profile.changed`（示例 ✅）

- **类型**：domain event
- **生产者**：service-b `UserService.updateProfile` 事务提交后（`service-b/src/main/java/.../UserService.java:123`）
- **消费者**：
  - service-a `SessionInvalidator.onProfileChanged`（`service-a/.../SessionInvalidator.java:45`）
- **schema**：
  ```json
  {
    "userId": "long",
    "changedFields": ["array<string>"],
    "version": "long",
    "timestamp": "iso8601",
    "schemaVersion": "int"
  }
  ```
- **语义**：at-least-once
- **幂等策略**：按 `(userId, version)` 去重
- **失败策略**：3 次重试，间隔 1s/5s/30s，失败进 DLQ，触发企业微信告警
- **版本演进**：字段只增不删，删除走 `schemaVersion` 升级 + 过渡期

---

## ❌ 反例

- ❌ 只写 topic 名和生产者，不列消费者 —— 无法评估影响面
- ❌ "失败会重试" —— 不写具体策略等于没写
- ❌ 没有幂等策略 —— 一次 MQ 重投就会造成业务事故
