#!/usr/bin/env bash
# scripts/scan/grype-vuln.sh — Anchore Grype SBOM-based vulnerability scan
#
# Single responsibility: run `grype sbom:<SBOM_FILE> -o json` and
# produce the canonical vuln-scan.json. Optional severity gate
# (GRYPE_FAIL_ON_SEVERITY) parallels xray-vuln.sh's gate so swapping
# scanners doesn't break downstream policy.
#
# Output filename is the SAME as scripts/scan/xray-vuln.sh — both
# write vuln-scan.json by default. That's the artifact contract:
# downstream stages (audit shippers, SecOps) consume vuln-scan.json
# without caring which scanner produced it. Swap one for the other
# by changing the script name in CI YAML; nothing else moves.
#
# Usage:
#   bash scripts/scan/grype-vuln.sh                # uses ${SBOM_FILE} from
#                                                  # build.env / artifact-names.sh
#   bash scripts/scan/grype-vuln.sh <sbom-path>    # scan an arbitrary SBOM
#
# Required upstream input: a CycloneDX SBOM at ${SBOM_FILE} (default
# sbom.cdx.json). Produced by scripts/scan/syft-sbom.sh OR
# scripts/scan/xray-sbom.sh — Grype reads either.
#
# Optional env:
#   SBOM_FILE                 input CycloneDX SBOM (default: sbom.cdx.json)
#   VULN_SCAN_FILE            output path (default: vuln-scan.json)
#   GRYPE_INSTALLER_URL       installer URL (default: GitHub raw)
#   GRYPE_VERSION             default v0.82.0
#   GRYPE_DB_UPDATE_URL       override CVE DB source (air-gap mirror)
#   GRYPE_FAIL_ON_SEVERITY    comma-separated severities that trigger
#                             exit 2 (case-insensitive — Critical,
#                             High, Medium, Low, Negligible, Unknown)
#                             Empty/unset = report-only mode.
#
# Exit codes:
#   0  scan completed (incl. report-only mode with findings)
#   1  hard error (missing SBOM, install failure)
#   2  policy gate failed (matching severity vulns present)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

# shellcheck source=../lib/load-image-env.sh
. "${REPO_ROOT}/scripts/lib/load-image-env.sh"
# shellcheck source=../lib/artifact-names.sh
. "${REPO_ROOT}/scripts/lib/artifact-names.sh"
import_bamboo_vars
load_image_env

