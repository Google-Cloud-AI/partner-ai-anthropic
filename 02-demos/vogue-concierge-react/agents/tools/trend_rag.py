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

"""Trend Search Tool — works locally and in Agent Runtime"""

import os
from typing import Optional

_trend_cache: Optional[str] = None

def _find_trend_report() -> str:
    candidates = [
        os.path.join(os.path.dirname(__file__), "..", "..", "data", "trend_report.md"),
        os.path.join(os.getcwd(), "data", "trend_report.md"),
        "/code/data/trend_report.md",
        "data/trend_report.md",
    ]
    for path in candidates:
        abs_path = os.path.abspath(path)
        if os.path.exists(abs_path):
            return abs_path
    return ""


def _load_trend_report() -> str:
    global _trend_cache
    if _trend_cache is None:
        report_file = _find_trend_report()
        if report_file:
            with open(report_file, "r") as f:
                _trend_cache = f.read()
            print(f"Trend report loaded from {report_file}")
        else:
            print("WARNING: trend_report.md not found")
            _trend_cache = ""
    return _trend_cache


async def trend_search(query: str) -> dict:
    """Search the current fashion trend report for style insights and seasonal trends.

    Use this tool when customers ask about what is trending, current fashion
    directions, seasonal must-haves, or style forecasts.

    Args:
        query: Natural language query about fashion trends.
               Examples: "summer 2026 trends", "what colors are in this season"

    Returns:
        Dictionary with relevant trend insights and recommendations.
    """
    try:
        from .rag_retrieval import retrieve

        hits = retrieve(query, top_k=3)
        if hits:
            return {"source": "rag", "results": hits}
    except Exception as e:
        print(f"RAG trend search failed ({e}), using local report")

    report = _load_trend_report()
    if not report:
        return {"source": "local", "results": [], "message": "Trend report not available."}

    query_lower = query.lower()
    query_terms = query_lower.split()
    sections = report.split("\n## ")
    scored_sections = []
    for section in sections:
        section_lower = section.lower()
        score = sum(1 for term in query_terms if term in section_lower)
        if score > 0:
            scored_sections.append((score, section.strip()))
    scored_sections.sort(key=lambda x: x[0], reverse=True)
    top_sections = [s for _, s in scored_sections[:3]]
    if not top_sections:
        top_sections = [sections[0][:500]] if sections else []
    return {"source": "local", "results": [{"content": s} for s in top_sections]}
