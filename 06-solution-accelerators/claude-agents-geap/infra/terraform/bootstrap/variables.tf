# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

variable "project_id" {
  description = "GCP project ID. Locked to cpe-slarbi-nvd-ant-demos for v1."
  type        = string
  default     = "cpe-slarbi-nvd-ant-demos"
}

variable "region" {
  description = "Primary GCP region. Locked to us-central1 for v1."
  type        = string
  default     = "us-central1"
}

variable "state_bucket_name" {
  description = "Terraform state bucket name. Consumed by the main root's gcs backend."
  type        = string
  default     = "cpe-slarbi-nvd-ant-demos-tfstate"
}

variable "builder_sa_account_id" {
  description = "Account ID (local part) for the Cloud Build service account."
  type        = string
  default     = "cc-a2a-builder"
}