# ── Resolve input SBOM ─────────────────────────────────────────────
SBOM_IN="${1:-${SBOM_FILE}}"
case "${SBOM_IN}" in
  /*) ;;
  *)  SBOM_IN="${REPO_ROOT}/${SBOM_IN}" ;;
esac
if [ ! -s "${SBOM_IN}" ]; then
  echo "ERROR: SBOM not found at ${SBOM_IN}" >&2
  echo "  Run scripts/scan/syft-sbom.sh (or xray-sbom.sh) first," >&2
  echo "  or pass an explicit SBOM path: bash scripts/scan/grype-vuln.sh <path>" >&2
  exit 1
fi

# ── Resolve output path ────────────────────────────────────────────
case "${VULN_SCAN_FILE}" in
  /*) SCAN_OUT="${VULN_SCAN_FILE}" ;;
  *)  SCAN_OUT="${REPO_ROOT}/${VULN_SCAN_FILE}" ;;
esac

# ── Auto-install grype ─────────────────────────────────────────────
if ! command -v grype >/dev/null 2>&1; then
  _url="${GRYPE_INSTALLER_URL:-https://raw.githubusercontent.com/anchore/grype/main/install.sh}"
  _ver="${GRYPE_VERSION:-v0.82.0}"
  echo "→ grype not on PATH — installing ${_ver} from ${_url}"
  mkdir -p "${REPO_ROOT}/.bin"
  if curl -fsSL --max-time 120 "${_url}" \
       | sh -s -- -b "${REPO_ROOT}/.bin" "${_ver}" >/dev/null 2>&1 \
     && [ -x "${REPO_ROOT}/.bin/grype" ]; then
    export PATH="${REPO_ROOT}/.bin:${PATH}"
    echo "  ✓ grype installed ($(grype version 2>&1 | head -1))"
  else
    echo "ERROR: grype install failed — set GRYPE_INSTALLER_URL to a reachable mirror" >&2
    exit 1
  fi
fi

# ── Air-gap CVE DB redirect (Artifactory mirror) ───────────────────
# Same logic as the inline GitLab block we replaced — picks up an
# Artifactory-hosted Grype DB when ARTIFACTORY_GRYPE_DB_REPO is set.
if [ -n "${ARTIFACTORY_GRYPE_DB_REPO:-}" ] && [ -n "${ARTIFACTORY_URL:-}" ] \
   && [ -z "${GRYPE_DB_UPDATE_URL:-}" ]; then
  _art_host="${ARTIFACTORY_URL#https://}"
  _art_host="${_art_host#http://}"
  _art_host="${_art_host%%/*}"
  _art_secret="${ARTIFACTORY_TOKEN:-${ARTIFACTORY_PASSWORD:-}}"
  _subpath="${GRYPE_DB_MIRROR_SUBPATH:-grype-db/v6}"
  if [ -n "${ARTIFACTORY_USER:-}" ] && [ -n "${_art_secret}" ]; then
    export GRYPE_DB_UPDATE_URL="https://${ARTIFACTORY_USER}:${_art_secret}@${_art_host}/artifactory/${ARTIFACTORY_GRYPE_DB_REPO}/${_subpath}/latest.json"
    export GRYPE_DB_AUTO_UPDATE=true
    echo "→ Grype DB source: ${ARTIFACTORY_URL}/artifactory/${ARTIFACTORY_GRYPE_DB_REPO}/${_subpath}/latest.json"
  fi
fi

# ── Run the scan ───────────────────────────────────────────────────
echo "→ grype sbom:${SBOM_IN} → ${SCAN_OUT}"
grype "sbom:${SBOM_IN}" --output json --file "${SCAN_OUT}" --fail-on "" || true
grype "sbom:${SBOM_IN}" --output table || true

if [ ! -s "${SCAN_OUT}" ]; then
  echo "ERROR: grype produced no output (rc=$?)" >&2
  exit 1
fi

# ── Severity summary for the pipeline log ──────────────────────────
if command -v jq >/dev/null 2>&1; then
  echo ""
  echo "→ Vulnerability summary:"
  for sev in Critical High Medium Low Negligible Unknown; do
    count=$(jq "[.matches[] | select(.vulnerability.severity==\"${sev}\")] | length" "${SCAN_OUT}")
    printf '    %-11s %s\n' "${sev}:" "${count}"
  done
fi

# ── Policy gate (opt-in) ───────────────────────────────────────────
if [ -n "${GRYPE_FAIL_ON_SEVERITY:-}" ]; then
  if ! command -v jq >/dev/null 2>&1; then
    echo "WARN: GRYPE_FAIL_ON_SEVERITY set but jq not on PATH — gate skipped" >&2
  else
    _gate=$(printf '%s' "${GRYPE_FAIL_ON_SEVERITY}" | tr '[:upper:]' '[:lower:]')
    _violations=0
    echo ""
    echo "→ Policy gate: fail-on=${_gate}"
    for sev in $(printf '%s\n' "${_gate}" | tr ',' '\n' | sed '/^$/d'); do
      _count=$(jq --arg s "${sev}" '[.matches[]? | select((.vulnerability.severity // "" | ascii_downcase) == $s)] | length' "${SCAN_OUT}")
      printf '    %-11s %s\n' "${sev}:" "${_count}"
      _violations=$((_violations + _count))
    done
    if [ "${_violations}" -gt 0 ]; then
      echo "  ✗ FAIL: ${_violations} vulnerabilit(ies) match policy gate (GRYPE_FAIL_ON_SEVERITY=${GRYPE_FAIL_ON_SEVERITY})" >&2
      exit 2
    fi
    echo "  ✓ PASS: no matching vulnerabilities at the configured severity threshold"
  fi
fi
