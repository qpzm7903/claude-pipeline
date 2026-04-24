# 服务内踩坑记录

**本服务内部**踩过的坑。跨服务的坑放根级 `repo-root/.agent-context/pitfalls.md`。

## 条目格式

```
### <一句话坑名>

- **现象**：问题表现
- **根因**：为什么会发生
- **修复方式**：具体怎么改的（代码锚点 + commit hash）
- **预防规则**：以后怎么避免（ArchUnit / 静态检查 / 代码 review 清单）
- **发现时间**：YYYY-MM-DD
```

## 增长控制

- 本文件硬上限 300 行
- 条目应逐步"上升"：具体事故 → 预防规则 → 写入 `cross-cutting.md` 后从此处删除
- 超过 3 个月未复发且已有预防规则的条目，删除

---

## 示例

### 登录超时未对齐导致连锁超时

- **现象**：service-a 登录接口 P99 从 300ms 飙升到 2s
- **根因**：调用 service-b 的 `getProfile` 未设置独立超时，走了全局默认 2s
- **修复方式**：`HttpClientConfig#userServiceClient` 显式设置 connectTimeout=200ms / readTimeout=500ms；提交 `abc1234`
- **预防规则**：所有 `@FeignClient` 或 RestTemplate bean 必须显式设置超时；在 `cross-cutting.md` 的失败处理规范中新增此条
- **发现时间**：2025-03-20

---

## 由 Agent 追加的条目

（agent 在失败时追加到此标题下，条目末尾标 `[agent: <task-id>]`，人工 review 后决定去留）
