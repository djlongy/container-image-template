#!/usr/bin/env bash
# Post a CycloneDX SBOM to one or more ingestion endpoints.
#
# Called from the pipeline after `syft` (or `jf docker scan`) generates
# sbom.cdx.json. This script is intentionally scaffolded even when no
# endpoint is configured — when the business decides which SBOM
# platform to adopt, populate the relevant variables and shipping
# starts. No code change required.
#
# ── Where do the sink env vars come from? ────────────────────────────
# Either shell / CI env or image.env (committed). Precedence: shell
# beats file. In CI these are typically masked group/project variables;
# locally they sit in image.env. See image.env.example for descriptions
# (template only — image.env.example is never read by the build).
#
# This script self-loads image.env via scripts/lib/load-image-env.sh —
# same pattern as build.sh and the scan scripts. URLs / repos /
# project names committed to image.env are picked up automatically;
# masked CI tokens come through via plan vars (auto-imported from
# `bamboo_FOO` → `FOO`). Callers don't relay anything by hand.
#
# ── Supported sinks (set one or more) ────────────────────────────────
#
#   Generic webhook (raw CycloneDX JSON body):
#     SBOM_WEBHOOK_URL          full URL accepting a POST
#     SBOM_WEBHOOK_AUTH_HEADER  optional, e.g. "Authorization: Bearer xxx"
#
#   OWASP Dependency-Track (de-facto enterprise SBOM platform; correlates
#   BOMs against its CVE database, fires webhooks on new matches):
#     DEPENDENCY_TRACK_URL      e.g. https://dtrack.example.com
#     DEPENDENCY_TRACK_API_KEY  BOM upload API key
#     DEPENDENCY_TRACK_PROJECT  project name (autoCreate=true on first upload)
#
#   JFrog Artifactory + Xray (native SBOM ingestion — upload a .cdx.json
#   to an Xray-indexed generic repo; Xray auto-indexes and scans it.
#   Requires Pro licence; JCR Free won't index.):
#     ARTIFACTORY_URL           https://artifactory.example.com
#     ARTIFACTORY_USER          user with Deploy on the generic repo
#     ARTIFACTORY_TOKEN         access token (preferred), OR
#     ARTIFACTORY_PASSWORD      basic-auth password
#     ARTIFACTORY_SBOM_REPO     generic repo name (must be Xray-indexed)
#
#   Splunk HEC (audit-trail ingestion; SBOM goes inside the HEC `event`
#   field, sourcetype defaults to "cyclonedx:json" — vendor-neutral):
#     SPLUNK_HEC_URL            HEC base URL (we append /services/collector)
#     SPLUNK_HEC_TOKEN          HEC token (Authorization: Splunk <token>)
#     SPLUNK_HEC_INDEX          target index. Default: main
#     SPLUNK_SBOM_SOURCETYPE    sourcetype tag. Default: cyclonedx:json
#     SPLUNK_HEC_INSECURE       "true" → curl -k. Default: false
#
# ── How each sink block is structured ────────────────────────────────
# Every block reads top-to-bottom in the same shape:
#
#   1. SKIP CHECK first — if the sink's required env vars aren't set,
#      log one "skip" line and move on. NO other work runs (no
#      checksum compute, no jq pipe, no curl). Skipping unconfigured
#      sinks first is the efficiency win.
#
#   2. Otherwise log a "POST"/"PUT" line, then run the upload inside
#      a `( ... ) || rc=$?` SUBSHELL. set -e is on, so any aux-command
#      failure (jq missing, base64 bad input, shasum unavailable)
#      exits the subshell with non-zero — but only the subshell, not
#      the whole script. The next sink still runs. This is what
#      stops "one failure blocks everything after it."
#
#   3. Tally: if the subshell exited 0 we count a posted sink; if
#      non-zero we log the failure and bump the failure counter.
#
# Adding a sink? Copy any block, change the comment header, the env
# var names, and the curl invocation. The shape stays identical.
#
# Exit codes:
#   0  success (including "no sinks configured — nothing to do")
#   1  one or more configured sinks returned an error

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=../lib/artifact-names.sh
. "${REPO_ROOT}/scripts/lib/artifact-names.sh"

