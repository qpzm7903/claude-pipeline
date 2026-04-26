# job-demo · 性能优化任务

## 项目上下文

仓库：https://github.com/qpzm7903/job-demo
当前状态：v0.5.x（OAuth2 授权服务器，含完整测试基线）。

## 黄金法则（红线）

- **先测量，后优化** —— 没有测量数据就不优化（猜测式优化一律拒绝）
- **所有现有测试必须通过** —— 不能因优化破坏功能
- **Public API 不变** —— 端点路径、方法、响应结构不变
- **每轮一个优化点** —— 不允许同时改多处

## 候选优化点（按优先级）

### P1：`GET /oauth2/jwks` 加 HTTP 缓存头
- 动机：JWK 公钥极少变更（密钥轮转按天/周），但所有 token 校验方都频繁拉取
- 硬指标：
  - 响应必须带 `Cache-Control: public, max-age=3600`、`Vary: Accept`
  - 其他 OAuth2 端点（`/oauth2/token`、`/oauth2/authorize`）**禁止**加缓存头
- 新增测试：
  - `test_jwks_endpoint_hasCacheControlHeader`：断言 max-age >= 600
  - `test_token_endpoint_hasNoCacheHeader`：断言 `/oauth2/token` 无 public 缓存

### P2：集成 Spring Boot Actuator + Micrometer
- 暴露 `/actuator/prometheus` 端点（仅在内网，需 client_credentials 鉴权）
- 关键指标：HTTP 响应时间、JVM 内存、线程池
- 不引入任何外部时序库（in-memory registry 即可）

### P3：H2 索引优化（仅在 v0.6+ 引入持久化时考虑）
- 检查 `oauth2_authorization` 表的查询路径
- 给高频 WHERE 字段加索引

## 每轮严格流程

### 1. Baseline
```
mvn test > /tmp/baseline.log 2>&1; echo "EXIT=$?" >> /tmp/baseline.log; tail -5 /tmp/baseline.log
```
EXIT≠0 → 本轮目标改为"修复基线"，用 `fix(test): ...` 提交，**不**做优化。

### 2. 测量（Plan）
输出决策块：
```
## 决策: 优化 <目标>
- 瓶颈: <定位到的瓶颈>
- 数据: <基线测量结果，例如 mvn test 耗时、端点响应头当前状态>
- 方案: <具体做法>
- 预期: <可量化的改善目标>
```

### 3. 实现
- 优先用 Spring 内建机制（`WebMvcConfigurer`、`HandlerInterceptor`）
- 禁止引入重量级依赖（Redis / Caffeine / Guava cache）
- 禁止改 Security Filter Chain 的排序或类型

### 4. 新增测试
覆盖优化的关键断言（如 P1 的两个 header 测试）。

### 5. 验证 + Commit
```
mvn test > /tmp/after.log 2>&1; echo "EXIT=$?" >> /tmp/after.log; tail -10 /tmp/after.log
```
EXIT=0 → `perf(<范围>): <描述>` 简体中文 + push
EXIT≠0 → `git checkout -- .` 回滚，提交 `docs(perf): 优化尝试说明` 附原因（200 字内）

### 6. 量化效果
commit message 末尾或 PR 描述需写明：
```
## 优化效果
- 优化前: <数据>
- 优化后: <数据>
- 改善: <百分比 或 定性描述>
```

## Commit 规范（红线）

- `perf(<范围>): <描述>` 简体中文
- **严禁** AI 署名（`Co-Authored-By: Claude` / `Written by AI`）
- 不附 `Signed-off-by`
- git 用户：默认（已配置为 qpzm7903）

## 禁止事项

- 禁止以牺牲代码可读性为代价做微优化
- 禁止改 Security Filter Chain 排序（容易破坏授权流）
- 禁止升主版本号（最多 PATCH）
- 禁止引入新的重量级依赖（Redis / Caffeine 等）

## 收敛

- 连续 1 轮无 commit（`MAX_NOCHANGE=1`）→ 视为完成
- 或达到 `MAX_ITERATIONS=3`
