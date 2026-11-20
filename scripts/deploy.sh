#!/usr/bin/env bash
#
# Copyright (c) 2026 thorsphere.
# All Rights Reserved. Use is governed by the Functional Source License v1.1
# (FSL-1.1-ALv2) that can be found in the LICENSE file.
#
# Build the LibreChat image via Cloud Build and deploy it to Cloud Run.
# Used both locally and by .github/workflows/deploy.yml.
#
# App secrets live in Secret Manager (created per the README "One-time setup"
# section) and are attached to the service as env vars; nothing secret is baked
# into the image.
#
# Optional environment overrides:
#   GOOGLE_PROJECT_ID  current gcloud project
#   GOOGLE_REGION      us-central1
#   SERVICE            librechat
#   AR_REPO            librechat
#   IMAGE_NAME         librechat
#   TAG                git short SHA (fallback: timestamp)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

GOOGLE_PROJECT_ID="${GOOGLE_PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
GOOGLE_REGION="${GOOGLE_REGION:-us-central1}"
SERVICE="${SERVICE:-librechat}"
AR_REPO="${AR_REPO:-librechat}"
IMAGE_NAME="${IMAGE_NAME:-librechat}"
TAG="${TAG:-$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || date +%Y%m%d%H%M%S)}"
IMAGE="${GOOGLE_REGION}-docker.pkg.dev/${GOOGLE_PROJECT_ID}/${AR_REPO}/${IMAGE_NAME}:${TAG}"

echo "==> Building ${IMAGE}"
gcloud builds submit "$ROOT" \
  --project "$GOOGLE_PROJECT_ID" \
  --config="$ROOT/cloudbuild.yaml" \
  --substitutions="_IMAGE=${IMAGE}" \
  --quiet

echo "==> Deploying '${SERVICE}' to Cloud Run (${GOOGLE_REGION})"
gcloud run deploy "$SERVICE" \
  --project "$GOOGLE_PROJECT_ID" \
  --region "$GOOGLE_REGION" \
  --image "$IMAGE" \
  --platform=managed \
  --allow-unauthenticated \
  --port=8080 \
  --cpu=2 \
  --memory=2Gi \
  --concurrency=80 \
  --timeout=3600s \
  --startup-probe=httpGet.path=/health,periodSeconds=10,failureThreshold=30 \
  --set-secrets=MONGO_URI=librechat-mongo-uri:latest,\
CREDS_KEY=librechat-creds-key:latest,\
CREDS_IV=librechat-creds-iv:latest,\
JWT_SECRET=librechat-jwt-secret:latest,\
JWT_REFRESH_SECRET=librechat-jwt-refresh-secret:latest,\
OPENROUTER_API_KEY=librechat-openrouter-api-key:latest

URL="$(gcloud run services describe "$SERVICE" \
  --project "$GOOGLE_PROJECT_ID" --region "$GOOGLE_REGION" \
  --format='value(status.url)')"
echo "==> Deployed: ${URL}"
