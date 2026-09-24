-- Copyright 2026 Google LLC
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

-- Schema probe. RUN THIS FIRST, before trusting any other file here.
--
-- The Log Router sink builds each table's schema from the first batch it writes,
-- sanitizing label keys (`user.email` -> labels.user_email). The other queries
-- assume those names. This tells you what they actually are.
--
-- Check for: labels.user_email, labels.app_version, labels.session_id,
-- labels.prompt_id, labels.tool_use_id, labels.cost_usd.
--
-- If user_email or app_version are missing, the two settings that produce them
-- are off (see print-settings.sh). Fix those and let NEW traffic land — log
-- entries cannot be rewritten, and after the _Default exclusion this is the only
-- copy. Schema evolution is additive, so later labels appear as new columns.

-- 1. Which event tables exist, and how big.
SELECT
  table_name,
  row_count,
  ROUND(size_bytes / 1024 / 1024, 1) AS size_mb
FROM `YOUR_PROJECT_ID.YOUR_SINK_DATASET.__TABLES__`
ORDER BY row_count DESC;

-- 2. Every label column, per table.
SELECT
  table_name,
  REPLACE(field_path, 'labels.', '') AS label,
  data_type
FROM `YOUR_PROJECT_ID.YOUR_SINK_DATASET`.INFORMATION_SCHEMA.COLUMN_FIELD_PATHS
WHERE field_path LIKE 'labels.%'
  AND table_name IN ('api_request', 'tool_decision', 'tool_result',
                     'assistant_response', 'hook_execution_complete')
ORDER BY table_name, label;
