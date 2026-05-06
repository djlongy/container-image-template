#!/usr/bin/env bash
# scripts/scan/xray-sbom.sh — JFrog Xray CycloneDX SBOM emitter
#
# Single responsibility: run `jf docker scan --format=cyclonedx --sbom`
# against the upstream image and produce xray-sbom.cdx.json. Hands off
# to scripts/sbom-post.sh for vendor-neutral sink shipping (Splunk,
# Dependency-Track, Artifactory, webhook).
#
# Pairs with scripts/scan/xray-vuln.sh which produces the simple-json
# vuln scan via a separate jf invocation.
#
# Why a separate scan call rather than reusing xray-vuln's output: jf
# docker scan emits ONE format per invocation (no caching across
# format flags). The CycloneDX output is structurally different from
# simple-json (formal BOM standard, components list, dependencies
# graph) and serves a different audience (audit / compliance / SCA
# tools rather than vuln triage).
#
# Default ON because in environments where Trivy is banned and Syft
# awaits security approval, this is the only working CycloneDX SBOM
# source. Skip via XRAY_GENERATE_SBOM=false in image.env when Syft is
# producing the SBOM and an Xray duplicate isn't needed.
#
# Usage:
#   bash scripts/scan/xray-sbom.sh                 # scan UPSTREAM_REF
#   bash scripts/scan/xray-sbom.sh <image-ref>     # scan arbitrary ref
#
# Required env (Phase 1 preconditions — no-op when unset):
#   ARTIFACTORY_URL + ARTIFACTORY_USER + ARTIFACTORY_TOKEN/PASSWORD
#     OR explicit XRAY_ARTIFACTORY_URL/USER/TOKEN/PASSWORD overrides.
#
# Optional env:
#   XRAY_GENERATE_SBOM    "true" (default) | "false" → no-op
#   XRAY_SBOM_FILE        output path (default xray-sbom.cdx.json)
#   ARTIFACTORY_PROJECT   pass-through to --project=
#
# Exit codes: 0 (including graceful no-ops), 1 (missing scan target).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

# shellcheck source=../lib/load-image-env.sh
. "${REPO_ROOT}/scripts/lib/load-image-env.sh"
import_bamboo_vars
load_image_env

# Opt-out gate
if [ "${XRAY_GENERATE_SBOM:-true}" = "false" ]; then
  echo "→ XRAY_GENERATE_SBOM=false — skipping Xray SBOM generation"
  exit 0
fi

# ── Resolve scan target ─────────────────────────────────────────────
SCAN_REF="${1:-}"
if [ -z "${SCAN_REF}" ]; then
  if [ -n "${UPSTREAM_REF:-}" ]; then
    SCAN_REF="${UPSTREAM_REF}"
  elif [ -n "${UPSTREAM_REGISTRY:-}" ] && [ -n "${UPSTREAM_IMAGE:-}" ] && [ -n "${UPSTREAM_TAG:-}" ]; then
    SCAN_REF="${UPSTREAM_REGISTRY}/${UPSTREAM_IMAGE}:${UPSTREAM_TAG}"
  fi
fi
if [ -z "${SCAN_REF}" ]; then
  echo "ERROR: no scan target — pass an image ref as \$1, or set UPSTREAM_REF" >&2
  exit 1
fi

# ── Phase 1 preconditions: scan-side Artifactory creds ────────────
SCAN_ART_URL="${XRAY_ARTIFACTORY_URL:-${ARTIFACTORY_URL:-}}"
SCAN_ART_USER="${XRAY_ARTIFACTORY_USER:-${ARTIFACTORY_USER:-}}"
SCAN_ART_TOKEN="${XRAY_ARTIFACTORY_TOKEN:-${ARTIFACTORY_TOKEN:-}}"
SCAN_ART_PASSWORD="${XRAY_ARTIFACTORY_PASSWORD:-${ARTIFACTORY_PASSWORD:-}}"
ART_SECRET="${SCAN_ART_TOKEN:-${SCAN_ART_PASSWORD}}"
if [ -z "${SCAN_ART_URL}" ] || [ -z "${SCAN_ART_USER}" ] || [ -z "${ART_SECRET}" ]; then
  echo "→ xray-sbom: Xray-side Artifactory creds unset — no-op"
  exit 0
fi

# ── jf install ────────────────────────────────────────────────────
if ! command -v jf >/dev/null 2>&1; then
  # shellcheck source=../lib/install-jf.sh
  . "${REPO_ROOT}/scripts/lib/install-jf.sh"
  install_jf || {
    echo "WARN: jf install failed — skipping Xray SBOM" >&2
    exit 0
  }
fi

