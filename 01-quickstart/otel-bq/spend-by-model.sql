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

-- Claude Code spend, aggregated per DAY and per MODEL.
-- Run in Observability Analytics (Logging → Observability Analytics → Query) for project YOUR_PROJECT_ID.
--
-- Cost source of truth: the `cost_usd` label on each `api_request` event.
-- (The Cloud Monitoring metric is a per-session counter and undercounts totals.)
--
-- Companion to daily-spend.sql, which groups by user; this one groups by model.

WITH events AS (
  SELECT
    timestamp,
    COALESCE(JSON_VALUE(labels, '$.model'), '(unknown)')       AS model,
    SAFE_CAST(JSON_VALUE(labels, '$.cost_usd')              AS FLOAT64) AS cost_usd,
    SAFE_CAST(JSON_VALUE(labels, '$.input_tokens')         AS INT64)   AS input_tokens,
    SAFE_CAST(JSON_VALUE(labels, '$.output_tokens')        AS INT64)   AS output_tokens,
    SAFE_CAST(JSON_VALUE(labels, '$.cache_creation_tokens') AS INT64)  AS cache_creation_tokens,
    SAFE_CAST(JSON_VALUE(labels, '$.cache_read_tokens')    AS INT64)   AS cache_read_tokens
  FROM `YOUR_PROJECT_ID.global._Default._AllLogs`
  WHERE
    log_name = 'projects/YOUR_PROJECT_ID/logs/claude-code'
    AND JSON_VALUE(labels, '$."event.name"') = 'api_request'
    -- Time range is controlled by the Log Analytics console time-range picker.
)
SELECT
  DATE(timestamp)                          AS day,        -- UTC; use DATE(timestamp,'America/Los_Angeles') for local
  model,
  COUNT(*)                                 AS api_requests,
  ROUND(SUM(cost_usd), 4)                  AS cost_usd,
  SUM(input_tokens)                        AS input_tokens,
  SUM(output_tokens)                       AS output_tokens,
  SUM(cache_creation_tokens)               AS cache_creation_tokens,
  SUM(cache_read_tokens)                   AS cache_read_tokens
FROM events
GROUP BY day, model
ORDER BY day DESC, cost_usd DESC;
