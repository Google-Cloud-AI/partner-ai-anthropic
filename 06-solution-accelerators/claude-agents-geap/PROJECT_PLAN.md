# Project Plan — Claude Code on Gemini Enterprise (MVP)

Live milestone tracker. Update as phases complete.

---

## Success criteria for MVP

The MVP is "done" when **all three** of the following are true:

1. **End-to-end demo works.** From a real Gemini Enterprise thread, a user
   selects "Claude Code" from the Agent Gallery, sends a prompt, and sees
   streaming tool activity + a downloadable file artifact. The three target
   CUJs (below) all complete successfully.
2. **Security model holds.** The isolation negative test passes: a pod for
   user A cannot read user B's GCS prefix even with full shell access. The
   pod's own service account has zero IAM on the snapshots bucket.
3. **Reproducible deploy.** `make bootstrap && make deploy` stands the
   entire stack up in an empty GCP project, with one manual step (OAuth
   consent screen).

---

## Three CUJs the MVP must demonstrably nail

These are the ones we will walk through on a live demo:

### CUJ 1 — PM: spec → clickable prototype
> "I pick Claude Code in the Agent Gallery, paste a PRD link from Drive,
> get a working HTML prototype back as a file artifact, then reply 'make
> the empty state friendlier and add a retry button' in the same thread
> and watch it edit the prototype it just wrote."

**Tests:** multi-turn context, file artifact emit, Drive URL ingestion
(stretch — connector context is officially out of v1; for the demo we
manually paste PRD text).

### CUJ 2 — Growth marketer: CSV → ad copy
> "I upload last month's ad performance CSV and say 'find the bottom-quartile
> headlines and write 50 new variants under 30 characters'. I get a sheet
> back as an artifact in minutes."

**Tests:** binary attachment ingestion, Read + Bash tool calls (pandas),
artifact emission for non-HTML files.

### CUJ 3 — Analyst: messy CSV → interactive dashboard
> "I drop a billing CSV and say 'build me an interactive chart of MRR by
> segment with a date slider'. I get a self-contained HTML dashboard."

**Tests:** complex multi-tool turn (Read → Bash → Write), self-contained
HTML output, dashboards run offline in the browser.

---

## Full CUJ list (reference, from doc 1)

Use these to drive future phase planning, internal demos, and persona
videos. The three above are required for MVP sign-off; the rest are
"nice-to-have" once the foundation works.

### Product Manager
- Spec → prototype (CUJ 1 above) — **p0, MVP**
- Iterate prototype in same thread — **p0, MVP**
- "What error states does checkout actually handle?" (read repo) — p1
- "How does pricing get calculated?" (grep + read billing service) — p0
- Attach cited files as artifacts — p1

### Growth Marketer
- CSV → 50 ad copy variants (CUJ 2 above) — **p0, MVP**
- Follow-up: descriptions, 90-char, top performers' tone — p1
- Save reusable script in workspace — p1
- A/B landing page variant from description — p0 (post-MVP)

### Sales / Solutions Engineer
- Rebrand demo repo for prospect (logo, palette, sample data) — p0
- Operate from phone between meetings, watch streaming — p0
- Mid-call: add fake SSO screen — p1

### Business / Data Analyst
- Messy CSV → interactive dashboard (CUJ 3 above) — **p0, MVP**
- Conversational data cleanup ("anything starting with ENT- is Enterprise") — p1
- Weekly report Python script → artifact for data eng — p1

### Product Designer
- Screenshot + "tighten spacing to 12px" → edit CSS in repo — p0
- "Show me everywhere we still say 'beta'" — p1
- Figma export → clickable prototype — p0

### Legal / Compliance
- "Find every 'unlimited' promise across app + marketing" — p0
- Draft replacement copy as a diff artifact — p1
- Internal tracker (Apps Script / web page) — p1

---

## Phases

### Phase 0 — Bootstrap (½ day)

- [x] Terraform state bucket `cpe-slarbi-nvd-ant-demos-tfstate` (uniform access, versioned, keep last 30 noncurrent)
- [x] Enable required APIs: aiplatform, container, run, firestore, storage, sts, iamcredentials, artifactregistry, cloudbuild, discoveryengine
- [x] `cc-a2a-builder` Cloud Build service account
       (`roles/editor`, `roles/run.admin`, `roles/container.admin` — **TODO: tighten before external demo**)
- [x] Two-root Terraform layout: `infra/terraform/bootstrap/` (local backend) creates the state bucket; `infra/terraform/` (gcs backend, prefix `cc-on-ge`) houses Phase 1+ resources
- [x] Empty repo with the target layout (see `CLAUDE.md`)
- [x] `Makefile` skeleton with `check-env`, `bootstrap`, `deploy`, `smoke`, `sandbox-smoke`, `iso-test`, `lint`, `github-init` targets; `check-env` is a prereq of `bootstrap`
- [x] `scripts/check-env.sh` verifies gcloud auth, project, and terraform/gh/jq/ruff on PATH
- [x] `pyproject.toml` ruff config at repo root
- [x] All seven skills in `.claude/skills/`
- [x] `git init` local only; defer GitHub remote (`make github-init` exists but is not run in Phase 0; target repo: `PTA-Co-innovation-Team/cc-on-ge`)

**Exit criterion:** `make bootstrap` runs clean on an empty project.

---

### Phase 1 — Infra slice (1 day)

Terraform brings up the static infrastructure. No application code yet.

- [x] GKE Autopilot cluster `cc-sandbox` (rapid channel; Agent Sandbox addon enabled via `null_resource` + `gcloud beta --enable-agent-sandbox` — provider lacks native field, see "Known deferrals")
- [x] Artifact Registry repo for `cc-bridge`, `cc-backend` images
- [x] Cloud Storage bucket `<project>-cc-a2a-snapshots` (uniform access, versioned)
- [x] Firestore database `cc-on-ge` (named — NOT the project default; native mode, `us-central1`)
- [x] Service accounts: `cc-a2a-bridge`, `cc-a2a-backend`
- [x] IAM: bridge SA gets `roles/storage.objectAdmin` on the snapshots bucket;
       backend SA gets **nothing** on the bucket
- [x] `sts.googleapis.com` enabled (Phase 0 bootstrap)
- [x] In-cluster manifests via `kubectl` provider: SandboxTemplate, SandboxWarmPool (plus Namespace, KSA) — done in Phase 2. **Router moved to Phase 5** alongside the bridge (its first real consumer); see Lessons learned.

**Exit criterion:** `terraform apply` returns clean. Empty cluster, empty bucket, empty Firestore — all reachable.

---

### Phase 2 — Backend hello-world (1 day)

The pod runs, the warm pool fills. No LLM yet. Router deferred to Phase 5
where it has a real consumer (the bridge) — see Lessons learned.

