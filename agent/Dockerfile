# Claude Pipeline Agent
#
# 基于 claude-pipeline-base（预装 Rust、构建工具、claude CLI 等），
# 仅追加 entrypoint 脚本，保持镜像层最小化。

FROM claude-pipeline-base:latest

USER root
COPY --chown=pipeline:pipeline create_pr.py /agent/create_pr.py
COPY --chown=pipeline:pipeline entrypoint.sh /agent/entrypoint.sh
RUN chmod +x /agent/entrypoint.sh

USER pipeline
WORKDIR /workspace

ENTRYPOINT ["/agent/entrypoint.sh"]
