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
# Deletes everything deploy-gcloud.sh created. Ordering matters: Cloud SQL must
# be gone before the peering, and the peering before the VPC.
#
# Normally invoked by ../teardown.sh. Required: PROJECT_ID REGION.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOYER_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../lib/common.sh
source "${DEPLOYER_DIR}/lib/common.sh"

: "${PROJECT_ID:?PROJECT_ID must be set}"
: "${REGION:?REGION must be set}"
VPC_NAME="${VPC_NAME:-cc-gateway-vpc}"
SUBNET_NAME="${SUBNET_NAME:-cc-gateway-subnet}"
SERVICE="claude-gateway"

gcloud config set project "$PROJECT_ID" --quiet

info "Deleting Cloud Run service..."
gcloud run services delete "$SERVICE" --region="$REGION" --quiet 2>/dev/null || true

info "Deleting secrets..."
for s in gateway-config gateway-postgres-url gateway-jwt-secret gateway-oidc-client-secret; do
  gcloud secrets delete "$s" --quiet 2>/dev/null || true
done

# Blocking: the peering cannot be removed while this instance holds an address
# in the reserved range.
info "Deleting Cloud SQL instance (several minutes)..."
gcloud sql instances delete "${SERVICE}-db" --quiet 2>/dev/null || true

info "Deleting Artifact Registry repository..."
gcloud artifacts repositories delete "$SERVICE" --location="$REGION" --quiet 2>/dev/null || true

info "Deleting service account..."
gcloud iam service-accounts delete "${SERVICE}@${PROJECT_ID}.iam.gserviceaccount.com" --quiet 2>/dev/null || true

# ---------------------------------------------------------------------------
# Networking, in dependency order
# ---------------------------------------------------------------------------
# The original version of this script stopped after the subnet, which is what
# left orphaned VPCs behind. Each step below blocks the next.
info "Deleting Private Services Access peering (retrying while Cloud SQL drains)..."
for attempt in 1 2 3 4 5 6; do
  if ! gcloud services vpc-peerings list --network="$VPC_NAME" \
       --format='value(peering)' 2>/dev/null | grep -q servicenetworking; then
    ok "Peering is gone."
    break
  fi
  if gcloud services vpc-peerings delete \
       --service=servicenetworking.googleapis.com \
       --network="$VPC_NAME" --quiet 2>/dev/null; then
    ok "Peering deleted."
    break
  fi
  warn "Attempt ${attempt}/6 failed; waiting 30s for producer resources to drain..."
  sleep 30
done

info "Deleting reserved peering range..."
gcloud compute addresses delete "google-managed-services-${VPC_NAME}" --global --quiet 2>/dev/null || true

info "Deleting subnet..."
gcloud compute networks subnets delete "$SUBNET_NAME" --region="$REGION" --quiet 2>/dev/null || true

info "Deleting VPC..."
gcloud compute networks delete "$VPC_NAME" --quiet 2>/dev/null || true

ok "gcloud teardown finished. The caller verifies what remains."
