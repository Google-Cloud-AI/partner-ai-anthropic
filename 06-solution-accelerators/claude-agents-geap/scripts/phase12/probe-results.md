# Phase 12 Step 1 — A2UI v0.8 probe results

Manual GE-thread verification of A2UI v0.8 rendering through
`cc-a2a-bridge` on the PTA Co-Innovation Team engine.

## Verdict: **PASS**

Probe agent: `projects/436293010210/locations/global/collections/default_collection/engines/pta-co-innovation-team_1774556044286/assistants/default_assistant/agents/4800737431245759808`
(deleted immediately after capture; total lifetime ~5 minutes,
inside the 15-minute discipline).

Bridge revision under test: `cc-a2a-bridge-00008-flh` on
`cc-a2a-bridge:phase12-r1`, env `A2UI_PROBE_ENABLED=true`.

## What rendered

A native Gemini Enterprise card surface, drawn by GE's A2UI v0.8
renderer using its dark-theme design system:

- Title text "Phase 12 A2UI v0.8 probe" (h2 usageHint applied).
- Body text describing the success condition.
- Styled blue **OK** button as a native UI control (NOT a code
  block, NOT raw JSON, NOT an "Unsupported attachment" chip).

Two screenshots captured by the project owner; this file records the
findings.

## Bonus finding — action round-trip works

Clicking the **OK** button delivered the configured action back to
the agent as a new turn. The bridge's executor received it as a
follow-up `message/send` whose parts included a DataPart with
`data = {"userAction": {"name": "a2ui_probe_ack", "context": {...}}}`
(per the upstream `a2ui.a2a` parts convention). The agent showed
"User action triggered." in the working pane.

Per probe design this action is inert — `a2ui_probe_ack` has no
handler — but **the delivery path is verified end-to-end**:

```
GE UI button click
  → GE issues follow-up A2A message/send
    → cc-a2a-bridge executor receives DataPart(userAction)
      → (would dispatch to a handler if one were registered)
```

This is the same back-channel the upstream sample's
`ContactAgentExecutor` uses for `view_profile`, `send_email`,
`send_message`, etc. Phase 12 full integration will register
real action handlers on this same plumbing.

## Spec-vs-sample resolution

A real contradiction surfaced during payload design:

- **v0.8 spec prose** says components must exist before
  `beginRendering` references the root. Emission order:
  `surfaceUpdate` THEN `beginRendering`.
- **Upstream `examples/0.8/follow_success.json`** reverses these:
  `beginRendering` first, `surfaceUpdate` second.

We picked the spec, with an explicit docstring noting the
disagreement.

**Result: the spec ordering rendered correctly on first try.**

**Recommendation for future A2UI work in this project:** when the
v0.8 spec prose and the upstream sample disagree on
ordering/structure, follow the spec. Document the disagreement
inline so the next reader doesn't re-litigate it. The upstream
`follow_success.json` is misleading on this one point.

## Schema-correctness notes (for the record)

Before deploying, the probe payload was reviewed against the
official catalog (`standard_catalog_definition.json`) and two
violations were caught at planning time, not at GE:

- `Button` was using `label` (inline string) → catalog requires
  `child` (Text-component ID) and `additionalProperties: false`.
  Fixed by adding a `submit_label` Text and pointing the Button's
  `child` at it.
- `Button` was missing the required `action` object. Fixed by
  adding `action: {name: "a2ui_probe_ack"}`. The bonus finding
  above is downstream of this fix — without it, there'd be no
  action to round-trip.

The other components (Card, Column, Text) passed catalog review
unchanged.

These pre-deploy catches saved a remediation cycle. Pattern worth
keeping: when a sample disagrees with the formal schema, validate
against the schema before testing in the live UI.

## What stays in place

- `cc-a2a-bridge:phase12-r1` image — kept; the probe code is the
  scaffolding Phase 12 full integration will build on.
- `A2UI_PROBE_ENABLED=true` on Cloud Run — kept. Harmless without
  a registered probe agent (the trigger phrase has no caller from
  the production agent's gallery flow, and even if a stray
  `A2UI-PROBE` came through the production agent, GE would not
  render A2UI for a card that doesn't advertise the extension).
- Probe code path (`_emit_a2ui_probe`, the constants, the
  executor branch) — kept; reusable for follow-up validation if
  needed.

## What was removed

- `Claude Code A2UI v0.8 PROBE` agent registration — DELETED at
  ~5 minutes after registration, well inside the 15-minute
  discipline. `agents.list` confirmed: probe is gone, production
  agent (`5479509043993124503`) untouched and ENABLED.

## Production-agent invariant

Verified post-teardown:

| Field                   | Value                                                       |
| ----------------------- | ----------------------------------------------------------- |
| Production agent ID     | `5479509043993124503`                                       |
| displayName             | `Claude Code`                                               |
| state                   | `ENABLED`                                                   |
| capabilities.extensions | (none — A2UI deliberately NOT advertised on production)     |

The production agent's behaviour is unchanged. Phase 10 routing
(MIME-aware Path A / Path B) continues to apply for production
traffic. A2UI is not yet a production capability.

## Recommendation

**Proceed to a fresh Phase 12 full-integration design conversation.**

The probe answered the question it set out to: *"Does A2UI v0.8
render end-to-end in this Gemini Enterprise tenant through our
existing bridge?"* — YES. Plus the bonus that **action round-trip
works**, which is the harder half of any integration.

Open design questions for Phase 12 full integration (NOT for this
file — for the next planning round):

- Which CUJs should produce A2UI surfaces vs. plain text replies?
  (CUJ 1's PRD-to-prototype is an obvious candidate; CUJ 2's
  CSV-to-ad-copy may not benefit.)
- How does the agent decide *when* to emit a surface? Tool-driven
  (the agent calls an `emit_surface` tool) or model-driven
  (system prompt asks for A2UI JSON between delimiters per the
  upstream sample's pattern)?
- How do we register A2UI capability on the production agent
  without breaking the Phase 10 MIME-routing invariants?
  (Probably: add the extension to the production agent card;
  declare `acceptsInlineCatalogs` only if we're prepared to
  ship our own catalog.)
- Catalog choice: stick with the standard catalog
  (`standard_catalog_definition.json`) which the probe verified
  is rendered, or define a project-specific catalog?
- Action handlers: what's the right pattern for routing
  `userAction.name` values into ADK tool calls or further
  surface emissions?

Those are the right questions for the next planning conversation.
This file is the final word on Step 1.

## HARD STOP

Phase 12 Step 1 complete. No code changes from here. Full
integration is a separate phase with its own design pass.
