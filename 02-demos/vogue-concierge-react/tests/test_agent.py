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

"""
Test Agent — Vogue Concierge
================================
Validates the ADK agent initializes correctly with all tools.

Usage:
    python tests/test_agent.py
"""

import asyncio
import sys
import os

# Add project root to path
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# The tools are ADK tools, which are async functions, so the tests that exercise
# them are async too and the runner below drives them on one event loop.


def test_agent_creation():
    """Test that the agent creates successfully."""
    print("Testing agent creation...")

    from agents.agent import create_agent
    agent = create_agent()

    print(f"  Agent name: {agent.name}")
    print(f"  Model: {agent.model}")
    print(f"  Tools: {len(agent.tools)}")
    for tool in agent.tools:
        name = getattr(tool, '__name__', getattr(tool, 'name', str(tool)))
        print(f"    - {name}")

    assert agent.name == "vogue_concierge"
    print("  PASSED")
    return True


async def test_catalog_search():
    """Test the catalog search tool."""
    print("\nTesting catalog_search tool...")

    from agents.tools.catalog_search import catalog_search
    result = await catalog_search("summer wedding dress")

    print(f"  Source: {result['source']}")
    print(f"  Results: {len(result['results'])}")
    for r in result['results'][:3]:
        if 'name' in r:
            print(f"    - {r['sku']}: {r['name']} (${r['price']})")
        else:
            print(f"    - {r.get('content', '')[:80]}...")

    assert len(result['results']) > 0
    print("  PASSED")
    return True


async def test_trend_search():
    """Test the trend search tool."""
    print("\nTesting trend_search tool...")

    from agents.tools.trend_rag import trend_search
    result = await trend_search("evening glamour cocktail")

    print(f"  Source: {result['source']}")
    print(f"  Results: {len(result['results'])}")
    for r in result['results'][:2]:
        print(f"    - {r['content'][:80]}...")

    assert len(result['results']) > 0
    print("  PASSED")
    return True


def test_inventory_toolset():
    """The Inventory Specialist must be wired to the MCP Toolbox.

    We check the wiring, not the queries: the toolset resolves its tools lazily
    on first call, so this runs offline. Actually executing `check_inventory`
    needs the deployed Toolbox and a seeded BigQuery dataset.
    """
    print("\nTesting MCP Toolbox wiring...")

    from toolbox_adk import ToolboxToolset
    from agents import config
    from agents.agent import create_agent

    root = create_agent()
    inventory = next(
        t.agent for t in root.tools
        if getattr(getattr(t, "agent", None), "name", None) == "inventory_specialist"
    )
    toolsets = [t for t in inventory.tools if isinstance(t, ToolboxToolset)]

    print(f"  Toolbox URL: {config.TOOLBOX_URL}")
    print(f"  ToolboxToolset attached: {len(toolsets)}")
    assert len(toolsets) == 1, "inventory_specialist is not wired to the MCP Toolbox"

    print("  PASSED")
    return True


async def main():
    print("=" * 60)
    print("Vogue Concierge — Agent Tests")
    print("=" * 60)

    results = []
    results.append(await test_catalog_search())
    results.append(await test_trend_search())
    results.append(test_inventory_toolset())
    results.append(test_agent_creation())

    print(f"\n{'=' * 60}")
    passed = sum(results)
    total = len(results)
    print(f"Results: {passed}/{total} tests passed")
    print(f"{'=' * 60}")

    return all(results)


if __name__ == "__main__":
    success = asyncio.run(main())
    exit(0 if success else 1)
