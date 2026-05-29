# Phase 10 Step 4 — Probe Y (manual real-GE-thread verification)

The Step 1 automated probe + Probe Z confirmed the **bridge** delivers
the right shape for both Path A and Path B. The original Phase 8
regression was at the **GE UI rendering layer** — so we still need one
manual eyeball in a real GE thread before commit.

## Three checks (in order, same thread is fine)

### 1. text/html → Path B (the original break)

Open a fresh thread in **PTA Co-Innovation Team → Claude Code agent**.
Paste:

> Build me a simple HTML form for collecting an email and a comment.
> Make it self-contained, no external CSS frameworks.

**Expect:**
- The agent uses `claude_code` to write something like
  `/workspace/form.html`.
- The agent's reply contains a clickable link of the form
  `https://storage.googleapis.com/cpe-slarbi-nvd-ant-demos-cc-a2a-snapshots/users/<key>/form.html?…X-Goog-Signature=…`
  embedded naturally in the text (e.g., *"I've created the form. You can
  download it here: https://…"*).
- No `Unsupported attachment` chip appears in the working pane for
  the HTML file.
- Clicking the link in the reply downloads `form.html` cleanly.

**Regression check (the Phase 8 bug):**
- ❌ If you see `Unsupported attachment` instead of the link, Path B
  did not fire. Halt and surface.
- ❌ If the link is present but clicking it returns a 403 or expired,
  the bridge `/workspace/sign` step broke. Halt.

### 2. text/csv → Path A (regression-safe control)

In the SAME thread (claim reuse), paste:

> Now create a 3-row CSV of sample employees (name,email,department)
> and surface it as a downloadable file.

**Expect:**
- The agent writes `/workspace/employees.csv` (or similar).
- A normal **downloadable chip** appears in the working pane — that's
  the Path A FilePart/FileWithBytes rendering. Click → CSV downloads.
- No signed URL link in the text (Path B was correctly NOT taken for
  text/csv).

### 3. application/json → Path A (allowlist edge case)

Same thread, paste:

> Generate a sample JSON config file with a few realistic settings and
> emit it as a downloadable artifact.

**Expect:**
- Path A chip again (application/json is on the allowlist).
- No "Unsupported attachment". No signed URL in text.

## What to report back

A one-line confirmation per check is enough. Example:

> 1. HTML → signed URL link, clicked, downloaded form.html. PASS.
> 2. CSV → chip, clicked, employees.csv downloaded. PASS.
> 3. JSON → chip, clicked, settings.json downloaded. PASS.

If any check fails, paste the exact GE UI behavior you see (or a
screenshot) so I can diagnose before committing.

## After your PASS confirmation

I'll commit **"Phase 10: route non-allowlist MIMEs through signed URLs;
full-file read mode; manifest sweep"** with:
- PROJECT_PLAN.md updated (Phase 10 entry, GE MIME allowlist section,
  Lessons learned on synthetic-vs-real UI tests, Phase 8 retro)
- A concise Phase 10 retrospective summary for the design-doc update
- Then HARD STOP.
