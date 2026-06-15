FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# System deps
RUN apt-get update && apt-get install -y \
    git \
    jq \
    curl \
    vim \
    ca-certificates \
    openssh-client \
    && rm -rf /var/lib/apt/lists/*

# Node.js (LTS) + npm
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# uv (Python package manager)
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/root/.local/bin:$PATH"

# Bust cache to always pull latest AI CLIs and code
ARG CACHEBUST=1

# AI CLIs
RUN curl -fsSL https://claude.ai/install.sh | bash -s latest
RUN npm install -g \
    @google/gemini-cli@latest \
    @openai/codex@latest

WORKDIR /root

COPY experiments.json interventions.json .

# Public repo: clone over HTTPS (no SSH key / agent forwarding needed).
RUN git clone -b datasets https://github.com/gyevnarb/indirect-data-poisoning.git datasets
RUN cd datasets && uv tool install .
