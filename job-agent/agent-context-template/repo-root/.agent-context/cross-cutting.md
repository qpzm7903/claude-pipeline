# 横切关注点

所有服务共同遵守、但实现分散的规则。**agent 修改任何服务都必须遵守这些**。

## 分类

### 1. 认证与授权
- 认证方式：JWT / Session / OAuth2（填你的实际选择）
- Token 签发方：哪个服务、什么算法、多久过期
- Token 校验点：网关 / 每个服务各自校验
- 权限模型：RBAC / ABAC / 混合
- 代码锚点：`common-security/` 模块路径

### 2. 日志规范
- 日志框架：Logback / Log4j2
- 日志级别约定：TRACE/DEBUG/INFO/WARN/ERROR 各自的使用场景
- 必填字段：traceId / userId / 业务 ID
- 敏感信息脱敏规则：手机号、身份证、token 的处理方式
- ❌ 禁止：`log.info("result = " + obj)`（拼字符串）、`e.printStackTrace()`

### 3. 异常处理
- 统一异常基类：`BaseBusinessException` 路径
- 异常码规范：`<service>-<category>-<code>` 格式
- 全局异常处理器：`@RestControllerAdvice` 所在类

### 4. 配置管理
- 配置源：Spring Cloud Config / Nacos / Apollo / application.yml
- 环境划分：dev / test / staging / prod
- 敏感配置处理：是否走 Vault / KMS
- ❌ 禁止：密码、token 硬编码或进 git

### 5. 构建与部署
- 构建命令：`mvn clean package -am -T1C ...`（从项目 CLAUDE.md 复制）
- JDK 版本：17
- Spring Boot 版本：3.x
- 镜像基础：哪个基础镜像
- K8s 部署拓扑：单 Deployment / StatefulSet

### 6. 分支与发布
- 主干分支：main / master
- 开发分支规则：feature/* / bugfix/* / release/*
- Agent 开发分支规则：`agent/<task-id>/<任务简述>`

---

## ❌ 反例

- ❌ "统一使用日志" —— 没有规范，约等于没写
- ❌ 罗列一堆工具名但不说"在哪用、怎么用"
