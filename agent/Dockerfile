# Claude Pipeline Agent 执行环境
#
# 包含:
#   - Node.js 20 LTS（用于安装 claude CLI）
#   - Python 3.11（辅助脚本运行环境）
#   - git（代码克隆和提交）
#   - claude CLI（@anthropic-ai/claude-code）

FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1
ENV NODE_VERSION=20

# 设置 SHELL 以便 pipefail 生效（hadolint DL4006）
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# 安装系统依赖（--no-install-recommends 减小镜像体积）
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    git \
    python3.11 \
    python3.11-venv \
    python3-pip \
    ca-certificates \
    gnupg \
    && rm -rf /var/lib/apt/lists/*

# 设置 python3 为默认
RUN update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.11 1 && \
    update-alternatives --install /usr/bin/python python /usr/bin/python3.11 1

# 安装 Node.js 20（通过 nodesource，apt-get 版本已由 setup 脚本固定）
RUN curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash - && \
    apt-get install -y --no-install-recommends nodejs && \
    rm -rf /var/lib/apt/lists/*

# 安装 claude CLI（始终使用最新版，intentionally unpinned）
# hadolint ignore=DL3016
RUN npm install -g @anthropic-ai/claude-code

# 创建非 root 用户（claude CLI 拒绝以 root 身份运行 --dangerously-skip-permissions）
RUN useradd -m -s /bin/bash pipeline && \
    mkdir -p /workspace /agent && \
    chown -R pipeline:pipeline /workspace /agent

COPY --chown=pipeline:pipeline create_pr.py /agent/create_pr.py
COPY --chown=pipeline:pipeline entrypoint.sh /agent/entrypoint.sh

RUN chmod +x /agent/entrypoint.sh

USER pipeline
WORKDIR /workspace

ENTRYPOINT ["/agent/entrypoint.sh"]
