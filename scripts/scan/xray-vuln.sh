#!/usr/bin/env bash
# scripts/scan/xray-vuln.sh — JFrog Xray vulnerability scan
#
# Single responsibility: run `jf docker scan --format=simple-json`
# against the upstream image and produce xray-scan.json. Optionally
# ships the JSON to Splunk HEC.
#
# Pairs with scripts/scan/xray-sbom.sh which produces the CycloneDX
# SBOM via a separate jf invocation. Both scripts read image.env via
# the shared loader and self-install jf via scripts/lib/install-jf.sh.
#
# Usage:
#   bash scripts/scan/xray-vuln.sh                 # scan UPSTREAM_REF
#   bash scripts/scan/xray-vuln.sh <image-ref>     # scan arbitrary ref
#
# Required env (Phase 1 preconditions — no-op when unset):
#   ARTIFACTORY_URL + ARTIFACTORY_USER + ARTIFACTORY_TOKEN/PASSWORD
#     OR explicit XRAY_ARTIFACTORY_URL/USER/TOKEN/PASSWORD overrides
#     when push-side and scan-side Artifactory differ.
#
# Optional env (Splunk side — when set, vuln JSON also ships):
#   SPLUNK_HEC_URL + SPLUNK_HEC_TOKEN  → see lib/splunk-hec.sh
#   SPLUNK_HEC_SOURCETYPE              default: jfrog:xray:scan
#
# Optional env (scan side):
#   UPSTREAM_REF                       full <reg>/<image>:<tag> when no
#                                      positional arg given
#   XRAY_SCAN_FILE                     output path (default xray-scan.json)
#   XRAY_SCAN_FORMAT                   simple-json (default) | json
#   ARTIFACTORY_PROJECT                pass-through to --project=
#
# Exit codes:
#   0  success (including graceful no-op when creds missing)
#   1  hard fatal — usually a malformed call (missing both ref and
#      UPSTREAM_REF). Scan failures, jf install failures, and Splunk
#      POST failures are all warnings + exit 0 by design.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

# shellcheck source=../lib/load-image-env.sh
. "${REPO_ROOT}/scripts/lib/load-image-env.sh"
import_bamboo_vars
load_image_env

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
  echo "       (or UPSTREAM_REGISTRY + UPSTREAM_IMAGE + UPSTREAM_TAG in image.env)" >&2
  exit 1
fi

# ── Phase 1 preconditions: resolve scan-side Artifactory creds ─────
SCAN_ART_URL="${XRAY_ARTIFACTORY_URL:-${ARTIFACTORY_URL:-}}"
SCAN_ART_USER="${XRAY_ARTIFACTORY_USER:-${ARTIFACTORY_USER:-}}"
SCAN_ART_TOKEN="${XRAY_ARTIFACTORY_TOKEN:-${ARTIFACTORY_TOKEN:-}}"
SCAN_ART_PASSWORD="${XRAY_ARTIFACTORY_PASSWORD:-${ARTIFACTORY_PASSWORD:-}}"
ART_SECRET="${SCAN_ART_TOKEN:-${SCAN_ART_PASSWORD}}"
if [ -z "${SCAN_ART_URL}" ] || [ -z "${SCAN_ART_USER}" ] || [ -z "${ART_SECRET}" ]; then
  echo "→ xray-vuln: Xray-side Artifactory creds unset — no-op"
  echo "  (set XRAY_ARTIFACTORY_URL/USER/TOKEN or ARTIFACTORY_URL/USER/TOKEN in image.env)"
  exit 0
fi

# ── jf install via shared helper ───────────────────────────────────
if ! command -v jf >/dev/null 2>&1; then
  # shellcheck source=../lib/install-jf.sh
  . "${REPO_ROOT}/scripts/lib/install-jf.sh"
  install_jf || {
    echo "WARN: jf install failed — skipping Xray vuln scan" >&2
    exit 0
  }
fi

# ── Configure jf to talk to the SCAN-side Artifactory ─────────────
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
echo "→ jf config add xray-vuln-server (url=${_platform_url}, user=${SCAN_ART_USER})"
# shellcheck disable=SC2086
jf config add xray-vuln-server \
  --url="${_platform_url}" \
  --artifactory-url="${_art_url}" \
  --user="${SCAN_ART_USER}" \
  ${_auth_flag} \
  --interactive=false \
  --overwrite=true >/dev/null
jf config use xray-vuln-server >/dev/null

# ── Pre-pull image so `jf docker scan → docker save` finds it ──────
if command -v docker >/dev/null 2>&1; then
  echo "→ docker pull ${SCAN_REF}"
  if ! docker pull "${SCAN_REF}" >/dev/null 2>/tmp/xray-vuln-pull.err; then
    echo "WARN: docker pull failed — jf docker scan will likely fail too" >&2
    sed 's/^/  /' /tmp/xray-vuln-pull.err >&2 || true
  fi
else
  echo "WARN: docker CLI not on PATH — jf docker scan needs local docker" >&2
fi

# ── Run the scan ────────────────────────────────────────────────────
SCAN_FORMAT="${XRAY_SCAN_FORMAT:-simple-json}"
SCAN_FILE="${XRAY_SCAN_FILE:-${REPO_ROOT}/xray-scan.json}"
PROJECT_FLAG=""
[ -n "${ARTIFACTORY_PROJECT:-}" ] && PROJECT_FLAG="--project=${ARTIFACTORY_PROJECT}"

echo "→ jf docker scan --format=${SCAN_FORMAT} ${PROJECT_FLAG} ${SCAN_REF}"
set +e
# shellcheck disable=SC2086
jf docker scan ${PROJECT_FLAG} \
  --format="${SCAN_FORMAT}" \
  --fail=false \
  "${SCAN_REF}" \
  > "${SCAN_FILE}" 2>/tmp/xray-vuln.err
SCAN_RC=$?
set -e

if [ ! -s "${SCAN_FILE}" ]; then
  echo "WARN: jf docker scan produced no output (rc=${SCAN_RC}) — continuing" >&2
  sed 's/^/  /' /tmp/xray-vuln.err >&2 || true
  exit 0
fi
echo "  ✓ vuln scan: ${SCAN_FILE} ($(wc -c < "${SCAN_FILE}") bytes, rc=${SCAN_RC})"

# ── Ship to Splunk HEC (no-op when unset) ─────────────────────────
# Build the event content (scanned_image + git_commit + xray scan
# nested under .xray) and hand to the shared poster.
GIT_SHA="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
EVENT_FILE=$(mktemp)
trap 'rm -f "${EVENT_FILE}"' EXIT
jq -nc \
  --arg image  "${SCAN_REF}" \
  --arg gitsha "${GIT_SHA}" \
  --slurpfile xray "${SCAN_FILE}" \
  '{ scanned_image: $image, git_commit: $gitsha, xray: $xray[0] }' \
  > "${EVENT_FILE}"

# shellcheck source=../lib/splunk-hec.sh
. "${REPO_ROOT}/scripts/lib/splunk-hec.sh"
splunk_hec_post "${EVENT_FILE}" "${SPLUNK_HEC_SOURCETYPE:-jfrog:xray:scan}" || true