- [x] `backend/Dockerfile` — python 3.12 + node 20 + chromium + playwright
- [x] `backend/server.py` — HTTP on :9000, `/execute` returns hard-coded SSE; `/healthz`
- [x] SandboxTemplate references the pushed image (`:phase2-hello`)
- [x] `make sandbox-smoke` — applies a throwaway SandboxClaim, waits for it
       to bind, uses **`kubectl exec`** to curl `/execute` from inside the
       bound pod (port-forward doesn't work on gVisor — see Lessons learned),
       asserts SSE contains a `"type":"result"` event

**Exit criterion:** `make sandbox-smoke` is green. **Met 2026-05-15.**

---

### Phase 3 — ADK agent + Claude Code tool (2 days)

The pod's HTTP server now hosts a real ADK agent that calls Claude Code.

- [x] `backend/adk_agent.py` — ADK `Agent` definition, `claude-opus-4-7`
       on Vertex global (bare `vertex_ai/<model>` LiteLLM string per
       Phase 3 Lesson learned; region/project via `VERTEXAI_*` env vars)
- [x] `backend/tools/claude_code_tool.py` — wraps `claude-agent-sdk`,
       spawns CLI subprocess against `/workspace`, parses typed events
       from `claude_agent_sdk.types` (drift caught — see Lessons learned)
- [x] `backend/tools/artifact_tool.py` — `emit_artifact(path)` ADK tool
       (Phase 5 will wire actual SSE `artifact` event emission; Phase 3
       validates path + queues for the future bridge translator)
- [x] Single-turn end-to-end: tested with "write a Python script that
       prints 'hello from phase 3' and run it; tell me the output" —
       orchestrator → `claude_code` (Write + Bash) → `emit_artifact` →
       final reply with the captured output.

**Exit criterion:** single-turn request returns streaming tool activity
plus a downloadable file. Vertex usage shows up in `cpe-slarbi-nvd-ant-demos`.
**Met 2026-05-15.**

---

### Phase 4 — Firestore sessions + memory (1.5 days)

Multi-turn works. Memory persists across pod restarts.

- [x] `backend/firestore_session.py` — `FirestoreSessionService` implementing
       ADK's `BaseSessionService` (named DB `cc-on-ge`, persists durable
       events on `append_event`, replays in `get_session`)
- [x] `backend/firestore_memory.py` — `FirestoreMemoryService` implementing
       `BaseMemoryService` (keyword-substring scoring with stopword filter,
       top-K=10 on matches, fallback to 5 most-recent on zero matches)
- [x] `backend/tools/memory_tools.py` — `remember(fact)` and `recall(query)`
       tools on the ADK agent (recall placed first in tool list to nudge
       turn-start usage per system prompt)
- [x] Firestore indexes deployed via Terraform (`memory_facts_by_user_time`;
       a session-events composite index was rejected as unnecessary by
       Firestore — single-field index auto-managed)
- [x] Multi-turn-across-restart smoke: Turn 1 prompt with durable fact →
       `tool_use remember` + 3 facts in Firestore. Pod 1 destroyed via
       claim deletion. Turn 2 (different pod, same context_id) → `tool_use
       recall` + response mentions "Schneider" AND "Google Cloud".

**Exit criterion:** multi-turn context survives pod restart.
**Met 2026-05-14.**

---

### Phase 5 — Bridge + A2A (2 days)

Cloud Run bridge speaks A2A. Real Gemini Enterprise turns work.

- [x] `bridge/Dockerfile`, `bridge/main.py` — `a2a-sdk` 0.2.13 server with
       custom CallContextBuilder so request headers reach the executor
- [x] `bridge/auth.py` — tokeninfo resolution + IAP-JWT-decode fallback +
       x-test-user header for smoke; degrades to "anon" on no identity
- [x] `bridge/sandbox.py` — get-or-create `SandboxClaim/cc-u-<user_key>`,
       wait for Ready, per-user asyncio.Lock; GKE auth via cluster
       endpoint + CA cert from env + GSA OAuth (refreshed per turn)
- [x] `bridge/translate.py` — backend SSE → A2A TaskUpdater events
       (working updates for text + tool_use + tool_result; complete on
       result; failed on error). Artifact emission is plumbed but inert
       — Phase 6 will add `emit_artifact` → `TaskArtifactUpdateEvent`
- [x] `/.well-known/agent-card.json` with `streaming: true`. Note: a2a-sdk
       0.2.13's `AgentCapabilities` has NO `artifacts` field — artifact
       support is signaled implicitly by emitting `TaskArtifactUpdateEvent`
- [x] Cloud Run service deployed: `cc-a2a-bridge` with Direct VPC egress
       (default/default), 1h timeout, min=1, max=10, no-allow-unauthenticated
       (IAM-gated via `run.invoker` grant to the Discovery Engine service
       agent — dormant until Phase 7 registration)
- [x] **sandbox-router Deployment + internal-LB Service** — upstream
       `kubernetes-sigs/agent-sandbox` mirrored into our AR (see commit
       c7510be). Internal LB at `10.128.15.223`; bridge reaches via Direct
       VPC egress without a public IP

**Exit criterion:** `make smoke` posts a real `message/send` and gets
`status.state == completed` back.
**Met 2026-05-14.** All three smoke assertions pass:
   1. Agent card returns 200 with `name: "Claude Code"`.
   2. `message/send` returns `status.state == "completed"` with a real
      Opus 4.7 response. Full ADK trace visible: `⏵ recall → ✓ recall →
      "Hello! How can I help you today?"`
   3. Second message/send with the same x-test-user reuses the claim
      (`cc-u-<user_key>` count stays at 1).

---

### Phase 6 — Isolation + persistence (1.5 days)

Security model holds. Workspace survives idle.

- [x] `bridge/downscope.py` — STS exchange, CEL CAB scoped to
       `users/<user_key>/`; per-user TTL cache (refresh 5 min before expiry)
- [x] Token passed to pod on every turn via `X-Workspace-Token` header;
       pod's GSA has zero bucket IAM (Phase 1 invariant verified by
       `make iso-test`'s pre-flight)
- [x] `backend/workspace.py` — park (walk + sha256 + diff-upload + prune
       via OLD manifest) and restore (read manifest + download per entry);
       sentinel `/workspace/.cc-restored` marks first-turn-on-fresh-claim
- [x] Background park on every turn end via `asyncio.create_task`; restore
       runs synchronously on first turn (sentinel-gated)
