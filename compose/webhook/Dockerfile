# =====================================================================
# FORGE-AI webhook receiver (Gitea -> Semaphore)
# =====================================================================
FROM python:3.12.7-alpine3.20

LABEL org.opencontainers.image.title="forge-webhook" \
      org.opencontainers.image.description="HMAC-validating Gitea webhook receiver that starts Semaphore tasks" \
      org.opencontainers.image.source="https://github.com/danielesalpietro/FORGE-AI" \
      org.opencontainers.image.licenses="Apache-2.0"

RUN addgroup -g 10002 -S forge \
 && adduser  -u 10002 -S -G forge -h /nonexistent -s /sbin/nologin forge \
 && apk add --no-cache curl=~8

WORKDIR /app
COPY --chown=root:root app.py /app/app.py
RUN chmod 0444 /app/app.py

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    FORGE_LISTEN_PORT=8000

USER forge
EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD curl -fsS "http://127.0.0.1:${FORGE_LISTEN_PORT}/healthz" || exit 1

ENTRYPOINT ["python3", "/app/app.py"]
