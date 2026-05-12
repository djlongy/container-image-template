#!/usr/bin/env bash
# push-backend: Harbor (and any plain Docker Registry v2 endpoint).
#
# Sourced by scripts/build.sh when REGISTRY_KIND is unset OR set to
# "harbor". Exposes a single entry point — push_to_backend() — that
# handles env validation, retag from the simple local build tag,
# docker login, docker push, digest extraction, and build.env emission.
#
# Mirrors the contract of scripts/push-backends/artifactory.sh so a
# fork can swap backends by changing REGISTRY_KIND alone, without
# touching build.sh.
#
# ── HARBOR vars are fully independent of ARTIFACTORY_* ──────────────
# This backend reads ONLY HARBOR_* env. It never falls back to or
# auto-derives anything from ARTIFACTORY_*. Same independence holds
# the other way — artifactory.sh ignores HARBOR_*. Pick the namespace
# that matches your REGISTRY_KIND; the other one is irrelevant.
#
# ── Variables this backend reads (set in image.env / shell env) ─────
#
# Required (when --push):
#   HARBOR_REGISTRY    destination registry host (e.g. harbor.example.com)
#   HARBOR_PROJECT     project / path prefix under HARBOR_REGISTRY
#                      (composes the push URL as
#                       <HARBOR_REGISTRY>/<HARBOR_PROJECT>/<IMAGE_NAME>:<FULL_TAG>)
#
# Required for authenticated registries:
#   HARBOR_USER
#   HARBOR_PASSWORD    password or token (CI-masked, never committed)
#
# Inputs from build.sh (already exported):
#   FULL_IMAGE         simple local docker tag, e.g. nginx:1.25.3-alpine-abc
#                      → this backend retags it to the Harbor target URL
#                        before pushing
#   FULL_TAG           computed tag (UPSTREAM_TAG[-gitShort])
#   IMAGE_NAME, UPSTREAM_TAG, UPSTREAM_REF, BASE_DIGEST, GIT_SHA, CREATED
#
# ── Outputs ─────────────────────────────────────────────────────────
#
# Emits the canonical artifact contract shared with the Artifactory
# backend so downstream stages don't care which backend ran:
#
#   build.env          IMAGE_REF, IMAGE_TAG, IMAGE_DIGEST, IMAGE_NAME,
#                      UPSTREAM_TAG, UPSTREAM_REF, BASE_DIGEST, GIT_SHA,
#                      CREATED, SBOM_FILE, VULN_SCAN_FILE

set -uo pipefail

# ════════════════════════════════════════════════════════════════════
# Internals
# ════════════════════════════════════════════════════════════════════

_harbor_require_env() {
  local missing=0 var
  for var in HARBOR_REGISTRY HARBOR_PROJECT; do
    if [ -z "${!var:-}" ]; then
      echo "ERROR: ${var} is required for the Harbor backend (--push)" >&2
      missing=1
    fi
  done
  return "${missing}"
}
# Public alias — build.sh's _build_validate_backend looks up
# `${kind}_require_env` so each backend exports a predictable name.
harbor_require_env() { _harbor_require_env "$@"; }

_harbor_docker_login() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: 'docker' CLI not found on PATH" >&2
    return 1
  fi
  if [ -z "${HARBOR_USER:-}" ] || [ -z "${HARBOR_PASSWORD:-}" ]; then
    _dbg "Harbor creds incomplete (registry=${HARBOR_REGISTRY} user=${HARBOR_USER:+set}) — skipping login"
    echo "  WARN: HARBOR_USER / HARBOR_PASSWORD unset — relying on existing daemon login" >&2
    return 0
  fi
  echo "→ docker login ${HARBOR_REGISTRY} (Harbor backend)"
  printf '%s' "${HARBOR_PASSWORD}" | docker login "${HARBOR_REGISTRY}" \
    -u "${HARBOR_USER}" --password-stdin
}

# Compose the Harbor push URL from HARBOR_* vars + the build-time
# IMAGE_NAME/FULL_TAG. Decoupled from build.sh so the backend owns
# its target shape.
_harbor_compose_target() {
  printf '%s/%s/%s:%s' \
    "${HARBOR_REGISTRY}" "${HARBOR_PROJECT}" "${IMAGE_NAME}" "${FULL_TAG}"
}

_harbor_print_banner() {
  local source_ref="$1" target="$2"
  echo ""
  echo "=== Harbor push ==="
  echo "  Source (local):  ${source_ref}"
  echo "  Target:          ${target}"
  echo "  Push host:       ${HARBOR_REGISTRY}"
  echo "  Project path:    ${HARBOR_PROJECT}"
}

_harbor_write_build_env() {
  local target="$1" digest_ref="$2"
  export IMAGE_REF="${target}"
  export IMAGE_DIGEST="${digest_ref}"

  # SBOM_FILE / VULN_SCAN_FILE come from scripts/lib/artifact-names.sh
  # (sourced by build.sh before this backend ran). Writing them here
  # propagates the canonical filenames to every downstream stage.
  #
  # `export ` prefix is critical: without it, `. ./build.env` only
  # creates SHELL vars that don't propagate to `bash ./script.sh`
  # subshells. GitLab CI's dotenv injection still works either way
  # (dotenv parses both forms), but local and Bamboo flows that
  # source-then-spawn need the export.
  cat > build.env <<EOF
export IMAGE_REF=${target}
export IMAGE_TAG=${FULL_TAG}
export IMAGE_DIGEST=${digest_ref}
export IMAGE_NAME=${IMAGE_NAME}
export UPSTREAM_TAG=${UPSTREAM_TAG:-unknown}
export UPSTREAM_REF=${UPSTREAM_REF:-unknown}
export BASE_DIGEST=${BASE_DIGEST:-}
export GIT_SHA=${GIT_SHA:-unknown}
export CREATED=${CREATED:-}
export SBOM_FILE=${SBOM_FILE}
export VULN_SCAN_FILE=${VULN_SCAN_FILE}
EOF
}

# ════════════════════════════════════════════════════════════════════
# Entry point
# ════════════════════════════════════════════════════════════════════

push_to_backend() {
  local source_ref="$1"   # simple local tag from build.sh, e.g. nginx:1.25.3-alpine-abc

  _harbor_require_env  || return 1
  _harbor_docker_login || return 1

  local target
  target="$(_harbor_compose_target)"
  _harbor_print_banner "${source_ref}" "${target}"

  # Retag the local image to the Harbor target URL before push.
  docker tag "${source_ref}" "${target}" || {
    echo "ERROR: docker tag ${source_ref} → ${target} failed" >&2
    return 1
  }

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
