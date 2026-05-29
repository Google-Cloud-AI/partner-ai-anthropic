#!/usr/bin/env bash
# mirror-sandbox-router.sh — copy an upstream sandbox-router image into
# our Artifact Registry so our manifests reference a registry we control.
#
# Why we mirror rather than reference upstream directly:
#   - The upstream image lives in k8s-staging-images/ — a SIG-managed
#     staging registry not intended for production pinning.
#   - Mirroring gives us a stable digest in our own AR and avoids
#     surprises if upstream rotates or retires staging tags.
#
# Upstream releases (find the tag from the latest release notes):
#   https://github.com/kubernetes-sigs/agent-sandbox/releases
#
# Usage:
#   scripts/mirror-sandbox-router.sh <upstream-tag>
#   # e.g.:
#   scripts/mirror-sandbox-router.sh v20260225-v0.1.1.post3-10-ga5bcb57
#
# The script is idempotent — `crane copy` is a no-op if the digest is
# already present in the destination repository.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  cat >&2 <<EOF
Usage: $0 <upstream-tag>

  upstream-tag — the tag at:
    us-central1-docker.pkg.dev/k8s-staging-images/agent-sandbox/sandbox-router:<TAG>

  Find current tags at:
    https://github.com/kubernetes-sigs/agent-sandbox/releases

EOF
  exit 2
fi

UPSTREAM_TAG="$1"
UPSTREAM="us-central1-docker.pkg.dev/k8s-staging-images/agent-sandbox/sandbox-router:${UPSTREAM_TAG}"
MIRROR_TAG="upstream-${UPSTREAM_TAG#v*-}"   # drops the `v<date>-` prefix, keeps `v0.1.1.post3-10-ga5bcb57`
MIRROR="us-central1-docker.pkg.dev/cpe-slarbi-nvd-ant-demos/cc-on-ge/sandbox-router:${MIRROR_TAG}"

echo "  upstream: ${UPSTREAM}"
echo "  mirror:   ${MIRROR}"

# Cloud Build with crane handles cross-registry copies cleanly and runs
# without local docker. ~10s for the copy.
TMPCFG=$(mktemp --suffix=.yaml)
trap 'rm -f "$TMPCFG"' EXIT
cat > "$TMPCFG" <<EOF
steps:
  - name: 'gcr.io/go-containerregistry/crane:latest'
    args: ['copy', '${UPSTREAM}', '${MIRROR}']
EOF

gcloud builds submit --no-source --config="$TMPCFG" \
  --project=cpe-slarbi-nvd-ant-demos

echo ""
echo "  ✓ mirrored. Reference this image in infra/terraform/k8s.tf:"
echo "    ${MIRROR}"
