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

"""Real checkout — runs on the Cloud Run layer (FastAPI app + A2A bridge).

WHY THIS LIVES HERE AND NOT IN THE AGENT
----------------------------------------
Not because the agent can't reach BigQuery — it can. Deployed agents run as the
Agent Runtime service agent and reach whatever that identity is granted, which
is exactly how the Inventory specialist reads inventory and loyalty through the
MCP Toolbox. The reads live in the agent; the WRITES live here, deliberately:

  * Money-moving logic stays off the model. Discount maths, payment, and the
    order row are ordinary server code that runs the same way every time, and no
    prompt can talk them into a different price.
  * The storefront needs the outcome. The UI renders an order confirmation, so
    the Cloud Run layer has to see the result anyway.

So the flow is:

  1. In the agent, the `place_order` tool SIGNALS intent and returns the order
     parameters (sku, size, customer_id, quantity).
  2. The Cloud Run caller (app.py for the React UI, a2a/server.py for Gemini
     Enterprise) sees that tool call in the Agent Runtime event stream and calls
     `finalize_order(...)` HERE, which does the real work: read loyalty, apply
     the discount, simulate payment, award reward points, and write the order.

`finalize_order` returns both the structured result and a ready-to-show
confirmation string, so the caller can render it directly.
"""

import datetime
import json
import os
import uuid
from pathlib import Path

PROJECT_ID = os.environ.get("VERTEXAI_PROJECT", "your-gcp-project-id")
BQ_DATASET = os.environ.get("BQ_DATASET", "vogue_concierge")
ORDERS_TABLE = f"{PROJECT_ID}.{BQ_DATASET}.orders"
LOYALTY_TABLE = f"{PROJECT_ID}.{BQ_DATASET}.loyalty_program"
INVENTORY_TABLE = f"{PROJECT_ID}.{BQ_DATASET}.inventory"

# Catalog (for product name + price). Loaded once.
_CATALOG = None


def _catalog():
    global _CATALOG
    if _CATALOG is None:
        path = Path(__file__).parent / "data" / "products.json"
        _CATALOG = json.loads(path.read_text()) if path.exists() else []
    return _CATALOG


def _find_product(sku: str):
    return next((p for p in _catalog() if p.get("sku") == sku), None)


def _lookup_loyalty(customer_id: str):
    """(tier, discount_percent, points_balance) from BigQuery, or None."""
    if not customer_id:
        return None
    from google.cloud import bigquery

    client = bigquery.Client(project=PROJECT_ID)
    query = (
        f"SELECT tier, discount_percent, points_balance "
        f"FROM `{LOYALTY_TABLE}` WHERE customer_id = @cid LIMIT 1"
    )
    job = client.query(
        query,
        job_config=bigquery.QueryJobConfig(
            query_parameters=[bigquery.ScalarQueryParameter("cid", "STRING", customer_id)]
        ),
    )
    for row in job.result():
        return (row["tier"], int(row["discount_percent"] or 0), int(row["points_balance"] or 0))
    return None


def _write_order(row: dict) -> bool:
    """Append one order line to BigQuery. True only if the row was accepted.

    This is a streaming insert, unlike the seed data in `scripts/setup_bigquery.py`,
    which uses a load job. The difference is deliberate: a streaming insert is a
    single synchronous call that returns in a few hundred milliseconds, whereas a
    load job is a queued BigQuery job that takes seconds — and this one runs while
    the customer waits for their receipt.

    The trade-off is that rows written this way sit in the streaming buffer for
    ~30 minutes, during which UPDATE/DELETE/MERGE cannot touch them
    (https://docs.cloud.google.com/bigquery/docs/data-manipulation-language#limitations).
    That costs nothing today because `orders` is only ever read after it is written.
    It would matter the moment you add the cancel/refund paths a real payment
    integration needs (see the README's "Payment is simulated" section): those are
    DML, so they would silently fail on a just-placed order. Move this to
    `load_table_from_json` if you go there.
    """
    from google.cloud import bigquery

    client = bigquery.Client(project=PROJECT_ID)
    errors = client.insert_rows_json(ORDERS_TABLE, [row])
    if errors:
        print(f"[checkout] BigQuery insert errors: {errors}")
        return False
    return True


