# syntax=docker/dockerfile:1.7
#
# cc-backend — Phase 3 image
# Adds google-adk + litellm + claude-agent-sdk + anthropic[vertex] +
# Claude Code CLI on top of the Phase 2 base.

FROM python:3.12-slim-bookworm

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_ROOT_USER_ACTION=ignore \
    DEBIAN_FRONTEND=noninteractive

# OS deps (Chromium runtime libs + tini + curl/gnupg for nodesource +
# libmagic1 for Phase 10 MIME sniffing fallback in artifact_tool.py).
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl ca-certificates gnupg tini libmagic1 \
        libnss3 libatk1.0-0 libatk-bridge2.0-0 libcups2 libxkbcommon0 \
        libxcomposite1 libxdamage1 libxrandr2 libgbm1 libpango-1.0-0 \
        libcairo2 libasound2 libdrm2 libxshmfence1 fonts-liberation \
    && rm -rf /var/lib/apt/lists/*

# Node 20 LTS — required by Claude Code CLI.
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && node --version && npm --version

WORKDIR /app

# Python deps — each package gets its own RUN layer.
# Rationale: google-adk + litellm in a single resolver exceed 16 GiB
# memory (Phase 3 Lesson learned). Each in its own layer also caches
# per-package — bumping one pin only rebuilds that layer onward.
COPY requirements.txt .
RUN pip install "playwright"
RUN python -m playwright install chromium
RUN pip install "anthropic[vertex]==0.102.0"
RUN pip install "claude-agent-sdk==0.1.81"
RUN pip install "google-adk==1.33.0"
RUN pip install "litellm==1.84.0"

# Phase 4 deps — async HTTP + Firestore. Separate RUN layers per the
# Phase 3 Lesson learned (per-package caching + bounded resolver memory).
RUN pip install "fastapi" "uvicorn[standard]"
RUN pip install "google-cloud-firestore"

# Phase 6 dep — GCS client for workspace park/restore. Pod uses this
# only with per-turn downscoped tokens from X-Workspace-Token; the pod
# SA has zero bucket IAM (Phase 1 invariant).
RUN pip install "google-cloud-storage"

# Phase 8 dep — httpx for backend → bridge /workspace/sign callback
# (signed-URL fallback for artifacts >5 MB).
RUN pip install "httpx"

# Phase 10 dep — python-magic for MIME sniffing fallback (handles
# extension-less files and rare cases where stdlib mimetypes returns
# None). Needs libmagic1 OS package (installed above).
RUN pip install "python-magic"

# Claude Code CLI install. Diagnostic first — does claude-agent-sdk
# ship the CLI binary, or do we need npm? Build log answers this.
RUN echo "--- pre-npm: which claude ---" && \
    (which claude && echo "  bundled by claude-agent-sdk") || \
    echo "  CLI not bundled by claude-agent-sdk, installing via npm"
RUN npm install -g @anthropic-ai/claude-code
RUN echo "--- post-npm: which claude ---" && which claude && claude --version

# Build-time import smoke — fails the build on transitive dep conflicts.
# Includes ADK types we import from non-top-level submodules (Phase 4
# Lesson learned: MemoryEntry, ListSessionsResponse, GetSessionConfig,
# SearchMemoryResponse are NOT in the package __init__.py exports).
RUN python -c "from google.adk.agents import Agent; from google.adk.models.lite_llm import LiteLlm; from claude_agent_sdk import ClaudeSDKClient; from anthropic import AnthropicVertex; from google.adk.sessions import BaseSessionService, Session; from google.adk.sessions.base_session_service import GetSessionConfig, ListSessionsResponse; from google.adk.memory import BaseMemoryService; from google.adk.memory.memory_entry import MemoryEntry; from google.adk.memory.base_memory_service import SearchMemoryResponse; from google.adk.events import Event; from google.cloud.firestore import AsyncClient; from google.cloud import storage; from google.oauth2.credentials import Credentials; from google.oauth2 import id_token; from fastapi import FastAPI; import httpx; import magic; m = magic.Magic(mime=True); print('all dep imports ok; libmagic:', m.from_buffer(b'%PDF-1.4'))"

# Application code.
COPY server.py adk_agent.py firestore_session.py firestore_memory.py workspace.py request_context.py ./
COPY tools/ ./tools/

# App-level import smoke — exercises the actual transitive graph of our
# code (catches import-path bugs without booting the server, which would
# trigger google.auth ADC prewarm that can't reach the metadata server
# from the Cloud Build worker). NOTE: imports adk_agent which constructs
# a LiteLlm instance at module load; that's network-free, just config.
RUN python -c "import sys; sys.path.insert(0, '/app'); from firestore_session import FirestoreSessionService; from firestore_memory import FirestoreMemoryService; from tools.memory_tools import recall, remember; from tools.artifact_tool import emit_artifact, get_download_url, ALLOWLIST_MIMES, sniff_mime; from tools.workspace_tools import list_workspace, read_workspace_file, delete_workspace_file, move_workspace_file, purge_old_trash; from adk_agent import build_agent; from workspace import park, restore, needs_restore, _sweep_scratchpad_temps; import request_context; assert 'text/csv' in ALLOWLIST_MIMES and 'text/html' not in ALLOWLIST_MIMES, 'Phase 10 ALLOWLIST_MIMES mismatch'; print('app imports ok; allowlist=', sorted(ALLOWLIST_MIMES))"

EXPOSE 9000
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["python", "server.py"]
