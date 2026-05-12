# airgap/alpine-cit-tools — pre-baked CI runner image
#
# Bakes every tool the GitLab `.install-tools` block + Bamboo BASH tasks
# currently `apk add` at job start. Build + push this image once to your
# internal Harbor / Artifactory, then point ALPINE_IMAGE at it in the
# pipeline. The install-tools block becomes a no-op when every required
# binary is already on PATH — no `apk add`, no Anchore CDN fetch.
#
# Why this exists: airgapped runners can't reach dl-cdn.alpinelinux.org
# for the apk repo metadata, nor https://github.com for the crane tarball.
# A pre-baked image collapses both into a single trusted internal mirror
# pull at job start.
#
# ── Build ────────────────────────────────────────────────────────────
# Build from the project root (this file lives in airgap/alpine-cit-tools/):
#
#   docker build \
#     -f airgap/alpine-cit-tools/Dockerfile \
#     -t harbor.mgt.newen.au/shared/base/alpine-cit-tools:3.20 \
#     airgap/alpine-cit-tools
#
# ── Push ─────────────────────────────────────────────────────────────
#
#   docker push harbor.mgt.newen.au/shared/base/alpine-cit-tools:3.20
#
# Then set ALPINE_IMAGE in the GitLab project CI variables (or Bamboo
# global variables) to that same ref. The install-tools block detects
# `command -v bash git curl openssl jq python3 crane` already exists and
# skips `apk add` + `curl crane`.
#
# ── Build args (override at build time) ──────────────────────────────
#
#   ALPINE_BASE     base image to derive from. Default: alpine:3.20
#                   On airgap rebuild, set this to your mirror, e.g.
#                   --build-arg ALPINE_BASE=harbor.mgt.newen.au/docker-hub/library/alpine:3.20
#
#   CRANE_VERSION   go-containerregistry release tag (no leading v).
#   CRANE_URL       full URL to the crane tarball. Default: GitHub release.
#                   Override to your internal Artifactory generic-tools
#                   mirror when GitHub is also blocked.

ARG ALPINE_BASE=alpine:3.20
FROM ${ALPINE_BASE}

ARG CRANE_VERSION=0.20.2
ARG CRANE_URL=https://github.com/google/go-containerregistry/releases/download/v${CRANE_VERSION}/go-containerregistry_Linux_x86_64.tar.gz

# Tools the install-tools block currently apk-adds. Keep the list 1:1
# with that block so adding a tool there means rebuilding this image,
# not silently degrading airgap support.
RUN apk add --no-cache \
      bash \
      git \
      curl \
      openssl \
      jq \
      python3 \
      ca-certificates

# crane lives at the same path the install-tools block writes to so
# scripts that PATH-discover it find it without touching ${HOME}/.local/bin.
RUN curl -fsSL "${CRANE_URL}" \
      | tar xz -C /usr/local/bin/ crane \
 && chmod +x /usr/local/bin/crane \
 && crane version

# Sanity check: every consumer's `command -v X` must hit here.
RUN bash --version \
 && git --version \
 && curl --version | head -1 \
 && openssl version \
 && jq --version \
 && python3 --version \
 && crane version
