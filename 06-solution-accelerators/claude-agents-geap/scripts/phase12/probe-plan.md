# Phase 12 Step 1 — A2UI v0.8 probe plan

Research + design only. No code, no deploy. HALT for sign-off
before Step 2 (build + register).

---

## 1. Reference sample summary

Source: `github.com/google/A2UI/tree/main/samples/agent/adk/gemini_enterprise/cloud_run`.

### (a) Agent card declaration

The sample's README registration payload embeds this card (relevant
fields only, formatted):

```json
{
  "protocolVersion": "0.3.0",
  "capabilities": {
    "streaming": false,
    "preferredTransport": "JSONRPC",
    "extensions": [
      {
        "uri": "https://a2ui.org/a2a-extension/a2ui/v0.8",
        "description": "Ability to render A2UI",
        "required": false,
        "params": {
          "supportedCatalogIds": [
            "https://a2ui.org/specification/v0_8/standard_catalog_definition.json"
          ]
        }
      }
    ]
  }
}
```

The sample's `agent.py` builds this programmatically via
`a2ui.a2a.get_a2ui_agent_extension(version="0.8", supported_catalog_ids=[...])`
which returns an `a2a.types.AgentExtension`. We can build the same
extension by hand without depending on the `a2ui` Python SDK — the
shape is small and stable.

### (b) How an ADK agent emits an A2UI surface

The sample's `agent_executor.py` does roughly:

1. `try_activate_a2ui_extension(context, agent_card)` — reads
   `context.requested_extensions` (URIs the client asked for), matches
   against the card's advertised extensions, returns the negotiated
   version (or None for text-only fallback).
2. When active, calls the LLM with a system prompt that asks for an
   A2UI JSON payload between `A2UI_OPEN_TAG`/`A2UI_CLOSE_TAG` markers.
3. `parse_response_to_parts(content, validator, fallback_text)` —
   splits the response into a list of A2A `Part`s. Each A2UI surface
   message becomes ITS OWN `DataPart` (no batching).
4. Emits via `updater.update_status(state, new_agent_parts_message(parts))`.
   The sample uses `TaskState.input_required` for surfaces that await
   user interaction; `TaskState.completed` only for terminal actions.

### (c) Wire format on A2A (from `a2ui/a2a/parts.py`)

```python
A2UI_MIME_TYPE = "application/json+a2ui"

def create_a2ui_part(a2ui_data: dict) -> Part:
    return Part(root=DataPart(
        data=a2ui_data,
        metadata={"mimeType": "application/json+a2ui"},
    ))
```

So each A2UI message (beginRendering / surfaceUpdate / dataModelUpdate)
becomes one `Part(DataPart(data=<that message dict>, metadata={mimeType:
"application/json+a2ui"}))`. The whole surface is therefore N parts in
the same `agent` message, in arrival order.

### (d) v0.8 message envelope (from `examples/0.8/follow_success.json`)

```json
[
  {"beginRendering": {"surfaceId": "<id>", "root": "<component-id>"}},
  {"surfaceUpdate": {
    "surfaceId": "<id>",
    "components": [
      {"id": "...", "component": {"<ComponentType>": { ... }}},
      ...
    ]
  }}
]
```

Two messages per surface: a `beginRendering` (tells GE to start
rendering surface X with root Y) followed by one or more
`surfaceUpdate`s (provides the component graph). Optionally
`dataModelUpdate` for data-bound inputs.

### (e) ClientEvent back-flow (NOT exercised by this probe)

User clicks → GE sends a follow-up `message/send` whose `parts`
include a `DataPart` with `data = {"userAction": {"name": "<event>",
"context": {...}}}`. The executor reads it and decides the next turn.
Out of scope for Step 1 — we'll add this if we proceed to Step 2.

---

## 2. Agent-card diff — probe vs. production

**Strategy:** keep the production agent registration UNTOUCHED.
Register a SECOND agent on the same engine with the A2UI extension
declared. Same bridge URL — both registrations point at it. GE will
only emit `requested_extensions` for calls routed to an agent that
advertises a matching extension, so the probe and prod paths stay
naturally isolated.

The probe registration payload — based on the current
`scripts/register-agent-payload.json` — needs only these changes:

