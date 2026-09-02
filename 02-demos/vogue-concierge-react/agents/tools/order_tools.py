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

"""BigQuery-backed SIGNAL tools for the agent (run on Agent Runtime).

IMPORTANT — where the real work happens:
These tools do NOT touch BigQuery. That is a design choice, not a limitation:
deployed agents run as the Agent Runtime service agent and can reach BigQuery
directly or through the MCP Toolbox (the Inventory specialist does exactly that).
The transactional path is kept separate so the money-moving logic stays off the
model and the storefront can render the outcome. These tools validate input and
SIGNAL intent by returning their parameters; the Cloud Run layer (app.py for the
React UI, a2a/server.py for Gemini Enterprise) sees the tool call in the Agent
Runtime event stream and runs the REAL BigQuery action there
(`checkout.finalize_order` / `checkout.loyalty_status`).

  * `place_order`   -> Cloud Run runs the real checkout (payment, order row, points)
  * `check_loyalty` -> Cloud Run reads the real loyalty tier / discount / points

Both are TOP-LEVEL tools on the orchestrator on purpose: only top-level tool calls
appear in the event stream the Cloud Run caller reads. A tool nested inside a
sub-agent would be invisible to the caller.
"""

from typing import Optional


def _find_product(sku: str):
    from .catalog_search import _load_catalog

    return next((p for p in _load_catalog() if p.get("sku") == sku), None)


def _clean_items(items) -> list:
    """Keep only well-formed {sku, size, quantity} entries with a known SKU."""
    clean = []
    for it in (items or []):
        if not isinstance(it, dict):
            continue
        sku = (it.get("sku") or "").strip()
        if not sku or not _find_product(sku):
            continue
        clean.append({
            "sku": sku,
            "size": str(it.get("size", "") or ""),
            "quantity": max(1, int(it.get("quantity", 1) or 1)),
        })
    return clean


async def place_order(items: list, customer_id: Optional[str] = None) -> dict:
    """Charge and place an order for one or MORE items at once (a basket).

    Call this ONLY after the customer has confirmed they want to pay, and you have
    a size for every item. Pass ALL the items the customer is buying in a SINGLE
    call — never call this once per item.

    A loyalty/customer ID is OPTIONAL — guests can check out. If provided, any
    loyalty discount and reward points are applied automatically during checkout.

    The actual payment, order recording, and reward points are completed by the
    boutique's checkout system after you call this. Do NOT state a total, a
    discount, 'paid', or list which items shipped yourself — the checkout system
    returns the authoritative confirmation listing exactly what was placed.

    Args:
        items: The line items to order, as a list where EACH element is an object:
            - sku (str): the product SKU, e.g. "SKU-002"
            - size (str): the size, e.g. "L", "M", "8", or "One Size" for accessories
            - quantity (int, optional): how many, default 1
          Example (two items):
            [{"sku": "SKU-002", "size": "L", "quantity": 1},
             {"sku": "SKU-019", "size": "L", "quantity": 1}]
          For one item, pass a list containing a single object.
        customer_id: Optional loyalty customer ID (e.g. "CUST-1042"). Omit for guests.

    Returns:
        A short acknowledgement; the final confirmation is produced by checkout.
    """
    clean = _clean_items(items)
    if not clean:
        return {"status": "error", "message": "I need at least one valid item (with a SKU and a size) to place the order."}
    return {
        "status": "submitted",
        "items": clean,
        "customer_id": customer_id or None,
        "item_count": len(clean),
        "message": (
            f"Submitting your order for {len(clean)} item(s) to our checkout system — "
            "your confirmation is on its way."
        ),
    }


