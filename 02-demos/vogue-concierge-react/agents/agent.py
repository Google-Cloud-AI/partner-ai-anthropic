# Copyright 2026 The "Anthropic on Google Cloud" Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Vogue Concierge — multi-agent definition (Claude on Agent Platform + Google ADK).

THE TEAM
--------
Instead of one model doing everything, we build a small team of ADK agents, each
on the Claude model that best fits its job (see ``agents/config.py``):

    vogue_concierge (Orchestrator, Sonnet 5)
      ├─ style_advisor        (Opus 5)     outfit / trend / recommendation
      ├─ inventory_specialist (Haiku 4.5)  stock / sizes / price / loyalty
      └─ returns_expert       (Haiku 4.5)  returns / exchanges / care

HOW DELEGATION WORKS (AgentTool)
--------------------------------
We wrap each specialist as an ADK ``AgentTool`` and hand those tools to the
orchestrator. From the orchestrator's point of view a specialist is "just a
tool": it calls the tool, the specialist runs its own model + its own tools, and
returns an answer the orchestrator relays to the customer. The orchestrator
keeps one consistent concierge voice throughout — it never hands the microphone
over, it delegates and reports back.

This pattern only became practical once we moved to Claude: the previous model
could not transfer between agents reliably, which is why the old build crammed
all three personas into a single agent. Claude's reliable tool-calling lets us
use the cleaner team structure.