# SBOM_FILE resolution (highest precedence first):
#   1. positional arg $1 (explicit caller override)
#   2. SBOM_FILE env (from build.env or scripts/lib/artifact-names.sh)
# Resolve to an absolute path BEFORE we cd anywhere so a relative arg
# keeps working from the caller's cwd.
SBOM_FILE="${1:-${SBOM_FILE}}"
case "${SBOM_FILE}" in
  /*) ;;
  *)  SBOM_FILE="$(pwd)/${SBOM_FILE}" ;;
esac
[ -f "${SBOM_FILE}" ] || { echo "ERROR: SBOM file not found: ${SBOM_FILE}" >&2; exit 1; }

cd "${REPO_ROOT}"

# Auto-import bamboo_* plan vars to bare names, then source image.env.
# Without this, sink URLs / project names committed to image.env would
# be invisible here and every sink branch would silently skip.
# shellcheck source=../lib/load-image-env.sh
. "${REPO_ROOT}/scripts/lib/load-image-env.sh"
import_bamboo_vars
load_image_env

# Pull build.env if the build job exported one — gives sinks IMAGE_REF,
# IMAGE_DIGEST, IMAGE_TAG, IMAGE_NAME, GIT_SHA for richer metadata.
[ -f build.env ] && . ./build.env

_TMP=$(mktemp -d)
trap 'rm -rf "${_TMP}"' EXIT

echo "→ SBOM: ${SBOM_FILE} ($(wc -c < "${SBOM_FILE}") bytes)"
echo ""

# ── Helpers ─────────────────────────────────────────────────────────
# Portable SHA wrappers — Mac uses shasum, Linux uses sha1sum/sha256sum.
# Used by the Artifactory PUT below for the X-Checksum-* headers.
compute_sha1()   { shasum -a 1   "$1" 2>/dev/null | awk '{print $1}' || sha1sum   "$1" | awk '{print $1}'; }
compute_sha256() { shasum -a 256 "$1" 2>/dev/null | awk '{print $1}' || sha256sum "$1" | awk '{print $1}'; }

# After a successful Artifactory upload, find the docker manifest in
# the same Artifactory and stamp it with sbom.path so consumers can
# cross-reference manifest → SBOM in the Artifactory UI. Best-effort —
# failures here log a WARN but don't fail the SBOM upload itself.
# Hoisted out of the Artifactory block because the embedded Python
# was the longest visual chunk in the file.
artifactory_tag_manifest_with_sbom_path() {
  local sbom_path="$1"
  [ -n "${IMAGE_TAG:-}" ] || return 0
  command -v python3 >/dev/null 2>&1 || { echo "    WARN: python3 missing — skipping sbom.path tag" >&2; return 0; }

  local art_base="${ARTIFACTORY_URL%/}/artifactory"
  local secret="${ARTIFACTORY_TOKEN:-${ARTIFACTORY_PASSWORD:-}}"
  local manifest_path
  manifest_path=$(curl -sS -u "${ARTIFACTORY_USER}:${secret}" \
    "${art_base}/api/search/prop?docker.manifest=${IMAGE_TAG}" 2>/dev/null \
    | python3 -c "
import json, sys
d = json.load(sys.stdin)
for r in d.get('results', []):
    uri = r.get('uri', '')
    if 'manifest.json' in uri:
        parts = uri.split('/api/storage/')
        if len(parts) == 2:
            print(parts[1])
            break
" 2>/dev/null) || return 0

  [ -n "${manifest_path}" ] || return 0
  local code
  code=$(curl -sS -o /dev/null -w "%{http_code}" \
    -u "${ARTIFACTORY_USER}:${secret}" \
    -X PUT "${art_base}/api/storage/${manifest_path}?properties=sbom.path=${sbom_path}" 2>/dev/null)
  if [ "${code}" = "204" ]; then
    echo "    sbom.path property set on ${manifest_path}"
  else
    echo "    WARN: could not set sbom.path (HTTP ${code})" >&2
  fi
}

posted=0
failed=0

# ════════════════════════════════════════════════════════════════════
# SINK 1: Generic CycloneDX webhook
# ════════════════════════════════════════════════════════════════════
# Posts the raw .cdx.json body to any URL that accepts a POST. Use
# for ad-hoc collectors / serverless functions / internal Slack bots /
# whatever consumes the BOM. Optional Authorization header pass-through.
if [ -z "${SBOM_WEBHOOK_URL:-}" ]; then
  echo "→ webhook              skip (SBOM_WEBHOOK_URL empty)"
else
  echo "→ webhook              POST ${SBOM_WEBHOOK_URL}"
  rc=0
  (
    headers=(-H "Content-Type: application/vnd.cyclonedx+json")
    [ -n "${SBOM_WEBHOOK_AUTH_HEADER:-}" ] && headers+=(-H "${SBOM_WEBHOOK_AUTH_HEADER}")
    [ -n "${IMAGE_DIGEST:-}" ]             && headers+=(-H "X-Image-Digest: ${IMAGE_DIGEST}")
    [ -n "${UPSTREAM_TAG:-}" ]             && headers+=(-H "X-Image-Version: ${UPSTREAM_TAG}")
    curl -fsSL -X POST "${headers[@]}" --data-binary "@${SBOM_FILE}" \
      "${SBOM_WEBHOOK_URL}" -o "${_TMP}/webhook.out"
    echo "  ✓ posted ($(wc -c < "${_TMP}/webhook.out") bytes response)"
  ) || rc=$?
  if [ "${rc}" -eq 0 ]; then
    posted=$((posted + 1))
  else
    echo "  ✗ webhook POST failed" >&2
    failed=$((failed + 1))
  fi
fi

# ════════════════════════════════════════════════════════════════════
# SINK 2: OWASP Dependency-Track
# ════════════════════════════════════════════════════════════════════
# Uploads to /api/v1/bom with a JSON body containing the base64-encoded
# CycloneDX. autoCreate=true creates the project on first upload, then
# subsequent uploads correlate against the same project/version so DT
# can show diff-style "new vulns since last build" notifications.
if [ -z "${DEPENDENCY_TRACK_URL:-}" ] || [ -z "${DEPENDENCY_TRACK_API_KEY:-}" ]; then
  echo "→ dependency-track     skip (URL or API_KEY empty)"
elif [ -z "${DEPENDENCY_TRACK_PROJECT:-}" ]; then
  echo "→ dependency-track     misconfigured (URL+KEY set but PROJECT empty)" >&2
  failed=$((failed + 1))
else
  echo "→ dependency-track     POST ${DEPENDENCY_TRACK_URL}"
  rc=0
  (
    ver="${UPSTREAM_TAG:-latest}"
    bom_b64=$(base64 < "${SBOM_FILE}" | tr -d '\n')
    if command -v jq >/dev/null 2>&1; then
      payload=$(jq -nc \
        --arg name "${DEPENDENCY_TRACK_PROJECT}" \
        --arg ver  "${ver}" \
        --arg bom  "${bom_b64}" \
        '{projectName:$name, projectVersion:$ver, autoCreate:true, bom:$bom}')
    else
      payload="{\"projectName\":\"${DEPENDENCY_TRACK_PROJECT}\",\"projectVersion\":\"${ver}\",\"autoCreate\":true,\"bom\":\"${bom_b64}\"}"
    fi
    curl -fsSL -X POST \
      -H "X-Api-Key: ${DEPENDENCY_TRACK_API_KEY}" \
      -H "Content-Type: application/json" \
      --data "${payload}" \
      "${DEPENDENCY_TRACK_URL%/}/api/v1/bom" -o "${_TMP}/dt.out"
    echo "  ✓ uploaded to project '${DEPENDENCY_TRACK_PROJECT}' v${ver}"
    [ -s "${_TMP}/dt.out" ] && echo "    response: $(cat "${_TMP}/dt.out")"
  ) || rc=$?
  if [ "${rc}" -eq 0 ]; then
    posted=$((posted + 1))
  else
    echo "  ✗ Dependency-Track upload failed" >&2
    failed=$((failed + 1))
  fi
fi

# ════════════════════════════════════════════════════════════════════
# SINK 3: JFrog Artifactory + Xray (native SBOM import)
# ════════════════════════════════════════════════════════════════════
# Xray picks up any .cdx.json uploaded to an indexed generic repo and
# scans the bill of materials. We PUT the file at a predictable path
# so it's discoverable in the Artifactory UI:
#   <repo>/<image-name>/<version>/sbom.cdx.json
# After the upload succeeds, we also stamp the docker manifest with a
# sbom.path property for cross-reference (best-effort, see helper).
if [ -z "${ARTIFACTORY_URL:-}" ] || [ -z "${ARTIFACTORY_USER:-}" ] || [ -z "${ARTIFACTORY_SBOM_REPO:-}" ]; then
  echo "→ artifactory-xray     skip (URL, USER, or SBOM_REPO empty)"
elif [ -z "${ARTIFACTORY_TOKEN:-}${ARTIFACTORY_PASSWORD:-}" ]; then
  echo "→ artifactory-xray     misconfigured (no TOKEN or PASSWORD)" >&2
  failed=$((failed + 1))
else
  # IMAGE_NAME from build.env may be a full registry path — keep just the leaf.
  art_image="${IMAGE_NAME:-image}"; art_image="${art_image##*/}"
  art_version="${IMAGE_TAG:-${UPSTREAM_TAG:-latest}}"
  art_sbom_path="${ARTIFACTORY_SBOM_REPO}/${art_image}/${art_version}/sbom.cdx.json"
  art_deploy_url="${ARTIFACTORY_URL%/}/artifactory/${art_sbom_path}"
  echo "→ artifactory-xray     PUT ${art_sbom_path}"

  rc=0
  (
    secret="${ARTIFACTORY_TOKEN:-${ARTIFACTORY_PASSWORD:-}}"
    sha1=$(compute_sha1   "${SBOM_FILE}")
    sha256=$(compute_sha256 "${SBOM_FILE}")
    curl -fsSL -X PUT \
      -u "${ARTIFACTORY_USER}:${secret}" \
      -H "Content-Type: application/vnd.cyclonedx+json" \
      -H "X-Checksum-Sha1: ${sha1}" \
      -H "X-Checksum-Sha256: ${sha256}" \
      --data-binary "@${SBOM_FILE}" \
      "${art_deploy_url}" -o "${_TMP}/art.out"
    echo "  ✓ deployed — Xray will auto-index"
    if command -v jq >/dev/null 2>&1 && [ -s "${_TMP}/art.out" ]; then
      uri=$(jq -r '.uri // empty' "${_TMP}/art.out" 2>/dev/null || echo "")
      [ -n "${uri}" ] && echo "    uri: ${uri}"
    fi
    artifactory_tag_manifest_with_sbom_path "${art_sbom_path}"
  ) || rc=$?
  if [ "${rc}" -eq 0 ]; then
    posted=$((posted + 1))
  else
    echo "  ✗ Artifactory SBOM upload failed" >&2
    cat "${_TMP}/art.out" >&2 2>/dev/null || true
    failed=$((failed + 1))
  fi
