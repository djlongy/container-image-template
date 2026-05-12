#!/usr/bin/env bash
# scripts/scan/syft-sbom.sh — Anchore Syft CycloneDX SBOM emitter
#
# Single responsibility: run `syft <target> -o cyclonedx-json=...`
# and produce the canonical sbom.cdx.json. Hands off to
# scripts/ingest/sbom-post.sh for vendor-neutral sink shipping (Splunk,
# Dependency-Track, Artifactory, webhook).
#
# Output filename is the SAME as scripts/scan/xray-sbom.sh — both
# write sbom.cdx.json by default. That's the artifact contract:
# downstream stages (Grype, sbom-post) consume sbom.cdx.json without
# caring which generator produced it. Swap one for the other by
# changing the script name in the CI YAML; nothing else needs to move.
#
# Usage:
#   bash scripts/scan/syft-sbom.sh                 # SBOM of the BUILT image
#                                                  # (IMAGE_DIGEST from
#                                                  #  build.env, fallback
#                                                  #  chain below)
#   bash scripts/scan/syft-sbom.sh <image-ref>     # SBOM of arbitrary ref
#   bash scripts/scan/syft-sbom.sh dir:./          # SBOM of source tree
#                                                  # (override SBOM_TARGET)
#
# Scan target resolution (highest precedence first):
#   1. positional arg $1
#   2. SBOM_SCAN_REF env var (explicit override)
#   3. SBOM_TARGET=source → dir:${REPO_ROOT}
#   4. IMAGE_DIGEST   (from build.env — the rebuilt image's digest)
#   5. IMAGE_REF      (from build.env — the rebuilt image's tag)
#   6. UPSTREAM_REF   (from image.env — the upstream we rebuilt from)
#   7. UPSTREAM_REGISTRY/UPSTREAM_IMAGE:UPSTREAM_TAG (assembled if all set)
#
# Default targets the BUILT image (consumers pull THAT, not upstream).
#
# Required env: none (the script auto-installs syft if missing).
#
# Optional env:
#   SBOM_SCAN_REF             override the resolved target (parallels XRAY_SCAN_REF)
#   SBOM_TARGET               "image" (default) | "source" — switches to dir:${REPO_ROOT}
#   SBOM_FILE                 output path (default sbom.cdx.json — the canonical name)
#   SYFT_INSTALLER_URL        installer URL (default: GitHub raw)
#   SYFT_VERSION              default v1.14.0
#
# Exit codes: 0 on success (incl. graceful fallbacks); 1 on missing
# scan target or unrecoverable syft failure.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

# shellcheck source=../lib/load-image-env.sh
. "${REPO_ROOT}/scripts/lib/load-image-env.sh"
# shellcheck source=../lib/artifact-names.sh
. "${REPO_ROOT}/scripts/lib/artifact-names.sh"
import_bamboo_vars
load_image_env

# ── Resolve scan target ─────────────────────────────────────────────
SBOM_TARGET="$(printf '%s' "${SBOM_TARGET:-image}" | tr '[:upper:]' '[:lower:]')"
SCAN_REF="${1:-${SBOM_SCAN_REF:-}}"
if [ -z "${SCAN_REF}" ]; then
  case "${SBOM_TARGET}" in
    source) SCAN_REF="dir:${REPO_ROOT}" ;;
    image|*)
      if   [ -n "${IMAGE_DIGEST:-}" ];                                          then SCAN_REF="${IMAGE_DIGEST}"
      elif [ -n "${IMAGE_REF:-}" ];                                             then SCAN_REF="${IMAGE_REF}"
      elif [ -n "${UPSTREAM_REF:-}" ];                                          then SCAN_REF="${UPSTREAM_REF}"
      elif [ -n "${UPSTREAM_REGISTRY:-}" ] && [ -n "${UPSTREAM_IMAGE:-}" ] && [ -n "${UPSTREAM_TAG:-}" ]; then
        SCAN_REF="${UPSTREAM_REGISTRY}/${UPSTREAM_IMAGE}:${UPSTREAM_TAG}"
      fi
      ;;
  esac
