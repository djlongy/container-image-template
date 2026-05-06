#!/usr/bin/env bash
# xray-scan-post.sh — run `jf docker scan` for both vulns AND SBOM,
# then ship to configured downstream sinks. Designed to fill the gap
# left by Trivy in environments where Trivy is banned and Syft/Grype
# are awaiting security approval — Xray covers both halves of what
# Trivy used to do (prescan vulns + CycloneDX SBOM emission).
#
# Three phases, each gated by its own preconditions; any phase can
# no-op independently without failing the others.
#
#   PHASE 1: VULN SCAN
#     Preconditions: ARTIFACTORY_URL + ARTIFACTORY_USER +
#       (ARTIFACTORY_TOKEN or ARTIFACTORY_PASSWORD)
#     Runs `jf docker scan --format=simple-json` against the target,
#     writes xray-scan.json (rich vuln data with Advanced Security
#     applicability info). Then ships to Splunk HEC if configured.
#
#   PHASE 2: SBOM (CycloneDX)
#     Preconditions: same as PHASE 1, plus XRAY_GENERATE_SBOM != false.
#     Runs `jf docker scan --format=cyclonedx --sbom` against the
#     same target, writes xray-sbom.cdx.json (CycloneDX 1.6 BOM with
#     full component inventory). Then invokes scripts/sbom-post.sh
#     against the file — that's where vendor-neutral sink shipping
#     happens (Splunk, Dependency-Track, Artifactory, webhook).
#
#   PHASE 3: SPLUNK SHIP (vuln scan only)
#     Preconditions: SPLUNK_HEC_URL + SPLUNK_HEC_TOKEN. Wraps the
#     PHASE 1 vuln JSON in a HEC envelope and POSTs. SBOM shipping
#     happens via PHASE 2's sbom-post.sh handoff (which has its own
#     Splunk sink, vendor-neutral sourcetype `cyclonedx:sbom`).
#
# Usage:
#   bash scripts/xray-scan-post.sh                 # scan UPSTREAM_REF
#   bash scripts/xray-scan-post.sh <image-ref>     # scan arbitrary ref
#
# Required env (no-op if any are unset):
#   ARTIFACTORY_URL         e.g. https://artifactory.example.com
#   ARTIFACTORY_USER        Xray-scan user
#   ARTIFACTORY_TOKEN       access token (preferred), OR
#   ARTIFACTORY_PASSWORD    basic-auth password
#
# Optional env (Splunk side — when set, vuln JSON also ships to HEC):
#   SPLUNK_HEC_URL          HEC endpoint base
#   SPLUNK_HEC_TOKEN        HEC token
#   SPLUNK_HEC_INDEX        target index. Default: main
#   SPLUNK_HEC_SOURCETYPE   sourcetype for vuln events. Default:
#                           jfrog:xray:scan
#   SPLUNK_HEC_INSECURE     "true" → curl -k. Default: false
#   (SBOM events use SPLUNK_SBOM_SOURCETYPE — defined in sbom-post.sh,
#    defaults to "cyclonedx:sbom")
#
# Optional env (scan side):
#   UPSTREAM_REF            full <registry>/<image>:<tag> to scan when no
#                           positional arg is given. Falls back to
#                           UPSTREAM_REGISTRY/UPSTREAM_IMAGE:UPSTREAM_TAG.
#   XRAY_SCAN_FILE          where to write the vuln JSON. Default:
#                           xray-scan.json (in REPO_ROOT)
#   XRAY_SBOM_FILE          where to write the CycloneDX SBOM. Default:
#                           xray-sbom.cdx.json (in REPO_ROOT). The
#                           .cdx.json suffix is required for Artifactory
#                           Xray's auto-indexing if you ship it there.
#   XRAY_SCAN_FORMAT        simple-json (default — rich vuln data)
#                           or json (deeper nesting, no Advanced Security)
#   XRAY_GENERATE_SBOM      "true" (default) runs PHASE 2. Set to
#                           "false" to skip SBOM generation entirely
#                           — useful when Syft is producing the SBOM
#                           and you don't need an Xray duplicate.
#                           Each phase costs ~1 full Xray scan.
#   ARTIFACTORY_PROJECT     pass-through to `jf docker scan --project`

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── Resolve target ref ─────────────────────────────────────────────
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
  echo "       (or UPSTREAM_REGISTRY + UPSTREAM_IMAGE + UPSTREAM_TAG)" >&2
  exit 1
fi

