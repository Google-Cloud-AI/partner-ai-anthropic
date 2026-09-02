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

"""
Setup BigQuery — Vogue Concierge
==================================
Creates a NEW BigQuery dataset 'vogue_concierge' and populates
inventory + loyalty_program tables with data for all 30 SKUs.

Completely separate from V1's retail_concierge dataset.

Usage:
    python scripts/setup_bigquery.py
"""

import json
import os
import random
from google.cloud import bigquery

PROJECT_ID = os.environ.get("VERTEXAI_PROJECT")
if not PROJECT_ID:
    raise RuntimeError(
        "VERTEXAI_PROJECT is not set. Export it (or copy .env.example to .env) with your "
        "GCP project id before running setup. See the README 'Setup' section."
    )
DATASET_ID = "vogue_concierge"
CATALOG_PATH = os.path.join(os.path.dirname(__file__), "..", "data", "products.json")


def create_dataset(client: bigquery.Client):
    """Create the vogue_concierge dataset."""
    dataset_ref = bigquery.Dataset(f"{PROJECT_ID}.{DATASET_ID}")
    dataset_ref.location = "US"
    dataset_ref.description = "Vogue Concierge AI Boutique — inventory and loyalty data"

    try:
        client.get_dataset(dataset_ref)
        print(f"Dataset {DATASET_ID} already exists")
    except Exception:
        client.create_dataset(dataset_ref)
        print(f"Created dataset {DATASET_ID}")


def replace_table_rows(client: bigquery.Client, table_id: str, schema: list, rows: list, label: str):
    """Atomically replace a table's contents with `rows`, via a load job.

    This deliberately does not use `insert_rows_json`. Streaming inserts land in
    a write-optimised buffer that DML cannot touch for up to ~30 minutes, so the
    obvious-looking "DELETE FROM t WHERE true, then stream the new rows" pairing
    is not actually idempotent: re-running the script within that window leaves
    the previous rows in place and the tools then read duplicate SKUs.

    A load job with WRITE_TRUNCATE swaps the whole table in one atomic operation,
    is immediately queryable, and costs nothing. `job.result()` raises on
    failure, so a bad load stops setup instead of printing an error and carrying
    on with a half-populated table.
    """
    job_config = bigquery.LoadJobConfig(
        schema=schema,
        write_disposition=bigquery.WriteDisposition.WRITE_TRUNCATE,
    )
    client.load_table_from_json(rows, table_id, job_config=job_config).result()
    print(f"Loaded {len(rows)} {label}")


def create_inventory_table(client: bigquery.Client, catalog: list):
    """Create and populate the inventory table with stock for all 30 products."""
    table_id = f"{PROJECT_ID}.{DATASET_ID}.inventory"

    schema = [
        bigquery.SchemaField("sku", "STRING", mode="REQUIRED"),
        bigquery.SchemaField("product_name", "STRING", mode="REQUIRED"),
        bigquery.SchemaField("category", "STRING"),
        bigquery.SchemaField("size", "STRING", mode="REQUIRED"),
        bigquery.SchemaField("quantity_in_stock", "INTEGER", mode="REQUIRED"),
        bigquery.SchemaField("price", "FLOAT", mode="REQUIRED"),
        bigquery.SchemaField("color", "STRING"),
        bigquery.SchemaField("material", "STRING"),
    ]

    table = bigquery.Table(table_id, schema=schema)
    table = client.create_table(table, exists_ok=True)
    print(f"Created/verified table: {table_id}")

    # Generate inventory rows
    rows = []
    random.seed(42)  # Reproducible data
    for product in catalog:
        for size in product["sizes"]:
            qty = random.randint(0, 20)
            # Make some items low stock for demo purposes
            if product["sku"] in ["SKU-005", "SKU-015", "SKU-018"]:
                qty = random.randint(0, 3)
            rows.append({
                "sku": product["sku"],
                "product_name": product["name"],
                "category": product["category"],
                "size": size,
                "quantity_in_stock": qty,
                "price": product["price"],
                "color": product.get("color", ""),
                "material": product.get("material", ""),
            })

    replace_table_rows(client, table_id, schema, rows, "inventory rows")