def _credit_points(customer_id: str, new_balance: int) -> None:
    from google.cloud import bigquery

    client = bigquery.Client(project=PROJECT_ID)
    client.query(
        f"UPDATE `{LOYALTY_TABLE}` SET points_balance = @pts WHERE customer_id = @cid",
        job_config=bigquery.QueryJobConfig(
            query_parameters=[
                bigquery.ScalarQueryParameter("pts", "INT64", new_balance),
                bigquery.ScalarQueryParameter("cid", "STRING", customer_id),
            ]
        ),
    ).result()


def _money(x) -> str:
    return f"${x:,.2f}"


# ---------------------------------------------------------------------------
# Real stock (BigQuery `inventory`). The Inventory specialist reads this table
# through the MCP Toolbox for conversational questions; this copy backs the
# checkout flow, so what the UI shows and what checkout validates against agree.
# ---------------------------------------------------------------------------
_SIZE_RANK = {s: i for i, s in enumerate(
    ["XS", "S", "S/M", "M", "L", "L/XL", "XL", "XXL", "One Size"]
)}


def _size_key(size: str):
    """Sort apparel sizes naturally (XS<S<M<L<XL), numerics by value, else by name."""
    s = str(size)
    if s in _SIZE_RANK:
        return (0, _SIZE_RANK[s])
    if s.isdigit():
        return (1, int(s))
    return (2, s)


def _get_stock(sku: str, size: str):
    """quantity_in_stock for (sku, size) from BigQuery, or None if there is no such
    row (unknown — caller should NOT treat None as out of stock)."""
    from google.cloud import bigquery

    client = bigquery.Client(project=PROJECT_ID)
    rows = list(client.query(
        f"SELECT quantity_in_stock FROM `{INVENTORY_TABLE}` WHERE sku=@s AND size=@z LIMIT 1",
        job_config=bigquery.QueryJobConfig(query_parameters=[
            bigquery.ScalarQueryParameter("s", "STRING", sku),
            bigquery.ScalarQueryParameter("z", "STRING", str(size)),
        ]),
    ).result())
    return int(rows[0]["quantity_in_stock"]) if rows else None


def _decrement_stock(sku: str, size: str, qty: int) -> None:
    """Reduce real stock for (sku, size) after a successful purchase (never below 0)."""
    from google.cloud import bigquery

    client = bigquery.Client(project=PROJECT_ID)
    client.query(
        f"UPDATE `{INVENTORY_TABLE}` SET quantity_in_stock = GREATEST(0, quantity_in_stock - @q) "
        f"WHERE sku=@s AND size=@z",
        job_config=bigquery.QueryJobConfig(query_parameters=[
            bigquery.ScalarQueryParameter("q", "INT64", int(qty)),
            bigquery.ScalarQueryParameter("s", "STRING", sku),
            bigquery.ScalarQueryParameter("z", "STRING", str(size)),
        ]),
    ).result()


def stock_status(sku: str) -> dict:
    """Real per-size stock for a SKU from BigQuery (Cloud Run only). This is the
    display counterpart to the stock that checkout validates against — reading the
    same `inventory` table keeps what the customer is *shown* consistent with what
    they can actually *buy*."""
    product = _find_product(sku)
    name = product.get("name", "") if product else sku
    try:
        from google.cloud import bigquery

        client = bigquery.Client(project=PROJECT_ID)
        rows = list(client.query(
            f"SELECT size, quantity_in_stock, price FROM `{INVENTORY_TABLE}` WHERE sku=@s",
            job_config=bigquery.QueryJobConfig(query_parameters=[
                bigquery.ScalarQueryParameter("s", "STRING", sku)]),
        ).result())
    except Exception as e:  # noqa: BLE001
        print(f"[checkout] stock_status lookup failed: {e}")
        return {"ok": False, "text": "I'm having trouble reaching our live stock right now — please try again in a moment."}

    if not rows:
        return {"ok": True, "found": False, "products": ([product] if product else []),
                "text": f"I couldn't find live stock for **{name}** ({sku}). It may not be in our current range."}

    rows.sort(key=lambda r: _size_key(r["size"]))
    price = next((r["price"] for r in rows if r["price"] is not None), None)
    total = sum(int(r["quantity_in_stock"] or 0) for r in rows)
    lines = [f"Here's the live availability for **{name}** ({sku}){' — ' + _money(price) if price else ''}:", ""]
    lines.append("| Size | In stock |")
    lines.append("|------|----------|")
    low = []
    for r in rows:
        q = int(r["quantity_in_stock"] or 0)
        flag = "  ⚠️ low" if 0 < q < 5 else ("  ❌ sold out" if q == 0 else "")
        lines.append(f"| {r['size']} | {q}{flag} |")
        if 0 < q < 5:
            low.append(r["size"])
    lines.append("")
    if total == 0:
        lines.append("Unfortunately this piece is fully sold out at the moment.")
    elif low:
        lines.append(f"Sizes running low: {', '.join(low)} — I'd recommend securing one soon. 🖤")
    return {"ok": True, "found": True, "sku": sku, "total": total,
            "products": ([product] if product else []), "text": "\n".join(lines)}