fi

# ════════════════════════════════════════════════════════════════════
# SINK 4: Artifactory generic archive (no Xray, just storage)
# ════════════════════════════════════════════════════════════════════
# Parallel to SINK 3 but targets a plain generic Artifactory repo (no
# Xray indexing assumed). Same path shape — predictable, human-browsable:
#   <repo>/<image-name>/<version>/sbom.cdx.json
# e.g. newen-generic-dev-local/nginx/1.29.8-alpine-5d3ea65/sbom.cdx.json
#
# Useful when you want a long-term archive of every SBOM you've ever
# shipped (cross-team browsability, audit trail) AND a separate
# Xray-indexed repo (SINK 3) for active scanning. Both can run in the
# same pipeline — independent ARTIFACTORY_SBOM_REPO / ARTIFACTORY_SBOM_ARCHIVE_REPO.
if [ -z "${ARTIFACTORY_URL:-}" ] || [ -z "${ARTIFACTORY_USER:-}" ] || [ -z "${ARTIFACTORY_SBOM_ARCHIVE_REPO:-}" ]; then
  echo "→ artifactory-archive  skip (URL, USER, or SBOM_ARCHIVE_REPO empty)"
elif [ -z "${ARTIFACTORY_TOKEN:-}${ARTIFACTORY_PASSWORD:-}" ]; then
  echo "→ artifactory-archive  misconfigured (no TOKEN or PASSWORD)" >&2
  failed=$((failed + 1))
