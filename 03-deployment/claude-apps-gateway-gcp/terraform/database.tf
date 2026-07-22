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

# Session store. Backs the device sign-in flow — the browser callback writes and
# the polling CLI reads — plus rate-limit counters. With spend limits enabled it
# also holds durable spend, audit, and identity tables that warrant backups.

resource "random_password" "pg_pass" {
  length = 24
  # Password lands in a URL, so avoid characters that would need escaping.
  special = false
}

resource "google_sql_database_instance" "gateway_db" {
  name                = "${var.service_name}-db"
  database_version    = "POSTGRES_16"
  region              = var.region
  deletion_protection = var.db_deletion_protection

  settings {
    tier = var.db_tier

    ip_configuration {
      ipv4_enabled    = false
      private_network = google_compute_network.vpc.id
    }
  }

  depends_on = [google_service_networking_connection.default]
}

resource "google_sql_database" "database" {
  name     = "claude_gateway"
  instance = google_sql_database_instance.gateway_db.name
}

resource "google_sql_user" "users" {
  name     = "gateway"
  instance = google_sql_database_instance.gateway_db.name
  password = random_password.pg_pass.result
}