WHERE THIS RUNS
---------------
``root_agent`` is the entry point Agent Runtime (the agent runtime)
loads and serves. ``deploy_agent_engine.py`` packages this module + data and
deploys it. Locally you can also run ``adk web agents`` to chat with it.
"""

from google.adk.agents import Agent

# ADK ships first-class support for Claude on Agent Platform: ``Claude`` is a
# BaseLlm that talks to the models through Anthropic's official SDK
# (``AsyncAnthropicVertex``) over Application Default Credentials — no API key.
# It handles the things a hand-rolled adapter gets wrong, most importantly
# round-tripping thinking blocks with their signatures inside a tool-use turn,
# which the current generation requires because thinking is on by default.
# ``AnthropicGenerateContentConfig`` carries the Claude-specific ``effort``
# knob that the generic GenerateContentConfig has no field for.
from google.adk.models import AnthropicGenerateContentConfig, Claude

# AgentTool turns a full Agent into a callable tool for a parent agent — this is
# the mechanism behind orchestrator -> specialist delegation.
from google.adk.tools.agent_tool import AgentTool

# The Toolbox ADK client: turns the MCP Toolbox's SQL tools into ADK tools and
# handles the ID-token exchange needed to call the service on Cloud Run.
from toolbox_adk import CredentialStrategy, ToolboxToolset

from . import config
from . import prompt

# Tools the specialists use. catalog_search / trend_search query the Vertex RAG
# corpus (with a local keyword fallback); the inventory tools run real SQL
# against BigQuery through the MCP Toolbox.
from .tools.catalog_search import catalog_search
from .tools.trend_rag import trend_search
from .tools.order_tools import (
    place_order, quote_order, check_loyalty, check_stock, get_order, enroll_loyalty,
)


def _inventory_toolset() -> ToolboxToolset:
    """The BigQuery inventory/loyalty tools, served by the MCP Toolbox.

    ``check_inventory`` and ``get_loyalty_discount`` are declared as SQL in
    ``toolbox/tools.yaml`` and executed by the Toolbox on Cloud Run, so the
    queries live outside the model and BigQuery is never addressed directly
    from here.

    The Toolbox runs authenticated. ``workload_identity`` mints a Google-signed
    ID token for the Toolbox URL from whatever ADC the caller has, which covers
    both places this runs: the Agent Runtime service agent in production, and
    your own ``gcloud auth login`` credentials when you drive the tree locally
    with ``adk web agents``. Nothing is resolved until the first tool call, so
    importing this module never needs the Toolbox to be up.
    """
    if not config.TOOLBOX_URL:
        raise RuntimeError(
            "TOOLBOX_URL is not set, so the Inventory Specialist has no BigQuery "
            "tools. Run ./deploy_toolbox.sh — it prints TOOLBOX_URL=<url> — then "
            "put that in .env and re-export it. See the README 'Manual setup'."
        )
    return ToolboxToolset(
        server_url=config.TOOLBOX_URL,
        toolset_name="default",
        credentials=CredentialStrategy.workload_identity(
            target_audience=config.TOOLBOX_URL,
        ),
    )


def create_agent() -> Agent:
    """Build and return the orchestrator with its three specialist sub-agents.

    We build the specialists first, then wrap them as tools for the orchestrator.
    Each ``Agent`` carries: a name (how it's addressed), its own ``Claude`` model
    (the right model for the job), a short description (the orchestrator reads
    these to choose whom to delegate to), an instruction (its system prompt), and
    its tools. Reasoning depth is set per agent via ``generate_content_config``.
    """

    # --- Specialist 1: Style Advisor (Opus 5, high effort) -----------------
    # The model path carries the project + serving region, so each agent can sit
    # on whichever endpoint has quota without a process-wide env var.
    style_advisor = Agent(
        name="style_advisor",
        model=Claude(model=config.vertex_model_path(config.STYLE_MODEL)),
        generate_content_config=AnthropicGenerateContentConfig(
            effort=config.STYLE_EFFORT,
        ),
        description=(
            "Expert fashion stylist. Handles outfit ideas, trend questions, "
            "product recommendations, and styling advice."
        ),
        instruction=prompt.STYLE_PROMPT,
        tools=[catalog_search, trend_search],
    )

    # --- Specialist 2: Inventory & Pricing (Haiku 4.5) --------------------
    # This is the structured-data half of the demo. `catalog_search` resolves a
    # product name to a SKU out of the RAG corpus; the Toolbox tools then run
    # real parameterised SQL against the BigQuery `inventory` and
    # `loyalty_program` tables — the same tables checkout validates against, so
    # the two never disagree. An earlier build mocked these with random per-size
    # numbers, which is exactly the fake, inconsistent stock this replaces.
    inventory_specialist = Agent(
        name="inventory_specialist",
        model=Claude(model=config.vertex_model_path(config.INVENTORY_MODEL)),
        description=(
            "Answers product and availability questions — pricing, materials, "
            "colours, live per-size stock, and loyalty tier — from the catalog "
            "and from BigQuery."
        ),
        instruction=prompt.INVENTORY_PROMPT,
        tools=[catalog_search, _inventory_toolset()],
    )

    # --- Specialist 3: Returns & Care (Haiku 4.5) -------------------------
    returns_expert = Agent(
        name="returns_expert",
        model=Claude(model=config.vertex_model_path(config.RETURNS_MODEL)),
        description=(
            "Handles returns, exchanges, order issues, and garment-care advice."
        ),
        instruction=prompt.RETURNS_PROMPT,
        # catalog_search lets it look up a product's material for care tips.
        tools=[catalog_search],
    )

    # --- Orchestrator (Sonnet 5, medium effort) ---------------------------
    # The three specialists become tools here. Checkout is different: `place_order`
    # is a TOP-LEVEL tool on the orchestrator (not a sub-agent) so its call — with
    # clean args (sku, size, customer_id, quantity) — is visible in the Agent
    # Engine event stream. The Cloud Run layer reads that call and runs the REAL
    # BigQuery checkout (see checkout.py). That split is a deliberate design
    # choice, not a reachability limit: reads go straight to BigQuery through the
    # Toolbox, while the money-moving writes stay off the model entirely.
    orchestrator = Agent(
        name="vogue_concierge",
        model=Claude(model=config.vertex_model_path(config.ORCHESTRATOR_MODEL)),
        # The orchestrator mostly routes and relays, so it runs at "medium"
        # rather than the model's "high" default — see agents/config.py.
        generate_content_config=AnthropicGenerateContentConfig(
            effort=config.ORCHESTRATOR_EFFORT,
        ),
        description="Vogue Concierge — the lead AI concierge of a luxury boutique.",
        instruction=prompt.ORCHESTRATOR_PROMPT,
        tools=[
            AgentTool(agent=style_advisor),
            AgentTool(agent=inventory_specialist),
            AgentTool(agent=returns_expert),
            check_stock,    # signal -> Cloud Run reads real BigQuery inventory
            quote_order,    # signal -> Cloud Run computes the confirm-to-pay summary
            place_order,    # signal -> Cloud Run charges + records the order
            get_order,      # signal -> Cloud Run reads a stored order by number
            check_loyalty,  # signal -> Cloud Run reads real BigQuery loyalty
            enroll_loyalty, # signal -> Cloud Run creates a new loyalty member
        ],
    )

    # Stamp a version so deployments are easy to tell apart. ``object.__setattr__``
    # bypasses pydantic's field validation on the Agent model.
    object.__setattr__(orchestrator, "version", "2.0.0")
    return orchestrator


# Agent Runtime and ``adk web`` both look for a module-level
# ``root_agent``. This is the single entry point to the whole team.
root_agent = create_agent()
