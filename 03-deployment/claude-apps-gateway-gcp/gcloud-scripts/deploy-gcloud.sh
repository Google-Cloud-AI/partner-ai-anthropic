#!/bin/bash
# Copyright 2026 Google LLC
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
#
# Imperative deployment, for teams that do not use Terraform. Idempotent: safe
# to re-run. Normally invoked by ../deploy.sh, which supplies the environment;
# it can also be run standalone once the variables below are exported.
#
# Required: PROJECT_ID REGION OAUTH_CLIENT_ID OAUTH_CLIENT_SECRET ALLOWED_DOMAIN
# Optional: GATEWAY_VERSION INGRESS INVOKER_MODE GATEWAY_PUBLIC_URL
#           PROXY_ONLY_SUBNET_CIDR VPC_NAME

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOYER_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../lib/common.sh
source "${DEPLOYER_DIR}/lib/common.sh"

: "${PROJECT_ID:?PROJECT_ID must be set}"
: "${REGION:?REGION must be set}"
: "${OAUTH_CLIENT_ID:?OAUTH_CLIENT_ID must be set}"
: "${OAUTH_CLIENT_SECRET:?OAUTH_CLIENT_SECRET must be set}"
: "${ALLOWED_DOMAIN:?ALLOWED_DOMAIN must be set}"

GATEWAY_VERSION="${GATEWAY_VERSION:-2.1.206}"
INGRESS="${INGRESS:-INGRESS_TRAFFIC_INTERNAL_ONLY}"
INVOKER_MODE="${INVOKER_MODE:-allusers}"
GATEWAY_PUBLIC_URL="${GATEWAY_PUBLIC_URL:-}"
PROXY_ONLY_SUBNET_CIDR="${PROXY_ONLY_SUBNET_CIDR:-}"
VPC_NAME="${VPC_NAME:-cc-gateway-vpc}"
SUBNET_NAME="${SUBNET_NAME:-cc-gateway-subnet}"
SERVICE="claude-gateway"
IMAGE_TAG="${REGION}-docker.pkg.dev/${PROJECT_ID}/${SERVICE}/gateway:${GATEWAY_VERSION}"

require_cmd gcloud "Install from https://cloud.google.com/sdk/docs/install"
require_cmd envsubst "Install gettext (gettext-base). Present by default in Cloud Shell."

# Terraform's ingress enum maps to a different spelling on the gcloud flag.
case "$INGRESS" in
  INGRESS_TRAFFIC_INTERNAL_ONLY)           INGRESS_FLAG="internal" ;;
  INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER)  INGRESS_FLAG="internal-and-cloud-load-balancing" ;;
  *) die "Unsupported INGRESS '${INGRESS}'. /login rejects publicly-resolving gateways, so INGRESS_TRAFFIC_ALL is not offered." ;;
esac

gcloud config set project "$PROJECT_ID" --quiet

# ---------------------------------------------------------------------------
# APIs
# ---------------------------------------------------------------------------
info "Enabling service APIs..."
gcloud services enable \
  aiplatform.googleapis.com \
  artifactregistry.googleapis.com \
  cloudbuild.googleapis.com \
  sqladmin.googleapis.com \
  secretmanager.googleapis.com \
  iamcredentials.googleapis.com \
  iam.googleapis.com \
  compute.googleapis.com \
  servicenetworking.googleapis.com \
  run.googleapis.com

# ---------------------------------------------------------------------------
# Service account
# ---------------------------------------------------------------------------
SA="${SERVICE}@${PROJECT_ID}.iam.gserviceaccount.com"
if gcloud iam service-accounts describe "$SA" >/dev/null 2>&1; then
  ok "Service account already exists."
else
  info "Creating service account..."
  gcloud iam service-accounts create "$SERVICE" --display-name="Claude apps gateway"
fi

# Re-applied unconditionally: the binding is idempotent and a missing role here
# surfaces only as a 403 on the first inference request, long after deploy.
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${SA}" --role="roles/aiplatform.user" --condition=None >/dev/null
ok "Granted roles/aiplatform.user."

