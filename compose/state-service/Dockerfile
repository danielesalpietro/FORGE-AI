# =====================================================================
# FORGE-AI provisioning state service
# =====================================================================
# Standard library only: no pip install, so there is no dependency
# surface to scan or patch beyond the base image itself.
# Digest-pinning the base image is the production recommendation; the
# PoC pins the tag so `make bootstrap` works on a fresh host without a
# registry lookup. See docs/SECURITY.md.
FROM python:3.12.7-alpine3.20

LABEL org.opencontainers.image.title="forge-state" \
      org.opencontainers.image.description="FORGE-AI provisioning state and iPXE dispatch service" \
      org.opencontainers.image.source="https://github.com/danielesalpietro/FORGE-AI" \
      org.opencontainers.image.licenses="Apache-2.0"

# Run unprivileged. UID/GID 10001 is fixed so the bind-mounted state
# directory can be chowned to a known owner by the Ansible role.
RUN addgroup -g 10001 -S forge \
 && adduser  -u 10001 -S -G forge -h /nonexistent -s /sbin/nologin forge \
 && apk add --no-cache curl=~8

WORKDIR /app
COPY --chown=root:root app.py /app/app.py
RUN chmod 0444 /app/app.py

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    FORGE_STATE_DIR=/srv/state \
    FORGE_LOG_DIR=/srv/logs \
    FORGE_REGISTRY=/srv/state/registry.json \
    FORGE_LISTEN_PORT=8090

USER forge
EXPOSE 8090

HEALTHCHECK --interval=20s --timeout=5s --start-period=10s --retries=3 \
  CMD curl -fsS "http://127.0.0.1:${FORGE_LISTEN_PORT}/healthz" || exit 1

ENTRYPOINT ["python3", "/app/app.py"]
