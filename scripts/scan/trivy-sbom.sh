#!/usr/bin/env bash
# scripts/scan/trivy-sbom.sh — Aqua Trivy CycloneDX SBOM generator
#
# Single responsibility: run `trivy image --format cyclonedx` and
# produce the canonical sbom.cdx.json. Three SBOM producers now share
# the contract: scan/syft-sbom.sh, scan/xray-sbom.sh, scan/trivy-sbom.sh.
# Swap any of them by changing the script name in CI YAML.
#
# ── DISABLED BY DEFAULT — Trivy is banned for business use here ─────
# Same security caveat as scripts/scan/trivy-vuln.sh: this is a
# scaffold for re-enablement. PINNED to v0.69.3 (the last safe
# pre-compromise binary release). Bump only after vetting the
# upstream advisory list — see the version note in trivy-vuln.sh.
#
# Usage:
#   bash scripts/scan/trivy-sbom.sh                # SBOM of IMAGE_DIGEST/IMAGE_REF
#   bash scripts/scan/trivy-sbom.sh <image-ref>    # SBOM of arbitrary ref
#
# Optional env:
#   SBOM_FILE                 output path (default sbom.cdx.json — the
#                             canonical name from artifact-names.sh)
#   TRIVY_VERSION             default 0.69.3 (last safe pre-compromise)
#   TRIVY_INSTALLER_URL       installer URL (default: aquasec install.sh)
#   TRIVY_BINARY_URL          direct binary tarball (air-gap mirror)
#
# Exit codes: 0 (success), 1 (install failure / no scan target).

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
SCAN_REF="${1:-${TRIVY_SCAN_REF:-${SBOM_SCAN_REF:-${XRAY_SCAN_REF:-}}}}"
if [ -z "${SCAN_REF}" ]; then
  if   [ -n "${IMAGE_DIGEST:-}" ];                                          then SCAN_REF="${IMAGE_DIGEST}"
  elif [ -n "${IMAGE_REF:-}" ];                                             then SCAN_REF="${IMAGE_REF}"
  elif [ -n "${UPSTREAM_REF:-}" ];                                          then SCAN_REF="${UPSTREAM_REF}"
  elif [ -n "${UPSTREAM_REGISTRY:-}" ] && [ -n "${UPSTREAM_IMAGE:-}" ] && [ -n "${UPSTREAM_TAG:-}" ]; then
    SCAN_REF="${UPSTREAM_REGISTRY}/${UPSTREAM_IMAGE}:${UPSTREAM_TAG}"
  fi
fi
if [ -z "${SCAN_REF}" ]; then
  echo "ERROR: no scan target available." >&2
  exit 1
fi
echo "→ Scan target: ${SCAN_REF}"

# ── Resolve output path ─────────────────────────────────────────────
case "${SBOM_FILE}" in
  /*) SBOM_OUT="${SBOM_FILE}" ;;
  *)  SBOM_OUT="${REPO_ROOT}/${SBOM_FILE}" ;;
esac

# ── Auto-install trivy at the PINNED safe version ──────────────────
TRIVY_VERSION="${TRIVY_VERSION:-0.69.3}"
if ! command -v trivy >/dev/null 2>&1; then
  if [ -n "${TRIVY_BINARY_URL:-}" ]; then
    echo "→ trivy not on PATH — installing from TRIVY_BINARY_URL"
    mkdir -p "${REPO_ROOT}/.bin"
    if curl -fsSL --max-time 120 "${TRIVY_BINARY_URL}" -o /tmp/trivy.tgz \
       && tar xz -C "${REPO_ROOT}/.bin" -f /tmp/trivy.tgz trivy 2>/dev/null \
       && [ -x "${REPO_ROOT}/.bin/trivy" ]; then
      export PATH="${REPO_ROOT}/.bin:${PATH}"
      echo "  ✓ trivy installed ($(trivy --version 2>&1 | head -1))"
    else
      echo "ERROR: trivy install from TRIVY_BINARY_URL failed" >&2
      exit 1
    fi
  else
    _url="${TRIVY_INSTALLER_URL:-https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh}"
    echo "→ trivy not on PATH — installing v${TRIVY_VERSION} from ${_url}"
    mkdir -p "${REPO_ROOT}/.bin"
    if curl -fsSL --max-time 120 "${_url}" \
         | sh -s -- -b "${REPO_ROOT}/.bin" "v${TRIVY_VERSION}" >/dev/null 2>&1 \
       && [ -x "${REPO_ROOT}/.bin/trivy" ]; then
      export PATH="${REPO_ROOT}/.bin:${PATH}"
      echo "  ✓ trivy installed ($(trivy --version 2>&1 | head -1))"
    else
      echo "ERROR: trivy install failed — set TRIVY_BINARY_URL to a reachable mirror" >&2
      exit 1
    fi
  fi
fi

# Refuse compromised versions (defence in depth — same check as
# trivy-vuln.sh).
_installed="$(trivy --version 2>&1 | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo unknown)"
case "${_installed}" in
  0.69.4|0.69.5|0.69.6)
    echo "ERROR: trivy ${_installed} is in the compromised range (v0.69.4–v0.69.6)." >&2
    echo "       Pin TRIVY_VERSION to 0.69.3 or upgrade past the next vetted release." >&2
    exit 1
    ;;
esac

# ── Multi-registry docker login ────────────────────────────────────
if command -v docker >/dev/null 2>&1; then
  # shellcheck source=../lib/docker-login.sh
  . "${REPO_ROOT}/scripts/lib/docker-login.sh"
  docker_login_for_xray_scan || true
fi

# ── Generate the SBOM ──────────────────────────────────────────────
echo "→ trivy image --format cyclonedx ${SCAN_REF} → ${SBOM_OUT}"
trivy image --format cyclonedx --output "${SBOM_OUT}" "${SCAN_REF}" || {
  echo "ERROR: trivy SBOM generation failed" >&2
  exit 1
}

if [ ! -s "${SBOM_OUT}" ]; then
  echo "ERROR: trivy produced no SBOM output" >&2
  exit 1
fi

if command -v jq >/dev/null 2>&1; then
  COMPONENT_COUNT="$(jq '.components | length' "${SBOM_OUT}" 2>/dev/null || echo '?')"
  echo "  ✓ Trivy SBOM: ${SBOM_OUT} ($(wc -c < "${SBOM_OUT}") bytes, ${COMPONENT_COUNT} components)"
else
  echo "  ✓ Trivy SBOM: ${SBOM_OUT} ($(wc -c < "${SBOM_OUT}") bytes)"
fi

# ── Hand off to sbom-post.sh (no-op when no sinks configured) ──────
if [ -f "${REPO_ROOT}/scripts/sbom-post.sh" ]; then
  echo ""
  echo "→ Handing off to scripts/sbom-post.sh"
  bash "${REPO_ROOT}/scripts/sbom-post.sh" "${SBOM_OUT}" || {
    echo "  WARN: sbom-post.sh exited non-zero — SBOM artifact still written" >&2
  }
fi