- [x] Idle sweeper: bridge deletes SandboxClaims whose `cc-a2a/last-use`
       annotation is >30 min old (cross-instance safe — annotation is the
       source of truth, any bridge replica can sweep any other's claims)
- [x] **Isolation negative test (`make iso-test`)**: with user_A's CAB
       token, cross-user object read → 403, cross-user list → 403, own
       prefix read → 200. All three pass. Pre-flight also asserts the
       backend GSA still has zero project-level storage.* and zero
       bucket-level IAM (Phase 1 invariant intact).
- [x] noexec /workspace via custom StorageClass `standard-rwo-noexec`
       (mountOptions: [noexec, nodev, nosuid]). Probe B verified Autopilot
       Warden blocks init-container `mount --bind` (SYS_ADMIN capability
       not permitted); StorageClass-mountOptions approach works under
       Autopilot and Probe B confirmed `chmod +x` then exec from
       /workspace fails (EACCES).

**Exit criterion:** `make iso-test` is green. `make smoke` proves park /
restore across pod death (file written in turn 1 is read back in turn 2
on a different pod).
**Met 2026-05-14.** All three exit criteria green:
1. `make iso-test` — three isolation assertions pass + Phase 1 invariant
   confirmed (backend SA has roles/aiplatform.user + roles/datastore.user
   only, no storage.*).
2. `make smoke` Assertion 4 (park/restore) — turn 1 writes
   `/workspace/park-test.txt` via claude_code, background park lands a
   manifest in GCS, SandboxClaim deleted (pod destroyed), turn 2 on a
   FRESH pod recovers the file and returns its contents verbatim.
3. Backend SA bucket IAM is still empty (verified inside iso-test).

---

### Phase 7 — Register + demo (1 day)

- [x] `scripts/register-agent.sh` — Discovery Engine REST registration,
       idempotent (LIST → PATCH-or-POST), SA-impersonation via
       cc-a2a-builder (user tokens org-blocked for Discovery Engine API),
       Probes A/B/C/D embedded as pre-flight
- [x] `scripts/unregister-agent.sh` — DELETE the agent (dry-run by default)
- [x] `scripts/register-agent-payload.json` — committed for audit; the
       exact body POSTed to the agents.create endpoint
- [x] `scripts/cuj-test.sh` — non-interactive sanity: agent listed +
       healthy state AND `assistants:streamAssist` returns 200 against
       the registered agent
- [x] `scripts/demo-runbook.md` — three CUJ prompts (PM/marketer/analyst)
       with sample CSVs and PRD text inlined
- [x] `Makefile` targets: register-agent, register-agent-apply,
       unregister-agent, cuj-test
- [x] **Agent appears in the GE Agent Gallery** (PTA Co-Innovation Team
       engine, displayName "Claude Code", state ENABLED, description
       ends with "v1 demo (single-user mode).") — confirmed visually
       2026-05-15
- [ ] Walk all three CUJs from a live GE thread, on video — interactive,
       driven manually after autonomous Phase 7 commits

**Exit criterion (autonomous part):** registration succeeds and the
agent is visible in the gallery; `make cuj-test` is green.
**Met 2026-05-15.** Agent resource:
`projects/436293010210/locations/global/collections/default_collection/engines/pta-co-innovation-team_1774556044286/assistants/default_assistant/agents/5479509043993124503`

The three CUJs themselves remain to be driven from a live GE thread by
the project owner, on video. Demo runbook is at
`scripts/demo-runbook.md`.

---

### Phase 10 — MIME-aware artifact routing (2026-05-15)

Fixes a Phase 8 regression that synthetic smoke tests missed. Phase 8
declared "downloadable chip working in GE UI" based on inspection of
the bridge's JSON-RPC response shape (`result.artifacts[].parts[].file
.bytes` was non-empty base64). Real-world use surfaced that GE applies a
**MIME allowlist at the UI rendering layer**, independent of A2A
protocol semantics: text/html, application/zip, and
application/octet-stream all show "Unsupported attachment" in the
working pane even though the bridge delivers the bytes correctly.

What landed:

- [x] **Empirical MIME probe** — `scripts/phase10/automated-mime-probe.sh`
       posts 9 separate `message/send` calls (one per MIME) to the
       bridge, captures full responses, and writes
       `scripts/phase10/mime-probe-results.md`. Probed in a real GE
       thread (Probe Y) 2026-05-15 to determine the verified allowlist.
- [x] **MIME-aware emit_artifact** — `backend/tools/artifact_tool.py`
       sniffs MIME (extension first, python-magic fallback) and routes
       on `ALLOWLIST_MIMES`:
         - Allowlisted → Path A (inline FilePart/FileWithBytes chip)
         - Not allowlisted → Path B (signed URL embedded in agent text)
       Logs the routing decision loudly without ever logging the URL.
- [x] **Full-file read mode** — `read_workspace_file(path, max_bytes)`
       accepts `max_bytes=None` for full content (200 KB hard ceiling
       with refusal message pointing at `get_download_url`); 4000-char
       default preserved for "peek" usage. System prompt teaches the
       agent to use `None` for explicit "show/open/display/view"
       requests, eliminating the `_*_part*.txt` temp-file pollution
       from pre-Phase-10 manual stitching.
- [x] **Scratchpad sweep on park** — `workspace.py` removes
       `_*_part*.{txt,html,json,md}` files before each manifest write
       so accidental scratchpad files don't propagate via park/restore.
- [x] **Tests** — `scripts/smoke.sh` adds Path A (text/csv) +
       Path B (text/html) routing assertions; `scripts/phase10/`
       contains the probe + raw responses + Probe-Y test brief.
       Probe Z (in-pod, verified separately) covers the read modes
       and sweep behavior.
- [x] **Probe Y real-GE confirmation (2026-05-15)** — three checks
       PASS: HTML form → clickable signed URL in reply, CSV → native
       chip with GE auto-preview, JSON → native chip with syntax
       highlighting.

**Phase 8 retro amendment (recorded honestly here since there's no
prior Phase 8 entry):** Phase 8 declared `text/html` chip rendering
working based on a synthetic smoke test that only inspected the
bridge's JSON-RPC response. The reality was THREE rejected MIMEs
(text/html + application/zip + application/octet-stream), not one,
and the rejection was at the UI layer downstream of the bridge.
Phase 10 corrects this. Lesson written below.

**Exit criteria (all met):**
- `make smoke` green including the new Phase 10 routing assertions
  (text/html → signed URL, text/csv → chip).
- `make iso-test` green — Phase 1 invariant holds.
- Probe Y in a real GE thread: all three checks PASS.

**Met 2026-05-15.** Images: `cc-backend:phase10-r2` (Path A/B router,
libmagic, full-file read mode, sweep), `cc-a2a-bridge:phase8-r1`
(unchanged — signing endpoint from Phase 8 still authoritative).

---

## GE MIME allowlist (verified 2026-05-15)

Empirical Gemini Enterprise UI allowlist for artifact chip rendering,
verified through the Phase 10 Probe Y manual test in a live GE thread.
This is the canonical source of truth for `emit_artifact`'s routing
decision in `backend/tools/artifact_tool.py:ALLOWLIST_MIMES`.

| MIME type                 | UI behavior in PTA Co-Innovation Team       | Route |
| ------------------------- | ------------------------------------------- | ----- |
| `text/csv`                | Native chip + inline preview (Export-to-Sheets) | Path A |
| `text/plain`              | Native chip                                 | Path A |
| `application/json`        | Native chip + inline syntax highlighting    | Path A |
| `application/pdf`         | Native chip + inline PDF viewer             | Path A |
| `image/png`               | Native chip (inferred — universal in chat) | Path A |
| `image/jpeg`              | Native chip (inferred — universal in chat) | Path A |
| `text/html`               | "Unsupported attachment"                    | Path B |
| `application/zip`         | "Unsupported attachment"                    | Path B |
| `application/octet-stream`| "Unsupported attachment"                    | Path B |
| **anything else**         | unknown / unverified                        | **Path B by default** |

**Safe-default rule:** if a MIME is not on this list, route through
Path B. The cost of an unnecessary signed URL is a less-elegant UX
(no chip, just a link); the cost of a Path A miss is an
"Unsupported attachment" error message in front of the user.

**When to revisit:** any time GE rolls out new attachment renderers
(check the release notes for new chip types) or any time a user
reports an "Unsupported attachment" symptom on a MIME we currently
route via Path A. The probe in `scripts/phase10/automated-mime-probe.sh`
is re-runnable; refresh the table here when results change.

---

## Known deferrals (pre-GA upstream gaps)

Tracked workarounds for features that aren't natively available in our
pinned tooling. Each gets replaced with native syntax when upstream catches
up; the workaround code carries a matching forward-migration TODO.

### GKE Agent Sandbox addon — no Terraform field

- **Gap:** `hashicorp/google ~> 5.45` does not expose an
  `addons_config.agent_sandbox_config` (or equivalent) block on
  `google_container_cluster`. The Agent Sandbox feature is still Preview
  at GKE; provider support lags.
- **Workaround:** `infra/terraform/gke.tf` creates the Autopilot cluster
  without the addon, then a `null_resource` with `local-exec` invokes
  `gcloud beta container clusters update ... --enable-agent-sandbox`.
- **Apply-host requirement:** the `beta` gcloud component must be
  installed. Enforced by `scripts/check-env.sh`.
- **Migration:** when the provider lands a native field, replace the
  `null_resource` with the native block in `gke.tf` and delete the
  beta-component check from `check-env.sh`. Track terraform-provider-google
  releases.

---

## Lessons learned

Recorded gotchas from phase work. Append as we hit new ones.

### Phase 1 — gcloud SDK staleness silently breaks Preview features (2026-05-14)

- The `--enable-agent-sandbox` flag landed in gcloud beta **2026.05.08**.
  Older betas (notably 2026.01.02 from gcloud SDK 551.0.0) silently lack
  the flag — `gcloud beta container clusters update ... --enable-agent-sandbox`
  fails with "unrecognized arguments" rather than a clear "feature not
  available" message.
- **Mitigation:** `scripts/check-env.sh` now probes the flag explicitly via
  `gcloud beta container clusters update --help | grep -q -- '--enable-agent-sandbox'`
  before any Phase 1+ apply. Stale SDKs fail check-env with a clear fix
  direction (`gcloud components update`).
- **Principle:** when working with Preview/beta GKE features, keep gcloud
  SDK current. Don't assume an unrecognized flag is a config issue —
  verify the SDK version against the docs' minimum first.

### Phase 1 — Agent Sandbox CRD apiGroups are split (2026-05-14)

The `gke-agent-sandbox` skill documented `extensions.agents.x-k8s.io/v1alpha1`
for all 4 CRDs. Reality post-addon-install:

- `sandboxclaims.extensions.agents.x-k8s.io` — user-facing claim
- `sandboxtemplates.extensions.agents.x-k8s.io` — user-facing template
- `sandboxwarmpools.extensions.agents.x-k8s.io` — user-facing warm pool
- `sandboxes.agents.x-k8s.io` — **controller-managed, different apiGroup**

The skill's documented apiVersion is correct for resources we author
(`SandboxClaim`, `SandboxTemplate`, `SandboxWarmPool`). The `Sandbox`
resource is controller-created from a Claim, so we don't write it
directly. If anyone ever does, use `apiVersion: agents.x-k8s.io/v1alpha1`
(without the `extensions.` prefix).

### Phase 1 — Pre-existing `(default)` Firestore DB pushed us to a named DB (2026-05-14)

The project had an unrelated `(default)` Firestore database from
2026-03-02. First Phase 1 apply hit a 409 conflict. We pivoted to a named
**`cc-on-ge`** database — see `CLAUDE.md` locked-config and the
`firestore-sessions` skill. **The Python SDK silently defaults to
`(default)`** — backend code must always pass `database="cc-on-ge"` to
`firestore.AsyncClient`. Unit tests should assert the client's
`_database_string` ends with `/cc-on-ge`.

### Phase 2 — Sandbox CRD schema drifted from the skill (2026-05-15)

Pre-write verification via `kubectl explain <crd>.spec --recursive` caught
three field-name divergences between the skill's documented YAML and the
live CRDs after the Agent Sandbox addon installed:

1. **`SandboxTemplate.spec.template` → `spec.podTemplate`** (rename;
   `podTemplate` is `-required-`).
2. **`SandboxWarmPool.spec.templateRef` → `spec.sandboxTemplateRef`** —
   same rename on `SandboxClaim.spec`.
3. **`SandboxClaim.spec.warmPoolRef` was removed** — the controller now
   routes claims to any matching WarmPool by `sandboxTemplateRef` alone.
4. **Bonus:** `SandboxTemplate.spec.networkPolicy` is a new inline field
   that lets the template carry its own ingress/egress rules. Phase 2
   adopted this in `k8s.tf` instead of standalone `NetworkPolicy`
   resources for v1 — single source of truth, no drift.

**Mitigation (institutionalized):** every CRD-touching phase runs
`kubectl explain <crd>.spec --recursive` against the live cluster
*before* writing manifests. If the schema diverges from the skill, update
the skill first.

**Principle:** with Preview-grade CRDs, the live schema is the source of
truth, not the skill. The skill records intent; the cluster records
reality.

### Phase 2 — Router deferred to Phase 5 (2026-05-15)

Phase 2's exit criterion originally included "router proxies" but the GKE
Agent Sandbox addon does NOT pre-install a router — the
`gke-managed-agentsandbox` namespace stays empty post-install. Three
options: (A) find an upstream router image, (B) write our own minimal
proxy (~150 LOC + Dockerfile + RBAC + Service), (C) defer.

Chose (C). Rationale: the router has no real consumer until the Cloud Run
bridge ships in Phase 5; building one in Phase 2 means maintaining a third
image with no caller. `make sandbox-smoke` uses `kubectl port-forward`
directly to the bound Sandbox pod, which proves warm pool / claim binding
/ gVisor boot / `/execute` SSE — 4 of 5 Phase 2 exit-criterion proof
points. The 5th ("router proxies") moves to Phase 5 alongside the bridge.

**Principle:** don't build infrastructure ahead of its first consumer.
Premature plumbing fragments scope and grows maintenance surface.

### Phase 2 — gVisor pods break `kubectl port-forward` (2026-05-15)

`kubectl port-forward` to a gVisor (`runtimeClassName: gvisor`) pod fails
with `dial tcp4 127.0.0.1:9000: connect: connection refused` even when the
in-pod server is verifiably listening — `kubectl exec <pod> -- curl
localhost:9000` returns the expected response. The kubelet's port-forward
implementation enters the CNI netns and dials localhost there, but the
gVisor pod's application network lives in its own user-space sandbox (the
sentry), not in the host-visible netns.

**Mitigation:** `scripts/sandbox-smoke.sh` uses `kubectl exec` to curl
`localhost:9000` from inside the bound pod. This reaches gVisor's network
stack the same way the future Phase 5 router will (in-cluster traffic
through CNI → gVisor TAP).

**Implications:**
- Local debugging of a gVisor pod via port-forward is not an option. Use
  `kubectl exec` for ad-hoc probes; use the Phase 5 router for
  out-of-cluster access.
- Smoke tests for gVisor-running services must use `kubectl exec` or
  spawn a temporary in-cluster pod (`kubectl run --image=curlimages/curl`).

**Principle:** runtime classes can break standard tooling in non-obvious
ways. Verify operational tooling against the actual runtime class before
assuming standard kubectl behaviors work.

### Phase 3 — Probe pods can't carry heavy pip installs (2026-05-15)

Heavy pip installs inside live Sandbox pods are evicted by Autopilot
under memory pressure even at 16 GiB. Probes requiring big deps belong
in the Dockerfile build, not runtime pods. The Dockerfile is the right
layer for dependency verification.

**Context:** Phase 3 attempted pre-write probes inside a one-off probe
pod (`kubectl run` against `cc-backend:phase2-hello` + inline
`pip install google-adk litellm claude-agent-sdk anthropic[vertex]`).
Pip's dependency resolver for `google-adk + litellm` together exceeded
16 GiB. Probe 1 (anthropic[vertex], small) succeeded; probes 2 & 3
couldn't run because the pod went down after install. Cloud Build with
`E2_HIGHCPU_32` (32 GiB) handles the same install cleanly in a build
context — the layered RUN steps also enable per-package caching.

**Implication:** the "verify before code" probes from earlier phases
shift for Phase 3+. Dep-verification moves to the Dockerfile build
(import smoke + `which claude` diagnostics + per-package RUN layers);
runtime probes that need the SDK only run *after* the image is built
and a real Sandbox pod is rotated in.

### Phase 3 — `litellm` 1.84 model-string drift and `claude-agent-sdk` 0.1 typed events (2026-05-15)

Two skill-drift discoveries from post-deploy mini-probes:

1. **`litellm` `vertex_ai/<model>@<region>` syntax broken.** `litellm`
   1.84.0 parses `@global` as part of the model name and 404s the call
   against `us-central1`. Use bare `vertex_ai/claude-opus-4-7` and set
   `VERTEXAI_PROJECT` + `VERTEXAI_LOCATION` env vars in the
   SandboxTemplate. Skills updated: `adk-agent`, `vertex-claude`.
2. **`claude-agent-sdk` 0.1.x events are typed objects.** `receive_response()`
   yields instances of `AssistantMessage` / `UserMessage` /
   `SystemMessage` / `ResultMessage` (from `claude_agent_sdk.types`),
   NOT dicts. Content blocks are `ToolUseBlock` / `TextBlock` /
   `ToolResultBlock`. Iterate with `isinstance` checks, not dict-key
   lookups. Skill updated: `claude-agent-sdk`.

Both were caught by mini-probes A + B against the freshly-deployed Phase 3
image (would have been caught earlier if pre-write probe pods had worked
— see the heavy-pip-install lesson above).

### Phase 3 — `ThreadingHTTPServer` + `asyncio` + gVisor breaks `google.auth` metadata fetch (2026-05-15)

Under `runtimeClassName: gvisor`, `ThreadingHTTPServer` (spawning a worker
thread per request) combined with `asyncio.run(...)` inside that worker
caused intermittent `Temporary failure in name resolution` for
`metadata.google.internal` — even though:

- Pod-level DNS worked (`getent`, `curl`, `dig` from inside the pod all
  resolved `metadata.google.internal → 169.254.169.254`).
- A fresh Python process inside the same pod (`kubectl exec python3 -c
  "google.auth.default()"`) succeeded.
- The same ADK + Runner flow ran cleanly when invoked via `kubectl exec
  python3 /tmp/sim.py` (no HTTP server, asyncio on the main thread).

Symptom in production: `/healthz` always passed; `/execute` failed
randomly at LiteLLM → `google.auth.default()` → metadata server. Sometimes
the first call would succeed and a later refresh would hang (curl
timeout); sometimes the very first call would 5xx at DNS resolution.

**Fix in `backend/server.py`:**
- Switched `ThreadingHTTPServer` → `HTTPServer`, so request handlers
  run in the main thread.
- Pre-warmed `google.auth.default()` at module load to cache ADC during
  known-good startup.

After the fix (`cc-backend:phase3-hello-r3`), smoke went from 0/3
assertions to 3/3 on a single try.

**Principle:** under gVisor, `asyncio` + thread-pool blocking I/O via C
extensions (urllib3 socket calls) has subtle interactions that don't
appear under standard runtimes. Validate non-async-native servers
carefully against gVisor before assuming "it works locally → it works
in the sandbox." Prefer async-native HTTP frameworks (`aiohttp`,
`fastapi`/`uvicorn`, `hypercorn`) for Phase 5+ where concurrency
matters.

### Phase 4 — ADK `__init__.py` exports a curated subset of types (2026-05-14)

`google-adk` 1.33's `google.adk.sessions/__init__.py` and
`google.adk.memory/__init__.py` re-export only a handful of types
(`BaseSessionService`, `Session`, `BaseMemoryService`). Other public
types we need (`ListSessionsResponse`, `GetSessionConfig`, `MemoryEntry`,
`SearchMemoryResponse`) live in the per-implementation submodules
(`base_session_service.py`, `memory_entry.py`, `base_memory_service.py`).
Importing them from the top-level package fails with `ImportError`.

**Cost:** three rebuild cycles (r1 missing Dockerfile COPY, r2 wrong
`MemoryEntry` path, r3 wrong `ListSessionsResponse` path) before r4
booted clean.

**Fix in `backend/Dockerfile`:** added an exhaustive build-time import
smoke (`RUN python -c "from google.adk.sessions.base_session_service
import GetSessionConfig, ListSessionsResponse; from
google.adk.memory.memory_entry import MemoryEntry; ..."`) and a separate
app-level smoke (`from firestore_session import FirestoreSessionService;
...`) that imports the actual transitive graph of our code. Both run
before EXPOSE, so import-path drift fails the build instead of crashing
the pod at start time.

**Principle:** when uncertain whether a type is at the top of a package,
import it from the submodule where it's *defined*, not the
`__init__.py`. And: extend the Dockerfile's import smoke to cover the
specific symbols the application uses, not just the package roots.

### Phase 4 — SandboxTemplate `networkPolicy` with only `ingress:` denies ALL egress (2026-05-14)

The Agent Sandbox controller renders the `SandboxTemplate.spec.networkPolicy`
block into a real Kubernetes `NetworkPolicy` on each claimed pod. If you
list only `ingress:` rules, the controller still sets
`policyTypes: [Ingress, Egress]` — and with **no `egress:` rules at all**,
NetworkPolicy semantics flip that to "deny ALL egress." Net result:
claimed pods could not reach the GCE metadata server, kube-dns, Vertex,
or Firestore. Warm (unclaimed) pods worked because the policy isn't
applied until the claim binds.

**Symptom progression** that obscured the root cause:
- LiteLLM mid-turn: `Failed to retrieve http://metadata.google.internal/...
  Temporary failure in name resolution` (we thought it was the Phase 3
  gVisor DNS flake again).
- After we pointed `GCE_METADATA_HOST` at the link-local IP
  `169.254.169.254`: `Connection to 169.254.169.254 timed out` (we
  thought it was gVisor link-local routing).
- A standalone probe inside an unclaimed warm pod returned the SA
  metadata in milliseconds — finally proving connectivity was fine on
  un-claimed pods and broken only after claim binding.

**Fix in `infra/terraform/k8s.tf`:** added `egress: - {}` (one rule with
no `to:`/`ports:` = allow all) to the SandboxTemplate's `networkPolicy`.
The v1 isolation goal is delivered by gVisor + Workload Identity +
downscoped STS tokens (Phase 6); network-level egress lockdown is
explicitly out of scope for v1 (see CLAUDE.md "Out of scope" list).

**Principle:** if you set ANY ingress rules on an Agent Sandbox
`networkPolicy`, you MUST also set explicit egress rules — empty egress
is not the same as "no egress restriction." Otherwise the rendered
NetworkPolicy is `[Ingress, Egress]` with deny-all egress.

### Phase 4 — Long-held `kubectl exec` SPDY tunnel drops on multi-min streams (2026-05-14)

`kubectl exec pod -- curl --max-time 600 ...` against the in-pod
`/execute` endpoint reliably died around the 4-minute mark with
`error from server: read: connection reset by peer` — even though the
SSE stream was actively flowing data. The apiserver / GKE tunnel tears
down the SPDY pipe on long-lived streams in a way curl can't recover
from.

**Fix in `scripts/sandbox-smoke.sh`:** rewrote `post_execute` to drive
the curl from a detached pod-side script (`nohup bash /tmp/smoke-runner
.sh >/dev/null 2>&1 < /dev/null &`) writing the response to
`/tmp/exec-out.txt`, then poll a marker file `/tmp/exec-done` from the
test harness. Each kubectl call is now short (~1s); no long-lived
tunnel to break.

**Principle:** for any in-cluster smoke that may run >1 min against an
agent-style endpoint, never rely on a held-open `kubectl exec`. Detach
the workload, poll a marker file.

### Phase 4 — LiteLLM default request timeout is 60s (2026-05-14)

`LiteLlm(model="vertex_ai/claude-opus-4-7")` inherits LiteLLM's default
`request_timeout=60`. Multi-tool turns (recall → think → remember×N →
final) regularly take longer than that even on the happy path, and
transient Vertex gRPC blips (`tcp handshaker shutdown`) eat the
remaining budget on retries.

**Fix in `backend/adk_agent.py`:** `LiteLlm(model=..., timeout=300,
num_retries=2)`. 5 min per individual completion call + 2 retries is
ample for multi-tool turns and survives the rare Vertex blip without
surfacing it.

### Phase 4 — `python3 -` over `kubectl exec` without `-i` silently no-ops (2026-05-14)

`kubectl exec pod -- python3 - <<'PY' ... PY` (without the `-i` flag)
sends no stdin to the container; `python3 -` reads EOF immediately and
exits 0 with no output. The test harness saw "FAIL Firestore shows zero
facts" not because writes failed, but because the inspection script
never ran. Pairs with the unsurprising-but-easy-to-miss bug that
`/tmp/inspect.py` shadows Python's stdlib `inspect` module via the
current working directory's `sys.path[0]` — a file named anything that
collides with stdlib (`inspect`, `tokenize`, `re`, ...) under `/tmp`
will break `import asyncio` (which transitively imports `inspect`).

**Fix in `scripts/sandbox-smoke.sh`:** `inspect_firestore_facts` now
uses `kubectl exec -i ... -- bash -c 'cd /workspace && python3 -'` to
both forward stdin and avoid the `/tmp` cwd-shadowing hazard.

### Phase 6 — Phase 5 latent auth bug surfaced (anon-hash collision) (2026-05-14)

Phase 5's `HeaderAwareBuilder` was defined inside `_call_context_builder()`
but never wired into `DefaultRequestHandler` or `A2AStarletteApplication`.
The result: `_headers_from_context()` always returned `{}`, every request
fell back to `auth.py`'s `"anon"` branch, and every user hashed to the
same `user_key`:

```
sha256("anon")[:16] == "5430eeed859cad61"
```

The Phase 5 smoke (single x-test-user) didn't catch it because all turns
that smoke ran shared one anon user anyway — the second-turn-reuses-claim
assertion was satisfied by collapsing to the same user_key, not by the
intended path. The Phase 6 iso-test caught it by detecting that both
`user_A` and `user_B` resolved to the same anon hash in backend logs.

**Fix:** delete the custom builder entirely. The default
`DefaultCallContextBuilder` in a2a-sdk 0.2.13 ALREADY stashes
`dict(request.headers)` under `ServerCallContext.state["headers"]`, and
the `SimpleRequestContextBuilder` carries that through as
`RequestContext.call_context`. So `_headers_from_context()` becomes:

```python
return context.call_context.state.get("headers") or {}
```

**Principle:** when an SDK has a fully-functional default that solves
your problem, don't subclass it. And: write the isolation negative test
EARLY — Phase 5's smoke proved JSON-RPC plumbing worked but a security
defect rode along beneath it for one whole phase. The iso-test caught it
within ~3 minutes of running.

### Phase 6 — Autopilot Warden blocks SYS_ADMIN; use StorageClass mountOptions for noexec (2026-05-14)

Initial Phase 6 design (from the gke-agent-sandbox skill) was an init
container running `mount --bind /workspace /workspace -o remount,bind,noexec`.
Autopilot's `autogke-default-linux-capabilities` admission webhook
rejects pods that add `SYS_ADMIN` (allowed caps are a curated list:
AUDIT_WRITE, CHOWN, DAC_OVERRIDE, FOWNER, FSETID, KILL, MKNOD,
NET_BIND_SERVICE, NET_RAW, SETFCAP, SETGID, SETPCAP, SETUID, SYS_CHROOT,
SYS_PTRACE).

**Fix:** create a dedicated StorageClass with `mountOptions: [noexec,
nodev, nosuid]` and switch the SandboxTemplate's `volumeClaimTemplate`
to it. `pd.csi.storage.gke.io` honors the mountOptions when the
ephemeral PVC binds. Verified in Probe B: `chmod +x /workspace/foo &&
/workspace/foo` fails with EACCES even though `mount` output doesn't
list the option (a containerd quirk; enforcement is real).

### Phase 6 — CAB-scoped tokens can't `list` the bucket (2026-05-14)

The `google.auth.downscoped.AccessBoundaryRule` grants object-level
permissions only. With `availability_condition` of
`resource.name.startsWith('projects/_/buckets/<b>/objects/users/<k>/')`,
the resulting token is allowed to GET/PUT/DELETE objects under that
prefix, but `storage.objects.list` at the bucket root (which is what
`list_blobs(..., prefix=...)` actually calls) gets a 403 — even when
listing the OWN prefix.

This is by design and load-bearing: the iso-test's "list other user's
prefix → 403" assertion passes BECAUSE list isn't grantable through the
CAB. It's also why `backend/workspace.py:restore()` reads
`_manifest.json` and downloads each listed file rather than calling
`list_blobs()`. There's no workaround at the CAB level; if we ever
needed list-own-prefix from the pod, we'd need a second token-type
(e.g., direct STS exchange with a different rule, or a pre-listed
manifest).

### Phase 6 — `google-cloud-storage` Python client needs `pyOpenSSL` for mTLS (2026-05-14)

The default Phase 5+6 probe venv didn't pull `pyOpenSSL`; first
`storage.Client.upload_from_string` call raised
`google.auth.exceptions.MutualTLSChannelError: No module named 'OpenSSL'`.

**Fix in `scripts/iso-test.sh`:** the venv setup hint installs
`pyopenssl` alongside `google-auth` and `google-cloud-storage`.
**Production images** (`backend/Dockerfile`) pick this up transitively
through `google-cloud-storage`'s default install — no Dockerfile change
was needed; the issue is workstation-venv-only.

### Phase 5 — gcloud pip mirror hides PyPI packages (2026-05-14)

The workstation's pip was preconfigured against
`us-python.pkg.dev/<your-artifact-registry-project>/...` (an internal Google
mirror). Pip flatly reported "No matching distribution found for
a2a-sdk" even though `https://pypi.org/simple/a2a-sdk/` returned a
valid listing.

**Fix in probe scripts:** explicit `--index-url https://pypi.org/simple/`
for any external package. In containerized environments (Dockerfile) the
default `pypi.org` index is used regardless, so this only bites
workstation venvs. Documented for future probe work — if `pip install
<known-good-package>` fails with "no matching distribution," check
`pip config get global.index-url`.

### Phase 5 — a2a-sdk 0.2.13 AgentCapabilities has no `artifacts` field (2026-05-14)

The original `a2a-protocol` skill listed `"artifacts": true` as part of
the AgentCard's `capabilities` block. In a2a-sdk 0.2.13 (the current
stable; 0.2.14 was yanked upstream for gRPC requirement issues),
`AgentCapabilities` exposes only `streaming`, `pushNotifications`,
`stateTransitionHistory`, and `extensions`. Artifact support is signaled
**implicitly** by emitting `TaskArtifactUpdateEvent`s — there's no flag.