else
  arc_image="${IMAGE_NAME:-image}"; arc_image="${arc_image##*/}"
  arc_version="${IMAGE_TAG:-${UPSTREAM_TAG:-latest}}"
  arc_sbom_path="${ARTIFACTORY_SBOM_ARCHIVE_REPO}/${arc_image}/${arc_version}/sbom.cdx.json"
  arc_deploy_url="${ARTIFACTORY_URL%/}/artifactory/${arc_sbom_path}"
  echo "→ artifactory-archive  PUT ${arc_sbom_path}"

  rc=0
  (
    secret="${ARTIFACTORY_TOKEN:-${ARTIFACTORY_PASSWORD:-}}"
    sha1=$(compute_sha1   "${SBOM_FILE}")
    sha256=$(compute_sha256 "${SBOM_FILE}")
    curl -fsSL -X PUT \
      -u "${ARTIFACTORY_USER}:${secret}" \
      -H "Content-Type: application/vnd.cyclonedx+json" \
      -H "X-Checksum-Sha1: ${sha1}" \
      -H "X-Checksum-Sha256: ${sha256}" \
      --data-binary "@${SBOM_FILE}" \
      "${arc_deploy_url}" -o "${_TMP}/arc.out"
    echo "  ✓ archived"
    if command -v jq >/dev/null 2>&1 && [ -s "${_TMP}/arc.out" ]; then
      uri=$(jq -r '.uri // empty' "${_TMP}/arc.out" 2>/dev/null || echo "")
      [ -n "${uri}" ] && echo "    uri: ${uri}"
    fi
  ) || rc=$?
  if [ "${rc}" -eq 0 ]; then
    posted=$((posted + 1))
  else
    echo "  ✗ Artifactory archive upload failed" >&2
    cat "${_TMP}/arc.out" >&2 2>/dev/null || true
    failed=$((failed + 1))
  fi
