#!/usr/bin/env bash
# xray-scan-post.sh — run `jf docker scan` and ship the JSON to Splunk.
#
# Mirrors the shape of scripts/sbom-post.sh: invoked as a standalone
# CI stage AFTER the upstream image is reachable, side-effect-only.
# Intended to give SecOps an audit trail of every Xray scan against
# the bases the platform pulls in.
#
# Usage:
#   bash scripts/xray-scan-post.sh                 # scan UPSTREAM_REF
#   bash scripts/xray-scan-post.sh <image-ref>     # scan an arbitrary ref
#
# Required env (no-op if any are unset — keeps this safe to wire into
# every pipeline before the Splunk side is provisioned):
#
#   SPLUNK_HEC_URL          full URL of the HEC endpoint, e.g.
#                           https://splunk.example.com:8088
#                           (we append /services/collector if missing)
#   SPLUNK_HEC_TOKEN        HEC token. Sent as `Authorization: Splunk <token>`.
#
# Optional env:
#   SPLUNK_HEC_INDEX        target index. Default: main
#   SPLUNK_HEC_SOURCETYPE   sourcetype. Default: jfrog:xray:scan
#   SPLUNK_HEC_INSECURE     "true" → curl -k (skip TLS verify). Default false.
#   UPSTREAM_REF            <registry>/<image>:<tag> to scan when no
#                           positional arg is given. Falls back to
#                           UPSTREAM_REGISTRY/UPSTREAM_IMAGE:UPSTREAM_TAG
#                           if those are set.
#   XRAY_SCAN_FILE          where to write the raw JSON. Default:
#                           xray-scan.json
#   XRAY_SCAN_FORMAT        simple-json (default — flat, Splunk-friendly)
#                           or json (richer Xray structure, deeply nested)
#   ARTIFACTORY_PROJECT     pass-through to `jf docker scan --project`
#                           when set (Artifactory project scope).
#
# This script does NOT run `jf config add` — it assumes the caller
# (build pipeline) has already pointed jf at the right Artifactory
# instance, since the same auth is needed for the docker pull.

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

# ── Splunk config — no-op if unset, mirrors sbom-post.sh ────────────
if [ -z "${SPLUNK_HEC_URL:-}" ] || [ -z "${SPLUNK_HEC_TOKEN:-}" ]; then
  echo "→ xray-scan-post: SPLUNK_HEC_URL or SPLUNK_HEC_TOKEN unset — no-op"
  echo "  (configure both to enable scan-result ingestion to Splunk)"
  exit 0
fi

# ── jf must be on PATH; install via shared helper if not ────────────
if ! command -v jf >/dev/null 2>&1; then
  if [ -f "${REPO_ROOT}/scripts/lib/install-jf.sh" ]; then
    # shellcheck source=lib/install-jf.sh
    . "${REPO_ROOT}/scripts/lib/install-jf.sh"
    install_jf || exit 1
  else
    echo "ERROR: jf not on PATH and ${REPO_ROOT}/scripts/lib/install-jf.sh missing" >&2
    exit 1
  fi
fi

# ── Run the scan ────────────────────────────────────────────────────
SCAN_FORMAT="${XRAY_SCAN_FORMAT:-simple-json}"
SCAN_FILE="${XRAY_SCAN_FILE:-${REPO_ROOT}/xray-scan.json}"
PROJECT_FLAG=""
[ -n "${ARTIFACTORY_PROJECT:-}" ] && PROJECT_FLAG="--project=${ARTIFACTORY_PROJECT}"

echo "→ jf docker scan --format=${SCAN_FORMAT} ${PROJECT_FLAG} ${SCAN_REF}"
# `jf docker scan` exits non-zero when violations are found even with
# --fail=false in some CLI versions, so capture rc and forward only
# when the JSON is missing (the audit trail is the priority here).
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
  echo "ERROR: jf docker scan produced no output (rc=${SCAN_RC})" >&2
  echo "── stderr ──" >&2
  sed 's/^/  /' /tmp/xray-scan.err >&2 || true
  exit 1
fi

echo "  ✓ scan output: ${SCAN_FILE} ($(wc -c < "${SCAN_FILE}") bytes, rc=${SCAN_RC})"

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
