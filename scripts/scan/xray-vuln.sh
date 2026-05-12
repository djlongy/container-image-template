#!/usr/bin/env bash
# scripts/scan/xray-vuln.sh — JFrog Xray vulnerability scan
#
# Single responsibility: run `jf docker scan --format=simple-json`
# against the upstream image and produce vuln-scan.json. Optionally
# ships the JSON to Splunk HEC.
#
# Pairs with scripts/scan/xray-sbom.sh which produces the CycloneDX
# SBOM via a separate jf invocation. Both scripts read image.env via
# the shared loader and self-install jf via scripts/lib/install-jf.sh.
#
# Usage:
#   bash scripts/scan/xray-vuln.sh                 # scan the BUILT image
#                                                  # (IMAGE_DIGEST from
#                                                  #  build.env, fallback
#                                                  #  chain below)
#   bash scripts/scan/xray-vuln.sh <image-ref>     # scan arbitrary ref
#                                                  # (e.g. for prescan:
#                                                  #  pass UPSTREAM_REF)
#
# Scan target resolution (highest precedence first):
#   1. positional arg $1
#   2. XRAY_SCAN_REF env var (explicit override)
#   3. IMAGE_DIGEST   (from build.env — the rebuilt image's digest)
#   4. IMAGE_REF      (from build.env — the rebuilt image's tag)
#   5. UPSTREAM_REF   (from image.env — the upstream we rebuilt from)
#   6. UPSTREAM_REGISTRY/UPSTREAM_IMAGE:UPSTREAM_TAG (assembled if all set)
#
# Default targets the BUILT image because that's what consumers actually
# pull — scanning only the upstream would leave a gap (remediation,
# cert injection, scripts/extend/ customisations all change the image
# contents). Use the positional arg or XRAY_SCAN_REF=upstream pattern
# in a separate prescan job if you want to fail-fast on a bad upstream
# BEFORE the build runs.
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
#   XRAY_SCAN_REF                      override the resolved target
#   VULN_SCAN_FILE                     output path (default vuln-scan.json
#                                      — the canonical name from
#                                      scripts/lib/artifact-names.sh, so
#                                      a future trivy/grype-vuln swap
#                                      can write to the same filename)
#   XRAY_SCAN_FORMAT                   simple-json (default) | json
#   ARTIFACTORY_PROJECT                pass-through to --project=
#
# Optional env (policy gate — exits non-zero on threshold breach):
#   XRAY_FAIL_ON_SEVERITY              comma-separated list of severities
#                                      that should fail the script.
#                                      Examples:
#                                        critical              (only criticals)
#                                        critical,high         (either)
#                                        critical,high,medium  (anything serious)
#                                      Empty/unset = report-only mode (current
#                                      default). Severities are matched
#                                      case-insensitive against the simple-json
#                                      vulnerabilities[].severity field.
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
# shellcheck source=../lib/artifact-names.sh
. "${REPO_ROOT}/scripts/lib/artifact-names.sh"
import_bamboo_vars
load_image_env

# ── Resolve scan target ─────────────────────────────────────────────
# Default to the BUILT image (IMAGE_DIGEST from build.env, populated
# by the build job's dotenv artifact). Falls back through tag → upstream
# → constructed-upstream so the script also works for prescan use cases
# where build hasn't run yet.
SCAN_REF="${1:-${XRAY_SCAN_REF:-}}"
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
  echo "  Resolution chain: \$1 > XRAY_SCAN_REF > IMAGE_DIGEST > IMAGE_REF > UPSTREAM_REF > UPSTREAM_REGISTRY/IMAGE:TAG" >&2
  echo "  All empty. To scan after build, ensure build.env (with IMAGE_DIGEST) is" >&2
  echo "  available. To scan upstream as a prescan, set UPSTREAM_REF in image.env" >&2
  echo "  or pass a ref explicitly: bash scripts/scan/xray-vuln.sh <image-ref>" >&2
  exit 1
fi
echo "→ Scan target: ${SCAN_REF}"
_dbg "(resolution: \$1=${1:-} XRAY_SCAN_REF=${XRAY_SCAN_REF:-} IMAGE_DIGEST=${IMAGE_DIGEST:-} IMAGE_REF=${IMAGE_REF:-} UPSTREAM_REF=${UPSTREAM_REF:-})"

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

# ── Multi-registry docker login (built image pulls need auth) ──────
# Postscan SCAN_REF is typically a private-registry digest. Without
# this login, docker pull returns 401 unauthorized and jf docker scan
# fails with "reference does not exist". For prescan (public upstream)
# the login is harmless — public pulls work either way.
# shellcheck source=../lib/docker-login.sh
. "${REPO_ROOT}/scripts/lib/docker-login.sh"
docker_login_for_xray_scan

