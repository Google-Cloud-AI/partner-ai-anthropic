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

-- Hook overhead, from `hook_execution_complete`.
--
-- Hooks run on the critical path: a slow PreToolUse hook delays every tool call.
-- Nothing about this is visible in metrics.
--
-- `hook_execution_complete` already carries total_duration_ms, so there is no
-- need to join back to `hook_execution_start`.

-- FRESH-DEPLOYMENT NOTE. The sink creates a table the first time an event of
-- that type is written. If nobody has configured a hook yet, the
-- hook_execution_complete table does not exist and querying it is a hard error.
-- The guard below returns an explanation instead.

DECLARE window_days INT64 DEFAULT 30;

DECLARE hooks_exist BOOL DEFAULT (
  SELECT COUNT(*) > 0
  FROM `YOUR_PROJECT_ID.YOUR_SINK_DATASET`.INFORMATION_SCHEMA.TABLES
  WHERE table_name = 'hook_execution_complete'
);

IF NOT hooks_exist THEN
  SELECT 'No hook_execution_complete table yet — no hook has fired since the sink was created. Nothing to report.' AS status;
  RETURN;
END IF;

CREATE TEMP TABLE hooks AS
SELECT
  timestamp,
  labels.hook_name   AS hook_name,    -- e.g. "PreToolUse:Read"
  labels.hook_event  AS hook_event,   -- e.g. "PreToolUse"
  labels.hook_source AS hook_source,  -- user / project / managed / merged
  labels.session_id  AS session_id,
  SAFE_CAST(labels.total_duration_ms        AS INT64) AS duration_ms,
  SAFE_CAST(labels.num_hooks                AS INT64) AS num_hooks,
  SAFE_CAST(labels.num_success              AS INT64) AS num_success,
  SAFE_CAST(labels.num_blocking             AS INT64) AS num_blocking,
  SAFE_CAST(labels.num_cancelled            AS INT64) AS num_cancelled,
  SAFE_CAST(labels.num_non_blocking_error   AS INT64) AS num_errors,
  SAFE_CAST(labels.stdout_chars             AS INT64) AS stdout_chars
FROM `YOUR_PROJECT_ID.YOUR_SINK_DATASET.hook_execution_complete`
WHERE timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL window_days DAY);

-- 1. Cost of each hook, worst first. total_seconds is real time developers wait.
SELECT
  hook_name,
  hook_event,
  hook_source,
  COUNT(*)                                       AS invocations,
  APPROX_QUANTILES(duration_ms, 100)[OFFSET(50)] AS p50_ms,
  APPROX_QUANTILES(duration_ms, 100)[OFFSET(95)] AS p95_ms,
  MAX(duration_ms)                               AS max_ms,
  ROUND(SUM(duration_ms) / 1000.0, 1)            AS total_seconds,
  SUM(num_blocking)                              AS blocked,
  SUM(num_cancelled)                             AS cancelled,
  SUM(num_errors)                                AS errors
FROM hooks
GROUP BY hook_name, hook_event, hook_source
ORDER BY total_seconds DESC;

-- 2. Hook time per session, to see whether the overhead is broad or one outlier.
SELECT
  session_id,
  COUNT(*)                            AS hook_runs,
  ROUND(SUM(duration_ms) / 1000.0, 1) AS hook_seconds,
  MAX(duration_ms)                    AS slowest_ms,
  SUM(num_blocking)                   AS blocked
FROM hooks
GROUP BY session_id
HAVING hook_seconds > 0
ORDER BY hook_seconds DESC
LIMIT 25;
