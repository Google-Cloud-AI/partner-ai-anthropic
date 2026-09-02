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

# Vogue Concierge — deploy the MCP Toolbox to Cloud Run.
#
# The toolbox exposes the BigQuery inventory/loyalty tools that the deployed
# agents call. deploy_agent_engine.py reads TOOLBOX_URL from the environment, so
# run this FIRST, then export the printed TOOLBOX_URL before deploying the agents.
# (bootstrap.sh does this chaining for you.)
#
# toolbox/tools.yaml ships with a `your-gcp-project-id` placeholder. We render a
# concrete copy into an isolated build context so the committed template stays
# clean and your real project id is never written back into the repo.
#
# SECURITY: the service is deployed WITHOUT public access. Callers present a
# Google-signed ID token and need roles/run.invoker on the service; the agents
# do this for you via the Toolbox ADK client's workload_identity strategy. The
# toolbox also runs as its own least-privilege service account that can only
# read BigQuery — not the Compute default SA, which is far broader.

set -e

PROJECT_ID="${VERTEXAI_PROJECT:?Set VERTEXAI_PROJECT to your GCP project id (see README)}"
PROJECT_NUMBER="${PROJECT_NUMBER:?Set PROJECT_NUMBER to your GCP project number (see README)}"
REGION="${REGION:-us-central1}"
SERVICE_NAME="vogue-toolbox"
IMAGE="gcr.io/${PROJECT_ID}/${SERVICE_NAME}"

# Dedicated identity for the toolbox: BigQuery read + job creation, nothing else.
TOOLBOX_SA_NAME="vogue-toolbox-sa"
TOOLBOX_SA="${TOOLBOX_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

# The identity deployed agents run as on Agent Runtime. This is who calls the
# toolbox, so this is who needs roles/run.invoker on the service.
ENGINE_SA="service-${PROJECT_NUMBER}@gcp-sa-aiplatform-re.iam.gserviceaccount.com"

echo "=== Vogue Concierge — MCP Toolbox Deploy ==="
echo "Project: ${PROJECT_ID} | Region: ${REGION} | Service: ${SERVICE_NAME}"
echo ""

# Render tools.yaml with the real project id into a throwaway build context so we
# never mutate the committed template (which keeps the your-gcp-project-id
# placeholder for the public repo).
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "${BUILD_DIR}"' EXIT
cp toolbox/Dockerfile "${BUILD_DIR}/Dockerfile"
sed "s/your-gcp-project-id/${PROJECT_ID}/g" toolbox/tools.yaml > "${BUILD_DIR}/tools.yaml"

echo "Step 1: Building toolbox image..."
gcloud builds submit "${BUILD_DIR}" --tag "${IMAGE}" --project "${PROJECT_ID}" --timeout=600

# The toolbox reaches BigQuery with its own service account's ADC, so it needs
# just enough to run a SELECT: read the data, and create the query job. It never
# writes — the only writes in this demo go through checkout.py.
echo ""
echo "Step 2: Ensuring the toolbox service account exists..."
if ! gcloud iam service-accounts describe "${TOOLBOX_SA}" \
      --project "${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud iam service-accounts create "${TOOLBOX_SA_NAME}" \
    --project "${PROJECT_ID}" \
    --display-name "Vogue Concierge MCP Toolbox"
  echo "  created ${TOOLBOX_SA}"
else
  echo "  ${TOOLBOX_SA} already exists"
fi

for ROLE in roles/bigquery.dataViewer roles/bigquery.jobUser; do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${TOOLBOX_SA}" --role="${ROLE}" \
    --condition=None --quiet >/dev/null
  echo "  granted ${ROLE}"
done

# The toolbox container listens on 5000 (see toolbox/Dockerfile), so tell Cloud
# Run to route to that port. --no-allow-unauthenticated keeps the SQL tools off
# the public internet; the agents authenticate with an ID token (see below).
echo ""
echo "Step 3: Deploying toolbox to Cloud Run..."
gcloud run deploy "${SERVICE_NAME}" \
  --image "${IMAGE}" \
  --region "${REGION}" \
  --project "${PROJECT_ID}" \
  --platform managed \
  --no-allow-unauthenticated \
  --port 5000 \
  --memory 512Mi \
  --cpu 1 \
  --timeout 60 \
  --min-instances 0 \
  --max-instances 3 \
  --service-account "${TOOLBOX_SA}"

URL=$(gcloud run services describe "${SERVICE_NAME}" \
  --region "${REGION}" --project "${PROJECT_ID}" --format "value(status.url)")

# Let the deployed agents call it. The Agent Runtime service agent is created
# the first time the project uses Agent Engine, so on a brand-new project this
# grant can't land yet — bootstrap.sh repeats it after deploying the agents, and
# the manual path is told to re-run this script.
echo ""
echo "Step 4: Authorising the Agent Runtime service agent to invoke the toolbox..."
if gcloud run services add-iam-policy-binding "${SERVICE_NAME}" \
     --region "${REGION}" --project "${PROJECT_ID}" \
     --member="serviceAccount:${ENGINE_SA}" \
     --role="roles/run.invoker" --quiet >/dev/null 2>&1; then
  echo "  granted roles/run.invoker to ${ENGINE_SA}"
else
  echo "  NOTE: could not grant roles/run.invoker to ${ENGINE_SA} yet."
  echo "        That identity appears the first time this project deploys an"
  echo "        agent. Re-run ./deploy_toolbox.sh after deploy_agent_engine.py."
fi

echo ""
echo "=========================================="
echo "MCP Toolbox deployed (authenticated)."
echo "Bridge the agents to it by exporting this before deploy_agent_engine.py:"
# Machine-readable line — bootstrap.sh greps for '^TOOLBOX_URL='.
echo "TOOLBOX_URL=${URL}"
echo "=========================================="
