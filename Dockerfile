# syntax=docker/dockerfile:1
#
# Copyright (c) 2026 thorsphere.
# All Rights Reserved. Use is governed by the Functional Source License v1.1
# (FSL-1.1-ALv2) that can be found in the LICENSE file.
#
# LibreChat container image for Google Cloud Run (stateless, external MongoDB Atlas).
#
# Build:  docker build -t librechat-cloudrun .
# Run:    docker run --rm -p 8080:8080 --env-file .env librechat-cloudrun
#
# All state (users, conversations) lives in MongoDB Atlas via the MONGO_URI env
# var supplied at deploy time. Only non-secret config (librechat.yaml) is baked
# into the image; secrets are supplied at runtime.

ARG NODE_IMAGE=node:24-alpine

# ---------------------------------------------------------------------------
# Stage 1: build LibreChat (API + React client)
# ---------------------------------------------------------------------------
FROM ${NODE_IMAGE} AS build

# Pin the LibreChat release to build. Override with:
#   docker build --build-arg LIBRECHAT_VERSION=v0.8.9 .
ARG LIBRECHAT_VERSION=v0.8.9

# Heap size (MB) for the frontend build; raise it if the Vite build OOMs.
ARG NODE_MAX_OLD_SPACE_SIZE=4096

# Toolchain for npm packages with native (node-gyp) bindings.
RUN apk add --no-cache git python3 make g++

# Disable dependency-install analytics.
ENV SCARF_ANALYTICS=false

WORKDIR /src

# Shallow clone of the pinned LibreChat release. The shallow .git is kept so
# the app can resolve its version for Settings -> About.
RUN git clone --depth 1 --branch "${LIBRECHAT_VERSION}" \
      https://github.com/LibreChat-AI/LibreChat.git .

# Make npm resilient to flaky CI networks.
RUN npm config set fetch-retries 5 && \
    npm config set fetch-retry-mintimeout 15000 && \
    npm config set fetch-retry-maxtimeout 600000

# Full install (devDependencies included) because the client build needs Vite.
RUN npm ci --no-audit

# Build the workspace packages and the React client -> client/dist.
RUN NODE_OPTIONS="--max-old-space-size=${NODE_MAX_OLD_SPACE_SIZE}" npm run frontend

# Drop devDependencies and caches from the tree we ship.
RUN npm prune --omit=dev --no-audit --no-fund && npm cache clean --force

# ---------------------------------------------------------------------------
# Stage 2: lean runtime image
# ---------------------------------------------------------------------------
FROM ${NODE_IMAGE} AS runtime

# jemalloc keeps the memory footprint lower on Cloud Run's constrained instances.
RUN apk add --no-cache jemalloc
ENV LD_PRELOAD=/usr/lib/libjemalloc.so.2

WORKDIR /app

# Sources + pruned node_modules + built client (served by the API in production).
COPY --from=build /src /app

# Our config overrides LibreChat's defaults. LibreChat resolves
# <projectRoot>/librechat.yaml (or $CONFIG_PATH) inside the container.
# Must be secret-free: use ${ENV_VAR} references for credentials.
COPY --chown=node:node librechat.yaml /app/librechat.yaml

# Directories LibreChat writes to at runtime. The Cloud Run filesystem is
# ephemeral, so uploads/logs vanish with the instance; use an external
# fileStrategy (S3, OpenAI, etc.) in librechat.yaml if persistence matters.
RUN mkdir -p client/public/images logs uploads skill data && \
    chown -R node:node /app

USER node

# HOST must be 0.0.0.0 or the server only listens on loopback and Cloud Run
# health checks fail. PORT: Cloud Run injects PORT (default 8080) and
# LibreChat reads it; the default below only applies to local runs.
ENV NODE_ENV=production \
    HOST=0.0.0.0 \
    PORT=8080

EXPOSE 8080

# Handy for local runs; Cloud Run ignores HEALTHCHECK and uses its own probes.
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s \
    CMD wget -qO- "http://127.0.0.1:${PORT:-8080}/health" || exit 1

# Exec form (no npm wrapper) so SIGTERM from Cloud Run reaches node directly
# and the server can shut down gracefully.
CMD ["node", "api/server/index.js"]
