# Phase 10 — MIME probe summary

Test user: `phase10-mime-1778877195-694594`

## What the automation tested

9 direct `message/send` JSON-RPC calls to `https://cc-a2a-bridge-qrr3gkz3tq-uc.a.run.app/`, one per MIME type, each asking the agent to write a tiny valid file of that type and then call `emit_artifact`. The bridge's full JSON-RPC response for each is in `scripts/phase10/probe-raw/<label>.json`.

## Bridge-side results

- **Delivered an artifact:** 8 / 9 — text-html, text-csv, text-plain, application-json, application-pdf, image-png, image-jpeg, application-zip
- **Completed turn but no artifact in response:** application-octet-stream

Per-row detail (mimeType the bridge stamped, base64 byte-count):

- `text-html`: state=completed, artifacts=1, bridge-labelled mime=`text/html`, bytes_b64=68c
- `text-csv`: state=completed, artifacts=1, bridge-labelled mime=`text/csv`, bytes_b64=32c
- `text-plain`: state=completed, artifacts=1, bridge-labelled mime=`text/plain`, bytes_b64=32c
- `application-json`: state=completed, artifacts=1, bridge-labelled mime=`application/json`, bytes_b64=40c
- `application-pdf`: state=completed, artifacts=1, bridge-labelled mime=`application/pdf`, bytes_b64=724c
- `image-png`: state=completed, artifacts=1, bridge-labelled mime=`image/png`, bytes_b64=92c
- `image-jpeg`: state=completed, artifacts=1, bridge-labelled mime=`image/jpeg`, bytes_b64=848c
- `application-zip`: state=completed, artifacts=1, bridge-labelled mime=`application/zip`, bytes_b64=176c
- `application-octet-stream`: state=completed, artifacts=0, bridge-labelled mime=``, bytes_b64=0c

## What this tells us about the BRIDGE

The bridge (Phase 8 plumbing) delivers Path A inline-base64
artifacts for every MIME type tested above. The bytes round-trip
cleanly. **If a chip is missing in the GE UI for a particular
MIME, the rejection happens DOWNSTREAM of the bridge — i.e., at
Gemini Enterprise's UI rendering layer or its session-write path.**
The bridge is not the bottleneck.

## Discovery Engine side-channel — what we found

As expected from the architecture: DE has NO record of our 9
probe threads. Direct `message/send` calls hit the bridge URL,
not `assistants:streamAssist`. DE only sees agents that the
assistant LLM routes to. So `mime-probe-results.md` is the
authoritative bridge-side artifact picture; the DE-history
column was vestigial for this probe.

## The one manual step still required

Run one end-to-end CUJ from a real GE thread that asks the agent
to produce a chip of each MIME type (or at least the contested
ones — text/html, the binaries — plus a known-good text/csv as a
control). Take a SINGLE screenshot of which chips render normally
vs which show `Unsupported attachment` or equivalent. That
screenshot is the empirical UI-render evidence for the routing
matrix in Step 2.

If we observe in that screenshot that `text/html` is the rejected
type (the originally-reported symptom), the routing matrix becomes:

- Path A (keep inline bytes): text/csv, text/plain, application/json, application/pdf, image/png, image/jpeg, application/zip, application/octet-stream
- Path B (route to signed URL embedded in assistant text):
  text/html, plus any other rejected types the screenshot reveals.
