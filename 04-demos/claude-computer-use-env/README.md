# Claude Computer-Use Environment (Tier 2)

The **real, sandboxed computer-use environment** — where `claude-opus-4-8` controls an **actual screen**. The model emits GUI actions (screenshot, click, type, key, scroll); a local agent loop **executes each action on a virtual display** and returns the resulting screenshot, so the model can see what happened and decide the next step.

This is the Tier-2 counterpart to the teaching notebook
`02-tutorials/claude-on-agent-platform/07-computer-use.ipynb`, which only demonstrates the tool definition and loop *shape*. Computer use needs a real display, so it runs here in an isolated container/VM rather than in a notebook.

> All Claude calls route through **Google Cloud's Agent Platform** via the `AnthropicVertex` path with **ADC** auth — **no first-party Anthropic API, no `ANTHROPIC_API_KEY`**. Model string is exactly `claude-opus-4-8`.

---

## The agent loop

```
  user goal
     │
     ▼
  model emits an action  (screenshot | click | type | key | scroll)
     │
     ▼
  execute the action on the virtual screen
     │
     ▼
  return a screenshot tool_result  (base64 PNG image block)
     │
     └──────────────► repeat until the model stops requesting actions
```

Each `tool_result` carries the new screen state as an image block:

```python
{"type": "tool_result", "tool_use_id": <id>,
 "content": [{"type": "image",
              "source": {"type": "base64", "media_type": "image/png", "data": <b64>}}]}
```

---

## Recommended approach: the official reference implementation

Rather than build the executor, virtual display, and UI from scratch, use Anthropic's
official **computer-use reference implementation** — the `computer-use-demo` Docker
container in the **anthropic-quickstarts** repo. It bundles:

- a **virtual display** (Xvfb) and a desktop environment,
- **example tool implementations** for `computer`, `bash`, and `text_editor`,
- an **agent loop** that executes actions and returns screenshots, and
- a **web UI** to give the model goals and watch it work.

Repo: <https://github.com/anthropics/anthropic-quickstarts>

The demo is the fastest correct path; you mainly need to point it at the Agent Platform.

---

## Routing through the Agent Platform (Vertex)

Configure the demo to use the Vertex provider instead of the first-party API. The
reference implementation reads its provider and credentials from environment
variables — set them roughly as below:

```bash
export API_PROVIDER=vertex
export CLOUD_ML_REGION=global
export ANTHROPIC_VERTEX_PROJECT_ID=<YOUR_PROJECT_ID>
# Authenticate with Application Default Credentials (no API key):
gcloud auth application-default login
```

- Use model **`claude-opus-4-8`**.
- Mount or forward your **ADC credentials** into the container so the Vertex client
  can authenticate (e.g. mount `~/.config/gcloud` read-only, or use the VM's
  attached service account).

> ⚠️ **Verify the exact env-var names and flags in the reference repo.** Provider
> flags, variable names, and the supported tool/beta versions change over time — the
> anthropic-quickstarts repo and the
> [computer-use docs](https://docs.claude.com/en/docs/agents-and-tools/tool-use/computer-use-tool)
> are the source of truth. Also confirm `claude-opus-4-8` availability and the current
> computer-use tool/beta version on the **Opus 4.8 Model Garden card**.

---

## Run it on an isolated GCE VM (not your laptop)

Run the container on a **dedicated, isolated GCE VM** — never on a machine with access
to personal data, credentials, or production systems.

1. Create a throwaway GCE VM (its own project/subnet where practical) with a service
   account scoped only to what the demo needs.
2. Install Docker and pull/run the `computer-use-demo` container on the VM.
3. Provide ADC (mounted gcloud config or the VM service account) and the env vars above.
4. **Reach the web UI over a controlled connection** — prefer an SSH tunnel / IAP
   port-forward to the UI port rather than exposing it on a public IP:

   ```bash
   gcloud compute ssh <vm-name> -- -L 8080:localhost:8080
   # then open http://localhost:8080 locally
   ```

5. When finished, **delete the VM** so nothing persists.

---

## Safety

Computer use lets the model drive a real machine. Treat it accordingly:

- **Sandbox isolation.** Run **only** in a disposable, isolated container/VM with no
  access to your real accounts, files, or networks. Never point it at your own desktop.
- **User consent.** Get **explicit consent** before the agent acts, and keep a human in
  the loop for anything consequential (purchases, sending messages, deleting data).
- **Prompt-injection risk.** Anything the model reads on screen — web pages, documents,
  pop-ups — is **untrusted input** that may try to hijack its behavior. Constrain what
  the environment can reach, limit credentials available inside the sandbox, and review
  actions before they touch anything outside it.

---

## See also

- Teaching notebook: `02-tutorials/claude-on-agent-platform/07-computer-use.ipynb`
- Computer-use docs: <https://docs.claude.com/en/docs/agents-and-tools/tool-use/computer-use-tool>
- Reference implementation: <https://github.com/anthropics/anthropic-quickstarts>
