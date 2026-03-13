# Claude Pipeline Agent 执行环境
#
# 包含:
#   - Node.js 20 LTS（用于安装 claude CLI）
#   - Python 3.11（task_runner.py 运行环境）
#   - git（代码克隆和提交）
#   - claude CLI（@anthropic-ai/claude-code）

FROM ubuntu:22.04

# 避免交互式提示
ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1
ENV NODE_VERSION=20

# 安装系统依赖
RUN apt-get update && apt-get install -y \
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

# 安装 Node.js 20
RUN curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash - && \
    apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/*

# 安装 claude CLI（全局）
RUN npm install -g @anthropic-ai/claude-code

# 创建非 root 用户（claude CLI 拒绝以 root 身份运行 --dangerously-skip-permissions）
RUN useradd -m -s /bin/bash pipeline && \
    mkdir -p /workspace /agent && \
    chown -R pipeline:pipeline /workspace /agent

# 复制 agent 脚本
COPY --chown=pipeline:pipeline create_pr.py /agent/create_pr.py
COPY --chown=pipeline:pipeline entrypoint.sh /agent/entrypoint.sh

RUN chmod +x /agent/entrypoint.sh

USER pipeline
WORKDIR /workspace

ENTRYPOINT ["/agent/entrypoint.sh"]
