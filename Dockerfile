# syntax=docker/dockerfile:1.7

# ----- STAGE 1: Build Vue frontend -----
FROM node:22-alpine AS frontend-builder

WORKDIR /app/frontend

COPY frontend/Vue/package*.json ./
RUN npm ci --no-audit --no-fund

COPY frontend/Vue/ ./
RUN npm run build

# ----- STAGE 2: Python runtime -----
FROM python:3.13-slim AS backend

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    LANG=de_DE.UTF-8 \
    LANGUAGE=de_DE:de \
    LC_ALL=de_DE.UTF-8 \
    TZ=Europe/Berlin

RUN apt-get update \
 && apt-get install -y --no-install-recommends locales tzdata curl tini \
 && sed -i '/de_DE.UTF-8/s/^# //g' /etc/locale.gen \
 && locale-gen \
 && ln -sf /usr/share/zoneinfo/Europe/Berlin /etc/localtime \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

# non-root user
RUN groupadd --system --gid 1000 app \
 && useradd --system --uid 1000 --gid app --create-home --shell /bin/bash app

WORKDIR /app

COPY backend/requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY --chown=app:app backend/ /app/backend/
COPY --from=frontend-builder --chown=app:app /app/frontend/dist /app/backend/static/

WORKDIR /app/backend

USER app

ENV FLASK_APP=app.py \
    PYTHONPATH=/app/backend \
    HOST=0.0.0.0 \
    PORT=8080

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD curl --fail --silent http://127.0.0.1:8080/api/health || exit 1

ENTRYPOINT ["/usr/bin/tini", "--"]

# NOTE: exactly ONE worker on purpose – the in-process APScheduler and the
# SSE pub/sub registry are process-local. Multiple workers would duplicate
# every upstream fetch (FritzBox lockout / OpenWeather rate-limit) and split
# the SSE subscriber set. Scale via threads, not workers.
CMD ["gunicorn", \
     "--bind", "0.0.0.0:8080", \
     "--workers", "1", \
     "--threads", "8", \
     "--timeout", "60", \
     "--access-logfile", "-", \
     "--error-logfile", "-", \
     "app:app"]
