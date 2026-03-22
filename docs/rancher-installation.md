# Rancher Dashboard 安装指南

本文档记录在 Docker Desktop Kubernetes 环境中安装 Rancher Dashboard 的完整步骤。

## 环境要求

- Docker Desktop with Kubernetes enabled
- Helm 3.x
- kubectl

## 安装步骤

### 1. 安装 Helm（如未安装）

```bash
brew install helm
```

### 2. 添加 Helm 仓库

```bash
# 添加 Rancher 仓库
helm repo add rancher-stable https://releases.rancher.com/server-charts/stable

# 添加 cert-manager 仓库（Rancher 依赖）
helm repo add jetstack https://charts.jetstack.io

# 更新仓库
helm repo update
```

### 3. 安装 cert-manager

Rancher 需要 cert-manager 来管理 TLS 证书。

```bash
# 创建命名空间
kubectl create namespace cert-manager

# 安装 cert-manager
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --set crds.enabled=true
```

验证安装：

```bash
kubectl get pods -n cert-manager
```

### 4. 安装 Rancher

```bash
# 创建命名空间
kubectl create namespace cattle-system

# 安装 Rancher
helm install rancher rancher-stable/rancher \
  --namespace cattle-system \
  --set hostname=rancher.local \
  --set bootstrapPassword=admin \
  --set replicas=1
```

参数说明：
- `hostname=rancher.local`：Rancher 访问域名（本地开发环境可用任意域名）
- `bootstrapPassword=admin`：初始管理员密码
- `replicas=1`：单副本部署（生产环境建议 3 副本）

验证安装：

```bash
kubectl get pods -n cattle-system
```

等待所有 Pod 状态为 `Running`。

### 5. 配置访问方式

#### 方式一：Port-Forward（推荐本地开发）

```bash
# 前台运行
kubectl port-forward svc/rancher -n cattle-system 8443:443

# 或后台运行
nohup kubectl port-forward svc/rancher -n cattle-system 8443:443 > /tmp/rancher-portforward.log 2>&1 &
```

访问地址：https://localhost:8443

#### 方式二：NodePort

```bash
# 将 Service 类型改为 NodePort
kubectl patch svc rancher -n cattle-system -p '{"spec": {"type": "NodePort"}}'

# 查看分配的端口
kubectl get svc rancher -n cattle-system
```

访问地址：https://localhost:<NodePort-443>

### 6. 登录 Rancher

- 访问地址：https://localhost:8443
- 用户名：`admin`
- 密码：`admin`（首次登录会提示修改密码）

> ⚠️ 浏览器会提示证书不受信任，点击"高级" → "继续前往 localhost"即可。

## 常用命令

```bash
# 查看 Rancher 状态
kubectl get pods -n cattle-system

# 查看 Rancher 日志
kubectl logs -n cattle-system -l app=rancher

# 查看 bootstrap 密码
kubectl get secret --namespace cattle-system bootstrap-secret -o go-template='{{.data.bootstrapPassword|base64decode}}{{ "\n" }}'

# 卸载 Rancher
helm uninstall rancher -n cattle-system
helm uninstall cert-manager -n cert-manager
kubectl delete namespace cattle-system cert-manager
```

## 故障排除

### Pod 一直处于 ContainerCreating 状态

```bash
# 检查事件
kubectl describe pod -n cattle-system -l app=rancher

# 检查镜像拉取
docker pull rancher/rancher:latest
```

### 证书错误

Rancher 使用自签名证书，浏览器会警告。对于本地开发环境可以忽略。生产环境应配置正确的 TLS 证书。

### 无法访问

1. 确认 port-forward 正在运行：
   ```bash
   ps aux | grep port-forward
   ```

2. 确认 Rancher Pod 正常：
   ```bash
   kubectl get pods -n cattle-system
   ```

3. 检查端口是否被占用：
   ```bash
   lsof -i :8443
   ```

## 参考资料

- [Rancher 官方文档](https://rancher.com/docs/)
- [Rancher Helm Chart](https://github.com/rancher/rancher/blob/master/chart/README.md)
- [cert-manager 文档](https://cert-manager.io/docs/)