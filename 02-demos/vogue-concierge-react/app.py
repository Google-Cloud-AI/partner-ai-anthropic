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

"""Vogue Concierge — FastAPI server for the Next.js / React UI.

ROLE
----
This is the web backend for the boutique's own React UI. It does NOT run the
agents itself — the agent team runs on Agent Runtime (the agent
runtime). This server simply:

  * serves the built Next.js frontend and a few catalog REST endpoints, and
  * relays chat messages to the deployed Agent Runtime via ``stream_query``.

THIS IS *NOT* A2A — IT'S A PLAIN REST/SSE API (important distinction)
--------------------------------------------------------------------
There are two front doors into the SAME agent team, and they use DIFFERENT wire
protocols:

  * React UI  ->  THIS server (app.py): a first-party, in-house client, so it
    uses a simple REST + SSE API (``POST /api/chat`` and ``/api/chat/stream``)
    with plain JSON. No A2A involved.
  * Gemini Enterprise (and any other external agent)  ->  ``a2a/server.py``: a
    third-party/cross-vendor caller, so it uses **A2A** (Agent-to-Agent), the
    standard JSON-RPC 2.0 protocol, with AgentCard discovery and A2UI cards.

Rule of thumb: you reach for A2A precisely when the caller is *not* your own UI.
Both doorways relay to the one agent on Agent Runtime and run the SAME real-BigQuery
checkout/loyalty interception here on Cloud Run — only the protocol differs.

WHAT CHANGED WITH THE MOVE TO CLAUDE
------------------------------------
An earlier build needed a lot of defensive post-processing here — regex to
strip leaked tool-call syntax, and logic to "correct" hallucinated product names
and SKUs back to real catalog entries. Claude grounds its answers in the tool
results reliably, so all of that is gone. This file is now just transport +
a light retry, which keeps the response faithful to what the agent actually said.
"""

import json
import os
import re
import time
import traceback
from pathlib import Path

from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
import vertexai
import uvicorn

import checkout  # runs the REAL BigQuery checkout (money-moving writes stay off the model)

# --- Where the deployed agent lives -----------------------------------------
PROJECT_ID = os.environ.get("VERTEXAI_PROJECT")
if not PROJECT_ID:
    raise RuntimeError(
        "VERTEXAI_PROJECT is not set. Copy .env.example to .env (or export it) and set "
        "it to your GCP project id. See the README 'Setup' section."
    )
LOCATION = os.environ.get("AGENT_ENGINE_LOCATION", "us-central1")
PROJECT_NUMBER = os.environ.get("PROJECT_NUMBER", "YOUR_PROJECT_NUMBER")
AGENT_ENGINE_ID = os.environ.get("AGENT_ENGINE_ID", "")
AGENT_ENGINE_RESOURCE = (
    f"projects/{PROJECT_NUMBER}/locations/{LOCATION}/reasoningEngines/{AGENT_ENGINE_ID}"
)

app = FastAPI(title="Vogue Concierge — AI Boutique", version="4.0.0")

# The UI is served from this same origin, so CORS only needs to be permissive
# enough for a local `npm run dev` frontend to talk to a deployed backend.
# `allow_credentials` stays off: combining it with a wildcard origin makes
# Starlette echo back whatever Origin it is sent, which would let any site drive
# authenticated requests. Nothing here reads cookies or an Authorization header,
# so there is no reason to opt in.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# The catalog is read once for the REST endpoints and for matching product cards.
CATALOG_PATH = Path(__file__).parent / "data" / "products.json"
CATALOG = []
if CATALOG_PATH.exists():
    with open(CATALOG_PATH) as f:
        CATALOG = json.load(f)

UI_DIR = Path(__file__).parent / "ui" / "out"

# Agent Runtime handle, connected on startup.
remote_app = None

# Light retry: Agent Runtime can occasionally return an empty first event while a
# session warms up. We retry a few times with a short backoff before giving up.
MAX_RETRIES = 3
RETRY_DELAYS = [2, 4, 6]


def extract_text_from_events(events) -> str:
    """Pull the final assistant text out of an Agent Runtime event stream."""
    final_response = ""
    for event in events:
        if isinstance(event, dict):
            content_obj = event.get("content", {})
            if isinstance(content_obj, dict):
                for part in content_obj.get("parts", []):
                    if isinstance(part, dict) and part.get("text", "").strip():
                        final_response = part["text"]
            if not final_response and "text" in event:
                final_response = event["text"]
        elif hasattr(event, "content") and event.content:
            if hasattr(event.content, "parts"):
                for part in event.content.parts:
                    if hasattr(part, "text") and part.text:
                        final_response = part.text
    return final_response