**Fix in `bridge/agent_card.py`:** drop the `artifacts` field from the
capabilities object. Skill update covered separately in the X-Sandbox-ID
commit (41f57bb).

### Phase 5 — Sandbox-router upstream image lives at `k8s-staging-images/agent-sandbox` (2026-05-14)

See commit 41f57bb ("Update gke-agent-sandbox skill for upstream router
image and X-Sandbox-ID header"). The original skill described building
our own router; in practice the SIG-maintained image is production-ready,
header is `X-Sandbox-ID` (not `X-Sandbox-Name`), and the mirror-into-AR
pattern keeps production manifests off the staging registry.

### Phase 5 — `SimpleRequestContextBuilder` drops HTTP headers (2026-05-14)

a2a-sdk 0.2.13's default `SimpleRequestContextBuilder` builds a
`RequestContext` from the JSON-RPC payload only — inbound HTTP headers
(Authorization, x-goog-iap-jwt-assertion, x-test-user) are NOT carried
through to the executor. Without them, `bridge/auth.py` couldn't resolve
end-user identity from anything except the A2A payload itself.

**Fix in `bridge/main.py`:** subclass `SimpleRequestContextBuilder`, stamp
`request_headers = dict(http_request.headers)` onto the context after
`super().build(...)`. Then `_headers_from_context()` in the executor
reads them.

```python
class HeaderAwareBuilder(SimpleRequestContextBuilder):
    async def build(self, *args, **kwargs):
        ctx = await super().build(*args, **kwargs)
        http_req = kwargs.get("http_request")
        if http_req is not None:
            ctx.request_headers = dict(http_req.headers)
        return ctx
```

**Principle:** when an SDK builds a context from one transport surface
but you need data from another, subclass the builder and stamp it in.

### Phase 5 — Cloud Run → GKE auth needs explicit Configuration construction (2026-05-14)

The kubernetes Python client has `config.load_incluster_config()` (kubelet
service account) and `config.load_kube_config()` (~/.kube/config file).
Neither works on Cloud Run: it's not in the cluster, and there's no
kubeconfig file in the bridge image.

**Fix in `bridge/sandbox.py`:** build the Kubernetes `Configuration`
object manually from `GKE_CLUSTER_ENDPOINT` + `GKE_CLUSTER_CA` env vars
(injected by Cloud Run from `google_container_cluster.cc_sandbox` outputs)
plus a fresh OAuth2 token from `google.auth.default()` (the bridge GSA,
which has `roles/container.developer`). Rebuild the client per turn —
GSA access tokens are short-lived and lock-coupled to the per-user
asyncio mutex anyway.

```python
endpoint = os.environ["GKE_CLUSTER_ENDPOINT"]
ca_b64 = os.environ["GKE_CLUSTER_CA"]
creds, _ = google.auth.default(
    scopes=["https://www.googleapis.com/auth/cloud-platform"],
)
creds.refresh(GoogleAuthRequest())
cfg = client.Configuration()
cfg.host = f"https://{endpoint}"
cfg.ssl_ca_cert = "/tmp/gke-cluster-ca.crt"  # base64-decoded from env
cfg.api_key = {"authorization": f"Bearer {creds.token}"}
return client.ApiClient(cfg)
```

### Phase 5 — Standalone NetworkPolicy needs explicit policyTypes (2026-05-14)

Same trap as the Phase 4 SandboxTemplate inline rule: if a `NetworkPolicy`
sets only `ingress:` and omits `policyTypes:`, K8s defaults `policyTypes`
to `[Ingress]` only (which is what we want for ingress-only rules).
**But** the agent-sandbox controller, when it renders the SandboxTemplate
inline rule, defaults to `[Ingress, Egress]`. Standalone `NetworkPolicy`
resources do NOT get this treatment — they obey the standard K8s default.

So for the standalone `allow-router-to-cc-backend` rule, setting
`policyTypes: [Ingress]` explicitly is belt-and-suspenders correct: the
default would also be `[Ingress]`, but documenting it inline makes the
"don't auto-promote to deny-all-egress" intent unambiguous in code review.

### Phase 5 — `gcloud artifacts docker copy` not in current SDK (2026-05-14)

Per docs, `gcloud artifacts docker images copy <src> <dst>` cross-copies
between registries. In the SDK version on the workstation, this
subcommand doesn't exist and gcloud suggests `tags add`/`tags list`
instead. `tags add` doesn't work across registries.

**Fix in `scripts/mirror-sandbox-router.sh`:** use Cloud Build with the
`gcr.io/go-containerregistry/crane:latest` image to run `crane copy
<src> <dst>`. Takes ~9 seconds end-to-end, idempotent (crane is a no-op
if the digest already exists in dst), and doesn't require any local
Docker installation.

### Phase 4 — Firestore composite index rejected as "unnecessary" (2026-05-14)

A composite index on `(timestamp ASC, __name__ ASC)` for the
`session_events_by_time` query was rejected by Firestore with "this
index is not necessary, configure using single field index controls."
Single-field indexes are auto-managed; you don't (and can't) create them
through `google_firestore_index`. Removed from `firestore.tf` with a
comment explaining the rejection. The `memory_facts_by_user_time`
composite (`user_key ASC + created_at DESC`) created cleanly in ~6 min.

