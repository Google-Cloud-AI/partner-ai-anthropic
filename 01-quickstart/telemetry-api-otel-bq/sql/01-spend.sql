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

-- Spend and token use from `api_request`.
--
-- Two results: per day x developer, then per model. This is the number the
-- metric path gets wrong — every request is one row here, so nothing is dropped.
--
-- Conventions used by every file in this folder:
--   - one table per event type, named for the bare event (`api_request`)
--   - `labels` is a STRUCT of STRINGs; numerics need SAFE_CAST
--   - `resource.labels.task_id` is the hostname
--   - BigQuery has no time picker, so the window is in the query. Filtering on
--     `timestamp` prunes partitions and is what keeps the scan cheap.

DECLARE window_days INT64 DEFAULT 30;

CREATE TEMP TABLE requests AS
SELECT
  timestamp,
  resource.labels.task_id AS host,
  -- user.email is absent on rows written before OTEL_METRICS_INCLUDE_RESOURCE_
  -- ATTRIBUTES was on; fall back to the hashed id so those rows still count.
  COALESCE(labels.user_email, CONCAT('id:', SUBSTR(labels.user_id, 1, 12))) AS user_key,
  labels.model AS model,
  SAFE_CAST(labels.cost_usd              AS FLOAT64) AS cost_usd,
  SAFE_CAST(labels.input_tokens          AS INT64)   AS input_tokens,
  SAFE_CAST(labels.output_tokens         AS INT64)   AS output_tokens,
  SAFE_CAST(labels.cache_creation_tokens AS INT64)   AS cache_creation_tokens,
  SAFE_CAST(labels.cache_read_tokens     AS INT64)   AS cache_read_tokens,
  SAFE_CAST(labels.duration_ms           AS INT64)   AS duration_ms,
  SAFE_CAST(labels.ttft_ms               AS INT64)   AS ttft_ms
FROM `YOUR_PROJECT_ID.YOUR_SINK_DATASET.api_request`
WHERE timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL window_days DAY);

-- 1. Per day, per developer.
SELECT
  DATE(timestamp)             AS day,   -- UTC; pass a tz to DATE() for local
  user_key,
  host,
  COUNT(*)                    AS requests,
  ROUND(SUM(cost_usd), 4)     AS cost_usd,
  SUM(input_tokens)           AS input_tokens,
  SUM(output_tokens)          AS output_tokens,
  SUM(cache_creation_tokens)  AS cache_creation_tokens,
  SUM(cache_read_tokens)      AS cache_read_tokens
FROM requests
GROUP BY day, user_key, host
ORDER BY day DESC, cost_usd DESC;

-- 2. Per model. cache_hit_pct is the share of read-in tokens served from cache —
--    low values on a long session usually mean the cache is being invalidated.
SELECT
  model,
  COUNT(*)                                   AS requests,
  ROUND(SUM(cost_usd), 4)                    AS cost_usd,
  ROUND(SUM(cost_usd) / COUNT(*), 5)         AS avg_cost_per_request,
  ROUND(SAFE_DIVIDE(SUM(cost_usd) * 1000, SUM(output_tokens)), 5)
                                             AS usd_per_1k_output_tokens,
  ROUND(100 * SAFE_DIVIDE(
    SUM(cache_read_tokens),
    SUM(cache_read_tokens) + SUM(cache_creation_tokens) + SUM(input_tokens)), 1)
                                             AS cache_hit_pct,
  APPROX_QUANTILES(duration_ms, 100)[OFFSET(50)] AS p50_ms,
  APPROX_QUANTILES(duration_ms, 100)[OFFSET(95)] AS p95_ms,
  APPROX_QUANTILES(ttft_ms, 100)[OFFSET(50)]     AS p50_ttft_ms
FROM requests
GROUP BY model
ORDER BY cost_usd DESC;
