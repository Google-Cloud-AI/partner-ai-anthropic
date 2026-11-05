-- Copyright 2026 The "Anthropic on Google Cloud" Authors
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     https://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

-- One row per day x user x model: usage, cost and tool calls. The cost and
-- token columns match daily_spend and spend_by_model.
--
-- Tool events carry no model, so each tool call takes the model of the API
-- request that asked for it (labels.request_id). Every source keeps one row per
-- insertId (the sink delivers at least once) and is aggregated before the join,
-- so nothing is counted twice.
-- create-views.sh fills in __PROJECT__, __DATASET__ (the views' dataset) and
-- __TABLE_DATASET__ (the sink's dataset).
CREATE OR REPLACE VIEW `__PROJECT__.__DATASET__.daily_usage`
OPTIONS (description = "Claude Code usage, cost and tool calls per day x user x model. Tool calls are attributed to the model of the API request that issued them.")
AS
WITH api AS (
  SELECT
    timestamp,
    labels.request_id AS request_id,
    labels.session_id AS session_id,
    COALESCE(NULLIF(labels.user_email, ''), CONCAT('id:', labels.user_id)) AS user,
    COALESCE(labels.model, '(unknown)') AS model,
    SAFE_CAST(labels.cost_usd              AS FLOAT64) AS cost_usd,
    SAFE_CAST(labels.input_tokens          AS INT64)   AS input_tokens,
    SAFE_CAST(labels.output_tokens         AS INT64)   AS output_tokens,
    SAFE_CAST(labels.cache_creation_tokens AS INT64)   AS cache_creation_tokens,
    SAFE_CAST(labels.cache_read_tokens     AS INT64)   AS cache_read_tokens
  FROM `__PROJECT__.__TABLE_DATASET__.api_request`
  WHERE TRUE
  QUALIFY ROW_NUMBER() OVER (PARTITION BY insertId) = 1
),
request_model AS (
  SELECT request_id, ANY_VALUE(model) AS model
  FROM api
  WHERE request_id IS NOT NULL
  GROUP BY request_id
),
api_daily AS (
  SELECT
    DATE(timestamp) AS day, user, model,
    COUNT(DISTINCT session_id)  AS sessions,
    COUNT(*)                    AS api_requests,
    ROUND(SUM(cost_usd), 6)     AS cost_usd,
    SUM(input_tokens)           AS input_tokens,
    SUM(output_tokens)          AS output_tokens,
    SUM(cache_creation_tokens)  AS cache_creation_tokens,
    SUM(cache_read_tokens)      AS cache_read_tokens
  FROM api
  GROUP BY day, user, model
),
decisions AS (
  SELECT
    d.timestamp,
    COALESCE(NULLIF(d.labels.user_email, ''), CONCAT('id:', d.labels.user_id)) AS user,
    COALESCE(m.model, '(unknown)') AS model,
    d.labels.decision AS decision
  FROM `__PROJECT__.__TABLE_DATASET__.tool_decision` AS d
  LEFT JOIN request_model AS m ON m.request_id = d.labels.request_id
  WHERE TRUE
  QUALIFY ROW_NUMBER() OVER (PARTITION BY d.insertId) = 1
),
decisions_daily AS (
  SELECT
    DATE(timestamp) AS day, user, model,
    COUNT(*)                        AS tool_calls_proposed,
    COUNTIF(decision = 'reject')    AS tool_calls_rejected
  FROM decisions
  GROUP BY day, user, model
),
results AS (
  SELECT
    r.timestamp,
    COALESCE(NULLIF(r.labels.user_email, ''), CONCAT('id:', r.labels.user_id)) AS user,
    COALESCE(m.model, '(unknown)') AS model,
    r.labels.success AS success
  FROM `__PROJECT__.__TABLE_DATASET__.tool_result` AS r
  LEFT JOIN request_model AS m ON m.request_id = r.labels.request_id
  WHERE TRUE
  QUALIFY ROW_NUMBER() OVER (PARTITION BY r.insertId) = 1
),
results_daily AS (
  SELECT
    DATE(timestamp) AS day, user, model,
    COUNT(*)                                    AS tool_calls,
    COUNTIF(success IS DISTINCT FROM 'true')    AS tool_calls_failed
  FROM results
  GROUP BY day, user, model
)
SELECT
  day, user, model,
  IFNULL(sessions, 0)              AS sessions,
  IFNULL(api_requests, 0)          AS api_requests,
  IFNULL(cost_usd, 0)              AS cost_usd,
  IFNULL(input_tokens, 0)          AS input_tokens,
  IFNULL(output_tokens, 0)         AS output_tokens,
  IFNULL(cache_creation_tokens, 0) AS cache_creation_tokens,
  IFNULL(cache_read_tokens, 0)     AS cache_read_tokens,
  IFNULL(tool_calls_proposed, 0)   AS tool_calls_proposed,
  IFNULL(tool_calls_rejected, 0)   AS tool_calls_rejected,
  IFNULL(tool_calls, 0)            AS tool_calls,
  IFNULL(tool_calls_failed, 0)     AS tool_calls_failed
FROM api_daily
FULL OUTER JOIN decisions_daily USING (day, user, model)
FULL OUTER JOIN results_daily   USING (day, user, model);