# A stand-in card so the quote and the receipt read like a real checkout. There is
# NO payment integration here: nothing is tokenised, authorised or charged, and the
# customer is never asked for card details. `finalize_order` mints a `payment_id`
# and writes `payment_status = "paid"` unconditionally, so the order always
# "succeeds".
#
# Going to production means replacing that simulated step with a real PSP (Stripe,
# Adyen, Checkout.com, Google Pay …). Collect the card in the browser with the
# provider's hosted fields or SDK so the number is tokenised client-side and never
# reaches this service — that keeps the PAN out of the Agent Runtime session
# transcript, the Cloud Run logs and BigQuery, and keeps your own PCI DSS scope to
# SAQ A. Send only the resulting token here, authorise against it, and persist just
# the brand and last four digits alongside the provider's charge id. The order row
# should then be written from the authorisation result rather than ahead of it, with
# declines and refunds handled explicitly.
MOCK_CARD = "Visa •••• 4242"


# ---------------------------------------------------------------------------
# Basket helpers — the checkout works on a LIST of line items so a customer can
# buy several pieces in one order (real retail behaviour). A single-item purchase
# is just a basket of one. We also accept the legacy single sku/size form so any
# older caller keeps working.
# ---------------------------------------------------------------------------
def _normalize_items(items=None, sku=None, size=None, quantity=1) -> list:
    """Return a clean list of {sku, size, quantity} from either a basket (`items`)
    or the legacy single-item args. Bad/blank entries are dropped."""
    norm = []
    if items:
        for it in items:
            if not isinstance(it, dict):
                continue
            s = (it.get("sku") or "").strip()
            if not s:
                continue
            norm.append({
                "sku": s,
                "size": str(it.get("size", "") or ""),
                "quantity": max(1, int(it.get("quantity", 1) or 1)),
            })
    elif sku:
        norm.append({"sku": str(sku), "size": str(size or ""), "quantity": max(1, int(quantity or 1))})
    return norm


def _price_items(norm: list):
    """Resolve each {sku,size,quantity} to a priced line item. Returns
    (line_items, subtotal, unknown_skus). Each line item carries the product,
    size, quantity, unit_price and line_total."""
    line_items = []
    unknown = []
    subtotal = 0.0
    for it in norm:
        product = _find_product(it["sku"])
        if not product:
            unknown.append(it["sku"])
            continue
        unit = float(product.get("price", 0) or 0)
        line_total = round(unit * it["quantity"], 2)
        subtotal += line_total
        line_items.append({
            "product": product, "sku": it["sku"], "name": product.get("name", ""),
            "size": it["size"], "quantity": it["quantity"],
            "unit_price": unit, "line_total": line_total,
        })
    return line_items, round(subtotal, 2), unknown


