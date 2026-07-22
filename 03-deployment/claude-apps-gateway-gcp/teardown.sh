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
# Removes everything the deployer created, including the networking layer that
# a plain `terraform destroy` tends to strand.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

CONFIG_FILE="${SCRIPT_DIR}/config.env"

banner "Claude apps gateway — Teardown"

load_config "$CONFIG_FILE"

ask PROJECT_ID "GCP project ID"
require_var PROJECT_ID
ask REGION "GCP region" "us-east5"
ask VPC_NAME "VPC name" "cc-gateway-vpc"

echo ""
warn "This permanently deletes the gateway, its session database, and its secrets."
warn "Project: ${PROJECT_ID}   Region: ${REGION}"
confirm "Continue?" || die "Aborted."

# ---------------------------------------------------------------------------
# The peering problem
# ---------------------------------------------------------------------------
# Deleting the Private Services Access peering fails while any producer
# resource still holds an address in the reserved range, and Cloud SQL lingers
# for a short window after its delete returns. The peering in turn blocks the
# VPC, subnet, and reserved range. So: retry, then force, then finish.
remove_peering() {
  info "Removing Private Services Access peering (retrying while Cloud SQL drains)..."
  for attempt in 1 2 3 4 5 6; do
    if ! gcloud services vpc-peerings list --network="$VPC_NAME" --project="$PROJECT_ID" \
         --format='value(peering)' 2>/dev/null | grep -q servicenetworking; then
      ok "Peering is gone."
      return 0
    fi
    if gcloud services vpc-peerings delete \
         --service=servicenetworking.googleapis.com \
         --network="$VPC_NAME" --project="$PROJECT_ID" --quiet 2>/dev/null; then
      ok "Peering deleted."
      return 0
    fi
    warn "Attempt ${attempt}/6 failed; producer resources still draining. Waiting 30s..."
    sleep 30
  done
  warn "Could not delete the peering automatically."
  warn "Re-run this script once Cloud SQL has fully drained, or delete it with:"
  warn "  gcloud services vpc-peerings delete --service=servicenetworking.googleapis.com --network=${VPC_NAME} --project=${PROJECT_ID}"
  return 1
}

echo ""
echo "How was this deployed?"
echo "  1) Terraform"
echo "  2) gcloud CLI"
echo ""
ask TEARDOWN_METHOD "Select [1 or 2]" "1"

case "$TEARDOWN_METHOD" in
  1)
    require_cmd terraform "Install from https://developer.hashicorp.com/terraform/downloads"
    pushd "${SCRIPT_DIR}/terraform" >/dev/null

    info "Running terraform destroy..."
    if terraform destroy -input=false -auto-approve; then
      ok "Terraform destroy completed."
    else
      warn "Destroy failed — almost always the service networking connection."
      remove_peering || true
      info "Re-running destroy now that the peering is gone..."
      terraform destroy -input=false -auto-approve \
        || die "Destroy still failing. Inspect 'terraform state list' and resolve manually."
      ok "Terraform destroy completed on the second pass."
    fi
    popd >/dev/null
    ;;
  2)
    export PROJECT_ID REGION VPC_NAME
    bash "${SCRIPT_DIR}/gcloud-scripts/teardown-gcloud.sh"
    ;;
  *)
    die "Invalid selection: $TEARDOWN_METHOD"
    ;;
esac

# ---------------------------------------------------------------------------
# Verify nothing was stranded
# ---------------------------------------------------------------------------
echo ""
info "Verifying teardown..."
LEFTOVERS=0
check_gone() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    warn "STILL PRESENT: ${label}"
    LEFTOVERS=$((LEFTOVERS + 1))
  else
    ok "Removed: ${label}"
  fi
}

check_gone "Cloud Run service"  gcloud run services describe claude-gateway --region="$REGION" --project="$PROJECT_ID"
check_gone "Cloud SQL instance" gcloud sql instances describe claude-gateway-db --project="$PROJECT_ID"
check_gone "Artifact Registry"  gcloud artifacts repositories describe claude-gateway --location="$REGION" --project="$PROJECT_ID"
check_gone "Service account"    gcloud iam service-accounts describe "claude-gateway@${PROJECT_ID}.iam.gserviceaccount.com" --project="$PROJECT_ID"
check_gone "VPC network"        gcloud compute networks describe "$VPC_NAME" --project="$PROJECT_ID"
check_gone "Reserved range"     gcloud compute addresses describe "google-managed-services-${VPC_NAME}" --global --project="$PROJECT_ID"

echo ""
if [[ "$LEFTOVERS" -eq 0 ]]; then
  ok "Teardown complete. Nothing left behind."
else
  warn "${LEFTOVERS} resource(s) remain — see the list above."
  warn "The usual cause is the peering blocking the VPC. Re-run this script."
  exit 1
fi
