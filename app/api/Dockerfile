# syntax=docker/dockerfile:1

# ---- Stage 1: install dependencies into a virtualenv ----
FROM python:3.15-slim@sha256:65a65fc7b30b06cb6df4930fd4650697cb23f4c2698ab81fc87e4b031bc36928 AS deps
ENV PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_NO_CACHE_DIR=1
COPY requirements.txt /tmp/requirements.txt
RUN python -m venv /opt/venv \
    && /opt/venv/bin/pip install --require-hashes -r /tmp/requirements.txt \
    && /opt/venv/bin/pip uninstall --yes pip

# ---- Stage 2: runtime image with only the virtualenv and the code ----
FROM python:3.15-slim@sha256:65a65fc7b30b06cb6df4930fd4650697cb23f4c2698ab81fc87e4b031bc36928 AS runtime
RUN groupadd --gid 10001 app \
    && useradd --uid 10001 --gid 10001 --no-create-home --shell /usr/sbin/nologin app \
    && rm -rf /usr/local/lib/python3.13/site-packages/pip* /usr/local/bin/pip*
ENV PATH="/opt/venv/bin:$PATH" PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
WORKDIR /app
COPY --from=deps /opt/venv /opt/venv
COPY leadpipe_api ./leadpipe_api
# A numeric user lets Kubernetes verify runAsNonRoot.
USER 10001:10001
EXPOSE 8000
HEALTHCHECK --interval=15s --timeout=3s --start-period=10s --retries=3 \
    CMD ["python", "-c", "import urllib.request as u; u.urlopen('http://127.0.0.1:8000/healthz', timeout=2)"]
CMD ["uvicorn", "--factory", "leadpipe_api.main:create_app", "--host", "0.0.0.0", "--port", "8000", "--no-access-log"]
