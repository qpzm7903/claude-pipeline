# 仓库级 Agent 上下文

本目录是**仓库级**（根级）上下文，服务于"需要同时知道多个服务才能做的决策"。

## 硬约束

- ✅ 只写两个及以上服务都需要知道的内容
- ❌ 禁止写任何单一服务的内部实现细节（放到 `service-*/.agent-context/`）
- ❌ 禁止和服务级文档重复——有重复就是职责越界

## 本目录文件清单

| 文件 | 内容 | 必填 |
|------|------|------|
| service-map.md | 服务清单 + 一句话职责 + 代码路径 | ✅ |
| integration-contracts.md | 服务间接口/事件/共享数据的契约 | ✅ |
| cross-cutting.md | 认证/日志/配置/部署等横切关注点 | ✅ |
| shared-data.md | 共享数据库表/Redis key 的写入方与只读方 | 条件必填 |
| events.md | 消息队列事件的生产者/消费者/语义 | 条件必填 |
| pitfalls.md | 跨服务踩过的坑（由 agent 在失败时追加，人工 review 后合入） | ✅ |

## 对 Agent 的阅读顺序建议

1. service-map.md —— 先知道有哪些服务
2. integration-contracts.md —— 再知道它们怎么通
3. 按 task.yml 声明的 `primary_service` 进入对应的 `service-*/.agent-context/`
4. 按 task.yml 声明的 `read_only_services` 只读对应服务的 `api-contracts.md`

## 维护规则

- 每个文件硬上限 300 行，超过必须拆或压缩
- 每次 PR 修改根级文档，必须跑 `scripts/validate_context.py` 结构校验
- 所有字段必须有**代码锚点**（文件路径 + 行号或类全限定名），无锚点的条目判不合格
