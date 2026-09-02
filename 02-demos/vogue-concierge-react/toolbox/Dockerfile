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

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y ca-certificates curl && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY tools.yaml /app/tools.yaml

# Download from official genai-toolbox URL (not cloud-sql-connectors)
RUN curl -O https://storage.googleapis.com/genai-toolbox/v0.28.0/linux/amd64/toolbox && \
    chmod +x toolbox

EXPOSE 5000

CMD ["/app/toolbox", "--tools-file", "/app/tools.yaml", "--address", "0.0.0.0", "--port", "5000"]
