# Claude Code on Gemini Enterprise — Demo Runbook

Three CUJs to drive live in the Agent Gallery, on video. Each prompt is
ready to paste verbatim. Sample CSVs and PRD text are inlined so the
demo doesn't depend on connector ingestion (deferred to v1.1).

**Pre-flight (do once before recording):**
- Open the **PTA Co-Innovation Team** app at Gemini Enterprise.
- Open **Agent Gallery** → select **Claude Code** (description ends with
  *"v1 demo (single-user mode)."*).
- Open a fresh thread.
- Confirm `scripts/smoke.sh` still passes (`make smoke`) right before
  recording so a regression doesn't bite mid-demo.

**Watch in the working pane** for streaming tool activity lines like
`⏵ claude_code(prompt="…")` then `✓ claude_code → ✓ wrote /workspace/x.html`,
followed by a downloadable file chip in the result pane.

---

## CUJ 1 — PM: spec → clickable prototype

**Setup:** none — paste both prompts in the same thread.

**Prompt 1:**
> I have a PRD for a customer signup form. Here it is in plain text:
>
> ```
> # PRD: Customer signup form
>
> Audience: SMB founders signing up for a 14-day trial.
> Fields: email, company name, team size (1-5, 6-25, 26-100, 101+),
>   "what brought you here?" (multi-select: blog, friend, search,
>   conference, other).
> CTA: "Start free trial" (primary blue), "Already have an account?
>   Sign in" (secondary text link).
> States: empty, loading, success ("Check your inbox — we sent a
>   verification link"), error ("Couldn't sign you up — please try
>   again or contact support").
> Polish: subtle entrance animation on field focus; mobile-responsive
>   (single column under 640px); accessible (aria-labels, keyboard nav).
> ```
>
> Build a working HTML prototype from this PRD. Make it self-contained —
> all CSS inline, no external frameworks, opens in any browser.

**Expected (Prompt 1):**
- Working-pane: `⏵ claude_code(prompt=…)`, file writes under `/workspace/`,
  final reply with a download chip linking to the HTML file.
- Open the artifact in a new tab — the form should render and the
  state transitions should be triggerable.

**Prompt 2 (same thread):**
> Make the empty state friendlier (warmer copy, less corporate),
> and add a retry button to the error state that re-submits the form.

**Expected (Prompt 2):**
- The agent edits the SAME `/workspace/...html` file (per `claude_code`
  Read → Edit → Write). Workspace persistence (Phase 6) makes this work.
- New artifact reflects only the diffed edits.

---

## CUJ 2 — Growth marketer: CSV → ad copy

**Prompt:**
> Below is last month's ad performance. Find the bottom-quartile
> headlines by CTR (i.e., the worst-performing 25%) and write 50
> new headline variants for them, each under 30 characters. Output as
> a downloadable CSV with columns `original_headline`, `original_ctr`,
> `new_variant`.
>
> ```
> headline,impressions,clicks,ctr
> "Try our shiny new dashboard",12450,89,0.0072
> "Stop guessing. Start knowing.",9870,341,0.0346
> "Built for teams that ship fast",15230,98,0.0064
> "Your data, finally legible",8210,287,0.0349
> "We do the boring parts so you don't have to",17890,42,0.0023
> "From spreadsheet to insight in 30 seconds",11200,256,0.0228
> "Make better decisions, faster",13500,201,0.0149
> "Onboarding in under 5 minutes",10100,178,0.0176
> "Ship the dashboard your CFO will actually open",6700,89,0.0133
> "Dashboards that don't lie",14200,395,0.0278
> "Built by people who hate dashboards",9500,71,0.0075
> "The honest analytics tool",11800,310,0.0263
> "Skip the SQL",8400,389,0.0463
> "Less time in spreadsheets",13900,178,0.0128
> "Trial expires never (no, really)",10250,103,0.0100
> "For PMs who want to ship",12700,254,0.0200
> "Stop debugging your dashboards",9100,52,0.0057
> "The dashboard that ships itself",11000,67,0.0061
> "We measure what matters",14500,322,0.0222
> "Dashboards in plain English",10800,398,0.0369
> ```

**Expected:**
- Working pane: tool calls showing CSV read, computation of CTR
  quartiles, header generation, CSV write.
- Artifact: a CSV file with ~50 new short variants paired to the
  bottom-quartile originals.

---

## CUJ 3 — Analyst: messy CSV → interactive dashboard

**Prompt:**
> Below is our last 6 months of MRR by customer segment. Build me a
> self-contained interactive HTML dashboard with: a line chart of MRR
> by segment, a date-range slider that filters the view, totals by
> segment that update when the slider moves, and a CSV-export button.
> Single HTML file, opens in any browser, no external CDN.
>
> ```
> month,segment,mrr
> 2025-12,enterprise,184500
> 2025-12,mid_market,92300
> 2025-12,smb,41800
> 2025-12,starter,12400
> 2026-01,enterprise,191200
> 2026-01,mid_market,97500
> 2026-01,smb,44600
> 2026-01,starter,11800
> 2026-02,enterprise,198700
> 2026-02,mid_market,103200
> 2026-02,smb,46900
> 2026-02,starter,12900
> 2026-03,enterprise,212400
> 2026-03,mid_market,108900
> 2026-03,smb,50100
> 2026-03,starter,13700
> 2026-04,enterprise,225800
> 2026-04,mid_market,114200
> 2026-04,smb,52800
> 2026-04,starter,14100
> 2026-05,enterprise,238100
> 2026-05,mid_market,119500
> 2026-05,smb,55400
> 2026-05,starter,14600
> ```

**Expected:**
- Multi-tool turn visible in the working pane: Read of the parsed CSV,
  Write of the HTML, possibly a Bash test to verify the file is valid.
- Artifact: a single `.html` file. Open it in a new browser tab —
  slider should work offline (no network calls).

---

## After the demo

- Stop recording.
- (Optional) `make unregister-agent` to take the agent off the
  Gallery while you iterate. Re-register with `make register-agent-apply`
  when ready to show again.
- File any anomalies / unexpected behaviors as Phase 7+ items in
  PROJECT_PLAN.md.