**Principle:** before adding a `google_firestore_index` resource for a
query, check whether the query truly needs a composite index or whether
single-field auto-indexing already covers it.

### Idempotent IAM grants accumulate without exit cleanup (2026-05-15)

`smoke.sh` and `iso-test.sh` were granting their caller `roles/run.invoker`
on `cc-a2a-bridge` via `gcloud run services add-iam-policy-binding`
at the start of each run, with no corresponding revoke. The grant
is idempotent, so subsequent runs don't error — but the binding
persists. Across Phases 5-8, this accumulated a `user:slarbi@google.com`
binding on a production-shape Cloud Run service that nobody noticed
until the Phase 9 IAM eyeball check explicitly counted bindings on
`roles/run.invoker` and saw three members instead of two.

It's not a vulnerability — `user:slarbi@google.com` is the
project owner already — but it widens the documented trust boundary
for the agent's runtime path, and the same pattern with a
less-trusted developer account would be a real exposure.

**Fix (committed separately as `IAM hygiene: grant-revoke pattern for
smoke scripts`):**

1. Both scripts now use a `revoke_invoker()` helper and a
   `trap revoke_invoker EXIT INT TERM` so the binding is removed
   on every exit path — success, assertion failure, Ctrl-C,
   external SIGTERM.
2. Belt-and-suspenders: BEFORE the trap is set, the script
   pre-emptively revokes any stale binding for the current user
   (handles the case where a previous run crashed before its
   trap fired — e.g., `kill -9`).
