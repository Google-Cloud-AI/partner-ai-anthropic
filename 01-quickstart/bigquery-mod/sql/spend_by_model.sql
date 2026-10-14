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

-- Spend per day and model, with the columns of the otel-bq quickstart's spend_by_model view.
-- Reads the api_request table; label values are strings, so numbers are cast.
-- setup.sh fills in __PROJECT__, __DATASET__ (the views' dataset),
-- __TABLE_DATASET__ and __TABLE_PREFIX__.
CREATE OR REPLACE VIEW `__PROJECT__.__DATASET__.spend_by_model` AS
WITH events AS (
  SELECT
    timestamp,
    COALESCE(labels.model, '(unknown)') AS model,
    SAFE_CAST(labels.cost_usd              AS FLOAT64) AS cost_usd,
    SAFE_CAST(labels.input_tokens          AS INT64)   AS input_tokens,
    SAFE_CAST(labels.output_tokens         AS INT64)   AS output_tokens,
    SAFE_CAST(labels.cache_creation_tokens AS INT64)   AS cache_creation_tokens,
    SAFE_CAST(labels.cache_read_tokens     AS INT64)   AS cache_read_tokens
  FROM `__PROJECT__.__TABLE_DATASET__.__TABLE_PREFIX__api_request`
  WHERE TRUE
  -- A send the mod retried after BigQuery had stored it can leave two rows
  -- with the same insertId and timestamp; keep one.
  QUALIFY ROW_NUMBER() OVER (PARTITION BY timestamp, insertId ORDER BY receiveTimestamp) = 1
)
SELECT
  DATE(timestamp)             AS day,
  model,
  COUNT(*)                    AS api_requests,
  ROUND(SUM(cost_usd), 6)     AS cost_usd,
  SUM(input_tokens)           AS input_tokens,
  SUM(output_tokens)          AS output_tokens,
  SUM(cache_creation_tokens)  AS cache_creation_tokens,
  SUM(cache_read_tokens)      AS cache_read_tokens
FROM events
GROUP BY day, model;
