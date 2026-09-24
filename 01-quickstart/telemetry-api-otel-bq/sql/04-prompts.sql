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

-- One row per user turn, joining all five event families on prompt.id.
--
-- This is the query metrics structurally cannot produce: cost, tool activity,
-- response size and hook overhead for the SAME turn, side by side. It answers
-- "what did that one request actually cost me, and where did the time go?"
--
-- Each family is pre-aggregated to one row per prompt BEFORE joining. Joining
-- the raw tables would fan out — a turn with 6 tool calls would count its cost
-- six times.

DECLARE window_days INT64 DEFAULT 7;

-- The sink only creates a table once that event type has been written. Projects
-- with no hooks configured have no hook_execution_complete table, and querying a
-- missing table is a hard error — so hook time is collected conditionally and
-- shows as 0 when unavailable.
DECLARE hooks_exist BOOL DEFAULT (
  SELECT COUNT(*) > 0
  FROM `YOUR_PROJECT_ID.YOUR_SINK_DATASET`.INFORMATION_SCHEMA.TABLES
  WHERE table_name = 'hook_execution_complete'
);

CREATE TEMP TABLE api AS
SELECT
  labels.prompt_id  AS prompt_id,
  ANY_VALUE(labels.session_id)  AS session_id,
  MIN(timestamp)                AS started_at,
  COALESCE(ANY_VALUE(labels.user_email),
           CONCAT('id:', SUBSTR(ANY_VALUE(labels.user_id), 1, 12))) AS user_key,
  ANY_VALUE(labels.model)       AS model,
  COUNT(*)                                            AS api_calls,
  SUM(SAFE_CAST(labels.cost_usd      AS FLOAT64))     AS cost_usd,
  SUM(SAFE_CAST(labels.input_tokens  AS INT64))       AS input_tokens,
  SUM(SAFE_CAST(labels.output_tokens AS INT64))       AS output_tokens,
  SUM(SAFE_CAST(labels.cache_read_tokens AS INT64))   AS cache_read_tokens,
  SUM(SAFE_CAST(labels.duration_ms   AS INT64))       AS api_ms
FROM `YOUR_PROJECT_ID.YOUR_SINK_DATASET.api_request`
WHERE timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL window_days DAY)
GROUP BY prompt_id;

CREATE TEMP TABLE dec AS
SELECT
  labels.prompt_id AS prompt_id,
  COUNT(*)                                  AS tools_proposed,
  COUNTIF(labels.decision = 'reject')       AS tools_rejected,
  STRING_AGG(DISTINCT labels.tool_name ORDER BY labels.tool_name) AS tools_used
FROM `YOUR_PROJECT_ID.YOUR_SINK_DATASET.tool_decision`
WHERE timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL window_days DAY)
GROUP BY prompt_id;

CREATE TEMP TABLE res AS
SELECT
  labels.prompt_id AS prompt_id,
  COUNT(*)                                             AS tool_runs,
  COUNTIF(labels.success != 'true')                    AS tool_failures,
  SUM(SAFE_CAST(labels.duration_ms AS INT64))          AS tool_ms,
  SUM(SAFE_CAST(labels.tool_result_size_bytes AS INT64)) AS tool_out_bytes
FROM `YOUR_PROJECT_ID.YOUR_SINK_DATASET.tool_result`
WHERE timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL window_days DAY)
GROUP BY prompt_id;

CREATE TEMP TABLE resp AS
SELECT
  labels.prompt_id AS prompt_id,
  COUNT(*)                                            AS responses,
  SUM(SAFE_CAST(labels.response_length AS INT64))     AS response_chars
FROM `YOUR_PROJECT_ID.YOUR_SINK_DATASET.assistant_response`
WHERE timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL window_days DAY)
GROUP BY prompt_id;

CREATE TEMP TABLE hook (prompt_id STRING, hook_ms INT64);
IF hooks_exist THEN
  EXECUTE IMMEDIATE FORMAT("""
    INSERT INTO hook
    SELECT labels.prompt_id,
           SUM(SAFE_CAST(labels.total_duration_ms AS INT64))
    FROM `YOUR_PROJECT_ID.YOUR_SINK_DATASET.hook_execution_complete`
    WHERE timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL %d DAY)
    GROUP BY 1
  """, window_days);
END IF;

SELECT
  a.started_at,
  a.user_key,
  a.model,
  a.prompt_id,
  a.api_calls,
  ROUND(a.cost_usd, 5)                       AS cost_usd,
  a.output_tokens,
  a.cache_read_tokens,
  IFNULL(d.tools_proposed, 0)                AS tools_proposed,
  IFNULL(d.tools_rejected, 0)                AS tools_rejected,
  IFNULL(r.tool_runs, 0)                     AS tool_runs,
  IFNULL(r.tool_failures, 0)                 AS tool_failures,
  IFNULL(p.response_chars, 0)                AS response_chars,
  -- Where the wall clock went on this turn.
  ROUND(a.api_ms / 1000.0, 1)                AS api_seconds,
  ROUND(IFNULL(r.tool_ms, 0) / 1000.0, 1)    AS tool_seconds,
  ROUND(IFNULL(h.hook_ms, 0) / 1000.0, 1)    AS hook_seconds,
  -- What the tools pushed back into context, which is what you pay for next turn.
  IFNULL(r.tool_out_bytes, 0)                AS tool_out_bytes,
  d.tools_used
FROM api a
LEFT JOIN dec  d USING (prompt_id)
LEFT JOIN res  r USING (prompt_id)
LEFT JOIN resp p USING (prompt_id)
LEFT JOIN hook h USING (prompt_id)
ORDER BY cost_usd DESC
LIMIT 100;