# ---------------------------------------------------------------------------
# Image
# ---------------------------------------------------------------------------
if ! gcloud artifacts repositories describe "$SERVICE" --location="$REGION" >/dev/null 2>&1; then
  info "Creating Artifact Registry repository..."
  gcloud artifacts repositories create "$SERVICE" \
    --repository-format=docker --location="$REGION"
fi

fetch_gateway_binary "$GATEWAY_VERSION" "${DEPLOYER_DIR}/templates/claude"

info "Building image via Cloud Build (guarantees linux/amd64)..."
gcloud builds submit --tag "$IMAGE_TAG" "${DEPLOYER_DIR}/templates/" --project="$PROJECT_ID"

# ---------------------------------------------------------------------------
# Network and Cloud SQL
# ---------------------------------------------------------------------------
if ! gcloud compute networks describe "$VPC_NAME" >/dev/null 2>&1; then
  info "Creating VPC, subnet, and Private Services Access peering..."
  gcloud compute networks create "$VPC_NAME" --subnet-mode=custom
  gcloud compute networks subnets create "$SUBNET_NAME" \
    --network="$VPC_NAME" --region="$REGION" --range=10.0.0.0/24
  gcloud compute addresses create "google-managed-services-${VPC_NAME}" \
    --global --purpose=VPC_PEERING --prefix-length=16 --network="$VPC_NAME"
  gcloud services vpc-peerings connect \
    --service=servicenetworking.googleapis.com \
    --ranges="google-managed-services-${VPC_NAME}" --network="$VPC_NAME"
else
  ok "VPC already exists."
fi

if gcloud sql instances describe "${SERVICE}-db" >/dev/null 2>&1; then
  ok "Cloud SQL instance already exists; rotating the gateway password."
  PGPASS="$(openssl rand -hex 24)"
  gcloud sql users set-password gateway --instance="${SERVICE}-db" --password="$PGPASS" --quiet
else
  info "Creating Cloud SQL instance (private IP; this takes several minutes)..."
  gcloud sql instances create "${SERVICE}-db" \
    --database-version=POSTGRES_16 --tier=db-g1-small --region="$REGION" \
    --network="projects/${PROJECT_ID}/global/networks/${VPC_NAME}" --no-assign-ip
  gcloud sql databases create claude_gateway --instance="${SERVICE}-db"
  PGPASS="$(openssl rand -hex 24)"
  gcloud sql users create gateway --instance="${SERVICE}-db" --password="$PGPASS"
fi

PRIVATE_IP="$(gcloud sql instances describe "${SERVICE}-db" --format='value(ipAddresses[0].ipAddress)')"
# sslmode=require, not disable: the session store carries auth state and Cloud
# SQL terminates TLS at no cost.
GATEWAY_POSTGRES_URL="postgres://gateway:${PGPASS}@${PRIVATE_IP}:5432/claude_gateway?sslmode=require"
GATEWAY_JWT_SECRET="$(openssl rand -base64 32)"

# ---------------------------------------------------------------------------
# Render gateway.yaml
# ---------------------------------------------------------------------------
# envsubst with an explicit allowlist substitutes only the non-secret values and
# leaves every $${...} placeholder for the gateway to expand from its own
# environment, so no secret is ever written into the rendered file. The trailing
# sed unescapes Terraform's $$ convention, which the same template carries so
# both deployment paths can share one file.
if [[ "$INGRESS" == "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER" ]]; then
  [[ -n "$PROXY_ONLY_SUBNET_CIDR" ]] || die "PROXY_ONLY_SUBNET_CIDR is required behind an internal ALB."
  TRUSTED_PROXIES="[\"169.254.0.0/16\", \"${PROXY_ONLY_SUBNET_CIDR}\"]"
else
  TRUSTED_PROXIES="[\"169.254.0.0/16\"]"
fi

RENDERED="$(mktemp)"
trap 'rm -f "$RENDERED"' EXIT

