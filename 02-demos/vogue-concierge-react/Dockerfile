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

# Stage 1: Build Next.js frontend
FROM node:20-slim AS frontend-builder
WORKDIR /app/ui
COPY ui/package*.json ./
RUN npm ci
COPY ui/ ./
RUN npm run build

# Stage 2: Python backend
FROM python:3.11-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl gnupg apt-transport-https ca-certificates \
    && echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
    | tee -a /etc/apt/sources.list.d/google-cloud-sdk.list \
    && curl https://packages.cloud.google.com/apt/doc/apt-key.gpg \
    | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg \
    && apt-get update && apt-get install -y google-cloud-cli \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY agents/ agents/
COPY data/ data/
COPY toolbox/ toolbox/
COPY app.py .
COPY checkout.py .

# Copy built frontend from stage 1
COPY --from=frontend-builder /app/ui/out ui/out/

ENV PORT=8080
# VERTEXAI_PROJECT / PROJECT_NUMBER / AGENT_ENGINE_ID are supplied at deploy time
# (see deploy.sh --set-env-vars), not baked into the image.

EXPOSE 8080
CMD ["python", "app.py"]
