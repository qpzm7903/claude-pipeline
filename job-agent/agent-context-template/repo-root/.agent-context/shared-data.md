# 共享数据资产

**条件必填**：当两个及以上服务共享同一张数据表 / 同一个 Redis key 命名空间 / 同一份文件存储时，必须登记。

## 为什么这份文档重要

共享数据是跨服务事故的头号来源：
- A 服务改了表结构没通知 B，B 服务崩溃
- A 写入格式变了，B 消费端反序列化失败
- A 和 B 都在写同一张表，无人负责最终一致性

## 字段规范

每条共享数据资产必须填：
- `资产`：表名 / key 前缀 / 路径
- `存储`：MySQL 实例 / Redis cluster / OSS bucket
- `写入方`：只能有**一个**服务（多写必须显式标为"多写，有锁保护"并说明锁机制）
- `只读方`：可以多个
- `Schema/格式定义位置`：指向 DDL 文件或实体类
- `变更流程`：谁可以改、怎么通知只读方

---

## 示例

### 表 `user_profile`（示例 ✅）

- **存储**：MySQL `user_db`
- **写入方**：service-b（唯一）
- **只读方**：service-a（只读 `id, display_name, status`）
- **Schema**：`service-b/src/main/java/.../entity/UserProfile.java` + `service-b/src/main/resources/db/migration/V1__init.sql`
- **变更流程**：
  1. service-b 提 PR 时必须在 PR 描述里 @service-a 的 owner
  2. 新增字段免协商；删字段/改字段必须先走一个版本的 `@Deprecated`
  3. 禁止 service-a 写入该表

### Redis key `session:*`（示例 ✅）

- **存储**：Redis cluster `cache-01`
- **写入方**：service-a（唯一）
- **只读方**：service-b（只读用于鉴权检查）
- **格式**：JSON，字段定义位于 `service-a/src/main/java/.../SessionData.java`
- **TTL**：30 分钟
- **变更流程**：字段只增不删，删除字段走 `@Deprecated` + 一个版本过渡期

---

## ❌ 反例

- ❌ "两个服务都会写 order 表" —— 没说谁是主写、没说锁机制
- ❌ 没有 Schema 锚点 —— agent 无法知道字段定义
