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

resource "google_artifact_registry_repository" "gateway_repo" {
  repository_id = var.service_name
  format        = "DOCKER"
  location      = var.region
  description   = "Container images for the Claude apps gateway"
  depends_on    = [google_project_service.apis]
}

# Cloud Build produces the image, so no local Docker daemon is required and the
# build runs on linux/amd64 as Cloud Run requires.
#
# The triggers map is what makes this re-run. Without it the provisioner fires
# once for the lifetime of the state and every later change to the Dockerfile or
# the pinned version silently deploys the old image.
resource "null_resource" "docker_push" {
  count = var.build_image ? 1 : 0

  triggers = {
    gateway_version = var.gateway_version
    dockerfile      = filemd5("${path.module}/../templates/Dockerfile")
    image_tag       = local.image_tag
  }

  provisioner "local-exec" {
    working_dir = "${path.module}/.."
    command     = "gcloud builds submit --tag ${local.image_tag} templates/ --project=${var.project_id}"
  }

  depends_on = [google_artifact_registry_repository.gateway_repo]
}