3. `--condition=None` on the `remove-iam-policy-binding` call so
   we never stomp on a binding that someone else might add with a
   CEL condition.

**Generalized principle for the project:** any dev-convenience IAM
grant must be paired with exit-time revocation, not added once and
forgotten. Audit any `add-iam-policy-binding` in scripts that
doesn't have a matching `remove` on the same exit path before
shipping. The convention going forward: a grant in a script
implies a trap-installed revoke before the next operation that
might fail.

### Synthetic smoke tests cannot validate UI-rendering claims (2026-05-15)

Phase 8 declared `text/html` artifact chip rendering working in the GE
UI based purely on inspecting the bridge's JSON-RPC response shape —
`result.artifacts[].parts[].file.bytes` was non-empty base64 with the
right `mimeType`, so the smoke marked it PASS. Real-world use in a GE
thread surfaced `Unsupported attachment` for HTML. Worse, this was
not just an HTML issue: Phase 10's empirical probe found GE rejects
**three** MIMEs (text/html, application/zip, application/octet-stream),
not one. The smoke's "PASS" claim was wrong about both the symptom
AND its scope.

**Root cause:** the bridge's response shape is not the same as what
GE renders. The A2A protocol layer is correct; GE imposes its own
MIME allowlist at the UI rendering layer, downstream of every check
the smoke had. A test that only inspects the protocol layer cannot
catch a UI-layer regression.