```diff
 {
-  "displayName": "Claude Code",
+  "displayName": "Claude Code A2UI v0.8 PROBE",
-  "description": "Build scripts, dashboards, and prototypes from plain English. … v1 demo (single-user mode).",
+  "description": "Phase 12 A2UI v0.8 probe. Send 'A2UI-PROBE' to render a hardcoded surface. Delete after testing.",
   "a2aAgentDefinition": {
     "jsonAgentCard": "{
       …,
       \"capabilities\": {
         \"pushNotifications\": false,
         \"stateTransitionHistory\": false,
         \"streaming\": true,
+        \"extensions\": [
+          {
+            \"uri\": \"https://a2ui.org/a2a-extension/a2ui/v0.8\",
+            \"description\": \"Ability to render A2UI\",
+            \"required\": false,
+            \"params\": {
+              \"supportedCatalogIds\": [
+                \"https://a2ui.org/specification/v0_8/standard_catalog_definition.json\"
+              ]
+            }
+          }
+        ]
       },
       …
     }"
   },
-  "starterPrompts": [ … prod three prompts … ],
+  "starterPrompts": [
+    {"text": "A2UI-PROBE"}
+  ],
   …
 }
```

`protocolVersion` stays at `"0.2"`. The sample uses `"0.3.0"` but our
existing prod registration uses `0.2` and works fine; `AgentCapabilities.
extensions` is already accepted by a2a-sdk 0.2.13 (verified in Phase 5
Probe A). If GE rejects the registration on protocol version we'll
bump on retry — but defer changing it until proven necessary.

`required: false` so GE doesn't refuse to call the agent if it can't
render A2UI. Description warns explicitly that this is a probe agent
to delete after testing.

The PRODUCTION agent's card is **not** modified. Phase 8 Path B
behavior is preserved exactly for the prod registration.

---

## 3. Hardcoded A2UI v0.8 payload

