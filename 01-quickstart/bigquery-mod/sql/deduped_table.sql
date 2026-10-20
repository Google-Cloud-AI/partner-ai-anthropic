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

-- A table with one row per insertId and timestamp: a send the mod retried
-- after BigQuery had stored it can leave two rows with the same insertId and
-- timestamp, and BigQuery removes such repeats only within about a minute.
-- setup.sh makes one of these per table, named like the table, and fills in
-- __PROJECT__, __TABLE_DATASET__, __DEDUPED_DATASET__ (the views' dataset) and
-- __VIEW_TABLE__ (the table's name, prefix included).
-- A filter on timestamp still limits which partitions are read, since the
-- duplicates are found within each timestamp.
CREATE OR REPLACE VIEW `__PROJECT__.__DEDUPED_DATASET__.__VIEW_TABLE__` AS
SELECT *
FROM `__PROJECT__.__TABLE_DATASET__.__VIEW_TABLE__`
WHERE TRUE
QUALIFY ROW_NUMBER() OVER (PARTITION BY timestamp, insertId ORDER BY receiveTimestamp) = 1;
