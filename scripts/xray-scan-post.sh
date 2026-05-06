#!/usr/bin/env bash
# xray-scan-post.sh — run `jf docker scan` and (optionally) ship JSON to Splunk.
#
# Mirrors the shape of scripts/sbom-post.sh: invoked as a standalone
# CI stage AFTER the upstream image is reachable, side-effect-only.
# Intended to give SecOps an audit trail of every Xray scan against
# the bases the platform pulls in.
#
# Two-phase: SCAN, then SHIP. Each has its own preconditions; either
# can no-op independently.
#
#   - SCAN preconditions: ARTIFACTORY_URL + ARTIFACTORY_USER +
#     (ARTIFACTORY_TOKEN or ARTIFACTORY_PASSWORD). When set, the
#     script installs jf if missing, runs `jf config add`, and writes
#     xray-scan.json. The JSON is the artifact value regardless of
#     whether Splunk is configured.
#
#   - SHIP preconditions: SPLUNK_HEC_URL + SPLUNK_HEC_TOKEN. When set,
#     the JSON is wrapped in a HEC envelope and POSTed to Splunk.
#     POST failure becomes a warning (audit is a side-effect, not the
#     build's purpose). When unset, the script just says "JSON saved,
#     not shipped" and exits 0.
#
# Usage:
#   bash scripts/xray-scan-post.sh                 # scan UPSTREAM_REF
#   bash scripts/xray-scan-post.sh <image-ref>     # scan an arbitrary ref
#
# Required env (no-op if any are unset):
#   ARTIFACTORY_URL         e.g. https://artifactory.example.com
#   ARTIFACTORY_USER        Xray-scan user
#   ARTIFACTORY_TOKEN       access token (preferred), OR
#   ARTIFACTORY_PASSWORD    basic-auth password
#
# Optional env (Splunk side — when set, also ships):
#   SPLUNK_HEC_URL          HEC endpoint base
#   SPLUNK_HEC_TOKEN        HEC token
#   SPLUNK_HEC_INDEX        target index. Default: main
#   SPLUNK_HEC_SOURCETYPE   sourcetype. Default: jfrog:xray:scan
#   SPLUNK_HEC_INSECURE     "true" → curl -k. Default: false
#
# Optional env (scan side):
#   UPSTREAM_REF            full <registry>/<image>:<tag> to scan when no
#                           positional arg is given. Falls back to
#                           UPSTREAM_REGISTRY/UPSTREAM_IMAGE:UPSTREAM_TAG.
#   XRAY_SCAN_FILE          where to write the raw JSON. Default:
#                           xray-scan.json (in REPO_ROOT)
#   XRAY_SCAN_FORMAT        simple-json (default — flat, Splunk-friendly)
#                           or json (richer Xray structure, nested)
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

# ── Phase 1 preconditions: scan needs Artifactory credentials ──────
ART_SECRET="${ARTIFACTORY_TOKEN:-${ARTIFACTORY_PASSWORD:-}}"
if [ -z "${ARTIFACTORY_URL:-}" ] || [ -z "${ARTIFACTORY_USER:-}" ] || [ -z "${ART_SECRET}" ]; then
  echo "→ xray-scan-post: ARTIFACTORY_URL / ARTIFACTORY_USER / ARTIFACTORY_TOKEN unset — no-op"
  echo "  (configure all three to enable Xray scanning + JSON artifact)"
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

# ── Configure jf to talk to Artifactory ────────────────────────────
# Sanitise URL: strip trailing slash, ensure single /artifactory suffix.
_url="${ARTIFACTORY_URL%/}"
if [[ "${_url}" == */artifactory ]]; then
  _art_url="${_url}"
  _platform_url="${_url%/artifactory}"
else
  _art_url="${_url}/artifactory"
  _platform_url="${_url}"
fi

if [ -n "${ARTIFACTORY_TOKEN:-}" ]; then
  _auth_flag="--access-token=${ARTIFACTORY_TOKEN}"
else
  _auth_flag="--password=${ARTIFACTORY_PASSWORD}"
fi

# shellcheck disable=SC2086
jf config add xray-scan-post-server \
  --url="${_platform_url}" \
  --artifactory-url="${_art_url}" \
  --user="${ARTIFACTORY_USER}" \
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

echo "  ✓ scan output: ${SCAN_FILE} ($(wc -c < "${SCAN_FILE}") bytes, rc=${SCAN_RC})"

# ── Phase 2 preconditions: ship to Splunk only when both vars set ──
if [ -z "${SPLUNK_HEC_URL:-}" ] || [ -z "${SPLUNK_HEC_TOKEN:-}" ]; then
  echo "→ Splunk HEC: SPLUNK_HEC_URL or SPLUNK_HEC_TOKEN unset — JSON saved as artifact, not shipped"
  exit 0
fi

# ── Ship to Splunk HEC ──────────────────────────────────────────────
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

# Build the HEC envelope. The Xray JSON goes inside `event` so Splunk
# auto-extracts fields. `host`, `time`, `source` are HEC metadata.
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

echo "→ POST ${HEC_URL} (index=${INDEX} sourcetype=${SOURCETYPE})"
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
    # Audit shipping is a side-effect, not the build's purpose. A
    # Splunk outage shouldn't block the image build/push pipeline —
    # warn and exit 0. Configure CI to treat job failures as warnings
    # if you'd rather see this in the dashboard. The scan JSON is
    # still on disk (${SCAN_FILE}) and an artifact, so it can be
    # re-shipped manually if HEC was down.
    echo "  WARN: Splunk HEC POST failed (HTTP ${HTTP_CODE}) — continuing" >&2
    echo "── response ──" >&2
    sed 's/^/  /' /tmp/xray-hec.resp >&2 || true
    ;;
esac
