#!/usr/bin/env bash
# Post a CycloneDX SBOM to an ingestion endpoint.
#
# Called from the pipeline after `syft` generates sbom.cdx.json. This
# script is intentionally scaffolded even when no endpoint is configured
# — when the business decides which SBOM platform to adopt, add the
# relevant variables and this script will start shipping. No code
# change required.
#
# ── Where do the sink env vars come from? ────────────────────────────
# Any of: shell / CI env, image.env (gitignored), or image.env.example
# (tracked). Precedence: shell > image.env > image.env.example. In CI
# these are typically masked group/project variables; locally they
# usually sit in image.env. See image.env.example for descriptions.
# This script doesn't source anything itself — callers export the
# relevant vars (or let build.sh's shell-snapshot propagate them) and
# then invoke `./scripts/sbom-post.sh <cdx.json>`.
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
#   Splunk HEC (audit-trail ingestion; the SBOM goes inside the HEC
#   `event` field, sourcetype defaults to "cyclonedx:json" — vendor-
#   neutral so the same sourcetype handles Syft-, Xray-, and Trivy-
#   generated SBOMs):
#     SPLUNK_HEC_URL            HEC base URL (we append /services/collector
#                               if missing). e.g. https://splunk.example.com:8088
#     SPLUNK_HEC_TOKEN          HEC token. Sent as `Authorization: Splunk <token>`.
#     SPLUNK_HEC_INDEX          target index. Default: main
#     SPLUNK_SBOM_SOURCETYPE    sourcetype tag. Default: cyclonedx:json
#                               (separate from SPLUNK_HEC_SOURCETYPE which
#                               xray-scan-post.sh uses for vuln events)
#     SPLUNK_HEC_INSECURE       "true" → curl -k. Default: false
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

