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
Setup Catalog — Vogue Concierge
=================================
Generates product images on Agent Platform and uploads everything to a NEW
GCS bucket separate from V1.

Creates:
  - GCS bucket: your-gcp-project-id-vogue-concierge
  - 30 product images
  - Updated products.json with image URLs

Usage:
    python scripts/setup_catalog.py
"""

import json
import os
import time

from google.cloud import storage
from google import genai
from google.genai import types

# Image generation runs through Gemini rather than Imagen. The Imagen publisher
# models (imagen-3.0-*, imagen-4.0-*, and the older imagegeneration@00x) no
# longer resolve on the Vertex endpoint — `from_pretrained` returns 404 — and
# `vertexai.preview.vision_models` is deprecated besides. `gemini-3.1-flash-image`
# is served from the global endpoint and returns the image as inline data on the
# response part.
#
# Pick the 3.1 generation, not 2.5: gemini-2.5-flash-image retires on
# 2026-10-02, and this is the first data-plane step bootstrap.sh runs, so a demo
# pinned to it stops working at its very first command. The call is identical —
# only the id differs.
IMAGE_MODEL = "gemini-3.1-flash-image"

PROJECT_ID = os.environ.get("VERTEXAI_PROJECT")
if not PROJECT_ID:
    raise RuntimeError(
        "VERTEXAI_PROJECT is not set. Export it (or copy .env.example to .env) with your "
        "GCP project id before running setup. See the README 'Setup' section."
    )
BUCKET_NAME = f"{PROJECT_ID}-vogue-concierge"
CATALOG_PATH = os.path.join(os.path.dirname(__file__), "..", "data", "products.json")


def create_bucket():
    """Create a new GCS bucket for Vogue Concierge assets."""
    client = storage.Client(project=PROJECT_ID)

    try:
        bucket = client.get_bucket(BUCKET_NAME)
        print(f"Bucket {BUCKET_NAME} already exists")
    except Exception:
        bucket = client.create_bucket(BUCKET_NAME, location="US")
        print(f"Created bucket: {BUCKET_NAME}")

    # Make images publicly readable
    bucket.iam_configuration.uniform_bucket_level_access_enabled = True
    bucket.patch()

    # Set public read policy
    policy = bucket.get_iam_policy(requested_policy_version=3)
    policy.bindings.append({
        "role": "roles/storage.objectViewer",
        "members": ["allUsers"],
    })
    bucket.set_iam_policy(policy)
    print(f"Set public read access on {BUCKET_NAME}")

    return bucket


def _generate_one(client: "genai.Client", prompt: str) -> bytes:
    """Return PNG bytes for `prompt`, or b"" if the model returned no image.

    The response can legitimately come back without an image part — a safety
    block returns text instead — so the caller treats empty bytes as "skip this
    product" rather than as a hard failure.
    """
    response = client.models.generate_content(
        model=IMAGE_MODEL,
        contents=prompt,
        config=types.GenerateContentConfig(
            response_modalities=["IMAGE"],
            image_config=types.ImageConfig(aspect_ratio="3:4"),
        ),
    )
    for candidate in response.candidates or []:
        for part in candidate.content.parts or []:
            if getattr(part, "inline_data", None) and part.inline_data.data:
                return part.inline_data.data
    return b""


def generate_images(catalog: list):
    """Generate product images and upload them to the assets bucket.

    Image generation is best-effort: a product whose image fails keeps an empty
    `image_url` and the catalog is still written. Setup is the first step of
    bootstrap.sh, and losing one picture is not a reason to abort a deploy.
    """
    # Constructing the client is inside the same error handling as generation:
    # if the image model is unavailable in this project, every product simply
    # ends up without a picture instead of killing bootstrap on step 1.
    try:
        genai_client = genai.Client(vertexai=True, project=PROJECT_ID, location="global")
    except Exception as e:
        print(f"WARNING: could not initialise the image model ({e}).")
        print("         Continuing without product images.")
        for product in catalog:
            product["image_url"] = ""
        return catalog

    client = storage.Client(project=PROJECT_ID)
    bucket = client.bucket(BUCKET_NAME)

    updated_catalog = []
    for i, product in enumerate(catalog):
        sku = product["sku"]
        image_filename = f"images/{sku.lower().replace('-', '_')}.png"
        image_url = f"https://storage.googleapis.com/{BUCKET_NAME}/{image_filename}"

        # Check if image already exists
        blob = bucket.blob(image_filename)
        if blob.exists():
            print(f"  [{i+1}/30] {sku} — image exists, skipping")
            product["image_url"] = image_url
            updated_catalog.append(product)
            continue

        print(f"  [{i+1}/30] Generating image for {sku}: {product['name']}")
        try:
            png = _generate_one(genai_client, product["image_prompt"])
            if png:
                blob.upload_from_string(png, content_type="image/png")
                print(f"           Uploaded to {image_url}")
            else:
                print(f"           WARNING: No image returned for {sku}")
                image_url = ""

        except Exception as e:
            print(f"           ERROR generating {sku}: {e}")
            image_url = ""

        product["image_url"] = image_url
        updated_catalog.append(product)

        # Rate limiting — be kind to the API
        if (i + 1) % 5 == 0:
            print(f"           Pausing 10s after {i+1} images...")
            time.sleep(10)
        else:
            time.sleep(2)

    return updated_catalog


def upload_data_files(catalog: list):
    """Upload catalog JSON and trend report to GCS."""
    client = storage.Client(project=PROJECT_ID)
    bucket = client.bucket(BUCKET_NAME)

    # Upload products.json
    blob = bucket.blob("data/products.json")
    blob.upload_from_string(json.dumps(catalog, indent=2), content_type="application/json")
    print(f"Uploaded data/products.json to GCS")

    # Upload trend report
    trend_path = os.path.join(os.path.dirname(__file__), "..", "data", "trend_report.md")
    if os.path.exists(trend_path):
        blob = bucket.blob("data/trend_report.md")
        blob.upload_from_filename(trend_path, content_type="text/markdown")
        print(f"Uploaded data/trend_report.md to GCS")


def main():
    print("=" * 60)
    print("Vogue Concierge — Catalog & Image Setup")
    print("=" * 60)

    # Load catalog
    with open(CATALOG_PATH, "r") as f:
        catalog = json.load(f)
    print(f"Loaded {len(catalog)} products\n")

    # Create bucket
    print("Step 1: Creating GCS bucket...")
    create_bucket()

    # Generate images
    print(f"\nStep 2: Generating {len(catalog)} product images...")
    updated_catalog = generate_images(catalog)

    # Save updated catalog locally
    print("\nStep 3: Saving updated catalog with image URLs...")
    with open(CATALOG_PATH, "w") as f:
        json.dump(updated_catalog, f, indent=2)
    print(f"Updated {CATALOG_PATH}")

    # Upload data files to GCS
    print("\nStep 4: Uploading data files to GCS...")
    upload_data_files(updated_catalog)

    # Summary
    success_count = sum(1 for p in updated_catalog if p.get("image_url"))
    print(f"\n{'=' * 60}")
    print(f"Catalog setup complete!")
    print(f"  Bucket: gs://{BUCKET_NAME}")
    print(f"  Images: {success_count}/{len(updated_catalog)} generated")
    print(f"  Public URL pattern: https://storage.googleapis.com/{BUCKET_NAME}/images/sku_XXX.png")
    print(f"{'=' * 60}")


if __name__ == "__main__":
    main()