**Fix in Phase 10:**
- `scripts/phase10/automated-mime-probe.sh` runs 9 separate
  message/send calls and captures the bridge-side response for each,
  but the SOURCE OF TRUTH for routing is a real GE thread (Probe Y).
- `make smoke` gained Phase 10 Assertion 5 (text/html → signed URL
  pattern in response, NO inline text/html chip) and Assertion 6
  (text/csv → chip preserved, regression-safe). These cover the
  bridge-side correctness; the UI-layer claim still needs the human
  eye.

**Generalized principle:** any claim about user-visible behavior
requires a real UI test, not just an API response check. When the
work involves a UI rendering surface owned by an upstream system
(GE, Gmail, Slack, etc.), the acceptance test for "looks right to
the user" cannot be a JSON shape assertion. Probe Y manual checks
should be cheap to run (one screenshot, three prompts) and triggered
any time the user-visible artifact shape changes.

---

## Known limitations

Things the v1 demo ships WITHOUT, with explicit caveats. Each entry
includes consequence, fix path, and tracking tag.

### v1 single-user demo (no end-user identity in GE-routed calls) — 2026-05-15

v1 GE registration omits authorizationConfig. Consequence: all GE-routed
calls reach the bridge with no end-user identity and resolve to
user_key=anon-<hash>. This means every Gemini Enterprise user shares one
workspace, one Firestore session, one memory store. The per-user
isolation proven by Phase 6's negative test applies only to direct bridge
calls (Authorization header present), NOT to GE-routed calls.
Fix: create a Discovery Engine Authorization resource, reference it in
authorizationConfig.agentAuthorization, and configure the OAuth consent
screen. Estimated effort: 30-60 min + manual consent screen step.
Tracked as v1.1 work.

**Surfaces of the disclosure:**
- Agent description in the GE Gallery includes "v1 demo (single-user
  mode)." so anyone who finds the agent reads it before invoking.
- `bridge/auth.py` logs `WARNING: GE-routed call resolved to anon
  user_key — per-user isolation NOT active. See PROJECT_PLAN.md
  'Known limitations'.` on every GE turn.

---

## Working agreement with Claude Code

1. Re-read `CLAUDE.md` at the start of every session.
2. Re-read this file at the start of every phase.
3. Before changing any file: state the edit plan, get sign-off.
4. After completing any phase: check off the boxes, commit, run the
   exit-criterion test before declaring done.
5. If a phase needs to slip, update this plan rather than silently
   skipping criteria.