# A customer who joins at checkout is charged on a LATER turn than the one that
# created their account, and the agent never learns the new ID — the sign-up runs
# here on Cloud Run and the tool result the engine sees is only a placeholder. So
# the follow-up place_order arrives with no customer_id. This maps an Agent Runtime
# session to the member it enrolled, so the charge keeps the discount the customer
# just approved. Bounded, because a warm instance would otherwise grow it forever.
_ENROLLED_MEMBER = {}
_ENROLLED_MEMBER_MAX = 500


def _remember_member(session_id, customer_id):
    """Record (or clear) the member enrolled in `session_id`."""
    if not session_id:
        return
    if session_id not in _ENROLLED_MEMBER and len(_ENROLLED_MEMBER) >= _ENROLLED_MEMBER_MAX:
        _ENROLLED_MEMBER.pop(next(iter(_ENROLLED_MEMBER)), None)
    _ENROLLED_MEMBER[session_id] = customer_id or ""


def _member_id_for_session(session_id, user_id):
    """The loyalty ID of a customer who joined earlier in THIS conversation, or "".

    The in-process map above is only a fast path: Cloud Run can serve one browser
    conversation from more than one instance, so a miss is rebuilt from the Agent
    Runtime session, which every instance can read. The session records the
    enroll_loyalty call, and the name on it identifies the account that call
    created. Misses are cached too, so a guest costs one lookup per conversation.
    """
    if not session_id or not remote_app:
        return ""
    if session_id in _ENROLLED_MEMBER:
        return _ENROLLED_MEMBER[session_id]

    name = ""
    try:
        session = remote_app.get_session(user_id=user_id, session_id=session_id)
        for event in session.get("events") or []:
            for part in (event.get("content") or {}).get("parts") or []:
                # get_session returns camelCase; stream_query returns snake_case.
                call = part.get("functionCall") or part.get("function_call") or {}
                if call.get("name") == "enroll_loyalty":
                    name = (call.get("args") or {}).get("name") or name
    except Exception as e:  # noqa: BLE001 — recovery is best effort, never fatal
        print(f"[app] could not read session history for {session_id}: {e}")
        return ""

    customer_id = checkout.find_member_by_name(name) if name else ""
    _remember_member(session_id, customer_id)
    return customer_id


def intercept_bigquery_action(events, session_id="", user_id="web_user"):
    """The agent SIGNALS transactional BigQuery actions via tool calls
    (place_order / check_loyalty) rather than performing them, so the money-moving
    logic stays off the model and the storefront can render the outcome. We detect
    those in the event stream and run the REAL action here on Cloud Run, returning
    (response_text, products). Returns (None, None) for a normal turn so the caller
    uses the agent's own reply."""
    # One checkout action runs per turn and the first match below wins, so the two
    # basket signals are resolved up front rather than inline.
    order = checkout.find_tool_call(events, "place_order")
    if not (order and (order.get("items") or order.get("sku"))):
        order = None
    quote = checkout.find_tool_call(events, "quote_order")
    if not (quote and (quote.get("items") or quote.get("sku"))):
        quote = None

    # Enrolment is settled BEFORE the basket action even though it is the lowest
    # priority signal, because a customer who joins at checkout produces BOTH in a
    # single turn: "sign me up" and "now summarise my basket". Resolving it further
    # down would let the basket branch return first and drop the sign-up on the
    # floor. The new ID does not exist when the agent picks its arguments, so the
    # quote/place signal arrives with no customer_id — we create the account here
    # and thread the ID into whichever basket action shares the turn, so the
    # membership discounts the very order that sold it. The welcome is prepended
    # to the checkout summary, not swapped for it.
    enrolment = ""
    new_customer_id = None
    enroll = checkout.find_tool_call(events, "enroll_loyalty")
    if enroll and enroll.get("name"):
        r = checkout.enroll_loyalty(
            enroll.get("name"), enroll.get("email"),
            continuing_to_checkout=bool(order or quote),
        )
        enrolment = r["text"]
        new_customer_id = r.get("customer_id")
        _remember_member(session_id, new_customer_id)

    def result(text, products=None):
        """Return `text`, prefixed with the welcome if a sign-up shared this turn."""
        return (f"{enrolment}\n\n---\n\n{text}" if enrolment else text), (products or [])

    # Step 2 (charge): the customer approved — take payment & record the order(s).
    # The basket is in `items`; checkout returns the products it ACTUALLY placed,
    # so the cards reflect reality (no hallucinated items).
    if order:
        r = checkout.finalize_order(
            items=order.get("items"),
            customer_id=(order.get("customer_id") or new_customer_id
                         or _member_id_for_session(session_id, user_id) or None),
            sku=order.get("sku"), size=order.get("size"), quantity=order.get("quantity", 1),
        )
        return result(r["text"], r.get("products", []))

    # Step 1 (summary): show the confirm-to-pay summary with the real basket total.
    if quote:
        r = checkout.quote_order(
            items=quote.get("items"),
            customer_id=(quote.get("customer_id") or new_customer_id
                         or _member_id_for_session(session_id, user_id) or None),
            sku=quote.get("sku"), size=quote.get("size"), quantity=quote.get("quantity", 1),
        )
        return result(r["text"], r.get("products", []))

    loyalty = checkout.find_tool_call(events, "check_loyalty")
    if loyalty and loyalty.get("customer_id"):
        return result(checkout.loyalty_status(loyalty.get("customer_id"))["text"])

    # Live stock: real BigQuery inventory (the engine's view was mock).
    stock = checkout.find_tool_call(events, "check_stock")
    if stock and stock.get("sku"):
        r = checkout.stock_status(stock.get("sku"))
        return result(r["text"], r.get("products", []))

    # Order lookup: read a stored order back from BigQuery.
    look = checkout.find_tool_call(events, "get_order")
    if look and look.get("order_id"):
        r = checkout.get_order(look.get("order_id"))
        return result(r["text"], r.get("products", []))

    # A sign-up on its own turn: the welcome message is the whole reply.
    if enrolment:
        return enrolment, []

    return None, None