fi

# ════════════════════════════════════════════════════════════════════
# SINK 5: Splunk HEC (audit ingestion)
# ════════════════════════════════════════════════════════════════════
# Vendor-agnostic: same sourcetype handles Syft-, Xray-, or Trivy-made
# SBOMs. Build the event content (sbom_file + image + git_commit + the
# BOM nested under .cyclonedx) and hand to the shared HEC poster.
if [ -z "${SPLUNK_HEC_URL:-}" ] || [ -z "${SPLUNK_HEC_TOKEN:-}" ]; then
  echo "→ splunk-hec           skip (URL or TOKEN empty)"
elif ! command -v jq >/dev/null 2>&1; then
  echo "→ splunk-hec           misconfigured (jq required for HEC envelope construction)" >&2
  failed=$((failed + 1))
else
  echo "→ splunk-hec           POST ${SPLUNK_HEC_URL}"
  rc=0
  (
    image_ref="${IMAGE_REF:-${UPSTREAM_REGISTRY:-}/${UPSTREAM_IMAGE:-}:${UPSTREAM_TAG:-}}"
    git_sha="${GIT_SHA:-$(git rev-parse HEAD 2>/dev/null || echo unknown)}"
    jq -nc \
      --arg sbom_file "${SBOM_FILE##*/}" \
      --arg image     "${image_ref}" \
      --arg gitsha    "${git_sha}" \
      --slurpfile bom "${SBOM_FILE}" \
      '{sbom_file:$sbom_file, scanned_image:$image, git_commit:$gitsha, cyclonedx:$bom[0]}' \
      > "${_TMP}/hec.json"

    # shellcheck source=../lib/splunk-hec.sh
    . "${REPO_ROOT}/scripts/lib/splunk-hec.sh"
    splunk_hec_post "${_TMP}/hec.json" "${SPLUNK_SBOM_SOURCETYPE:-cyclonedx:json}"
  ) || rc=$?
  if [ "${rc}" -eq 0 ]; then
    posted=$((posted + 1))
  else
    # splunk_hec_post already logs the curl error
    failed=$((failed + 1))
  fi
fi

echo ""

# ════════════════════════════════════════════════════════════════════
# Summary
# ════════════════════════════════════════════════════════════════════
if [ ${posted} -eq 0 ] && [ ${failed} -eq 0 ]; then
  echo "SBOM post-processing: no sinks configured."
  echo "  To enable ingestion, set one of:"
  echo "    - SBOM_WEBHOOK_URL (+ optional SBOM_WEBHOOK_AUTH_HEADER)"
  echo "    - DEPENDENCY_TRACK_URL + DEPENDENCY_TRACK_API_KEY + DEPENDENCY_TRACK_PROJECT"
  echo "    - ARTIFACTORY_URL + ARTIFACTORY_USER + ARTIFACTORY_TOKEN/PASSWORD + ARTIFACTORY_SBOM_REPO"
  echo "        (Xray-indexed repo — Xray auto-scans on upload)"
  echo "    - ARTIFACTORY_URL + ARTIFACTORY_USER + ARTIFACTORY_TOKEN/PASSWORD + ARTIFACTORY_SBOM_ARCHIVE_REPO"
  echo "        (plain generic repo — long-term human-browsable archive)"
  echo "    - SPLUNK_HEC_URL + SPLUNK_HEC_TOKEN"
  echo "  SBOM was still generated and is available as a pipeline artifact."
  exit 0
fi

if [ ${failed} -gt 0 ]; then
  echo "ERROR: ${failed} sink(s) failed — ${posted} succeeded" >&2
  exit 1
fi

echo "SBOM post-processing: ${posted} sink(s) succeeded"