async def quote_order(items: list, customer_id: Optional[str] = None) -> dict:
    """Prepare an order SUMMARY for one or MORE items for the customer to review and
    approve BEFORE paying.

    Call this the FIRST time a customer wants to buy, once you have a size for every
    item. Pass ALL the items the customer wants in a SINGLE call — never call this
    once per item. The boutique's system computes the price (including any loyalty
    discount) and shows the customer every line and the total, asking them to
    confirm the charge. NOTHING is charged or ordered yet.

    After the customer confirms, call `place_order` with the SAME items to take
    payment. Do NOT state a total yourself — the system shows the real one.

    Args:
        items: The line items to summarise, as a list where EACH element is an object:
            - sku (str): the product SKU, e.g. "SKU-002"
            - size (str): the size, e.g. "L", "M", "8", or "One Size" for accessories
            - quantity (int, optional): how many, default 1
          Example (two items):
            [{"sku": "SKU-005", "size": "M", "quantity": 1},
             {"sku": "SKU-030", "size": "One Size", "quantity": 1}]
        customer_id: Optional loyalty customer ID (e.g. "CUST-1042"). Omit for guests.

    Returns:
        A short acknowledgement; the real summary + total are filled in by the system.
    """
    clean = _clean_items(items)
    if not clean:
        return {"status": "error", "message": "I need at least one valid item (with a SKU and a size) to prepare a summary."}
    return {
        "status": "quote",
        "items": clean,
        "customer_id": customer_id or None,
        "item_count": len(clean),
        "message": f"Preparing your order summary for {len(clean)} item(s)…",
    }


async def check_stock(sku: str) -> dict:
    """Look up REAL, live per-size stock for a product.

    Use this whenever the customer asks what sizes are available, whether something
    is in stock, or how many are left. You need a SKU — if you only have a product
    name, ask style_advisor to identify the exact SKU first, then call this.

    The boutique's system finishes this lookup and renders the live size/stock
    table for the customer, kept consistent with what checkout will actually let
    them buy. After calling this, simply let the customer know you're checking
    availability — do NOT invent or state stock numbers yourself.

    Args:
        sku: The product SKU (e.g. "SKU-002").

    Returns:
        A short acknowledgement; the real per-size stock is filled in by the system.
    """
    product = _find_product(sku)
    if not product:
        return {"status": "error", "message": f"I couldn't find {sku} in our catalog."}
    return {
        "status": "checking",
        "sku": sku,
        "product_name": product.get("name", ""),
        "message": f"Checking live availability for the {product.get('name', '')}…",
    }


async def get_order(order_id: str) -> dict:
    """Look up a previously placed order by its order number.

    Use this whenever the customer asks about an existing order — "what's in order
    ORD-1234?", "show me my order", "where's my order", "order status". The
    boutique's system finishes the lookup and renders the real order (items,
    totals, payment, status,
    delivery). After calling this, simply let the customer know you're pulling it up
    — do NOT invent order contents yourself.

    Args:
        order_id: The order number, e.g. "ORD-37D8F676".

    Returns:
        A short acknowledgement; the real order details are filled in by the system.
    """
    return {
        "status": "looking_up",
        "order_id": str(order_id).strip(),
        "message": f"Pulling up order {str(order_id).strip()}…",
    }


async def enroll_loyalty(name: str, email: Optional[str] = None) -> dict:
    """Sign a NEW customer up for the loyalty program and generate their loyalty ID.

    Use this when a customer wants to join the rewards program, become a member, or
    asks about rewards/their loyalty ID but does NOT already have one. You need their
    NAME first — ask for it warmly if you don't have it. (An existing member instead
    gives you their ID, which you pass to check_loyalty.)

    The boutique's system creates the real account in BigQuery, generates the new
    loyalty ID, and returns it — do NOT invent an ID yourself.

    Args:
        name: The customer's name for the account (e.g. "Alex Rivera").
        email: Optional email address.

    Returns:
        A short acknowledgement; the new loyalty ID + details are filled in by the system.
    """
    if not name or not str(name).strip():
        return {"status": "need_name", "message": "I'll need the customer's name to set up their membership."}
    return {
        "status": "enrolling",
        "name": str(name).strip(),
        "email": (email or None),
        "message": f"Setting up a new rewards membership for {str(name).strip()}…",
    }


async def check_loyalty(customer_id: str) -> dict:
    """Look up a customer's loyalty status, discount eligibility, and reward points.

    Use this whenever the customer asks if they qualify for a discount, what their
    loyalty tier is, or how many reward points they have — and they have given a
    customer ID.

    The boutique's system finishes this lookup and renders the customer's REAL
    tier, discount, and points, kept consistent with what checkout charges. After
    calling this, simply let the customer know you're pulling up their status — do
    NOT state a tier, a discount percentage, or a points balance yourself.

    Args:
        customer_id: The loyalty customer ID (e.g. "CUST-1042").

    Returns:
        A short acknowledgement; the real loyalty details are filled in by the system.
    """
    return {
        "status": "checking",
        "customer_id": customer_id,
        "message": f"Pulling up the loyalty status for {customer_id}…",
    }