def extract_product_mentions(text: str) -> list:
    """Find catalog products mentioned in the reply, so the UI can show cards.

    Matches by SKU first (e.g. 'SKU-007'), then by exact product name. Because
    Claude only names products that came back from catalog_search, these matches
    are real catalog items — no correction needed.
    """
    mentioned = []
    seen_skus = set()
    for match in re.findall(r"SKU-0*(\d{1,3})", text or ""):
        sku = f"SKU-{int(match):03d}"
        if sku not in seen_skus:
            product = next((p for p in CATALOG if p["sku"] == sku), None)
            if product:
                mentioned.append(product)
                seen_skus.add(sku)
    for product in CATALOG:
        if product["sku"] not in seen_skus and product["name"].lower() in (text or "").lower():
            mentioned.append(product)
            seen_skus.add(product["sku"])
    return mentioned[:6]


@app.on_event("startup")
async def setup():
    global remote_app
    try:
        vertexai.init(project=PROJECT_ID, location=LOCATION)
        client = vertexai.Client(project=PROJECT_ID, location=LOCATION)
        remote_app = client.agent_engines.get(name=AGENT_ENGINE_RESOURCE)
        print(f"Connected to Agent Engine: {AGENT_ENGINE_ID}")
    except Exception as e:
        print(f"ERROR connecting to Agent Runtime: {e}")


@app.get("/health")
async def health():
    return {"status": "healthy", "agent_engine": AGENT_ENGINE_ID, "products": len(CATALOG)}


@app.get("/api/products")
async def get_products():
    return {"products": CATALOG, "count": len(CATALOG)}


@app.get("/api/products/{sku}")
async def get_product(sku: str):
    product = next((p for p in CATALOG if p["sku"] == sku), None)
    if not product:
        raise HTTPException(status_code=404, detail=f"Product {sku} not found")
    return product


@app.get("/api/sample-prompts")
async def get_sample_prompts():
    from agents.prompt import SAMPLE_PROMPTS

    return {"prompts": SAMPLE_PROMPTS}