A minimal surface modelled on `examples/0.8/follow_success.json`
(known-valid v0.8 shape per the spec's `standard_catalog`). Two
messages → two `Part(DataPart(...))`s in the agent reply:

**Message 1 — `beginRendering`:**
```json
{
  "beginRendering": {
    "surfaceId": "phase12-probe",
    "root": "root_card"
  }
}
```

**Message 2 — `surfaceUpdate`:**
```json
{
  "surfaceUpdate": {
    "surfaceId": "phase12-probe",
    "components": [
      {"id": "root_card", "component": {"Card": {"child": "col"}}},
      {"id": "col", "component": {"Column": {
        "children": {"explicitList": ["title", "info", "submit"]},
        "alignment": "stretch"
      }}},
      {"id": "title", "component": {"Text": {
        "text": {"literalString": "Phase 12 A2UI v0.8 probe"},
        "usageHint": "h2"
      }}},
      {"id": "info", "component": {"Text": {
        "text": {"literalString": "If you see this rendered with a working Submit button, A2UI v0.8 ↔ GE works end-to-end via cc-a2a-bridge."}
      }}},
      {"id": "submit", "component": {"Button": {
        "label": {"literalString": "OK"}
      }}}
    ]
  }
}
```

Why this shape:
- Uses only `Card`, `Column`, `Text`, `Button` — all present in the
  v0.8 standard catalog (confirmed in `examples/0.8/follow_success.json`
  which uses Card/Column/Text/Icon).
- Distinct enough to be obvious in the UI — title is "Phase 12 A2UI
  v0.8 probe", not generic.
- Button click is NOT round-tripped — we end the task as `completed`
  on first emission. If you click OK after rendering, nothing happens
  (probe limitation; documented as such in the test brief).

---

## 4. Bridge changes

**Single function:** add an early branch in
`bridge/main.py:CCAgentExecutor.execute` that intercepts the trigger
phrase before any backend work runs:

```python
# Pseudocode — actual change is ~25 lines, gated on env flag.
if os.environ.get("A2UI_PROBE_ENABLED") == "true":
    user_input = (context.get_user_input(delimiter="\n") or "").strip()
    if user_input == "A2UI-PROBE":
        updater = TaskUpdater(event_queue, task_id, context_id)
        await updater.submit()
        await updater.start_work()
        parts = [
            Part(root=TextPart(text="Rendering A2UI v0.8 probe surface…")),
            Part(root=DataPart(
                data={"beginRendering": {"surfaceId": "phase12-probe", "root": "root_card"}},
                metadata={"mimeType": "application/json+a2ui"},
            )),
            Part(root=DataPart(
                data={"surfaceUpdate": { … as above … }},
                metadata={"mimeType": "application/json+a2ui"},
            )),
        ]
        await updater.complete(message=updater.new_agent_message(parts=parts))
        return
# else: existing flow (resolve user → claim → backend → translate)
```

- **No `bridge/translate.py` changes.** translate.py only kicks in for
  the backend's SSE → A2A path. The probe short-circuits BEFORE
  invoking the backend, so the SSE translator is bypassed entirely.
- **No backend changes.** `backend/server.py`, `adk_agent.py`,
  `tools/*` all stay identical. Probe is bridge-only.
- **Gated by `A2UI_PROBE_ENABLED=true` env on the bridge Cloud Run
  service.** Without the env var, the trigger is inert and the bridge
  behaves exactly as today.
- **`required_extensions` check is skipped.** Per the upstream
  `try_activate_a2ui_extension` logic, GE will send `requested_extensions
  = ["https://a2ui.org/a2a-extension/a2ui/v0.8"]` when calling the
  probe registration (because that registration advertises it). The
  probe code path doesn't need to verify this — if A2UI rendering is
  off (e.g., wrong agent called), GE will just display the DataParts
  as raw JSON which is fine for a probe.

**Why this design:**
- Production traffic completely unaffected when env is off.
- One env var flip + redeploy disables the probe path without touching
  code.
- Probe-specific logic is self-contained in a single early branch in
  one function — no fan-out to other modules.

---

## 5. Registration plan

Add a new script `scripts/phase12/register-probe-agent.sh` that's a
near-copy of the existing `scripts/register-agent.sh` with three
deltas:

1. `AGENT_DISPLAY_NAME="Claude Code A2UI v0.8 PROBE"`
2. Payload builder injects the `capabilities.extensions` array
3. Idempotent: GET-list first, match displayName, POST or PATCH

Idempotency: same `LIST → match by displayName → POST/PATCH` pattern
the prod script uses. So re-running the probe registration is safe
even if the agent already exists.

The script reuses the existing builder-SA impersonation pattern for
the Discovery Engine API; no new IAM grants needed.

Same `run.invoker` IAM on the bridge — already in place
(`service-PROJECT_NUMBER@gcp-sa-discoveryengine.iam.gserviceaccount.com`
has been a member of `run.invoker` since Phase 5). Probe registration
uses the same Cloud Run service, so no IAM change.

---

## 6. Manual test plan (Probe Y-style, real GE thread)

### Operational note — probe lifetime

The probe agent registers as **ENABLED** (visible to all PTA users
in the gallery — no documented `PRIVATE` create-time path on the
Agent resource). To minimise exposure: **the probe agent's lifetime
is one focused session, target ≤15 minutes**. Do not register the
probe and walk away; do not let it sit overnight. Sequence:

1. Register → 2. Open thread → 3. Send `A2UI-PROBE` → 4. Screenshot
→ 5. `unregister-probe-agent.sh --apply` immediately.

Same operational rule is repeated in the unregister script's header
so anyone who runs it sees the lifetime expectation first.

### Test sequence

After bridge redeploys with `A2UI_PROBE_ENABLED=true` and probe agent
is registered:

1. Open the **PTA Co-Innovation Team** app in GE.
2. Open the Agent Gallery — **two** Claude Code agents now visible:
   - "Claude Code" (production)
   - "Claude Code A2UI v0.8 PROBE" (probe — description warns it's
     temporary)
3. Select the **probe** agent.
4. Send the single literal message: `A2UI-PROBE`.
5. Apply the observation rubric below to whatever appears.
6. Take one screenshot and paste it back with the matching rubric
   verdict.
7. **Immediately** run `bash scripts/phase12/unregister-probe-agent.sh
   --apply` — do not pause to celebrate or debug while the probe is
   still in the gallery.

### Observation rubric (decide BEFORE taking the screenshot)

Each verdict has a fixed interpretation and a fixed next action.
Pick the closest match.

| Verdict | What you see | Interpretation | Next action |
|---------|--------------|----------------|-------------|
| **PASS** | GE renders a native Card with the title "Phase 12 A2UI v0.8 probe", the info text, and an OK button. No raw JSON, no error chip, no "Unsupported attachment". Task shows `completed`. | A2UI v0.8 handshake works end-to-end: agent-card extension declaration negotiated, A2A DataParts with `mimeType: application/json+a2ui` rendered by GE's A2UI surface engine. Phase 12 is feasible. | Screenshot, unregister probe immediately, commit "Phase 12 probe: A2UI v0.8 render verified", move planning to Step 3 (production integration scope). |
| **PARTIAL** | A card-like UI appears but elements are missing, misaligned, fall back to a default component, or text reads but Button is unstyled. No outright error. | A2UI handshake succeeded but GE's renderer doesn't recognise one or more components in the payload (catalog mismatch, v0.8 schema drift). | Screenshot showing exactly which components rendered vs. didn't. Unregister probe. Decide: simplify the probe payload to text-only Card+Text and re-probe, OR confirm catalog version mismatch with Google docs. Probably one retry, not a full rebuild. |
| **FAIL-JSON** | GE renders the literal text content of the DataParts (e.g., `{"beginRendering": ...}`) as a normal text reply, OR renders nothing visible from the surface parts and just shows the TextPart preamble. | A2UI extension was NOT activated on this call. The agent-card declaration didn't take effect, or GE didn't include the extension in `requested_extensions` for this turn. Most likely cause: missing/malformed `params.supportedCatalogIds`, wrong extension URI, or `mimeType` metadata key incorrect on the DataPart. | Screenshot. Unregister probe. Inspect the actual registered jsonAgentCard via DE GET to confirm the extension landed verbatim. Inspect bridge logs for the request — did GE send `requested_extensions`? If yes but render failed, the issue is the DataPart metadata; if no, the issue is registration. Fix is a one-line patch; re-probe in a fresh session. |
| **FAIL-UNSUPPORTED** | GE shows "Unsupported attachment" (same UI error as the Phase 8 text/html regression) on the DataPart(s). | GE knows about the DataPart but its renderer rejected it — same class of bug as the Phase 10 MIME allowlist issue, but at the DataPart-mime layer instead of the FilePart-mime layer. The `application/json+a2ui` MIME is not on GE's currently-supported A2UI surface renderer list. | Screenshot. Unregister probe. Add `application/json+a2ui` to the design-doc retrospective alongside text/html/zip/octet-stream as another GE rendering blocker. A2UI on GE may not be live for PTA Co-Innovation Team yet — check the GE release notes / contact platform owners. Phase 12 is BLOCKED until GE's A2UI surface renderer is enabled for this engine type. |
| **FAIL-REGISTRATION** | `register-probe-agent.sh --apply` returns non-2xx HTTP, or the gallery never shows the probe agent. | Discovery Engine refused the registration — most likely `protocolVersion` mismatch, malformed `extensions` array shape, or a permission denial on the API call. | Capture the registration response body. If it's a 400, inspect the error detail and try the obvious fixes (bump `protocolVersion` to `0.3.0`, double-check `params` schema, etc.). If 403, re-verify the builder SA impersonation. No probe code/payload work needed until registration succeeds. |

The rubric is the gate, not gut feel. If two verdicts apply, pick the
more pessimistic one and document why.

### Rubric addendum — emission-order remediation

The probe ships with surfaceUpdate emitted BEFORE beginRendering,
because the v0.8 spec prose says components must exist before the
surface is told to render its root. The upstream
`examples/0.8/follow_success.json` reverses the order. That's a real
spec-vs-sample contradiction; we picked the spec.

**Consequence:** if the probe fails, emission order is the prime
suspect — not GE support.

**Branch on FAIL-UNSUPPORTED or PARTIAL:**

BEFORE concluding "GE does not support A2UI", the FIRST remediation
to try is flipping the emission order to **beginRendering-then-
surfaceUpdate** (matching the upstream `follow_success.json` sample).
Rationale: upstream sample code is what Google actually ships and
tests; spec-vs-sample disagreements frequently resolve in favor of
the running sample.

Remediation steps if needed:
1. Swap the two `Part(root=DataPart(...))` entries in
   `_emit_a2ui_probe`. One-line reorder.
2. Rebuild `cc-a2a-bridge:phase12-r2`.
3. `terraform apply` the new image tag (no env change, no agent
   re-registration — the agent card is unchanged).
4. Re-run the same `A2UI-PROBE` turn in the same GE thread (or a
   fresh thread if state caching is suspected).
5. Re-apply the rubric to the second attempt.

Only after BOTH orderings fail do we record FAIL-UNSUPPORTED as a
genuine GE limitation. Document which ordering worked (or that both
failed) in `scripts/phase12/probe-results.md`.

**Branch on PASS:** the spec ordering was correct. Record in the
probe results that spec beat sample for future A2UI work in this
project — the upstream follow_success.json example is misleading on
this one point, and the spec prose is authoritative.

---

## 7. Rollback

Three-step revert, ~5 minutes:

1. `bash scripts/phase12/unregister-probe-agent.sh --apply`
   → DELETE the probe agent from DE.
2. `gcloud run services update cc-a2a-bridge --remove-env-vars=A2UI_PROBE_ENABLED`
   (or set to anything other than `"true"`)
   → trigger-phrase becomes inert.
3. `terraform apply` — if we baked the env into `cloudrun.tf`, remove
   the entry and apply. Otherwise the gcloud update is sufficient.

The bridge code's probe branch is harmless when the env flag is off —
no need to revert the code unless we decide A2UI is not coming back.
After Step 2 (build), the bridge image still carries the probe code
but won't run it.

If we want a clean code revert: `git revert <phase12-step2-commit>`
and redeploy. That removes the probe branch entirely, just leaving
the plan markdown.

---

## 8. Open questions to confirm before Step 2

1. **`protocolVersion`:** keep at `"0.2"` (what our prod agent uses
   today, no GE complaints) or bump probe to `"0.3.0"` to match the
   upstream sample? I'd start with `0.2` and bump only if GE rejects
   the registration. **Recommendation: stay at 0.2.**

2. **Probe agent gallery visibility:** ACCEPTED — `PRIVATE` isn't a
   real create-time option on the Agent resource (it's a state set by
   GE's review path, not by the create call), so the probe will be
   ENABLED and gallery-visible to all PTA users for its lifetime.
   **Mitigated by operational rule: probe lifetime ≤ 15 minutes,
   delete immediately after screenshot, never leave running while
   away from keyboard.** The rule is repeated in §6 above and in the
   unregister script's header so it's impossible to miss.

3. **`required: false` is the right choice** (matches upstream
   sample). Setting `required: true` would mean clients refuse to
   call us unless they support A2UI — too aggressive for a probe.
   **No question; confirming for the record.**

4. **TaskState for the probe response.** Upstream uses
   `input_required` for surfaces awaiting clicks; we'll use
   `completed` to keep the task closed and not hang on the OK button.
   If we want to test the click round-trip later, that's a Step 2.x
   follow-up. **Recommendation: completed.**

5. **What about `accepts_inline_catalogs`?** The sample's
   `get_a2ui_agent_extension` adds `params.acceptsInlineCatalogs = true`
   if the agent supports inline catalogs. We don't, so we won't add
   that param — only `supportedCatalogIds` per the user's stated facts.
   **No question; confirming for the record.**

---

## 9. What I'm NOT changing

- Production agent registration (`Claude Code` agentId
  `5479509043993124503`). Untouched.
- `backend/*` — no changes.
- `bridge/translate.py`, `bridge/auth.py`, `bridge/sandbox.py`,
  `bridge/downscope.py`. No changes.
- `bridge/agent_card.py` — no changes (only the registration
  payload's embedded JSON card carries the extension).
- IAM, NetworkPolicy, SandboxTemplate. No changes.
- iso-test or smoke. No changes (the probe path doesn't touch the
  isolation invariant or any existing functional path).

---

## 10. Step 2 preview (what would happen on plan approval)

Roughly:

1. Add `A2UI_PROBE_ENABLED` env support to bridge code (~25-line
   early branch in `CCAgentExecutor.execute`).
2. Build `cc-a2a-bridge:phase12-r1`.
3. `terraform apply` — adds the env var to cloudrun.tf and bumps
   image tag. Show plan first.
4. Write `scripts/phase12/register-probe-agent.sh` +
   `scripts/phase12/unregister-probe-agent.sh`.
5. Run the probe registration. Capture the response.
6. HALT — wait for you to do the manual GE-thread test and paste the
   screenshot.
7. On PASS: commit "Phase 12 probe: A2UI v0.8 render verified in GE".
8. On the way out: unregister probe agent, flip env off, optionally
   keep the probe code path behind the now-off flag for future
   re-enablement.
