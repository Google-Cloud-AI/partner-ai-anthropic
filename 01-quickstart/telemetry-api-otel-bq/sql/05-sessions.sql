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

-- One row per session, joining all five event families on session.id.
--
-- The zoomed-out view of 04-prompts.sql: what a whole working session cost, how
-- long it ran, how much of it was tool and hook time, and how often Claude
-- proposed something the developer rejected.
--
-- Same pre-aggregate-then-join rule as 04 — never join the raw tables.

DECLARE window_days INT64 DEFAULT 30;

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
  labels.session_id AS session_id,
  COALESCE(ANY_VALUE(labels.user_email),
           CONCAT('id:', SUBSTR(ANY_VALUE(labels.user_id), 1, 12))) AS user_key,
  ANY_VALUE(resource.labels.task_id)              AS host,
  MIN(timestamp)                                  AS started_at,
  MAX(timestamp)                                  AS ended_at,
  COUNT(*)                                        AS api_calls,
  COUNT(DISTINCT labels.prompt_id)                AS turns,
  COUNT(DISTINCT labels.model)                    AS models_used,
  SUM(SAFE_CAST(labels.cost_usd      AS FLOAT64)) AS cost_usd,
  SUM(SAFE_CAST(labels.output_tokens AS INT64))   AS output_tokens,
  SUM(SAFE_CAST(labels.duration_ms   AS INT64))   AS api_ms
FROM `YOUR_PROJECT_ID.YOUR_SINK_DATASET.api_request`
WHERE timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL window_days DAY)
GROUP BY session_id;

CREATE TEMP TABLE dec AS
SELECT
  labels.session_id AS session_id,
  COUNT(*)                            AS tools_proposed,
  COUNTIF(labels.decision = 'reject') AS tools_rejected
FROM `YOUR_PROJECT_ID.YOUR_SINK_DATASET.tool_decision`
WHERE timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL window_days DAY)
GROUP BY session_id;

CREATE TEMP TABLE res AS
SELECT
  labels.session_id AS session_id,
  COUNT(*)                                    AS tool_runs,
  COUNTIF(labels.success != 'true')           AS tool_failures,
  SUM(SAFE_CAST(labels.duration_ms AS INT64)) AS tool_ms
FROM `YOUR_PROJECT_ID.YOUR_SINK_DATASET.tool_result`
WHERE timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL window_days DAY)
GROUP BY session_id;

CREATE TEMP TABLE resp AS
SELECT
  labels.session_id AS session_id,
  SUM(SAFE_CAST(labels.response_length AS INT64)) AS response_chars
FROM `YOUR_PROJECT_ID.YOUR_SINK_DATASET.assistant_response`
WHERE timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL window_days DAY)
GROUP BY session_id;

CREATE TEMP TABLE hook (session_id STRING, hook_runs INT64, hook_ms INT64);
IF hooks_exist THEN
  EXECUTE IMMEDIATE FORMAT("""
    INSERT INTO hook
    SELECT labels.session_id,
           COUNT(*),
           SUM(SAFE_CAST(labels.total_duration_ms AS INT64))
    FROM `YOUR_PROJECT_ID.YOUR_SINK_DATASET.hook_execution_complete`
    WHERE timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL %d DAY)
    GROUP BY 1
  """, window_days);
END IF;

SELECT
  DATE(a.started_at)                            AS day,
  a.user_key,
  a.host,
  a.session_id,
  TIMESTAMP_DIFF(a.ended_at, a.started_at, MINUTE) AS span_minutes,
  a.turns,
  a.api_calls,
  ROUND(a.cost_usd, 4)                          AS cost_usd,
  ROUND(SAFE_DIVIDE(a.cost_usd, a.turns), 5)    AS cost_per_turn,
  IFNULL(d.tools_proposed, 0)                   AS tools_proposed,
  ROUND(100 * SAFE_DIVIDE(d.tools_rejected, d.tools_proposed), 1) AS reject_pct,
  IFNULL(r.tool_runs, 0)                        AS tool_runs,
  IFNULL(r.tool_failures, 0)                    AS tool_failures,
  IFNULL(p.response_chars, 0)                   AS response_chars,
  ROUND(a.api_ms / 1000.0, 1)                   AS api_seconds,
  ROUND(IFNULL(r.tool_ms, 0) / 1000.0, 1)       AS tool_seconds,
  ROUND(IFNULL(h.hook_ms, 0) / 1000.0, 1)       AS hook_seconds,
  -- Hook time as a share of everything Claude Code spent doing work. A steadily
  -- rising number here means hooks are eating the session.
  ROUND(100 * SAFE_DIVIDE(IFNULL(h.hook_ms, 0),
        a.api_ms + IFNULL(r.tool_ms, 0) + IFNULL(h.hook_ms, 0)), 1) AS hook_pct
FROM api a
LEFT JOIN dec  d USING (session_id)
LEFT JOIN res  r USING (session_id)
LEFT JOIN resp p USING (session_id)
LEFT JOIN hook h USING (session_id)
ORDER BY day DESC, cost_usd DESC;