def create_loyalty_table(client: bigquery.Client):
    """Create and populate the loyalty program table."""
    table_id = f"{PROJECT_ID}.{DATASET_ID}.loyalty_program"

    schema = [
        bigquery.SchemaField("customer_id", "STRING", mode="REQUIRED"),
        bigquery.SchemaField("customer_name", "STRING", mode="REQUIRED"),
        bigquery.SchemaField("tier", "STRING", mode="REQUIRED"),
        bigquery.SchemaField("discount_percent", "INTEGER", mode="REQUIRED"),
        bigquery.SchemaField("points_balance", "INTEGER"),
        bigquery.SchemaField("free_shipping", "BOOLEAN"),
        bigquery.SchemaField("member_since", "DATE"),
    ]

    table = bigquery.Table(table_id, schema=schema)
    table = client.create_table(table, exists_ok=True)
    print(f"Created/verified table: {table_id}")

    # Sample loyalty customers
    customers = [
        {"customer_id": "CUST-1001", "customer_name": "Amara Johnson", "tier": "Platinum", "discount_percent": 20, "points_balance": 4850, "free_shipping": True, "member_since": "2022-03-15"},
        {"customer_id": "CUST-1002", "customer_name": "Luca Moretti", "tier": "Gold", "discount_percent": 15, "points_balance": 3200, "free_shipping": True, "member_since": "2023-01-20"},
        {"customer_id": "CUST-1003", "customer_name": "Sophia Chen", "tier": "Silver", "discount_percent": 10, "points_balance": 1800, "free_shipping": False, "member_since": "2023-08-10"},
        {"customer_id": "CUST-1004", "customer_name": "James Okonkwo", "tier": "Gold", "discount_percent": 15, "points_balance": 2750, "free_shipping": True, "member_since": "2022-11-05"},
        {"customer_id": "CUST-1005", "customer_name": "Elena Vasquez", "tier": "Bronze", "discount_percent": 5, "points_balance": 650, "free_shipping": False, "member_since": "2024-06-22"},
        {"customer_id": "CUST-1006", "customer_name": "Yuki Tanaka", "tier": "Platinum", "discount_percent": 20, "points_balance": 5100, "free_shipping": True, "member_since": "2021-12-01"},
        {"customer_id": "CUST-1007", "customer_name": "Marcus Schmidt", "tier": "Silver", "discount_percent": 10, "points_balance": 1400, "free_shipping": False, "member_since": "2024-02-14"},
        {"customer_id": "CUST-1008", "customer_name": "Priya Patel", "tier": "Gold", "discount_percent": 15, "points_balance": 3600, "free_shipping": True, "member_since": "2023-04-30"},
        {"customer_id": "CUST-1009", "customer_name": "Oliver Brooks", "tier": "Bronze", "discount_percent": 5, "points_balance": 320, "free_shipping": False, "member_since": "2025-01-10"},
        {"customer_id": "CUST-1010", "customer_name": "Camille Dubois", "tier": "Platinum", "discount_percent": 20, "points_balance": 4200, "free_shipping": True, "member_since": "2022-07-18"},
        {"customer_id": "CUST-1042", "customer_name": "Alex Rivera", "tier": "Gold", "discount_percent": 15, "points_balance": 2900, "free_shipping": True, "member_since": "2023-05-12"},
        {"customer_id": "CUST-1050", "customer_name": "Zara Mitchell", "tier": "Silver", "discount_percent": 10, "points_balance": 1100, "free_shipping": False, "member_since": "2024-09-01"},
    ]

    replace_table_rows(client, table_id, schema, customers, "loyalty program members")


def main():
    print("=" * 60)
    print("Vogue Concierge — BigQuery Setup")
    print("=" * 60)

    # Load catalog
    with open(CATALOG_PATH, "r") as f:
        catalog = json.load(f)
    print(f"Loaded {len(catalog)} products from catalog")

    client = bigquery.Client(project=PROJECT_ID)

    create_dataset(client)
    create_inventory_table(client, catalog)
    create_loyalty_table(client)

    print("\nBigQuery setup complete!")
    print(f"  Dataset: {PROJECT_ID}.{DATASET_ID}")
    print(f"  Tables: inventory, loyalty_program")


if __name__ == "__main__":
    main()