export REGION PROJECT_ID OAUTH_CLIENT_ID ALLOWED_DOMAIN TRUSTED_PROXIES
envsubst '${REGION} ${PROJECT_ID} ${OAUTH_CLIENT_ID} ${ALLOWED_DOMAIN} ${TRUSTED_PROXIES}' \
  < "${DEPLOYER_DIR}/templates/gateway.yaml.template" \
  | sed 's/\$\$/\$/g' > "$RENDERED"
ok "Rendered gateway.yaml."

# ---------------------------------------------------------------------------
# Secrets
# ---------------------------------------------------------------------------
store_secret() {
  local name="$1" file="$2"
  if ! gcloud secrets describe "$name" >/dev/null 2>&1; then
    gcloud secrets create "$name" --replication-policy="automatic"
  fi
  gcloud secrets versions add "$name" --data-file="$file" >/dev/null
  gcloud secrets add-iam-policy-binding "$name" \
    --member="serviceAccount:${SA}" --role="roles/secretmanager.secretAccessor" >/dev/null
  ok "Stored secret ${name}."
}

# Values reach gcloud through files, never argv, so they stay out of the process
# table and shell history. A private temp dir, not a pipe: store_secret runs
# other gcloud calls before the one that reads the data, and any of them could
# swallow stdin.
SECRET_DIR="$(mktemp -d)"
chmod 700 "$SECRET_DIR"
trap 'rm -rf "$SECRET_DIR"; rm -f "$RENDERED"' EXIT

write_secret_file() {
  local path="$SECRET_DIR/$1"
  ( umask 077; printf '%s' "$2" > "$path" )
  echo "$path"
}

info "Storing secrets..."
store_secret "gateway-config"             "$RENDERED"
store_secret "gateway-jwt-secret"         "$(write_secret_file jwt   "$GATEWAY_JWT_SECRET")"
store_secret "gateway-oidc-client-secret" "$(write_secret_file oidc  "$OAUTH_CLIENT_SECRET")"
store_secret "gateway-postgres-url"       "$(write_secret_file pgurl "$GATEWAY_POSTGRES_URL")"

# ---------------------------------------------------------------------------
# Deploy
# ---------------------------------------------------------------------------
# The invoker check must admit unauthenticated requests: the gateway runs its
# own OIDC and its clients carry no GCP token. --no-invoker-iam-check leaves no
# allUsers binding and works under Domain Restricted Sharing; --allow-
# unauthenticated is the fallback where org policy forbids the former.
if [[ "$INVOKER_MODE" == "external" ]]; then
  INVOKER_FLAG="--no-invoker-iam-check"
else
  INVOKER_FLAG="--allow-unauthenticated"
fi

info "Deploying to Cloud Run (ingress=${INGRESS_FLAG})..."
gcloud run deploy "$SERVICE" \
  --image="$IMAGE_TAG" \
  --region="$REGION" \
  --service-account="$SA" \
  --min-instances=1 \
  --timeout=3600 \
  --ingress="$INGRESS_FLAG" \
  --network="$VPC_NAME" --subnet="$SUBNET_NAME" --vpc-egress=private-ranges-only \
  --set-secrets="/etc/claude/gateway.yaml=gateway-config:latest,GATEWAY_JWT_SECRET=gateway-jwt-secret:latest,OIDC_CLIENT_SECRET=gateway-oidc-client-secret:latest,GATEWAY_POSTGRES_URL=gateway-postgres-url:latest" \
  --set-env-vars="GATEWAY_PUBLIC_URL=https://placeholder.invalid" \
  "$INVOKER_FLAG"

if [[ -n "$GATEWAY_PUBLIC_URL" ]]; then
  FINAL_URL="$GATEWAY_PUBLIC_URL"
else
  FINAL_URL="$(gcloud run services describe "$SERVICE" --region="$REGION" --format='value(status.url)')"
fi

info "Pinning public_url into the service: ${FINAL_URL}"
gcloud run services update "$SERVICE" \
  --region="$REGION" \
  --update-env-vars="GATEWAY_PUBLIC_URL=${FINAL_URL}" \
  --quiet

ok "Gateway deployed at ${FINAL_URL}"
