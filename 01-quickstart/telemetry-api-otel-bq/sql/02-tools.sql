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

-- Tool funnel and tool reliability, from `tool_decision` + `tool_result`.
--
-- Covers EVERY tool. The metric path only ever exposed code_edit_tool.decision,
-- and tool_result has no metric equivalent at all — duration, success,
-- error_type and IO sizes exist only in the logs.
--
-- The two events join on tool_use_id: one decision, then at most one result.

-- FRESH-DEPLOYMENT NOTE. The sink builds each table's schema from the labels it
-- has actually seen, and adds columns as new ones appear. `error_type` is only
-- emitted on a FAILED tool call, so until something fails the column does not
-- exist and referencing it directly is a hard error rather than a null. It is
-- therefore selected dynamically below.

DECLARE window_days INT64 DEFAULT 30;

DECLARE error_type_expr STRING DEFAULT (
  SELECT IF(COUNT(*) > 0, 'labels.error_type', 'CAST(NULL AS STRING)')
  FROM `YOUR_PROJECT_ID.YOUR_SINK_DATASET`.INFORMATION_SCHEMA.COLUMN_FIELD_PATHS
  WHERE table_name = 'tool_result' AND field_path = 'labels.error_type'
);

CREATE TEMP TABLE decisions AS
SELECT
  labels.tool_use_id AS tool_use_id,
  labels.tool_name   AS tool_name,
  labels.decision    AS decision,     -- accept / reject
  labels.source      AS source,       -- how the decision was made
  labels.tool_source AS tool_source   -- built-in, mcp, plugin, ...
FROM `YOUR_PROJECT_ID.YOUR_SINK_DATASET.tool_decision`
WHERE timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL window_days DAY);

EXECUTE IMMEDIATE FORMAT("""
CREATE TEMP TABLE results AS
SELECT
  labels.tool_use_id AS tool_use_id,
  labels.tool_name   AS tool_name,
  labels.success     AS success,
  %s                 AS error_type,
  SAFE_CAST(labels.duration_ms             AS INT64) AS duration_ms,
  SAFE_CAST(labels.tool_input_size_bytes   AS INT64) AS in_bytes,
  SAFE_CAST(labels.tool_result_size_bytes  AS INT64) AS out_bytes
FROM `YOUR_PROJECT_ID.YOUR_SINK_DATASET.tool_result`
WHERE timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL %d DAY)
""", error_type_expr, window_days);

-- 1. The funnel: proposed -> accepted -> succeeded, per tool.
--    A high reject_pct means Claude keeps proposing something you do not want.
--    A gap between accepted and ran means the tool was approved but never
--    produced a result (cancelled, or the turn was interrupted).
SELECT
  d.tool_name,
  d.tool_source,
  d.source,
  COUNT(*)                                                  AS proposed,
  COUNTIF(d.decision = 'accept')                            AS accepted,
  ROUND(100 * SAFE_DIVIDE(COUNTIF(d.decision = 'reject'), COUNT(*)), 1)
                                                            AS reject_pct,
  COUNTIF(r.tool_use_id IS NOT NULL)                        AS ran,
  COUNTIF(r.success = 'true')                               AS succeeded,
  ROUND(100 * SAFE_DIVIDE(COUNTIF(r.success = 'true'),
                          NULLIF(COUNTIF(r.tool_use_id IS NOT NULL), 0)), 1)
                                                            AS success_pct
FROM decisions d
LEFT JOIN results r USING (tool_use_id)
GROUP BY tool_name, tool_source, source
ORDER BY proposed DESC;

-- 2. Reliability and cost-in-context, per tool. out_bytes is what the tool pushes
--    back into the context window, so the p95 column is where your tokens go.
SELECT
  tool_name,
  COUNT(*)                                          AS runs,
  ROUND(100 * SAFE_DIVIDE(COUNTIF(success = 'true'), COUNT(*)), 1) AS success_pct,
  APPROX_QUANTILES(duration_ms, 100)[OFFSET(50)]    AS p50_ms,
  APPROX_QUANTILES(duration_ms, 100)[OFFSET(95)]    AS p95_ms,
  MAX(duration_ms)                                  AS max_ms,
  ROUND(SUM(duration_ms) / 1000.0, 1)               AS total_seconds,
  APPROX_QUANTILES(out_bytes, 100)[OFFSET(50)]      AS p50_out_bytes,
  APPROX_QUANTILES(out_bytes, 100)[OFFSET(95)]      AS p95_out_bytes,
  SUM(out_bytes)                                    AS total_out_bytes
FROM results
GROUP BY tool_name
ORDER BY total_seconds DESC;

-- 3. What actually fails, and how.
SELECT
  tool_name,
  error_type,
  COUNT(*)                                       AS failures,
  APPROX_QUANTILES(duration_ms, 100)[OFFSET(50)] AS p50_ms
FROM results
WHERE success != 'true'
GROUP BY tool_name, error_type
ORDER BY failures DESC;
