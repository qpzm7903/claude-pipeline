# Orchestrator 服务镜像
FROM python:3.11-slim

WORKDIR /app

RUN apt-get update && apt-get install -y git && rm -rf /var/lib/apt/lists/*

# 安装 Python 依赖
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# 复制源码
COPY orchestrator/ ./orchestrator/
COPY config/ ./config/

CMD ["python", "-m", "orchestrator.main"]
