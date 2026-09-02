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

"""Catalog Search Tool — works locally and in Agent Runtime"""

import json
import os
from typing import Optional

# Try multiple paths for the catalog file
_catalog_cache: Optional[list] = None

def _find_catalog() -> str:
    """Find products.json in various possible locations."""
    candidates = [
        os.path.join(os.path.dirname(__file__), "..", "..", "data", "products.json"),
        os.path.join(os.getcwd(), "data", "products.json"),
        "/code/data/products.json",
        "data/products.json",
    ]
    for path in candidates:
        abs_path = os.path.abspath(path)
        if os.path.exists(abs_path):
            return abs_path
    return ""


def _load_catalog() -> list:
    global _catalog_cache
    if _catalog_cache is None:
        catalog_file = _find_catalog()
        if catalog_file:
            with open(catalog_file, "r") as f:
                _catalog_cache = json.load(f)
            print(f"Catalog loaded from {catalog_file}: {len(_catalog_cache)} products")
        else:
            print("WARNING: products.json not found in any location")
            _catalog_cache = []
    return _catalog_cache


def _audience_ok(product: dict, audience: str) -> bool:
    """True if the product fits the requested audience. women/men also include
    unisex; unisex means gender-neutral items only."""
    if audience not in ("women", "men", "unisex"):
        return True
    pa = product.get("audience", "unisex")
    if audience == "unisex":
        return pa == "unisex"
    return pa in (audience, "unisex")


def _local_search(query: str, max_results: int = 5, audience: str = "") -> list:
    catalog = _load_catalog()
    query_lower = query.lower()
    query_terms = query_lower.split()
    scored = []
    for product in catalog:
        if not _audience_ok(product, audience):
            continue
        searchable = " ".join([
            product.get("name", ""),
            product.get("description", ""),
            product.get("category", ""),
            product.get("material", ""),
            product.get("color", ""),
            " ".join(product.get("occasions", [])),
            " ".join(product.get("tags", [])),
        ]).lower()
        score = sum(1 for term in query_terms if term in searchable)
        if score > 0:
            scored.append((score, product))
    scored.sort(key=lambda x: x[0], reverse=True)
    return [p for _, p in scored[:max_results]]


async def catalog_search(query: str, audience: str = "") -> dict:
    """Search the Vogue Concierge product catalog for items matching the query.

    Use this tool when a customer asks about products, recommendations,
    outfit suggestions, or wants to browse the catalog.

    Args:
        query: Natural language search query describing what the customer wants.
               Examples: "summer dress", "leather accessories", "business casual outfit"
        audience: Optional. Set to "women", "men", or "unisex" to tailor results to
                  who the customer is shopping for (women's/men's also include unisex
                  pieces). Pass it whenever you know the audience; leave it empty if
                  you don't yet know.

    Returns:
        Dictionary with matching products including name, SKU, price, description,
        and image URL for each result.
    """
    aud = (audience or "").strip().lower()

    # When NO audience is specified, use the Vertex RAG corpus (semantic search).
    # When an audience IS specified, skip RAG and use the local structured catalog
    # (which has a reliable `audience` field) so the gender filter is exact — RAG
    # returns free text that can't be filtered by audience reliably.
    if aud not in ("women", "men", "unisex"):
        try:
            from .rag_retrieval import retrieve

            hits = retrieve(query, top_k=5)
            if hits:
                return {"source": "rag", "results": hits}
        except Exception as e:
            print(f"RAG search failed ({e}), using local catalog")

    results = _local_search(query, audience=aud)
    if not results:
        msg = "No products found. Try broader terms."
        if aud in ("women", "men", "unisex"):
            msg = f"No {aud} products found for that. Try broader terms or a different audience."
        return {"source": "local", "results": [], "message": msg}

    formatted = []
    for p in results:
        formatted.append({
            "sku": p["sku"], "name": p["name"], "price": p["price"],
            "category": p["category"], "description": p["description"],
            "color": p.get("color", ""), "material": p.get("material", ""),
            "occasions": p.get("occasions", []), "audience": p.get("audience", "unisex"), "image_url": p.get("image_url", ""),
        })
    return {"source": "local", "results": formatted}
