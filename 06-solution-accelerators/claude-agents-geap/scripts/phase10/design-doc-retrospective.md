# Phase 10 retrospective — for design doc v1.2

A clean, paste-ready summary you can use to update the engineering
design doc. Honest about what Phase 8 missed and what Phase 10 fixed.

## What changed

Phase 8 had claimed "downloadable chip working in GE UI" based on a
synthetic smoke test that inspected the bridge's JSON-RPC response
shape and confirmed `result.artifacts[0].parts[0].file.bytes` was a
non-empty base64 string with the right `mimeType`. That claim was
wrong: in a live Gemini Enterprise thread, three MIME types
(text/html, application/zip, application/octet-stream) surfaced
"Unsupported attachment" at the UI rendering layer even though the
A2A protocol delivery was correct. GE applies its own MIME allowlist
downstream of the bridge.

Phase 10 corrects this with MIME-aware routing in `emit_artifact`,
adds a full-file read mode to eliminate temp-file pollution from the
agent's prior workaround for the 4000-char read truncation, and adds
a manifest sweep that purges those leftover scratchpad files on park.

## The verified GE MIME allowlist (2026-05-15)

| MIME                       | GE UI behavior                              | Route |
| -------------------------- | ------------------------------------------- | ----- |
| `text/csv`                 | Native chip + Export-to-Sheets preview      | Path A |
| `text/plain`               | Native chip                                 | Path A |
| `application/json`         | Native chip + inline syntax highlighting    | Path A |
| `application/pdf`          | Native chip + inline PDF viewer             | Path A |
| `image/png`, `image/jpeg`  | Native chip (universal)                     | Path A |
| `text/html`                | "Unsupported attachment"                    | Path B |
| `application/zip`          | "Unsupported attachment"                    | Path B |
| `application/octet-stream` | "Unsupported attachment"                    | Path B |
| (anything not listed)      | Unverified                                  | **Path B by default** |

**Routing rule:** allowlisted MIME with size ≤ 5 MB → Path A (inline
FilePart/FileWithBytes chip). Everything else → Path B (15-min v4
signed Cloud Storage URL, embedded in the assistant's reply text
verbatim per system-prompt instruction). The bridge never sees the
URL in logs; it appears once in the reply and the agent does not
repeat it.

## How the verification worked

1. **Automated bridge-side probe** (`scripts/phase10/automated-mime-probe.sh`)
   — 9 separate `message/send` calls to the bridge, one per MIME type.
   Captured the full JSON-RPC response for each. Result: 8 of 9 round-
   tripped cleanly bridge-side (the 9th, octet-stream, failed inside
   the inner `claude_code` subagent on a Usage-Policy refusal of the
   synthetic binary blob — not a bridge issue).

2. **Discovery Engine session check** confirmed an architectural
   detail: direct A2A `message/send` calls don't transit DE's session
   layer (only `assistants:streamAssist` does), so DE has no record
   of these threads. The bridge-side capture is the authoritative
   signal.

3. **Probe Y — real GE thread (the empirical authority)**: three
   manual prompts (HTML form, CSV employees, JSON config) sent through
   the actual GE UI. Result: HTML rendered as a clickable signed-URL
   link in the agent's reply text; CSV and JSON rendered as native
   chips with bonus GE inline previews. All three PASS.

## Lessons that go into the doc

1. **Any claim about user-visible behavior requires a real UI test,
   not just an API response check.** The protocol layer can be correct
   while the rendering layer rejects. When the UI rendering surface is
   owned by an upstream system (GE, Slack, Gmail, etc.), the
   acceptance test for "looks right to the user" cannot be a JSON
   shape assertion alone.

2. **MIME allowlist is a property of the host UI, not the protocol.**
   A2A delivers any MIME the bridge stamps. GE accepts the subset it
   knows how to render. Routing decisions live at the artifact-
   emission boundary, where the producer can introspect the file
   before deciding whether to emit a chip or a link.

3. **Safe defaults beat clever optimism.** The post-Phase-10 rule is
   "if not verified to render in GE, use a signed URL." A link with
   explanatory text always works; a chip that fails is a dead end for
   the user.

4. **Phase 8's regression scope was bigger than the bug report.** The
   user reported text/html; the probe found text/html + zip + octet-
   stream. Future bug triages: always re-run the probe across the
   adjacent MIME space, not just the reported case.

## Operational notes for ongoing maintenance

- The probe in `scripts/phase10/automated-mime-probe.sh` is
  re-runnable. Refresh `PROJECT_PLAN.md`'s allowlist table when GE
  ships new attachment renderers (or when a user reports
  "Unsupported attachment" on a type we currently route via Path A).
- `bridge/auth.py` continues to log the anon-fallback warning for
  GE-routed calls (Phase 7's v1 single-user-mode caveat — separate
  follow-up work).
- The bridge image `phase8-r1` is unchanged in Phase 10; signed URLs
  still come from the `/workspace/sign` endpoint that Phase 8 built.

## Pointers to the artifacts

| What                                      | Where |
| ----------------------------------------- | ----- |
| Routing decision in code                  | `backend/tools/artifact_tool.py:emit_artifact` + `ALLOWLIST_MIMES` |
| Signed-URL minting (bridge side)          | `bridge/main.py:/workspace/sign` |
| Probe script                              | `scripts/phase10/automated-mime-probe.sh` |
| Probe results (auto-generated)            | `scripts/phase10/mime-probe-results.md`, `probe-summary.md`, `probe-raw/*.json` |
| Probe Y manual test brief                 | `scripts/phase10/probe-y-ge-thread-test.md` |
| Allowlist source-of-truth                 | `PROJECT_PLAN.md` § "GE MIME allowlist (verified 2026-05-15)" |
| Lessons learned                           | `PROJECT_PLAN.md` § "Synthetic smoke tests cannot validate UI-rendering claims" |
