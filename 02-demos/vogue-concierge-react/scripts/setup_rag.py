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
Setup RAG — Vogue Concierge
==============================
Creates a NEW Agent Platform RAG corpus and ingests product catalog + trend report.

Separate from V1's RAG corpus.

Usage:
    python scripts/setup_rag.py
"""

import json
import os
import time

import vertexai

# `agentplatform.rag` ships inside google-cloud-aiplatform and is where both
# `vertexai.preview.rag` and `vertexai.rag` now redirect — each of those emits a
# deprecation warning pointing here, so moving to `vertexai.rag` would only swap
# one deprecated import for another. Retrieval and chunking knobs live in config
# objects in this API rather than as flat keyword arguments.
from agentplatform import rag

PROJECT_ID = os.environ.get("VERTEXAI_PROJECT")
if not PROJECT_ID:
    raise RuntimeError(
        "VERTEXAI_PROJECT is not set. Export it (or copy .env.example to .env) with your "
        "GCP project id before running setup. See the README 'Setup' section."
    )
RAG_REGION = "us-west1"  # Same region as endpoint to avoid cross-region issues (V1 Fix 16)
BUCKET_NAME = f"{PROJECT_ID}-vogue-concierge"
CORPUS_DISPLAY_NAME = "vogue-concierge-catalog"


def create_corpus():
    """Create a new RAG corpus for Vogue Concierge."""
    vertexai.init(project=PROJECT_ID, location=RAG_REGION)

    # Check if corpus already exists
    existing = rag.list_corpora()
    for corpus in existing:
        if corpus.display_name == CORPUS_DISPLAY_NAME:
            print(f"Corpus '{CORPUS_DISPLAY_NAME}' already exists: {corpus.name}")
            return corpus

    # Create new corpus
    corpus = rag.create_corpus(
        display_name=CORPUS_DISPLAY_NAME,
        description="Vogue Concierge AI Boutique — product catalog and trend data",
    )
    print(f"Created corpus: {corpus.name}")
    return corpus


def prepare_catalog_for_rag(catalog_path: str) -> str:
    """Convert product catalog JSON to a text file suitable for RAG ingestion."""
    with open(catalog_path, "r") as f:
        catalog = json.load(f)

    lines = []
    lines.append("# Vogue Concierge — Product Catalog\n")
    lines.append(f"Total products: {len(catalog)}\n\n")

    for product in catalog:
        lines.append(f"## {product['name']} ({product['sku']})")
        lines.append(f"Price: ${product['price']:.2f}")
        lines.append(f"Category: {product['category']}")
        lines.append(f"Color: {product.get('color', 'N/A')}")
        lines.append(f"Material: {product.get('material', 'N/A')}")
        lines.append(f"Sizes: {', '.join(product.get('sizes', []))}")
        lines.append(f"Occasions: {', '.join(product.get('occasions', []))}")
        lines.append(f"Description: {product['description']}")
        if product.get("image_url"):
            lines.append(f"Image: {product['image_url']}")
        lines.append("")  # blank line between products

    output_path = "/tmp/vogue_catalog_for_rag.md"
    with open(output_path, "w") as f:
        f.write("\n".join(lines))

    print(f"Prepared catalog text file: {output_path} ({len(catalog)} products)")
    return output_path


def ingest_files(corpus):
    """Upload and ingest files into the RAG corpus."""
    from google.cloud import storage

    client = storage.Client(project=PROJECT_ID)
    bucket = client.bucket(BUCKET_NAME)

    # Prepare catalog text for RAG
    catalog_path = os.path.join(os.path.dirname(__file__), "..", "data", "products.json")
    catalog_text_path = prepare_catalog_for_rag(catalog_path)

    # Upload catalog text to GCS for RAG
    blob = bucket.blob("rag/catalog.md")
    blob.upload_from_filename(catalog_text_path, content_type="text/markdown")
    print(f"Uploaded catalog text to gs://{BUCKET_NAME}/rag/catalog.md")

    # Upload trend report to GCS for RAG
    trend_path = os.path.join(os.path.dirname(__file__), "..", "data", "trend_report.md")
    blob = bucket.blob("rag/trend_report.md")
    blob.upload_from_filename(trend_path, content_type="text/markdown")
    print(f"Uploaded trend report to gs://{BUCKET_NAME}/rag/trend_report.md")

    # Ingest from GCS
    print("\nIngesting files into RAG corpus...")
    gcs_uris = [
        f"gs://{BUCKET_NAME}/rag/catalog.md",
        f"gs://{BUCKET_NAME}/rag/trend_report.md",
    ]

    # import_files returns a long-running operation, and the service returns a
    # transient 500 often enough that a single attempt is not good enough here:
    # this is the last step of the data plane, so failing it throws away the
    # images and BigQuery tables that bootstrap.sh just spent several minutes
    # building. Retry with a linear backoff before giving up.
    last_error = None
    for attempt in range(1, 5):
        try:
            response = rag.import_files(
                corpus_name=corpus.name,
                paths=gcs_uris,
                transformation_config=rag.TransformationConfig(
                    chunking_config=rag.ChunkingConfig(chunk_size=512, chunk_overlap=100),
                ),
            )
            print(f"RAG ingestion complete: {response.imported_rag_files_count} files imported")
            return response
        except Exception as e:  # noqa: BLE001 — any failure here is worth retrying
            last_error = e
            print(f"  import attempt {attempt}/4 failed ({type(e).__name__}: {e})")
            if attempt < 4:
                delay = 15 * attempt
                print(f"  retrying in {delay}s…")
                time.sleep(delay)

    raise RuntimeError(
        "RAG ingestion failed after 4 attempts. The corpus was created and the "
        f"source files are in GCS, so re-running this script will resume: {last_error}"
    )


def test_rag_query(corpus):
    """Test the RAG corpus with a sample query."""
    print("\nTesting RAG query: 'summer wedding dress'")
    response = rag.retrieval_query(
        text="summer wedding dress",
        rag_resources=[rag.RagResource(rag_corpus=corpus.name)],
        rag_retrieval_config=rag.RagRetrievalConfig(
            top_k=3,
            filter=rag.Filter(vector_distance_threshold=0.5),
        ),
    )

    if response and response.contexts and response.contexts.contexts:
        for i, ctx in enumerate(response.contexts.contexts):
            print(f"  Result {i+1} (score: {ctx.score:.3f}): {ctx.text[:100]}...")
    else:
        print("  No results — corpus may still be indexing. Try again in a few minutes.")


def main():
    print("=" * 60)
    print("Vogue Concierge — RAG Setup")
    print("=" * 60)

    # Create corpus
    print("\nStep 1: Creating RAG corpus...")
    corpus = create_corpus()

    # Ingest files
    print("\nStep 2: Ingesting files...")
    ingest_files(corpus)

    # Wait a moment for indexing
    print("\nWaiting 30 seconds for indexing...")
    time.sleep(30)

    # Test
    print("\nStep 3: Testing RAG query...")
    test_rag_query(corpus)

    print(f"\n{'=' * 60}")
    print("RAG setup complete!")
    print(f"  Corpus: {corpus.name}")
    print(f"  Region: {RAG_REGION}")
    print(f"  Files: catalog.md, trend_report.md")
    print(f"{'=' * 60}")
    print("\nAdd this to your .env (bootstrap.sh captures it automatically):")
    # Machine-readable line — bootstrap.sh greps for '^RAG_CORPUS_RESOURCE='.
    print(f"RAG_CORPUS_RESOURCE={corpus.name}")


if __name__ == "__main__":
    main()
