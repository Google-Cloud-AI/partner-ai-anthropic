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

"""Shared RAG retrieval for the catalog and trend tools.

WHICH CLIENT
------------
This uses ``agentplatform.rag``, which ships inside ``google-cloud-aiplatform``.
Both older entry points now emit a deprecation warning pointing here:

    vertexai.preview.rag  -> deprecated
    vertexai.rag          -> also deprecated

so moving to ``vertexai.rag`` would only trade one deprecated import for another.
The module-level functions are used rather than ``agentplatform.Client().rag``
because the client property pulls in ``pandas``, which is a heavy dependency for
a container that only ever runs one retrieval call.

Retrieval knobs moved into ``RagRetrievalConfig`` in this API; the old flat
``similarity_top_k`` / ``vector_distance_threshold`` arguments are gone.
"""

from typing import Optional

from ..config import PROJECT_ID, RAG_CORPUS_RESOURCE, RAG_REGION


def retrieve(query: str, top_k: int, distance_threshold: float = 0.5) -> Optional[list]:
    """Query the RAG corpus and return ``[{content, score}, ...]``.

    Returns ``None`` when retrieval is unavailable or finds nothing, which is the
    callers' signal to fall back to their local copy of the data. The corpus
    lives in its own region (see ``RAG_REGION``), so the region is passed per
    call rather than relying on process-wide state set elsewhere.
    """
    if not RAG_CORPUS_RESOURCE:
        return None

    import vertexai
    from agentplatform import rag

    vertexai.init(project=PROJECT_ID, location=RAG_REGION)
    response = rag.retrieval_query(
        text=query,
        rag_resources=[rag.RagResource(rag_corpus=RAG_CORPUS_RESOURCE)],
        rag_retrieval_config=rag.RagRetrievalConfig(
            top_k=top_k,
            filter=rag.Filter(vector_distance_threshold=distance_threshold),
        ),
    )
    contexts = getattr(getattr(response, "contexts", None), "contexts", None)
    if not contexts:
        return None
    return [{"content": ctx.text, "score": ctx.score} for ctx in contexts]
