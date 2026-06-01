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

# ============================================================================
# Firestore named database — cc-on-ge
# ----------------------------------------------------------------------------
# We deliberately use a NAMED Firestore database (not the project's
# `(default)` database). The `(default)` DB in cpe-slarbi-nvd-ant-demos
# predates this project (created 2026-03-02) and holds unrelated data that
# must not be touched.
#
# Holds ADK Sessions (sessions/{context_id}) and cross-thread Memory
# (memory/{user_key}/facts/{fact_id}). Phase 4 adds collection-group indexes
# for events and facts. See firestore-sessions skill.
#
# IMPORTANT: Phase 4 backend code must specify `database="cc-on-ge"` when
# constructing google.cloud.firestore.AsyncClient — the SDK silently
# defaults to `(default)` if database is omitted.
# ============================================================================

resource "google_firestore_database" "cc_on_ge" {
  project     = var.project_id
  name        = var.firestore_database_name
  location_id = var.region
  type        = "FIRESTORE_NATIVE"

  # Disable delete protection so dev environments can be reset.
  # TODO: enable before production.
  delete_protection_state = "DELETE_PROTECTION_DISABLED"
}

# ============================================================================
# Phase 4 — collection-group indexes per firestore-sessions skill
# ----------------------------------------------------------------------------
# Both are COLLECTION_GROUP scope so the indexes apply across all
# sessions/{id}/events/ and memory/{user_key}/facts/ subcollections.
# Phase 4 MVP queries within a single subcollection don't strictly need
# these (single-field indexes are auto-managed), but adding them now
# unblocks Phase v2 (cross-user recall, cross-session event analytics)
# without another terraform apply.
# ============================================================================

# NOTE: a `session_events_by_time` collection-group index on `events`
# (`timestamp` + `__name__`) was attempted but Firestore rejected it as
# "this index is not necessary, configure using single field index
# controls" — single-field ordering is auto-managed for the
# sessions/{id}/events/ subcollection queries we run. Leaving this
# comment so a future maintainer doesn't re-add it.

resource "google_firestore_index" "memory_facts_by_user_time" {
  project    = var.project_id
  database   = google_firestore_database.cc_on_ge.name
  collection = "facts"
  query_scope = "COLLECTION_GROUP"

  fields {
    field_path = "user_key"
    order      = "ASCENDING"
  }
  fields {
    field_path = "created_at"
    order      = "DESCENDING"
  }
}
