#!/usr/bin/env bash
# Post a CycloneDX SBOM to an ingestion endpoint.
#
# Called from the pipeline after `syft` generates sbom.cdx.json. This
# script is intentionally scaffolded even when no endpoint is configured
# — when the business decides which SBOM platform to adopt, add the
# relevant CI variables and this script will start shipping. No code
# change required.
#
# Supported sinks (set one or more):
#
#   Generic webhook (raw CycloneDX JSON body):
#     SBOM_WEBHOOK_URL          full URL accepting a POST
#     SBOM_WEBHOOK_AUTH_HEADER  optional, e.g. "Authorization: Bearer xxx"
#
#   OWASP Dependency-Track (the de-facto standard for SBOM + CVE
#   correlation; scales to enterprise and produces webhook
#   notifications on new CVEs matching previously-uploaded BOMs):
#     DEPENDENCY_TRACK_URL      e.g. https://dtrack.example.com
#     DEPENDENCY_TRACK_API_KEY  BOM upload API key
#     DEPENDENCY_TRACK_PROJECT  project name (autoCreate=true will
#                               create it on first upload)
#
#   JFrog Artifactory Pro + Xray (native SBOM ingestion — upload a
#   CycloneDX file with .cdx.json suffix to an indexed generic repo;
#   Xray auto-indexes and scans it, results appear in Scans → SBOM
#   Imports. No extra server-side integration needed. Xray licence
#   required for the indexing half to do anything useful.):
#     ARTIFACTORY_URL           https://artifactory.example.com
#     ARTIFACTORY_USER          user with Deploy on the generic repo
#     ARTIFACTORY_TOKEN         access token (preferred), OR
#     ARTIFACTORY_PASSWORD      basic-auth password
#     ARTIFACTORY_SBOM_REPO     generic repo name (must be Xray-
#                               indexed), e.g. "sboms-local"
#
# Extending:
#   To add another sink (Snyk, GitLab Security Dashboard, Kafka, etc.)
#   drop a new block below following the same pattern — guard on the
#   sink's env var being set, post, report success. No sink should
#   fail the pipeline if it's unconfigured.
#
# Exit codes:
#   0  success (including "no sinks configured — nothing to do")
#   1  a configured sink returned an error

set -euo pipefail

SBOM_FILE="${1:-sbom.cdx.json}"

if [ ! -f "${SBOM_FILE}" ]; then
  echo "ERROR: SBOM file not found: ${SBOM_FILE}" >&2
  exit 1
fi

SBOM_SIZE=$(wc -c < "${SBOM_FILE}")
echo "→ SBOM: ${SBOM_FILE} (${SBOM_SIZE} bytes)"

# Load build context if present so sink metadata matches the pipeline.
if [ -f build.env ]; then
  # shellcheck disable=SC1091
  . ./build.env
fi

did_post=0
failures=0

# ── Generic webhook ─────────────────────────────────────────────────
if [ -n "${SBOM_WEBHOOK_URL:-}" ]; then
  echo "→ POST SBOM to generic webhook: ${SBOM_WEBHOOK_URL}"
  HEADERS=(-H "Content-Type: application/vnd.cyclonedx+json")
  if [ -n "${SBOM_WEBHOOK_AUTH_HEADER:-}" ]; then
    HEADERS+=(-H "${SBOM_WEBHOOK_AUTH_HEADER}")
  fi
  if [ -n "${IMAGE_DIGEST:-}" ]; then
    HEADERS+=(-H "X-Image-Digest: ${IMAGE_DIGEST}")
  fi
  if [ -n "${INTERNAL_VERSION:-}" ]; then
    HEADERS+=(-H "X-Image-Version: ${INTERNAL_VERSION}")
  fi
  if curl -fsSL -X POST "${HEADERS[@]}" --data-binary "@${SBOM_FILE}" "${SBOM_WEBHOOK_URL}" -o /tmp/webhook-response.txt 2>&1; then
    echo "  ✓ posted ($(wc -c < /tmp/webhook-response.txt) bytes response)"
    did_post=1
  else
    echo "  ✗ webhook POST failed" >&2
    failures=$((failures + 1))
  fi
fi

# ── OWASP Dependency-Track ──────────────────────────────────────────
if [ -n "${DEPENDENCY_TRACK_URL:-}" ] && [ -n "${DEPENDENCY_TRACK_API_KEY:-}" ]; then
  echo "→ Upload SBOM to Dependency-Track: ${DEPENDENCY_TRACK_URL}"

  if [ -z "${DEPENDENCY_TRACK_PROJECT:-}" ]; then
    echo "  ✗ DEPENDENCY_TRACK_PROJECT not set — skipping" >&2
    failures=$((failures + 1))
  else
    DT_VERSION="${INTERNAL_VERSION:-latest}"
    # DT /api/v1/bom expects a JSON body with base64-encoded bom.
    # `jq -Rs .` handles the escaping for us reliably.
    if command -v jq >/dev/null 2>&1; then
      BOM_B64=$(base64 < "${SBOM_FILE}" | tr -d '\n')
      PAYLOAD=$(jq -nc \
        --arg name "${DEPENDENCY_TRACK_PROJECT}" \
        --arg ver "${DT_VERSION}" \
        --arg bom "${BOM_B64}" \
        '{projectName:$name,projectVersion:$ver,autoCreate:true,bom:$bom}')
    else
      BOM_B64=$(base64 < "${SBOM_FILE}" | tr -d '\n')
      PAYLOAD="{\"projectName\":\"${DEPENDENCY_TRACK_PROJECT}\",\"projectVersion\":\"${DT_VERSION}\",\"autoCreate\":true,\"bom\":\"${BOM_B64}\"}"
    fi

    if curl -fsSL -X POST \
         -H "X-Api-Key: ${DEPENDENCY_TRACK_API_KEY}" \
         -H "Content-Type: application/json" \
         --data "${PAYLOAD}" \
         "${DEPENDENCY_TRACK_URL%/}/api/v1/bom" -o /tmp/dt-response.txt; then
      echo "  ✓ uploaded to project '${DEPENDENCY_TRACK_PROJECT}' v${DT_VERSION}"
      echo "    response: $(cat /tmp/dt-response.txt)"
      did_post=1
    else
      echo "  ✗ Dependency-Track upload failed" >&2
      failures=$((failures + 1))
    fi
  fi