# ── Phase 1 preconditions: scan needs Artifactory + Xray credentials ──
# Two sets of env var names accepted, in precedence order:
#   1. XRAY_ARTIFACTORY_URL/USER/TOKEN (or PASSWORD) — explicit override.
#      Use this when the Artifactory you push to (no Xray license, e.g.
#      JCR Free) is different from the Artifactory that runs Xray (Pro
#      or Cloud trial).
#   2. ARTIFACTORY_URL/USER/TOKEN — fall back to the same instance the
#      push backend uses. Works when one Artifactory does both jobs.
SCAN_ART_URL="${XRAY_ARTIFACTORY_URL:-${ARTIFACTORY_URL:-}}"
SCAN_ART_USER="${XRAY_ARTIFACTORY_USER:-${ARTIFACTORY_USER:-}}"
SCAN_ART_TOKEN="${XRAY_ARTIFACTORY_TOKEN:-${ARTIFACTORY_TOKEN:-}}"
SCAN_ART_PASSWORD="${XRAY_ARTIFACTORY_PASSWORD:-${ARTIFACTORY_PASSWORD:-}}"
ART_SECRET="${SCAN_ART_TOKEN:-${SCAN_ART_PASSWORD}}"
if [ -z "${SCAN_ART_URL}" ] || [ -z "${SCAN_ART_USER}" ] || [ -z "${ART_SECRET}" ]; then
  echo "→ xray-scan-post: Xray-side Artifactory creds unset — no-op"
  echo "  (set either XRAY_ARTIFACTORY_URL/USER/TOKEN or ARTIFACTORY_URL/USER/TOKEN"
  echo "   to enable Xray scanning + JSON artifact)"
  exit 0
fi

# ── jf must be on PATH; install via shared helper if not ───────────
if ! command -v jf >/dev/null 2>&1; then
  if [ -f "${REPO_ROOT}/scripts/lib/install-jf.sh" ]; then
    # shellcheck source=lib/install-jf.sh
    . "${REPO_ROOT}/scripts/lib/install-jf.sh"
    install_jf || {
      echo "WARN: jf install failed — skipping Xray scan" >&2
      exit 0
    }
  else
    echo "WARN: jf not on PATH and helper missing — skipping Xray scan" >&2
    exit 0
  fi
fi

# ── Configure jf to talk to the SCAN-side Artifactory ─────────────
# Uses SCAN_ART_* (which already resolved XRAY_ARTIFACTORY_* with
# fallback to ARTIFACTORY_*) — NOT the bare ARTIFACTORY_* names. That
# distinction matters when push-side Artifactory has no Xray license
# (e.g. JCR Free) and a separate scan-side instance has it (Pro/Cloud).
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

echo "→ jf config add xray-scan-post-server (url=${_platform_url}, user=${SCAN_ART_USER})"

# shellcheck disable=SC2086
jf config add xray-scan-post-server \
  --url="${_platform_url}" \
  --artifactory-url="${_art_url}" \
  --user="${SCAN_ART_USER}" \
  ${_auth_flag} \
  --interactive=false \
  --overwrite=true >/dev/null
jf config use xray-scan-post-server >/dev/null

# ── Run the scan ────────────────────────────────────────────────────
SCAN_FORMAT="${XRAY_SCAN_FORMAT:-simple-json}"
SCAN_FILE="${XRAY_SCAN_FILE:-${REPO_ROOT}/xray-scan.json}"
PROJECT_FLAG=""
[ -n "${ARTIFACTORY_PROJECT:-}" ] && PROJECT_FLAG="--project=${ARTIFACTORY_PROJECT}"

echo "→ jf docker scan --format=${SCAN_FORMAT} ${PROJECT_FLAG} ${SCAN_REF}"
# `jf docker scan` exits non-zero when violations are found even with
# --fail=false in some CLI versions; capture rc and proceed unless
# the JSON is empty (the artifact is the priority here).
set +e
# shellcheck disable=SC2086
jf docker scan ${PROJECT_FLAG} \
  --format="${SCAN_FORMAT}" \
  --fail=false \
  "${SCAN_REF}" \
  > "${SCAN_FILE}" 2>/tmp/xray-scan.err
SCAN_RC=$?
set -e

if [ ! -s "${SCAN_FILE}" ]; then
  echo "WARN: jf docker scan produced no output (rc=${SCAN_RC}) — continuing" >&2
  echo "── stderr ──" >&2
  sed 's/^/  /' /tmp/xray-scan.err >&2 || true
  # Still exit 0 — Xray could be temporarily offline / re-indexing,
  # which shouldn't block the build pipeline.
  exit 0
fi

echo "  ✓ vuln scan: ${SCAN_FILE} ($(wc -c < "${SCAN_FILE}") bytes, rc=${SCAN_RC})"

