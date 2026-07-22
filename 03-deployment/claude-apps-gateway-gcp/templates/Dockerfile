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

# Distroless: no shell, no package manager, minimal attack surface. The `cc`
# variant supplies the glibc the linux-x64 gateway binary links against.
#
# Cloud Run requires linux/amd64. Building through Cloud Build (the default in
# this deployer) guarantees that. If you build locally instead, pass
#   --platform=linux/amd64 --provenance=false
# the latter to stop buildx emitting an OCI image index that Cloud Run rejects
# with "Container manifest type ... must support amd64/linux".
FROM gcr.io/distroless/cc-debian12:latest-amd64

# Downloaded by deploy.sh at the pinned gateway_version; gitignored, never
# committed. The gateway server runs only from the native binary — under Node
# it exits with "requires the native binary".
COPY claude /claude

EXPOSE 8080
USER nonroot:nonroot

# gateway.yaml arrives as a Secret Manager volume mount; the three secrets it
# references arrive as environment variables.
ENTRYPOINT ["/claude", "gateway", "--config", "/etc/claude/gateway.yaml"]