def quote_order(items=None, customer_id: str = None, sku: str = None, size: str = None, quantity: int = 1) -> dict:
    """Compute an order SUMMARY for a basket with the real loyalty discount applied —
    but charge nothing and write nothing. Powers the confirm-to-pay step: the
    customer sees every line item and the total, and is asked to approve the charge
    before `finalize_order` runs. Cloud Run only (it reads BigQuery loyalty)."""
    line_items, subtotal, unknown = _price_items(_normalize_items(items, sku, size, quantity))
    if not line_items:
        return {"ok": False, "products": [], "text": "I couldn't find those items in our catalog, so I can't prepare that order."}

    tier = None
    discount_percent = 0
    try:
        loyalty = _lookup_loyalty(customer_id)
        if loyalty:
            tier, discount_percent, _ = loyalty
    except Exception as e:  # noqa: BLE001
        print(f"[checkout] quote loyalty lookup failed: {e}")

    discount_amount = round(subtotal * discount_percent / 100.0, 2)
    total = round(subtotal - discount_amount, 2)

    # Real-stock heads-up so the customer learns about any issue BEFORE confirming.
    out_of_stock = []
    low_stock = []
    for li in line_items:
        try:
            avail = _get_stock(li["sku"], li["size"])
        except Exception:  # noqa: BLE001
            avail = None
        if avail is not None and avail < li["quantity"]:
            out_of_stock.append(li)
        elif avail is not None and avail < 5:
            low_stock.append((li, avail))

    # Every block is a heading paragraph followed by its own tight bullet list. The
    # headings are structural, not decorative: two bullet lists separated by nothing
    # but a blank line are ONE list as far as Markdown is concerned, and a list with
    # a blank line inside it is "loose", so the renderer wraps every bullet in a
    # paragraph and the whole summary gains ragged spacing. A paragraph between them
    # closes the first list. Consecutive "**Label:** value" lines have the mirror
    # problem — they collapse into a single run-on paragraph — so those are bullets
    # too. finalize_order and get_order are built the same way, so the three
    # screens line up with each other.
    lines = ["Here's your order summary — please review before I take payment:", ""]
    lines.append(f"**Your items ({len(line_items)})**" if len(line_items) > 1 else "**Item**")
    for li in line_items:
        lines.append(f"- {li['name']} ({li['sku']}) · Size {li['size']} · Qty {li['quantity']} — {_money(li['line_total'])}")
    lines.append("")
    lines.append("**Price**")
    lines.append(f"- Subtotal: {_money(subtotal)}")
    if discount_percent:
        lines.append(f"- {tier} loyalty discount ({discount_percent}%): −{_money(discount_amount)}")
    lines.append(f"- **Total: {_money(total)}**")
    if low_stock:
        lines.append("")
        lines.append("⚠️ " + "; ".join(f"{li['name']} (size {li['size']}) — only {a} left" for li, a in low_stock))
    if out_of_stock:
        lines.append("")
        oos = ", ".join(f"{li['name']} (size {li['size']})" for li in out_of_stock)
        lines.append(f"❗ {oos} {'is' if len(out_of_stock)==1 else 'are'} currently out of stock in {'that size' if len(out_of_stock)==1 else 'those sizes'} and won't be charged — let me know if you'd like a different size.")
    if unknown:
        lines.append("")
        lines.append(f"_(Note: I couldn't find {', '.join(unknown)}, so I've left {'it' if len(unknown)==1 else 'them'} out.)_")
    lines.append("")
    lines.append(
        f"Shall I charge **{_money(total)}** to your card ({MOCK_CARD}) to complete the order? "
        "Just say the word and it's yours. 🛍️"
    )
    return {
        "ok": True,
        "skus": [li["sku"] for li in line_items],
        "products": [li["product"] for li in line_items],
        "total": total,
        "text": "\n".join(lines),
    }


def find_tool_call(events, name: str):
    """Scan an Agent Runtime event stream for a top-level tool call by name and
    return its args dict, or None. Used by BOTH Cloud Run callers (the React UI's
    app.py and the A2A bridge) to detect the agent's `place_order` / `check_loyalty`
    signals and run the real BigQuery action here, where BigQuery is reachable."""
    for ev in events:
        content = ev.get("content", {}) if isinstance(ev, dict) else {}
        for part in (content.get("parts", []) if isinstance(content, dict) else []):
            if isinstance(part, dict) and isinstance(part.get("function_call"), dict):
                fc = part["function_call"]
                if fc.get("name") == name:
                    return dict(fc.get("args", {}) or {})
    return None