# ── Phase 2: ship vuln JSON to Splunk HEC (if configured) ──────────
if [ -n "${SPLUNK_HEC_URL:-}" ] && [ -n "${SPLUNK_HEC_TOKEN:-}" ]; then
  HEC_URL="${SPLUNK_HEC_URL%/}"
  case "${HEC_URL}" in
    */services/collector|*/services/collector/event) ;;
    *) HEC_URL="${HEC_URL}/services/collector" ;;
  esac

  INDEX="${SPLUNK_HEC_INDEX:-main}"
  SOURCETYPE="${SPLUNK_HEC_SOURCETYPE:-jfrog:xray:scan}"
  INSECURE_FLAG=""
  [ "${SPLUNK_HEC_INSECURE:-false}" = "true" ] && INSECURE_FLAG="-k"

  GIT_SHA="$(git -C "${REPO_ROOT}" rev-parse HEAD 2>/dev/null || echo 'unknown')"

  # Build the HEC envelope. The Xray JSON goes inside `event` so
  # Splunk auto-extracts fields. host/time/source are HEC metadata.
  HEC_PAYLOAD="$(
    jq -nc \
      --arg sourcetype "${SOURCETYPE}" \
      --arg index      "${INDEX}" \
      --arg source     "container-image-template/xray-scan-post.sh" \
      --arg host       "${HOSTNAME:-$(uname -n)}" \
      --arg image      "${SCAN_REF}" \
      --arg gitsha     "${GIT_SHA}" \
      --slurpfile event "${SCAN_FILE}" \
      '{
         sourcetype: $sourcetype,
         index:      $index,
         source:     $source,
         host:       $host,
         event: {
           scanned_image: $image,
           git_commit:    $gitsha,
           xray:          $event[0]
         }
       }'
  )"

  echo "→ POST vuln scan to ${HEC_URL} (index=${INDEX} sourcetype=${SOURCETYPE})"
  HTTP_CODE="$(
    curl -sS -o /tmp/xray-hec.resp -w '%{http_code}' \
      ${INSECURE_FLAG} \
      -X POST "${HEC_URL}" \
      -H "Authorization: Splunk ${SPLUNK_HEC_TOKEN}" \
      -H 'Content-Type: application/json' \
      --data-binary "${HEC_PAYLOAD}" \
    || echo '000'
  )"
  case "${HTTP_CODE}" in
    2*)
      echo "  ✓ posted to Splunk HEC (HTTP ${HTTP_CODE})"
      ;;
    *)
      echo "  WARN: Splunk HEC POST failed (HTTP ${HTTP_CODE}) — continuing" >&2
      echo "── response ──" >&2
      sed 's/^/  /' /tmp/xray-hec.resp >&2 || true
      ;;
  esac
else
  echo "→ Splunk HEC: SPLUNK_HEC_URL or SPLUNK_HEC_TOKEN unset — vuln JSON saved as artifact, not shipped"
fi

# ── Phase 3: CycloneDX SBOM via second jf docker scan ──────────────
# Default ON because in environments where Trivy is banned and Syft is
# awaiting approval, this is the only working SBOM source. Set
# XRAY_GENERATE_SBOM=false to skip when Syft is producing the SBOM
# and an Xray duplicate isn't needed (each call costs one full Xray
# scan — Xray doesn't cache between format invocations).
if [ "${XRAY_GENERATE_SBOM:-true}" = "false" ]; then
  echo "→ XRAY_GENERATE_SBOM=false — skipping SBOM phase"
  exit 0
fi

SBOM_FILE_OUT="${XRAY_SBOM_FILE:-${REPO_ROOT}/xray-sbom.cdx.json}"
echo ""
echo "→ jf docker scan --format=cyclonedx --sbom ${PROJECT_FLAG} ${SCAN_REF}"
echo "  (CycloneDX 1.6 SBOM — fills the Trivy gap until Syft is approved)"
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
  echo "WARN: jf docker scan (cyclonedx) produced no output (rc=${SBOM_RC}) — SBOM phase skipped" >&2
  echo "── stderr ──" >&2
  sed 's/^/  /' /tmp/xray-sbom.err >&2 || true
  exit 0
fi

# Sanity-check the output is valid JSON (jf occasionally emits warnings
# above the JSON in some paths). If the file doesn't parse, log it and
# still keep the file as artifact for inspection.
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

# ── Phase 4: hand off SBOM to sbom-post.sh ─────────────────────────
# sbom-post.sh is vendor-agnostic — it doesn't care that Xray made
# this BOM rather than Syft. Same downstream sinks (Splunk, DT,
# Artifactory, generic webhook), same auth. If you've also got a
# Syft-generated SBOM in the same pipeline, both flow through the
# same script and sinks; consumers correlate via the SBOM file's
# embedded metadata + the HEC envelope's `sbom_file` field.
if [ -f "${REPO_ROOT}/scripts/sbom-post.sh" ]; then
  echo ""
  echo "→ Handoff to sbom-post.sh for sink shipping"
  bash "${REPO_ROOT}/scripts/sbom-post.sh" "${SBOM_FILE_OUT}" || {
    echo "WARN: sbom-post.sh returned non-zero — Xray SBOM still saved as artifact" >&2
  }
else
  echo "→ scripts/sbom-post.sh missing — SBOM saved as artifact only"
fi
