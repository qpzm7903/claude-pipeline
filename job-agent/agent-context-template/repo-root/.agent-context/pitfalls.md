# 跨服务踩坑记录

记录**跨服务**层面踩过的坑。单服务内部的坑放到对应服务的 `service-*/.agent-context/pitfalls.md`。

## 条目格式

```
### <一句话坑名>

- **现象**：问题表现
- **根因**：为什么会发生
- **影响面**：涉及哪些服务、哪些场景
- **修复方式**：具体怎么改的（代码锚点 + commit hash）
- **预防规则**：以后怎么避免再踩（可以变成 ArchUnit 规则 / CI 检查项吗？）
- **发现时间**：YYYY-MM-DD
```

## 增长控制

- 本文件硬上限 300 行
- 超过后必须压缩：3 个月前的条目且已有预防规则的，删除或合并到 `cross-cutting.md`
- 条目应从"具体事故"升级为"预防规则"，最终消失在 pitfalls.md

---

## 示例

### session 失效延迟导致越权

- **现象**：用户在 service-b 被降权后，30 秒内仍能通过 service-a 签发的旧 token 访问敏感接口
- **根因**：`user.profile.changed` 事件消费延迟 + service-a 本地缓存 TTL 未对齐
- **影响面**：所有依赖 session 做授权的接口
- **修复方式**：
  - service-b 在降权时额外发一个 `session.invalidate` 同步事件
  - service-a 将权限缓存 TTL 从 30s 降到 5s
  - 提交：`abc1234` (service-a), `def5678` (service-b)
- **预防规则**：授权相关的缓存 TTL ≤ 5s；写入 `cross-cutting.md` 的认证规范
- **发现时间**：2025-03-15

---

## 由 Agent 追加的条目

Agent 在任务中遇到新坑时可追加，但必须：
1. 写在 `## 由 Agent 追加的条目` 这个标题下
2. 条目末尾标注 `[agent: <task-id>]`
3. 必须经过人工 review 才能合入正式仓

### 示例（agent 草稿）

### [草稿] MQ 消费者默认线程池被打满

- **现象**：service-a 在批量处理 `user.profile.changed` 时，其他 MQ topic 消费停滞
- **根因**：多个 `@KafkaListener` 共用默认 `ConcurrentKafkaListenerContainerFactory`
- **修复方式**：为高吞吐 topic 单独配置独立 factory
- **预防规则**：任何新增 `@KafkaListener` 必须声明独立 factory
- [agent: task-2025-04-20-kafka-tuning]
