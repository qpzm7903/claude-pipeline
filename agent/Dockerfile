# rust-claude-pipeline
#
# 基于 rust-claude（预装 Rust、构建工具、claude CLI 等），
# 仅追加 entrypoint 脚本，保持镜像层最小化。

FROM rust-claude:latest

USER root
COPY --chown=pipeline:pipeline entrypoint.sh /agent/entrypoint.sh
COPY --chown=pipeline:pipeline default-prompt.txt /agent/default-prompt.txt
COPY --chown=pipeline:pipeline repo-prompt-driven.txt /agent/repo-prompt-driven.txt
COPY --chown=pipeline:pipeline auto-iterate-prompt.txt /agent/auto-iterate-prompt.txt
COPY --chown=pipeline:pipeline lib/ /agent/lib/
RUN chmod +x /agent/entrypoint.sh /agent/lib/*.sh

RUN mkdir -p /home/pipeline/.claude && chown pipeline:pipeline /home/pipeline/.claude

USER pipeline
WORKDIR /workspace

ENTRYPOINT ["/agent/entrypoint.sh"]