def loyalty_status(customer_id: str) -> dict:
    """Look up a customer's REAL loyalty status from BigQuery (Cloud Run only).

    This is the display counterpart to the discount/points that `finalize_order`
    applies — reading from the same `loyalty_program` table keeps what the customer
    is *told* consistent with what they're actually *charged*. (The agent signals
    via the `check_loyalty` tool so the storefront can render the result; the
    Inventory specialist can also read the same table through the MCP Toolbox.)
    """
    if not customer_id:
        return {"ok": False, "text": "I'd be glad to check your loyalty status — could you share your customer ID (for example CUST-1042)?"}
    try:
        from google.cloud import bigquery

        client = bigquery.Client(project=PROJECT_ID)
        rows = list(
            client.query(
                f"SELECT customer_name, tier, discount_percent, points_balance, free_shipping "
                f"FROM `{LOYALTY_TABLE}` WHERE customer_id = @cid LIMIT 1",
                job_config=bigquery.QueryJobConfig(
                    query_parameters=[bigquery.ScalarQueryParameter("cid", "STRING", customer_id)]
                ),
            ).result()
        )
    except Exception as e:  # noqa: BLE001
        print(f"[checkout] loyalty_status lookup failed: {e}")
        return {"ok": False, "text": "I'm having trouble reaching your loyalty account right now — please try again in a moment."}

    if not rows:
        return {
            "ok": True, "found": False,
            "text": (
                f"I couldn't find a loyalty account for **{customer_id}**. If you'd like, I can help "
                "you join — members earn points on every purchase and unlock exclusive discounts. 🖤"
            ),
        }
    r = rows[0]
    name = r["customer_name"]
    tier = r["tier"]
    disc = int(r["discount_percent"] or 0)
    pts = int(r["points_balance"] or 0)
    ship = bool(r["free_shipping"])
    text = "\n".join([
        f"Wonderful news{', ' + name if name else ''} — here are your loyalty benefits:",
        "",
        f"- **Tier:** {tier}",
        f"- **Discount:** {disc}% off every purchase",
        f"- **Reward points:** {pts:,}",
        f"- **Free shipping:** {'Yes' if ship else 'No'}",
        "",
        "Your discount and points are applied automatically at checkout. Anything you'd love to treat yourself to? 🖤",
    ])
    return {
        "ok": True, "found": True, "customer_id": customer_id,
        "tier": tier, "discount_percent": disc, "points_balance": pts, "text": text,
    }


def get_order(order_id: str) -> dict:
    """Look up a stored order by its number from BigQuery (Cloud Run only).

    Orders are persisted by `finalize_order` (one row per line item, sharing an
    order_id). This reads them back so the concierge can show a customer exactly
    what they ordered — items, sizes, totals, payment, status, and delivery.
    """
    if not order_id or not str(order_id).strip():
        return {"ok": False, "text": "Of course — what's the order number? It looks like **ORD-XXXXXXXX**."}
    oid = str(order_id).strip().upper()
    if not oid.startswith("ORD-"):
        oid = "ORD-" + oid.lstrip("-")
    try:
        from google.cloud import bigquery

        client = bigquery.Client(project=PROJECT_ID)
        rows = list(client.query(
            f"SELECT sku, product_name, size, quantity, unit_price, subtotal, discount_amount, "
            f"total, payment_id, payment_status, status, estimated_delivery, created_at, "
            f"customer_id, loyalty_tier FROM `{ORDERS_TABLE}` WHERE order_id=@o ORDER BY product_name",
            job_config=bigquery.QueryJobConfig(query_parameters=[
                bigquery.ScalarQueryParameter("o", "STRING", oid)]),
        ).result())
    except Exception as e:  # noqa: BLE001
        print(f"[checkout] get_order lookup failed: {e}")
        return {"ok": False, "text": "I'm having trouble reaching our order system right now — please try again in a moment."}

    if not rows:
        return {"ok": True, "found": False,
                "text": f"I couldn't find an order with the number **{oid}**. Could you double-check it? (It looks like ORD-XXXXXXXX.)"}

    order_total = round(sum(float(r["total"] or 0) for r in rows), 2)
    discount_total = round(sum(float(r["discount_amount"] or 0) for r in rows), 2)
    subtotal_total = round(sum(float(r["subtotal"] or 0) for r in rows), 2)
    r0 = rows[0]
    placed_on = str(r0["created_at"])[:10]
    products = [p for p in (_find_product(r["sku"]) for r in rows) if p]

    lines = [
        f"Here are the details for order **{oid}**:",
        "",
        f"- **Placed:** {placed_on}  ·  **Status:** {str(r0['status']).title()}",
        f"- **Payment:** {str(r0['payment_status']).title()} to {MOCK_CARD}  ·  ref {r0['payment_id']}",
    ]
    if r0["customer_id"]:
        lines.append(f"- **Member:** {r0['customer_id']}" + (f" ({r0['loyalty_tier']})" if r0["loyalty_tier"] else ""))
    lines.append("")
    lines.append("**Items**")
    for r in rows:
        # The line price is the pre-discount subtotal, so the items add up to the
        # Subtotal below and the discount is stated once. finalize_order prints the
        # same figures, so a receipt and a later lookup of that order agree.
        lines.append(f"- {r['product_name']} ({r['sku']}) · Size {r['size']} · Qty {r['quantity']} — {_money(float(r['subtotal'] or 0))}")
    lines.append("")
    lines.append("**Price**")
    if discount_total:
        lines.append(f"- Subtotal: {_money(subtotal_total)}")
        lines.append(f"- Discount: −{_money(discount_total)}")
    lines.append(f"- **Total: {_money(order_total)}**")
    lines.append("")
    lines.append(f"**Estimated delivery:** {r0['estimated_delivery']}")
    return {"ok": True, "found": True, "order_id": oid, "total": order_total,
            "products": products, "text": "\n".join(lines)}