# ── Configure jf (separate server-id from xray-vuln to avoid clash) ─
_url="${SCAN_ART_URL%/}"
if [[ "${_url}" == */artifactory ]]; then
  _art_url="${_url}"
  _platform_url="${_url%/artifactory}"
else
  _art_url="${_url}/artifactory"
  _platform_url="${_url}"
fi
if [ -n "${SCAN_ART_TOKEN}" ]; then
  _auth_flag="--access-token=${SCAN_ART_TOKEN}"
else
  _auth_flag="--password=${SCAN_ART_PASSWORD}"
fi
echo "→ jf config add xray-sbom-server (url=${_platform_url}, user=${SCAN_ART_USER})"
# shellcheck disable=SC2086
jf config add xray-sbom-server \
  --url="${_platform_url}" \
  --artifactory-url="${_art_url}" \
  --user="${SCAN_ART_USER}" \
  ${_auth_flag} \
  --interactive=false \
  --overwrite=true >/dev/null
jf config use xray-sbom-server >/dev/null

# ── Pre-pull image ────────────────────────────────────────────────
if command -v docker >/dev/null 2>&1; then
  echo "→ docker pull ${SCAN_REF}"
  if ! docker pull "${SCAN_REF}" >/dev/null 2>/tmp/xray-sbom-pull.err; then
    echo "WARN: docker pull failed — jf docker scan will likely fail too" >&2
    sed 's/^/  /' /tmp/xray-sbom-pull.err >&2 || true
  fi
else
  echo "WARN: docker CLI not on PATH — jf docker scan needs local docker" >&2
fi

# ── Generate SBOM ─────────────────────────────────────────────────
SBOM_FILE_OUT="${XRAY_SBOM_FILE:-${REPO_ROOT}/xray-sbom.cdx.json}"
PROJECT_FLAG=""
[ -n "${ARTIFACTORY_PROJECT:-}" ] && PROJECT_FLAG="--project=${ARTIFACTORY_PROJECT}"

echo "→ jf docker scan --format=cyclonedx --sbom ${PROJECT_FLAG} ${SCAN_REF}"
set +e
# shellcheck disable=SC2086
jf docker scan ${PROJECT_FLAG} \
  --format=cyclonedx \
  --sbom \
  --fail=false \
  "${SCAN_REF}" \
  > "${SBOM_FILE_OUT}" 2>/tmp/xray-sbom.err
SBOM_RC=$?
set -e

if [ ! -s "${SBOM_FILE_OUT}" ]; then
  echo "WARN: jf docker scan (cyclonedx) produced no output (rc=${SBOM_RC}) — continuing" >&2
  sed 's/^/  /' /tmp/xray-sbom.err >&2 || true
  exit 0
fi

# Validate JSON shape (jf occasionally emits a warning above the JSON).
if command -v jq >/dev/null 2>&1; then
  if ! jq empty "${SBOM_FILE_OUT}" >/dev/null 2>&1; then
    echo "WARN: ${SBOM_FILE_OUT} is not valid JSON — keeping as artifact for debug" >&2
    exit 0
  fi
  COMPONENT_COUNT="$(jq '.components | length' "${SBOM_FILE_OUT}" 2>/dev/null || echo '?')"
  VULN_COUNT="$(jq '.vulnerabilities | length' "${SBOM_FILE_OUT}" 2>/dev/null || echo '?')"
  echo "  ✓ Xray SBOM: ${SBOM_FILE_OUT} ($(wc -c < "${SBOM_FILE_OUT}") bytes, ${COMPONENT_COUNT} components, ${VULN_COUNT} vulns inline, rc=${SBOM_RC})"
else
  echo "  ✓ Xray SBOM: ${SBOM_FILE_OUT} ($(wc -c < "${SBOM_FILE_OUT}") bytes, rc=${SBOM_RC})"
fi

# ── Hand off to sbom-post.sh ──────────────────────────────────────
# sbom-post.sh is vendor-agnostic — same downstream sinks (Splunk
# HEC, Dependency-Track, Artifactory, webhook) handle the Xray SBOM
# and the Syft SBOM identically. Failures stay non-fatal.
if [ -x "${REPO_ROOT}/scripts/sbom-post.sh" ]; then
  echo ""
  echo "→ Handoff to sbom-post.sh for sink shipping"
  bash "${REPO_ROOT}/scripts/sbom-post.sh" "${SBOM_FILE_OUT}" || {
    echo "WARN: sbom-post.sh returned non-zero — Xray SBOM still saved as artifact" >&2
  }
else
  echo "WARN: scripts/sbom-post.sh not executable — SBOM saved as artifact only" >&2
fi