# Per-run temp directory — avoids /tmp collisions if multiple jobs run
# in parallel.
_SBOM_TMPDIR=$(mktemp -d)
trap 'rm -rf "${_SBOM_TMPDIR}"' EXIT

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
  if [ -n "${UPSTREAM_TAG:-}" ]; then
    HEADERS+=(-H "X-Image-Version: ${UPSTREAM_TAG}")
  fi
  if curl -fsSL -X POST "${HEADERS[@]}" --data-binary "@${SBOM_FILE}" "${SBOM_WEBHOOK_URL}" -o ${_SBOM_TMPDIR}/webhook-response.txt 2>&1; then
    echo "  ✓ posted ($(wc -c < ${_SBOM_TMPDIR}/webhook-response.txt) bytes response)"
    did_post=$((did_post + 1))
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
    DT_VERSION="${UPSTREAM_TAG:-latest}"
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
         "${DEPENDENCY_TRACK_URL%/}/api/v1/bom" -o ${_SBOM_TMPDIR}/dt-response.txt; then
      echo "  ✓ uploaded to project '${DEPENDENCY_TRACK_PROJECT}' v${DT_VERSION}"
      echo "    response: $(cat ${_SBOM_TMPDIR}/dt-response.txt)"
      did_post=$((did_post + 1))
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
    # IMAGE_NAME from build.env may include the full registry path
    # (e.g. registry.example.com/project/nginx). Extract the short name.
    IMG="${IMAGE_NAME:-image}"
    IMG="${IMG##*/}"
    # Use IMAGE_TAG (includes git hash, e.g. 1.29.8-alpine-5d3ea65) for
    # 1:1 mapping between SBOM and pushed image. Falls back to upstream
    # tag if IMAGE_TAG isn't set.
    VER="${IMAGE_TAG:-${UPSTREAM_TAG:-latest}}"
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
         "${DEPLOY_URL}" -o ${_SBOM_TMPDIR}/art-response.txt; then
      echo "  ✓ deployed — Xray will auto-index"
      if command -v jq >/dev/null 2>&1 && [ -s ${_SBOM_TMPDIR}/art-response.txt ]; then
        URI=$(jq -r '.uri // empty' ${_SBOM_TMPDIR}/art-response.txt 2>/dev/null || echo "")
        [ -n "${URI}" ] && echo "    uri: ${URI}"
      fi
      # Tag the Docker manifest with sbom.path for cross-reference.
      # Uses Artifactory property search API to find the manifest, then
      # sets sbom.path via REST. Does not depend on jf config state.
      if [ -n "${IMAGE_TAG:-}" ]; then
        _art_base="${ARTIFACTORY_URL%/}/artifactory"
        _manifest_path=$(curl -sS -u "${ARTIFACTORY_USER}:${ART_SECRET}" \
          "${_art_base}/api/search/prop?docker.manifest=${IMAGE_TAG}" 2>/dev/null \
          | python3 -c "
import json,sys
d=json.load(sys.stdin)
for r in d.get('results',[]):
    uri=r.get('uri','')
    if 'manifest.json' in uri:
        parts=uri.split('/api/storage/')
        if len(parts)==2: print(parts[1]); break
" 2>/dev/null || echo "")
        if [ -n "${_manifest_path}" ]; then
          _prop_code=$(curl -sS -o /dev/null -w "%{http_code}" \
            -u "${ARTIFACTORY_USER}:${ART_SECRET}" \
            -X PUT "${_art_base}/api/storage/${_manifest_path}?properties=sbom.path=${DEPLOY_PATH}" 2>/dev/null)
          if [ "${_prop_code}" = "204" ]; then
            echo "    sbom.path property set on ${_manifest_path}"
          else
            echo "    WARN: could not set sbom.path (HTTP ${_prop_code})" >&2
          fi
        fi
      fi
      did_post=$((did_post + 1))
    else
      echo "  ✗ Artifactory SBOM upload failed" >&2
      cat ${_SBOM_TMPDIR}/art-response.txt >&2 2>/dev/null || true
      failures=$((failures + 1))
    fi
  fi
fi

# ── Splunk HEC ──────────────────────────────────────────────────────
# Vendor-agnostic — this sink doesn't care if the SBOM came from Syft,
# Xray, Trivy, or anything else, as long as it's CycloneDX. Each event
# carries the source filename + image ref + git commit so consumers
# can correlate across multiple generators.
if [ -n "${SPLUNK_HEC_URL:-}" ] && [ -n "${SPLUNK_HEC_TOKEN:-}" ]; then
  HEC_URL="${SPLUNK_HEC_URL%/}"
  case "${HEC_URL}" in
    */services/collector|*/services/collector/event) ;;
    *) HEC_URL="${HEC_URL}/services/collector" ;;
  esac

  HEC_INDEX="${SPLUNK_HEC_INDEX:-main}"
  HEC_SOURCETYPE="${SPLUNK_SBOM_SOURCETYPE:-cyclonedx:json}"
  HEC_INSECURE_FLAG=""
  [ "${SPLUNK_HEC_INSECURE:-false}" = "true" ] && HEC_INSECURE_FLAG="-k"

  GIT_SHA_HEC="${GIT_SHA:-$(git rev-parse HEAD 2>/dev/null || echo unknown)}"
  IMAGE_REF_HEC="${IMAGE_REF:-${UPSTREAM_REGISTRY:-}/${UPSTREAM_IMAGE:-}:${UPSTREAM_TAG:-}}"

  echo "→ POST SBOM to Splunk HEC: ${HEC_URL} (sourcetype=${HEC_SOURCETYPE})"

  if ! command -v jq >/dev/null 2>&1; then
    echo "  ✗ jq required for Splunk HEC envelope construction" >&2
    failures=$((failures + 1))
  else
    # Write payload to a tmp FILE (not via "$VAR") because SBOM
    # envelopes routinely exceed the OS argv limit (E2BIG / "Argument
    # list too long" — Linux ARG_MAX minus env is often <500 KB).
    # `--data-binary @file` avoids the limit entirely.
    jq -nc \
      --arg sourcetype "${HEC_SOURCETYPE}" \
      --arg index      "${HEC_INDEX}" \
      --arg source     "container-image-template/sbom-post.sh" \
      --arg host       "${HOSTNAME:-$(uname -n)}" \
      --arg sbom_file  "${SBOM_FILE##*/}" \
      --arg image      "${IMAGE_REF_HEC}" \
      --arg gitsha     "${GIT_SHA_HEC}" \
      --slurpfile bom  "${SBOM_FILE}" \
      '{
         sourcetype: $sourcetype,
         index:      $index,
         source:     $source,
         host:       $host,
         event: {
           sbom_file:     $sbom_file,
           scanned_image: $image,
           git_commit:    $gitsha,
           cyclonedx:     $bom[0]
         }
       }' > ${_SBOM_TMPDIR}/hec-payload.json

    HEC_HTTP_CODE=$(curl -sS -o ${_SBOM_TMPDIR}/hec-response.txt -w '%{http_code}' \
      ${HEC_INSECURE_FLAG} \
      -X POST "${HEC_URL}" \
      -H "Authorization: Splunk ${SPLUNK_HEC_TOKEN}" \
      -H 'Content-Type: application/json' \
      --data-binary "@${_SBOM_TMPDIR}/hec-payload.json" \
      || echo '000')
    case "${HEC_HTTP_CODE}" in
      2*)
        echo "  ✓ posted to Splunk HEC (HTTP ${HEC_HTTP_CODE})"
        did_post=$((did_post + 1))
        ;;
      *)
        # Audit shipping is non-blocking — warn but don't fail the
        # whole sbom-post run. Other sinks may still want to succeed.
        echo "  WARN: Splunk HEC POST failed (HTTP ${HEC_HTTP_CODE}) — continuing" >&2
        sed 's/^/    /' ${_SBOM_TMPDIR}/hec-response.txt >&2 2>/dev/null || true
        ;;
    esac
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
  echo "    - SPLUNK_HEC_URL + SPLUNK_HEC_TOKEN"
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
