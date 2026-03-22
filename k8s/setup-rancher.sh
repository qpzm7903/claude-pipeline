#!/bin/bash
set -euo pipefail

echo "=== Rancher Dashboard 安装脚本 ==="
echo ""

HELM_VERSION="v3.14.0"
CERT_MANAGER_VERSION="v1.14.5"
RANCHER_PASSWORD="${RANCHER_PASSWORD:-admin123}"

command -v helm &>/dev/null || {
    echo "❌ 需要安装 Helm: brew install helm"
    exit 1
}

command -v kubectl &>/dev/null || {
    echo "❌ 需要安装 kubectl: brew install kubectl"
    exit 1
}

echo "[1/4] 添加 Helm 仓库..."
helm repo add rancher-stable https://releases.rancher.com/server-charts/stable 2>/dev/null || true
helm repo add jetstack https://charts.jetstack.io 2>/dev/null || true
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
helm repo update

echo "[2/4] 安装 cert-manager..."
kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml" --server-side --force-conflicts 2>/dev/null || true
kubectl wait --for=condition=Available deployment/cert-manager -n cert-manager --timeout=120s 2>/dev/null || true
kubectl wait --for=condition=Available deployment/cert-manager-webhook -n cert-manager --timeout=60s 2>/dev/null || true

echo "[3/4] 安装 nginx Ingress Controller..."
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
    --namespace ingress-nginx \
    --create-namespace \
    --set controller.service.type=LoadBalancer \
    --wait 2>/dev/null || true

echo "[4/4] 安装 Rancher..."
helm upgrade --install rancher rancher-stable/rancher \
    --namespace cattle-system \
    --create-namespace \
    --set hostname=rancher.localhost \
    --set bootstrapPassword="${RANCHER_PASSWORD}" \
    --set replicas=1 \
    --set ingress.tls.source=rancher \
    --set global.cattle.psp.enabled=false \
    --wait

kubectl wait --for=condition=Ready pod -l app=rancher -n cattle-system --timeout=300s 2>/dev/null || true

echo ""
echo "=== 安装完成 ==="
echo ""
echo "访问方式:"
echo "  Port-forward: kubectl port-forward svc/rancher -n cattle-system 8443:443"
echo "  访问地址:     https://localhost:8443"
echo ""
echo "登录信息:"
echo "  用户名: admin"
echo "  密码:   ${RANCHER_PASSWORD}"
echo ""
echo "添加 hosts 记录后可直接通过域名访问:"
echo "  sudo sh -c 'echo \"127.0.0.1 rancher.localhost\" >> /etc/hosts'"
echo "  https://rancher.localhost"