# Copyright 2026 The "Anthropic on Google Cloud" Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Create the BigQuery `orders` table used by the checkout flow.

Run once (idempotent — skips if the table already exists):
    python scripts/setup_orders.py

The `place_order` tool (agents/tools/order_tools.py) appends a row here for every
completed purchase. Append-only — orders are never updated after creation.
"""

import os

from google.cloud import bigquery

PROJECT_ID = os.environ.get("VERTEXAI_PROJECT")
if not PROJECT_ID:
    raise RuntimeError(
        "VERTEXAI_PROJECT is not set. Export it (or copy .env.example to .env) with your "
        "GCP project id before running setup. See the README 'Setup' section."
    )
DATASET = "vogue_concierge"
TABLE = "orders"

SCHEMA = [
    bigquery.SchemaField("order_id", "STRING", mode="REQUIRED"),
    bigquery.SchemaField("created_at", "TIMESTAMP"),
    bigquery.SchemaField("customer_id", "STRING"),          # nullable — guests allowed
    bigquery.SchemaField("sku", "STRING"),
    bigquery.SchemaField("product_name", "STRING"),
    bigquery.SchemaField("size", "STRING"),
    bigquery.SchemaField("quantity", "INTEGER"),
    bigquery.SchemaField("unit_price", "FLOAT"),
    bigquery.SchemaField("discount_percent", "INTEGER"),
    bigquery.SchemaField("discount_amount", "FLOAT"),
    bigquery.SchemaField("subtotal", "FLOAT"),
    bigquery.SchemaField("total", "FLOAT"),
    bigquery.SchemaField("payment_id", "STRING"),
    bigquery.SchemaField("payment_status", "STRING"),
    bigquery.SchemaField("points_earned", "INTEGER"),
    bigquery.SchemaField("loyalty_tier", "STRING"),
    bigquery.SchemaField("status", "STRING"),
    bigquery.SchemaField("estimated_delivery", "STRING"),
]


def main():
    client = bigquery.Client(project=PROJECT_ID)
    table_id = f"{PROJECT_ID}.{DATASET}.{TABLE}"
    table = bigquery.Table(table_id, schema=SCHEMA)
    table = client.create_table(table, exists_ok=True)
    print(f"Ready: {table_id} ({len(table.schema)} columns)")


if __name__ == "__main__":
    main()