fi

# ── JFrog Artifactory Pro + Xray (native SBOM indexing) ─────────────
# Xray picks up any .cdx.json uploaded to an indexed generic repo and
# runs its scanner against the bill of materials. We PUT the file at
# a predictable path so it's easy to find in the Artifactory UI:
#   <repo>/<image-name>/<version>/sbom.cdx.json
# Xray catalogs it under Scans → SBOM Imports on first upload, and
# correlates repeat uploads against the same project/version.
if [ -n "${ARTIFACTORY_URL:-}" ] && [ -n "${ARTIFACTORY_USER:-}" ] \
   && [ -n "${ARTIFACTORY_SBOM_REPO:-}" ]; then
  ART_SECRET="${ARTIFACTORY_TOKEN:-${ARTIFACTORY_PASSWORD:-}}"
  if [ -z "${ART_SECRET}" ]; then
    echo "  ✗ Artifactory SBOM sink: no ARTIFACTORY_TOKEN or ARTIFACTORY_PASSWORD" >&2
    failures=$((failures + 1))
  else
    IMG="${IMAGE_NAME:-image}"
    VER="${INTERNAL_VERSION:-latest}"
    DEPLOY_PATH="${ARTIFACTORY_SBOM_REPO}/${IMG}/${VER}/sbom.cdx.json"
    DEPLOY_URL="${ARTIFACTORY_URL%/}/artifactory/${DEPLOY_PATH}"
    echo "→ Upload SBOM to Artifactory Xray: ${DEPLOY_PATH}"

    # Compute SHA-1 + SHA-256 checksums for the X-Checksum headers.
    # Artifactory will reject the PUT if the body doesn't match.
    SHA1=$(shasum -a 1 "${SBOM_FILE}" 2>/dev/null | awk '{print $1}')
    SHA256=$(shasum -a 256 "${SBOM_FILE}" 2>/dev/null | awk '{print $1}')
    # Fallback to sha1sum/sha256sum on Linux runners
    [ -z "${SHA1}" ] && SHA1=$(sha1sum "${SBOM_FILE}" | awk '{print $1}')
    [ -z "${SHA256}" ] && SHA256=$(sha256sum "${SBOM_FILE}" | awk '{print $1}')

    if curl -fsSL -X PUT \
         -u "${ARTIFACTORY_USER}:${ART_SECRET}" \
         -H "Content-Type: application/vnd.cyclonedx+json" \
         -H "X-Checksum-Sha1: ${SHA1}" \
         -H "X-Checksum-Sha256: ${SHA256}" \
         --data-binary "@${SBOM_FILE}" \
         "${DEPLOY_URL}" -o /tmp/art-response.txt; then
      echo "  ✓ deployed — Xray will auto-index"
      if command -v jq >/dev/null 2>&1 && [ -s /tmp/art-response.txt ]; then
        URI=$(jq -r '.uri // empty' /tmp/art-response.txt 2>/dev/null || echo "")
        [ -n "${URI}" ] && echo "    uri: ${URI}"
      fi
      did_post=1
    else
      echo "  ✗ Artifactory SBOM upload failed" >&2
      cat /tmp/art-response.txt >&2 2>/dev/null || true
      failures=$((failures + 1))
    fi
  fi
fi

# ── Summary ─────────────────────────────────────────────────────────
if [ ${did_post} -eq 0 ] && [ ${failures} -eq 0 ]; then
  echo ""
  echo "SBOM post-processing: no sinks configured."
  echo "  To enable ingestion, set one of:"
  echo "    - SBOM_WEBHOOK_URL (+ optional SBOM_WEBHOOK_AUTH_HEADER)"
  echo "    - DEPENDENCY_TRACK_URL + DEPENDENCY_TRACK_API_KEY + DEPENDENCY_TRACK_PROJECT"
  echo "    - ARTIFACTORY_URL + ARTIFACTORY_USER + ARTIFACTORY_TOKEN/PASSWORD + ARTIFACTORY_SBOM_REPO"
  echo "  SBOM was still generated and is available as a pipeline artifact."
  exit 0
fi

if [ ${failures} -gt 0 ]; then
  echo ""
  echo "ERROR: ${failures} sink(s) failed" >&2
  exit 1
fi

echo ""
echo "SBOM post-processing: ${did_post} sink(s) succeeded"
