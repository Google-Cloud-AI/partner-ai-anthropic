#!/bin/bash
# Copyright 2026 The "Anthropic on Google Cloud" Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Vogue Concierge — deploy the React UI + FastAPI server to Cloud Run.
#
# This service serves the Next.js frontend and relays chat to Agent Runtime. The
# agents themselves are deployed separately with `python deploy_agent_engine.py`,
# which prints the AGENT_ENGINE_ID you pass in below.
#
# Auth note: Claude runs on Agent Platform via the service account's ADC — there is no
# Anthropic API key to set here.

set -e

PROJECT_ID="${VERTEXAI_PROJECT:?Set VERTEXAI_PROJECT to your GCP project id (see README)}"
PROJECT_NUMBER="${PROJECT_NUMBER:?Set PROJECT_NUMBER to your GCP project number (see README)}"
REGION="us-central1"
SERVICE_NAME="vogue-concierge"
IMAGE="gcr.io/${PROJECT_ID}/${SERVICE_NAME}"

# The Agent Engine ID printed by deploy_agent_engine.py. Export it before running,
# e.g.  AGENT_ENGINE_ID=1234567890 ./deploy.sh
AGENT_ENGINE_ID="${AGENT_ENGINE_ID:-}"

echo "=== Vogue Concierge — Cloud Run Deploy (UI) ==="
echo "Project: ${PROJECT_ID} | Region: ${REGION} | Service: ${SERVICE_NAME}"
echo "Agent Engine ID: ${AGENT_ENGINE_ID:-<not set>}"
echo ""

echo "Step 1: Building container image..."
gcloud builds submit --tag "${IMAGE}" --project "${PROJECT_ID}" --timeout=600

echo ""
echo "Step 2: Deploying to Cloud Run..."
gcloud run deploy "${SERVICE_NAME}" \
  --image "${IMAGE}" \
  --region "${REGION}" \
  --project "${PROJECT_ID}" \
  --platform managed \
  --allow-unauthenticated \
  --memory 2Gi \
  --cpu 2 \
  --timeout 120 \
  --min-instances 0 \
  --max-instances 3 \
  --set-env-vars "VERTEXAI_PROJECT=${PROJECT_ID}" \
  --set-env-vars "PROJECT_NUMBER=${PROJECT_NUMBER}" \
  --set-env-vars "AGENT_ENGINE_ID=${AGENT_ENGINE_ID}" \
  --service-account "${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

echo ""
echo "Step 3: Getting service URL..."
URL=$(gcloud run services describe "${SERVICE_NAME}" \
  --region "${REGION}" \
  --project "${PROJECT_ID}" \
  --format "value(status.url)")

echo ""
echo "=========================================="
echo "Vogue Concierge UI deployed."
echo "URL: ${URL}"
echo "=========================================="