fi
if [ -z "${SCAN_REF}" ]; then
  echo "ERROR: no scan target available." >&2
  echo "  Resolution chain: \$1 > SBOM_SCAN_REF > IMAGE_DIGEST > IMAGE_REF > UPSTREAM_REF > UPSTREAM_REGISTRY/IMAGE:TAG" >&2
  echo "  All empty. To scan after build, ensure build.env (with IMAGE_DIGEST)" >&2
  echo "  is on disk. To scan upstream as a prescan, set UPSTREAM_REF in image.env" >&2
  echo "  or pass a ref explicitly: bash scripts/scan/syft-sbom.sh <image-ref>" >&2
  exit 1
fi
echo "→ Scan target: ${SCAN_REF}"

# ── Auto-install syft ───────────────────────────────────────────────
if ! command -v syft >/dev/null 2>&1; then
  _url="${SYFT_INSTALLER_URL:-https://raw.githubusercontent.com/anchore/syft/main/install.sh}"
  _ver="${SYFT_VERSION:-v1.14.0}"
  echo "→ syft not on PATH — installing ${_ver} from ${_url}"
  mkdir -p "${REPO_ROOT}/.bin"
  if curl -fsSL --max-time 120 "${_url}" \
       | sh -s -- -b "${REPO_ROOT}/.bin" "${_ver}" >/dev/null 2>&1 \
     && [ -x "${REPO_ROOT}/.bin/syft" ]; then
    export PATH="${REPO_ROOT}/.bin:${PATH}"
    echo "  ✓ syft installed ($(syft version 2>&1 | head -1))"
  else
    echo "ERROR: syft install failed — set SYFT_INSTALLER_URL to a reachable mirror" >&2
    exit 1
  fi
fi

# ── docker login when scanning an image (Syft pulls by digest) ──────
# Same multi-registry pattern as xray-vuln.sh — login to whichever
# backend the build pushed to, so syft can `docker pull` the digest.
if [ "${SCAN_REF#dir:}" = "${SCAN_REF}" ] && command -v docker >/dev/null 2>&1; then
  # shellcheck source=../lib/docker-login.sh
  . "${REPO_ROOT}/scripts/lib/docker-login.sh"
  docker_login_for_xray_scan || true
fi

# ── Generate the SBOM ───────────────────────────────────────────────
# SBOM_FILE comes from scripts/lib/artifact-names.sh (default
# sbom.cdx.json) or build.env (when sourced beforehand). Treat bare
# filenames as REPO_ROOT-relative.
case "${SBOM_FILE}" in
  /*) SBOM_FILE_OUT="${SBOM_FILE}" ;;
  *)  SBOM_FILE_OUT="${REPO_ROOT}/${SBOM_FILE}" ;;
esac
echo "→ syft ${SCAN_REF} → ${SBOM_FILE_OUT}"

if ! syft "${SCAN_REF}" -o "cyclonedx-json=${SBOM_FILE_OUT}"; then
  echo "ERROR: syft failed — no SBOM produced" >&2
  exit 1
fi

if [ ! -s "${SBOM_FILE_OUT}" ]; then
  echo "ERROR: syft produced an empty file at ${SBOM_FILE_OUT}" >&2
  exit 1
fi

if command -v jq >/dev/null 2>&1; then
  COMPONENT_COUNT="$(jq '.components | length' "${SBOM_FILE_OUT}" 2>/dev/null || echo '?')"
  echo "  ✓ Syft SBOM: ${SBOM_FILE_OUT} ($(wc -c < "${SBOM_FILE_OUT}") bytes, ${COMPONENT_COUNT} components)"
else
  echo "  ✓ Syft SBOM: ${SBOM_FILE_OUT} ($(wc -c < "${SBOM_FILE_OUT}") bytes)"
fi

# ── Hand off to sbom-post.sh (no-op when no sinks configured) ──────
if [ -x "${REPO_ROOT}/scripts/ingest/sbom-post.sh" ] || [ -f "${REPO_ROOT}/scripts/ingest/sbom-post.sh" ]; then
  echo ""
  echo "→ Handing off to scripts/ingest/sbom-post.sh"
  bash "${REPO_ROOT}/scripts/ingest/sbom-post.sh" "${SBOM_FILE_OUT}" || {
    echo "  WARN: sbom-post.sh exited non-zero — SBOM artifact still written" >&2
  }
fi
