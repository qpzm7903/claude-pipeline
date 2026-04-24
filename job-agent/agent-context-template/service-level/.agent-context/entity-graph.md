# 实体关系图（服务内）

本服务的核心领域实体 + 关系。**骨架由 `scripts/extract_*.py` 自动生成，业务语义必须人工补**。

## 分治策略（JPA + MyBatis）

本仓库双 ORM 混用：
- **JPA 部分**：`scripts/extract_jpa_entities.py` 扫描 `@Entity` + 关系注解（`@OneToMany` 等），自动生成骨架
- **MyBatis 部分**：`scripts/extract_mybatis_mappers.py` 扫描 `@Mapper` + `*Mapper.xml`，生成 Mapper 清单（**不自动推导实体关系**，必须人工补——MyBatis 的关系藏在 SQL 里，自动提取不可靠）

## 字段规范

每个实体必须填：
- `实体名`（Java 类名）
- `对应表名`
- `ORM`：JPA / MyBatis
- `代码锚点`：类全限定名
- `业务含义`：**必须人工补**（≤2 行）
- `核心字段`：只列业务关键字段，不列审计字段（created_at 这类）
- `关系`：与其他实体的关联（1:1 / 1:N / N:M）+ 业务含义
- `唯一索引/约束`：业务层面的唯一性约束
- `生命周期`：何时创建、何时归档/软删除

---

## 示例（JPA 实体，人工补全后）

### UserProfile（示例 ✅）

- **表名**：`user_profile`
- **ORM**：JPA
- **代码锚点**：`com.example.user.entity.UserProfile`
- **业务含义**：用户的档案主记录，登录之外所有用户相关信息的唯一真源
- **核心字段**：
  - `id`：主键
  - `displayName`：展示名，可修改
  - `orgUnitId`：归属组织（外键 → OrgUnit）
  - `status`：ACTIVE / DOWNGRADED / DISABLED
  - `role`：权限角色
- **关系**：
  - N:1 → OrgUnit（一个用户归属一个组织单元）
  - 1:N → UserAuditLog（用户档案变更审计）
- **唯一索引**：`(tenantId, externalId)` —— 跨租户唯一
- **生命周期**：注册时创建；disable 后保留 90 天归档

---

## 示例（MyBatis 实体，人工补全后）

### OrderItem（示例 ✅）

- **表名**：`order_item`
- **ORM**：MyBatis
- **代码锚点**：`com.example.order.entity.OrderItem` + `com.example.order.mapper.OrderItemMapper`
- **XML 锚点**：`src/main/resources/mapper/OrderItemMapper.xml`
- **业务含义**：订单明细行，一个订单对应多个明细
- **核心字段**：`id`、`orderId`、`productId`、`quantity`、`unitPrice`
- **关系**：
  - N:1 → Order（XML 中通过 `orderId` 关联，**不是外键约束，仅业务层关联**）
- **唯一索引**：`(orderId, productId)`
- **生命周期**：下单时创建；订单关闭 180 天后归档到历史表

---

## 自动生成区（由脚本维护，**人工禁改此区**）

<!-- BEGIN AUTO-GENERATED -->
<!-- 运行 scripts/generate_entity_graph.sh 刷新 -->
<!-- END AUTO-GENERATED -->

## 人工增补区（业务语义，**脚本禁改此区**）

<!-- BEGIN HUMAN-CURATED -->
<!-- 在此区补充业务含义、关系、生命周期 -->
<!-- END HUMAN-CURATED -->

---

## ❌ 反例

- ❌ 只列字段名不写业务含义 —— 等于 `desc table` 输出
- ❌ 人工区和自动区混写 —— 下次刷新会冲突
- ❌ MyBatis 实体没有 XML 锚点 —— agent 无法找到 SQL