def _next_customer_id() -> str:
    """Generate the next loyalty ID (e.g. CUST-1051) from the highest existing one."""
    from google.cloud import bigquery

    client = bigquery.Client(project=PROJECT_ID)
    rows = list(client.query(
        f"SELECT MAX(CAST(REGEXP_EXTRACT(customer_id, r'[0-9]+') AS INT64)) m FROM `{LOYALTY_TABLE}`"
    ).result())
    n = (rows[0]["m"] or 1050) + 1
    return f"CUST-{n}"


def enroll_loyalty(name: str, email: str = None, continuing_to_checkout: bool = False) -> dict:
    """Create a REAL new loyalty member in BigQuery (Cloud Run only) and return their
    new ID. New members start at Bronze (5% off) with a 100-point welcome bonus.

    This is the 'new customer' path; existing members simply give their ID (read by
    `loyalty_status`). Uses a DML INSERT so the account is immediately queryable.

    Set `continuing_to_checkout` when the caller is about to append an order summary
    below this message — the closing invitation to shop is replaced by a note that
    the new discount already applies, so the two messages read as one.
    """
    if not name or not str(name).strip():
        return {"ok": False, "text": "I'd love to set up your membership! What name shall I put on the account?"}
    clean_name = str(name).strip()
    try:
        from google.cloud import bigquery

        client = bigquery.Client(project=PROJECT_ID)
        cid = _next_customer_id()
        today = datetime.date.today().isoformat()
        client.query(
            f"INSERT INTO `{LOYALTY_TABLE}` "
            f"(customer_id, customer_name, tier, discount_percent, points_balance, free_shipping, member_since) "
            f"VALUES (@cid, @name, 'Bronze', 5, 100, FALSE, @ms)",
            job_config=bigquery.QueryJobConfig(query_parameters=[
                bigquery.ScalarQueryParameter("cid", "STRING", cid),
                bigquery.ScalarQueryParameter("name", "STRING", clean_name),
                bigquery.ScalarQueryParameter("ms", "DATE", today),
            ]),
        ).result()
    except Exception as e:  # noqa: BLE001
        print(f"[checkout] enroll_loyalty failed: {e}")
        return {"ok": False, "text": "I hit a snag creating your membership just now — could you try again in a moment?"}

    text = "\n".join([
        f"🎉 Welcome to Vogue Concierge Rewards, {clean_name}! Your membership is all set:",
        "",
        f"- **Loyalty ID:** {cid}  _(keep this — you'll use it at checkout)_",
        "- **Tier:** Bronze · **5% off** every purchase",
        "- **Welcome bonus:** 100 points",
        "- **Earning:** 1 point per $1 spent — your discount and points apply automatically when you give this ID.",
        "",
        ("Your new member discount is already applied to the summary below. 🖤"
         if continuing_to_checkout else "Would you like to use it on an order now? 🖤"),
    ])
    return {"ok": True, "customer_id": cid, "tier": "Bronze",
            "discount_percent": 5, "points_balance": 100, "text": text}



