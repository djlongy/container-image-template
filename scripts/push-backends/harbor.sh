#!/usr/bin/env bash
# push-backend: Harbor (and any plain Docker Registry v2 endpoint).
#
# Sourced by scripts/build.sh when REGISTRY_KIND is unset OR set to
# "harbor". Exposes a single entry point — push_to_backend() — that
# handles docker login, docker push, digest extraction, and build.env
# emission.
#
# Mirrors the contract of scripts/push-backends/artifactory.sh so a
# fork can swap backends by changing REGISTRY_KIND alone, without
# touching build.sh.
#
# ── Variables this backend reads (set in image.env / shell env) ─────
#
# Required (when --push):
#   PUSH_REGISTRY              destination registry host (e.g. harbor.example.com)
#   PUSH_PROJECT               project / path prefix under PUSH_REGISTRY
#
# Required at runtime for authenticated registries:
#   PUSH_REGISTRY_USER
#   PUSH_REGISTRY_PASSWORD     password or token (CI-masked, never committed)
#
# Inputs from build.sh (already exported):
#   FULL_IMAGE                 fully-qualified ref to push (the local tag)
#   FULL_TAG                   computed tag (UPSTREAM_TAG[-gitShort])
#   IMAGE_NAME                 image short name
#   UPSTREAM_TAG, UPSTREAM_REF, BASE_DIGEST, GIT_SHA, CREATED
#
# ── Outputs ─────────────────────────────────────────────────────────
#
# Emits the canonical artifact contract shared with the Artifactory
# backend so downstream stages don't care which backend ran:
#
#   build.env                  IMAGE_REF, IMAGE_TAG, IMAGE_DIGEST,
#                              IMAGE_NAME, UPSTREAM_TAG, UPSTREAM_REF,
#                              BASE_DIGEST, GIT_SHA, CREATED

set -uo pipefail

# ════════════════════════════════════════════════════════════════════
# Internals
# ════════════════════════════════════════════════════════════════════

_harbor_docker_login() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: 'docker' CLI not found on PATH" >&2
    return 1
  fi
  if [ -z "${PUSH_REGISTRY:-}" ]; then
    echo "ERROR: PUSH_REGISTRY is required for the Harbor backend" >&2
    return 1
  fi
  if [ -z "${PUSH_REGISTRY_USER:-}" ] || [ -z "${PUSH_REGISTRY_PASSWORD:-}" ]; then
    _dbg "Harbor creds incomplete (registry=${PUSH_REGISTRY} user=${PUSH_REGISTRY_USER:+set}) — skipping login"
    echo "  WARN: PUSH_REGISTRY_USER / PUSH_REGISTRY_PASSWORD unset — relying on existing daemon login" >&2
    return 0
  fi
  echo "→ docker login ${PUSH_REGISTRY} (Harbor backend)"
  printf '%s' "${PUSH_REGISTRY_PASSWORD}" | docker login "${PUSH_REGISTRY}" \
    -u "${PUSH_REGISTRY_USER}" --password-stdin
}

_harbor_print_banner() {
  local target="$1"
  echo ""
  echo "=== Harbor push ==="
  echo "  Source (local):  ${target}"
  echo "  Target:          ${target}"
  echo "  Push host:       ${PUSH_REGISTRY}"
  echo "  Project path:    ${PUSH_PROJECT}"
}

_harbor_write_build_env() {
  local target="$1" digest_ref="$2"
  export IMAGE_REF="${target}"
  export IMAGE_DIGEST="${digest_ref}"

  # SBOM_FILE / VULN_SCAN_FILE come from scripts/lib/artifact-names.sh
  # (sourced by build.sh before this backend ran). Writing them here
  # propagates the canonical filenames to every downstream stage that
  # does `. ./build.env`, so scan/ingest jobs never hardcode names.
  cat > build.env <<EOF
IMAGE_REF=${target}
IMAGE_TAG=${FULL_TAG}
IMAGE_DIGEST=${digest_ref}
IMAGE_NAME=${IMAGE_NAME}
UPSTREAM_TAG=${UPSTREAM_TAG:-unknown}
UPSTREAM_REF=${UPSTREAM_REF:-unknown}
BASE_DIGEST=${BASE_DIGEST:-}
GIT_SHA=${GIT_SHA:-unknown}
CREATED=${CREATED:-}
SBOM_FILE=${SBOM_FILE}
VULN_SCAN_FILE=${VULN_SCAN_FILE}
EOF
}

# ════════════════════════════════════════════════════════════════════
# Entry point
# ════════════════════════════════════════════════════════════════════

push_to_backend() {
  local target="$1"

  _harbor_docker_login || return 1
  _harbor_print_banner "${target}"

  echo ""
  echo "→ docker push ${target}"
  local push_output push_digest digest_ref=""
  push_output=$(docker push "${target}" 2>&1) || {
    echo "${push_output}" >&2
    echo "ERROR: docker push failed" >&2
    return 1
  }
  echo "${push_output}"

  push_digest=$(printf '%s' "${push_output}" | grep -oE 'sha256:[0-9a-f]{64}' | head -1)
  if [ -n "${push_digest}" ]; then
    digest_ref="${target%:*}@${push_digest}"
    echo "→ pushed: ${digest_ref}"
  fi

  _harbor_write_build_env "${target}" "${digest_ref}"
  echo "Pushed: ${target}"
}