# ── Pre-pull image so `jf docker scan → docker save` finds it ──────
if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker CLI not on PATH — jf docker scan needs local docker" >&2
  exit 1
fi
echo "→ docker pull ${SCAN_REF}"
if ! docker pull "${SCAN_REF}" >/dev/null 2>/tmp/xray-vuln-pull.err; then
  echo "ERROR: docker pull failed — cannot scan a missing local image" >&2
  echo "── pull error ──" >&2
  sed 's/^/  /' /tmp/xray-vuln-pull.err >&2 || true
  echo "  Check: registry credentials in env, network reachability, image ref correctness." >&2
  exit 1
fi

# ── Run the scan ────────────────────────────────────────────────────
SCAN_FORMAT="${XRAY_SCAN_FORMAT:-simple-json}"
# VULN_SCAN_FILE is the canonical vuln-scan filename (default
# vuln-scan.json from scripts/lib/artifact-names.sh; build.env override
# wins). Treat bare names as REPO_ROOT-relative.
case "${VULN_SCAN_FILE}" in
  /*) SCAN_FILE="${VULN_SCAN_FILE}" ;;
  *)  SCAN_FILE="${REPO_ROOT}/${VULN_SCAN_FILE}" ;;
esac
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
  echo "ERROR: jf docker scan produced no output (rc=${SCAN_RC})" >&2
  echo "── stderr ──" >&2
  sed 's/^/  /' /tmp/xray-vuln.err >&2 || true
  echo "  Common causes: image not pulled into local daemon, Xray service" >&2
  echo "  unreachable, or credentials wrong. The job will fail visibly so" >&2
  echo "  the gap is noticed (allow_failure: true at the CI level still" >&2
  echo "  prevents this from blocking downstream jobs)." >&2
  exit 1
fi
echo "  ✓ vuln scan: ${SCAN_FILE} ($(wc -c < "${SCAN_FILE}") bytes, rc=${SCAN_RC})"

# ── Free disk: image tarball + indexer can each be 100s of MB ─────
# `jf docker scan` writes the saved image to /tmp/jfrog.cli.temp.* and
# downloads the Xray indexer + analyzer-manager (~300MB combined) on
# first run. Across many scans on a long-lived runner these add up
# and cause `no space left on device`. Clean up our own footprint.
rm -rf /tmp/jfrog.cli.temp.* 2>/dev/null || true
if command -v docker >/dev/null 2>&1; then
  docker rmi -f "${SCAN_REF}" >/dev/null 2>&1 || true
fi

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

# ── Policy gate (opt-in): fail on configured severity threshold ───
# XRAY_FAIL_ON_SEVERITY="critical"            → any critical fails the script
# XRAY_FAIL_ON_SEVERITY="critical,high"       → either one fails
# XRAY_FAIL_ON_SEVERITY=""                    → report-only (default)
#
# Useful for promoting the xray-vuln job from "audit-only" to a real
# pre-build/post-build gate. Pair with the pipeline's `prescan` stage
# (or `postscan` for built-image gating). Reads severity strings from
# the simple-json `vulnerabilities[].severity` field, case-insensitive.
if [ -n "${XRAY_FAIL_ON_SEVERITY:-}" ]; then
  if ! command -v jq >/dev/null 2>&1; then
    echo "WARN: XRAY_FAIL_ON_SEVERITY set but jq not on PATH — gate skipped" >&2
  else
    # Lowercase the configured list for case-insensitive matching.
    _gate=$(printf '%s' "${XRAY_FAIL_ON_SEVERITY}" | tr '[:upper:]' '[:lower:]')
    _violations=0
    echo "→ Policy gate: fail-on=${_gate}"
    for sev in $(printf '%s\n' "${_gate}" | tr ',' '\n' | sed '/^$/d'); do
      _count=$(jq --arg s "${sev}" '[.vulnerabilities[]? | select((.severity // "" | ascii_downcase) == $s)] | length' "${SCAN_FILE}")
      printf '    %-10s %s\n' "${sev}" "${_count}"
      _violations=$((_violations + _count))
    done
    if [ "${_violations}" -gt 0 ]; then
      echo "  ✗ FAIL: ${_violations} vulnerabilit(ies) match policy gate (XRAY_FAIL_ON_SEVERITY=${XRAY_FAIL_ON_SEVERITY})" >&2
      echo "    To override (audit-only this run): unset XRAY_FAIL_ON_SEVERITY" >&2
      exit 2   # distinct from script-error (1) and clean-no-op (0)
    fi
    echo "  ✓ PASS: no matching vulnerabilities at the configured severity threshold"
  fi
fi
