# syntax=docker/dockerfile:1.7
#
# cc-a2a-bridge — Cloud Run image. Pure A2A adapter; no LLM here, just
# routing + identity resolution + SandboxClaim management.
FROM python:3.12-slim-bookworm

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_ROOT_USER_ACTION=ignore \
    DEBIAN_FRONTEND=noninteractive \
    PORT=8080

# tini for clean signal forwarding under Cloud Run.
RUN apt-get update && apt-get install -y --no-install-recommends \
        tini ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
# One layer per (logical) package group — same pattern as backend, lets
# us iterate on subsets without recooking the whole image.
# Note: this Dockerfile does NOT use `pip install -r requirements.txt`.
# The pins below are the actual source of truth for the build;
# requirements.txt records the same pins as parallel documentation.
RUN pip install "fastapi" "uvicorn[standard]"
RUN pip install "a2a-sdk==0.2.13"
# Pinned 2026-05-21: kubernetes-36 (released ~May 2026) introduced an
# aiohttp-based async client and broke GKE control-plane auth,
# producing 401 on every SandboxClaim CRUD. phase12-r3 outage of
# 2026-05-20 was caused by pip resolving 36 when this was unpinned.
# Re-test before bumping.
RUN pip install "kubernetes==35.0.0"
# Pinned 2026-05-21: precautionary, paired with the kubernetes pin
# because google-auth produces the token kubernetes uses; we want
# both sides of the auth interaction stable. 2.52.0 was the version
# in the working phase8-r1 build.
RUN pip install "google-auth==2.52.0" "google-auth-httplib2" "httpx"

# Phase 8 — bridge mints v4 signed URLs at /workspace/sign.
RUN pip install "google-cloud-storage"

# Build-time import smoke — fails the build on transitive dep conflicts.
# Mirrors Phase 4 lesson: cover the specific submodule imports the app
# uses, not just package roots.
RUN python -c "from a2a.server.agent_execution import AgentExecutor, RequestContext, SimpleRequestContextBuilder; from a2a.server.events import EventQueue; from a2a.server.tasks import TaskUpdater, InMemoryTaskStore; from a2a.server.apps import A2AStarletteApplication; from a2a.server.request_handlers import DefaultRequestHandler; from a2a.types import AgentCard, AgentCapabilities, AgentSkill, TaskState, Part, TextPart, FilePart, FileWithBytes; from kubernetes import client, config; from fastapi import FastAPI; import httpx; from google.auth import downscoped; from google.auth.downscoped import AccessBoundaryRule, AvailabilityCondition, CredentialAccessBoundary, Credentials as DownscopedCredentials; from google.cloud import storage as gcs_storage; print('all dep imports ok')"

# Application code.
COPY main.py agent_card.py auth.py sandbox.py translate.py downscope.py sign_helpers.py ./

# App-level import smoke — exercises the actual transitive graph of our
# bridge code. Build fails (not pod-start fails) if anything drifts.
RUN python -c "import sys; sys.path.insert(0, '/app'); from agent_card import build_agent_card; from auth import resolve_user_key; from sandbox import broker; from downscope import broker as wsbroker; from translate import stream_backend_to_a2a; import main; print('app imports ok')"

EXPOSE 8080
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["python", "main.py"]