@app.post("/api/chat")
async def chat(request: Request):
    """Relay a chat turn to Agent Runtime and return the reply + product cards."""
    body = await request.json()
    messages = body.get("messages", [])
    user_id = body.get("user_id", "web_user")
    session_id = body.get("session_id", None)

    if not messages or not remote_app:
        raise HTTPException(status_code=400, detail="No messages or Agent Runtime not connected")

    latest_message = messages[-1]["content"]

    # One Agent Runtime session per browser conversation, so context carries over.
    if not session_id:
        session = remote_app.create_session(user_id=user_id)
        session_id = session["id"]

    final_response = ""
    last_error = None
    events = []
    for attempt in range(MAX_RETRIES):
        try:
            events = list(
                remote_app.stream_query(
                    user_id=user_id, session_id=session_id, message=latest_message
                )
            )
            final_response = extract_text_from_events(events)
            if final_response.strip():
                break
            if attempt < MAX_RETRIES - 1:
                time.sleep(RETRY_DELAYS[attempt])
        except Exception as e:
            last_error = e
            traceback.print_exc()
            if attempt < MAX_RETRIES - 1:
                time.sleep(RETRY_DELAYS[attempt])

    if not final_response.strip():
        if last_error:
            print(f"All {MAX_RETRIES} attempts failed. Last error: {last_error}")
        final_response = (
            "I'm taking a moment to gather my thoughts — could you try that again? "
            "If this keeps happening, try starting a new chat.\n\n[Vogue Concierge]"
        )

    # If the agent signalled a BigQuery action (order / loyalty), run the REAL
    # action here — money-moving writes stay off the model by design, not because
    # the engine can't reach BigQuery — and return the authoritative result in
    # place of the agent's placeholder.
    resp_text, prods = intercept_bigquery_action(events, session_id, user_id)
    if resp_text is not None:
        return {"response": resp_text, "products": prods, "session_id": session_id}

    # Product cards for the UI — straight from the reply, no correction needed.
    mentioned_products = extract_product_mentions(final_response)

    return {
        "response": final_response,
        "products": mentioned_products,
        "session_id": session_id,
    }


@app.post("/api/chat/stream")
async def chat_stream(request: Request):
    """Streaming variant of /api/chat (Server-Sent Events) for a snappier UI.

    Emits the agent's messages as they arrive (`{"delta": text}`), then a final
    frame (`{"final": {response, products, session_id}}`) with the authoritative
    reply — which, for a purchase, is the real checkout confirmation. The plain
    /api/chat endpoint above is kept intact as a fallback (the UI falls back to it
    if streaming fails), so this can't break the working request/response path.
    """
    body = await request.json()
    messages = body.get("messages", [])
    user_id = body.get("user_id", "web_user")
    session_id = body.get("session_id", None)
    if not messages or not remote_app:
        raise HTTPException(status_code=400, detail="No messages or Agent Runtime not connected")
    latest_message = messages[-1]["content"]
    if not session_id:
        session = remote_app.create_session(user_id=user_id)
        session_id = session["id"]

    def _event_text(ev) -> str:
        content = ev.get("content", {}) if isinstance(ev, dict) else {}
        text = ""
        for part in (content.get("parts", []) if isinstance(content, dict) else []):
            if isinstance(part, dict) and part.get("text", "").strip():
                text = part["text"]
        return text

    def gen():
        events = []
        try:
            for ev in remote_app.stream_query(user_id=user_id, session_id=session_id, message=latest_message):
                events.append(ev)
                t = _event_text(ev)
                if t:
                    yield "data: " + json.dumps({"delta": t}) + "\n\n"
        except Exception:
            traceback.print_exc()

        # Finalize: a BigQuery action (order / loyalty) runs the real thing;
        # otherwise use the agent's own reply.
        resp_text, prods = intercept_bigquery_action(events, session_id, user_id)
        if resp_text is not None:
            final = {"response": resp_text, "products": prods, "session_id": session_id}
        else:
            txt = extract_text_from_events(events) or (
                "I'm taking a moment to gather my thoughts — could you try that again?"
            )
            final = {"response": txt, "products": extract_product_mentions(txt), "session_id": session_id}
        yield "data: " + json.dumps({"final": final}) + "\n\n"

    return StreamingResponse(gen(), media_type="text/event-stream")


# --- Serve the built Next.js frontend ---------------------------------------
if UI_DIR.exists():
    next_dir = UI_DIR / "_next"
    if next_dir.exists():
        app.mount("/_next", StaticFiles(directory=str(next_dir)), name="next-static")

    # Resolved once so the containment check below compares real paths.
    UI_ROOT = UI_DIR.resolve()

    def _ui_file(candidate: Path):
        """Return `candidate` only if it is a real file inside the built UI.

        The catch-all route takes an arbitrary path straight off the URL, so it
        has to be contained explicitly. Resolving first collapses `..` segments
        and follows symlinks; anything that lands outside ui/out is rejected and
        falls through to index.html rather than being served.
        """
        try:
            resolved = candidate.resolve()
        except OSError:
            return None
        if not resolved.is_relative_to(UI_ROOT) or not resolved.is_file():
            return None
        return resolved

    @app.get("/{path:path}")
    async def serve_frontend(path: str):
        for candidate in (UI_DIR / path, UI_DIR / f"{path}.html"):
            found = _ui_file(candidate)
            if found is not None:
                return FileResponse(str(found))
        # Unknown route: hand back the SPA shell and let the client router deal.
        return FileResponse(str(UI_ROOT / "index.html"))


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8080))
    uvicorn.run(app, host="0.0.0.0", port=port)