def find_member_by_name(name: str) -> str:
    """The loyalty ID most recently issued to `name`, or "" if there is none.

    Used to recover the account created earlier in a conversation when the caller
    only knows the name the customer signed up with (see `_member_id_for_session`
    in app.py). Newest account wins, so a repeated name resolves to the sign-up
    that just happened rather than an older namesake.
    """
    if not name or not str(name).strip():
        return ""
    try:
        from google.cloud import bigquery

        client = bigquery.Client(project=PROJECT_ID)
        rows = list(client.query(
            f"SELECT customer_id FROM `{LOYALTY_TABLE}` WHERE customer_name = @name "
            f"ORDER BY member_since DESC, customer_id DESC LIMIT 1",
            job_config=bigquery.QueryJobConfig(query_parameters=[
                bigquery.ScalarQueryParameter("name", "STRING", str(name).strip()),
            ]),
        ).result())
        return rows[0]["customer_id"] if rows else ""
    except Exception as e:  # noqa: BLE001 — recovery is best effort
        print(f"[checkout] find_member_by_name failed: {e}")
        return ""


def finalize_order(items=None, customer_id: str = None, sku: str = None, size: str = None, quantity: int = 1) -> dict:
    """Run the real checkout for a BASKET against BigQuery and return result +
    confirmation text. One order_id and one payment cover all line items; one
    BigQuery row is written per line item (sharing order_id + payment_id), so
    summing the rows reconstructs the order. Cloud Run only (has BigQuery access).
    Always returns a human-readable ``text`` field for display.
    """
    line_items, _all_subtotal, unknown = _price_items(_normalize_items(items, sku, size, quantity))
    if not line_items:
        return {"ok": False, "products": [], "text": "I couldn't find those items in our catalog, so I wasn't able to place that order."}

    # Stock validation (real BigQuery). A line is placed only if we can confirm
    # enough stock for that size. A MISSING inventory row is treated as available
    # (we never reject on a data gap), so a valid order is never wrongly blocked.
    placed = []
    unavailable = []
    for li in line_items:
        try:
            avail = _get_stock(li["sku"], li["size"])
        except Exception as e:  # noqa: BLE001
            print(f"[checkout] stock check failed for {li['sku']}/{li['size']}: {e}")
            avail = None  # treat as available rather than block on an error
        if avail is not None and avail < li["quantity"]:
            li["available"] = avail
            unavailable.append(li)
        else:
            placed.append(li)

    if not placed:
        names = ", ".join(f"{li['name']} (size {li['size']})" for li in unavailable)
        return {"ok": False, "placed": False, "products": [li["product"] for li in unavailable],
                "text": (f"I'm so sorry — {names} {'is' if len(unavailable) == 1 else 'are'} out of stock in "
                         f"{'that size' if len(unavailable) == 1 else 'those sizes'}, so I haven't charged you for "
                         "anything. Would you like a different size, or shall I suggest something similar?")}

    subtotal = round(sum(li["line_total"] for li in placed), 2)

    # Loyalty (real BigQuery read) — optional.
    tier = None
    discount_percent = 0
    points_balance = 0
    loyalty_ok = False
    try:
        loyalty = _lookup_loyalty(customer_id)
        if loyalty:
            tier, discount_percent, points_balance = loyalty
            loyalty_ok = True
    except Exception as e:  # noqa: BLE001
        print(f"[checkout] loyalty lookup failed: {e}")

    # One order, one payment, one delivery for the whole basket.
    order_id = "ORD-" + uuid.uuid4().hex[:8].upper()
    payment_id = "PAY-" + uuid.uuid4().hex[:10].upper()
    now = datetime.datetime.utcnow()
    eta = (now + datetime.timedelta(days=5)).date().isoformat()

    # Apply the loyalty discount per line so each BigQuery row is internally
    # consistent and the order total is the sum of the rows.
    order_total = 0.0
    order_discount = 0.0
    points_earned = 0
    rows = []
    for li in placed:
        line_discount = round(li["line_total"] * discount_percent / 100.0, 2)
        line_net = round(li["line_total"] - line_discount, 2)
        line_points = int(line_net)
        order_total = round(order_total + line_net, 2)
        order_discount = round(order_discount + line_discount, 2)
        points_earned += line_points
        rows.append({
            "order_id": order_id, "created_at": now.isoformat(),
            "customer_id": customer_id or None, "sku": li["sku"],
            "product_name": li["name"], "size": str(li["size"]),
            "quantity": li["quantity"], "unit_price": li["unit_price"],
            "discount_percent": discount_percent, "discount_amount": line_discount,
            "subtotal": li["line_total"], "total": line_net, "payment_id": payment_id,
            "payment_status": "paid", "points_earned": line_points,
            "loyalty_tier": tier, "status": "confirmed", "estimated_delivery": eta,
        })

    # Write every line item (one BigQuery row each). recorded=True only if ALL wrote.
    recorded = False
    try:
        recorded = all(_write_order(r) for r in rows)
    except Exception as e:  # noqa: BLE001
        print(f"[checkout] order write failed: {e}")

    # HONEST FAILURE: never tell the customer an order is confirmed/charged if it
    # didn't actually record. Don't decrement stock or credit points either.
    if not recorded:
        return {"ok": False, "placed": False, "recorded_in_bigquery": False,
                "products": [li["product"] for li in placed],
                "text": ("I hit a snag saving your order, and I didn't want to charge you for something that "
                         "didn't go through — so **nothing has been charged**. Could you try again in a moment? "
                         "If it keeps happening, our team will be glad to help right away.")}

    # Order recorded → move real stock and credit reward points.
    for li in placed:
        try:
            _decrement_stock(li["sku"], li["size"], li["quantity"])
        except Exception as e:  # noqa: BLE001
            print(f"[checkout] stock decrement failed for {li['sku']}/{li['size']}: {e}")

    new_points_balance = points_balance + points_earned if loyalty_ok else None
    if loyalty_ok and customer_id:
        try:
            _credit_points(customer_id, new_points_balance)
        except Exception as e:  # noqa: BLE001
            print(f"[checkout] points credit failed: {e}")

    # Build a clean confirmation string from the items ACTUALLY placed.
    n = len(placed)
    if n == 1:
        header = f"🎉 **Order Confirmed** — your **{placed[0]['name']}** is on its way!"
    else:
        header = f"🎉 **Order Confirmed** — your **{n} items** are on their way!"
    lines = [
        header,
        "",
        f"- **Order number:** {order_id}",
        f"- **Payment:** ✓ Charged {_money(order_total)} to {MOCK_CARD}  ·  ref {payment_id}",
        "",
        "**Your items**" if n > 1 else "**Item**",
    ]
    for li in placed:
        lines.append(f"- {li['name']} ({li['sku']}) · Size {li['size']} · Qty {li['quantity']} — {_money(li['line_total'])}")
    lines.append("")
    lines.append("**Price**")
    lines.append(f"- Subtotal: {_money(subtotal)}")
    if discount_percent:
        lines.append(f"- {tier} loyalty discount ({discount_percent}%): −{_money(order_discount)}")
    lines.append(f"- **Total charged: {_money(order_total)}**")
    if unavailable:
        un = ", ".join(f"{li['name']} (size {li['size']})" for li in unavailable)
        lines.append("")
        lines.append(f"_(Note: {un} {'was' if len(unavailable) == 1 else 'were'} out of stock, so {'it was' if len(unavailable) == 1 else 'they were'} not included or charged.)_")
    if unknown:
        lines.append("")
        lines.append(f"_(Note: I couldn't find {', '.join(unknown)}, so {'it was' if len(unknown) == 1 else 'they were'} not ordered.)_")
    lines.append("")
    lines.append("**Rewards & delivery**")
    if loyalty_ok:
        lines.append(f"- +{points_earned} points earned · new balance **{new_points_balance:,} points**")
    else:
        lines.append(f"- +{points_earned} points on this order. Join our loyalty program to start saving them!")
    lines.append(f"- Estimated delivery: {eta}")
    lines.append("")
    lines.append("Is there anything else I can help you with? — Vogue Concierge")

    return {
        "ok": True, "placed": True, "order_id": order_id,
        "skus": [li["sku"] for li in placed],
        "products": [li["product"] for li in placed],
        "item_count": n, "subtotal": subtotal,
        "discount_percent": discount_percent, "discount_amount": order_discount,
        "total": order_total, "tier": tier, "payment_id": payment_id,
        "points_earned": points_earned, "points_balance": new_points_balance,
        "estimated_delivery": eta, "unknown_skus": unknown,
        "unavailable_skus": [li["sku"] for li in unavailable],
        "recorded_in_bigquery": recorded,
        "text": "\n".join(lines),
    }
