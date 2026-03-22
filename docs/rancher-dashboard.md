# Rancher Dashboard 部署文档

## 概述

Rancher 是一个开源的 Kubernetes 管理平台，提供强大的 Web UI 来管理多个 K8s 集群。

## 环境信息

| 项目 | 值 |
|------|------|
| 集群类型 | Docker Desktop Kubernetes |
| K8s 版本 | v1.34.1 |
| Rancher 版本 | latest (stable) |
| cert-manager 版本 | v1.14.5 |
| Ingress Controller | nginx |

## 部署步骤

### 1. 添加 Helm 仓库

```bash
helm repo add rancher-stable https://releases.rancher.com/server-charts/stable
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
```

### 2. 安装 cert-manager

Rancher 依赖 cert-manager 来管理 TLS 证书：

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.5/cert-manager.yaml

# 等待 cert-manager 就绪
kubectl wait --for=condition=Available deployment/cert-manager -n cert-manager --timeout=120s
kubectl wait --for=condition=Available deployment/cert-manager-webhook -n cert-manager --timeout=60s
```

### 3. 安装 nginx Ingress Controller

```bash
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.service.type=LoadBalancer
```

### 4. 安装 Rancher

```bash
helm install rancher rancher-stable/rancher \
  --namespace cattle-system \
  --create-namespace \
  --set hostname=rancher.localhost \
  --set bootstrapPassword=admin123 \
  --set replicas=1 \
  --set ingress.tls.source=rancher \
  --set global.cattle.psp.enabled=false
```

### 5. 配置 Ingress

```bash
kubectl annotate ingress rancher -n cattle-system kubernetes.io/ingress.class=nginx --overwrite
```

### 6. 配置 hosts (可选)

```bash
sudo sh -c 'echo "127.0.0.1 rancher.localhost" >> /etc/hosts'
```

## 访问方式

### 方式一：Port-forward (推荐测试使用)

```bash
kubectl port-forward svc/rancher -n cattle-system 8443:443
```

访问地址: https://localhost:8443

### 方式二：Ingress (需要配置 hosts)

1. 确保 hosts 文件包含:
   ```
   127.0.0.1 rancher.localhost
   ```

2. 访问地址: https://rancher.localhost

## 登录信息

| 字段 | 值 |
|------|------|
| 用户名 | `admin` |
| 初始密码 | `admin123` |

首次登录后需要设置新密码。

## 常用命令

```bash
# 查看 Rancher 状态
kubectl get all -n cattle-system

# 查看 Rancher 日志
kubectl logs -f deployment/rancher -n cattle-system

# 查看 Ingress 状态
kubectl get ingress -n cattle-system

# 查看 cert-manager 状态
kubectl get all -n cert-manager

# Port-forward 访问
kubectl port-forward svc/rancher -n cattle-system 8443:443

# 获取 bootstrap 密码
kubectl get secret --namespace cattle-system bootstrap-secret -o go-template='{{.data.bootstrapPassword|base64decode}}{{ "\n" }}'
```

## 卸载

```bash
# 删除 Rancher
helm uninstall rancher -n cattle-system
kubectl delete namespace cattle-system --ignore-not-found=true

# 删除 Ingress Controller
helm uninstall ingress-nginx -n ingress-nginx
kubectl delete namespace ingress-nginx --ignore-not-found=true

# 删除 cert-manager
kubectl delete -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.5/cert-manager.yaml
kubectl delete namespace cert-manager --ignore-not-found=true
```

## 部署资源汇总

| 组件 | Namespace | 说明 |
|------|-----------|------|
| cert-manager | cert-manager | TLS 证书管理 |
| ingress-nginx | ingress-nginx | Ingress 控制器 |
| rancher | cattle-system | Rancher Dashboard |

## 注意事项

1. **Docker Desktop K8s**: 使用 `LoadBalancer` 类型 Service 会自动分配 `localhost` 作为外部 IP
2. **密码安全**: 生产环境请使用强密码
3. **证书**: 默认使用 Rancher 自签名证书，浏览器会提示不安全
4. **资源占用**: Rancher 及依赖组件约占用 1-2GB 内存

## 参考链接

- [Rancher 官方文档](https://rancher.com/docs/)
- [Rancher Helm Chart](https://github.com/rancher/rancher)
- [cert-manager](https://cert-manager.io/)
- [ingress-nginx](https://kubernetes.github.io/ingress-nginx/)