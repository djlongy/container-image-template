#!/usr/bin/env bash
# Mirror the Grype vulnerability database to an Artifactory generic repo.
#
# Why this exists:
#   In an air-gapped environment, Grype can't reach grype.anchore.io for
#   its CVE database. This script downloads the latest DB from Anchore's
#   CDN and uploads it to an Artifactory generic repo that the pipeline
#   CAN reach. Grype then pulls the DB from there on every scan.
#
# Run this:
#   - Manually when you want a fresh DB: `./scripts/mirror-grype-db.sh`
#   - As a CI stage before grype scan runs (see .gitlab-ci.yml)
#   - On a cron schedule (GitLab scheduled pipeline) for daily freshness
#
# Required env:
#   ARTIFACTORY_URL          e.g. https://artifactory.example.com
#   ARTIFACTORY_USER         user with Deploy rights on the DB repo
#   ARTIFACTORY_TOKEN | ARTIFACTORY_PASSWORD
#   ARTIFACTORY_GRYPE_DB_REPO  generic repo name (e.g. grype-db-local)
#
# Optional:
#   GRYPE_DB_SOURCE_URL      default: https://grype.anchore.io/databases/v6/latest.json
#                            override if Anchore changes their CDN layout
#                            or you want to pin to a legacy DB schema
#   GRYPE_DB_MIRROR_SUBPATH  path inside the Artifactory repo — default:
#                            databases/v6 (matches Anchore's structure so
#                            relative hrefs in latest.json resolve correctly)
#
# Exit codes:
#   0  mirror complete
#   1  any step failed (download, checksum mismatch, upload)

set -euo pipefail

# ── Config ──────────────────────────────────────────────────────────
: "${ARTIFACTORY_URL:?ARTIFACTORY_URL must be set}"
: "${ARTIFACTORY_USER:?ARTIFACTORY_USER must be set}"
: "${ARTIFACTORY_GRYPE_DB_REPO:?ARTIFACTORY_GRYPE_DB_REPO must be set (e.g. grype-db-local)}"

ART_SECRET="${ARTIFACTORY_TOKEN:-${ARTIFACTORY_PASSWORD:-}}"
if [ -z "${ART_SECRET}" ]; then
  echo "ERROR: set either ARTIFACTORY_TOKEN (preferred) or ARTIFACTORY_PASSWORD" >&2
  exit 1
fi

SOURCE_URL="${GRYPE_DB_SOURCE_URL:-https://grype.anchore.io/databases/v6/latest.json}"
MIRROR_SUBPATH="${GRYPE_DB_MIRROR_SUBPATH:-databases/v6}"
ART_BASE="${ARTIFACTORY_URL%/}/artifactory"
MIRROR_BASE="${ART_BASE}/${ARTIFACTORY_GRYPE_DB_REPO}/${MIRROR_SUBPATH}"

# ── Per-run temp dir with cleanup ───────────────────────────────────
TMPDIR=$(mktemp -d)
trap 'rm -rf "${TMPDIR}"' EXIT

echo "════════════════════════════════════════════════════════════════"
echo "  Grype DB Mirror"
echo "════════════════════════════════════════════════════════════════"
echo "  Source:       ${SOURCE_URL}"
echo "  Destination:  ${MIRROR_BASE}/"
echo ""

# ── 1. Download the listing file ────────────────────────────────────
echo "→ Fetching listing: $(basename "${SOURCE_URL}")"
LISTING_FILE="${TMPDIR}/$(basename "${SOURCE_URL}")"
if ! curl -fsSL "${SOURCE_URL}" -o "${LISTING_FILE}"; then
  echo "ERROR: failed to download listing from ${SOURCE_URL}" >&2
  exit 1
fi
echo "  ✓ listing downloaded ($(wc -c < "${LISTING_FILE}") bytes)"

# ── 2. Parse listing to find DB tarball + checksum ──────────────────
# Anchore's v6 format:
#   {
#     "schemaVersion": "v6.1.4",
#     "path": "vulnerability-db_v6.1.4_..._....tar.zst",  (relative)
#     "checksum": "sha256:..."
#   }
DB_PATH=$(python3 -c "
import json, sys
d = json.load(open('${LISTING_FILE}'))
print(d.get('path') or d.get('url') or '')
")
DB_CHECKSUM=$(python3 -c "
import json
d = json.load(open('${LISTING_FILE}'))
print(d.get('checksum', ''))
")

if [ -z "${DB_PATH}" ]; then
  echo "ERROR: could not find 'path' or 'url' in listing JSON" >&2
  cat "${LISTING_FILE}" | head -20 >&2
  exit 1
fi
if [ -z "${DB_CHECKSUM}" ]; then
  echo "ERROR: listing JSON missing 'checksum' field" >&2
  exit 1
fi

echo "  schema:       $(python3 -c "import json; print(json.load(open('${LISTING_FILE}')).get('schemaVersion',''))")"
echo "  tarball:      ${DB_PATH}"
echo "  checksum:     ${DB_CHECKSUM}"

# ── 3. Resolve tarball URL (relative to listing location) ───────────
# Listing is at .../databases/v6/latest.json
# DB path is relative, so full URL is .../databases/v6/<DB_PATH>
SOURCE_DIR="${SOURCE_URL%/*}"
TARBALL_URL="${SOURCE_DIR}/${DB_PATH}"

# ── 4. Download the DB tarball ──────────────────────────────────────
echo ""
echo "→ Downloading DB tarball: ${DB_PATH}"
TARBALL_FILE="${TMPDIR}/${DB_PATH}"
if ! curl -fsSL "${TARBALL_URL}" -o "${TARBALL_FILE}"; then
  echo "ERROR: failed to download ${TARBALL_URL}" >&2
  exit 1
fi
TARBALL_SIZE=$(wc -c < "${TARBALL_FILE}")
echo "  ✓ downloaded ($(printf '%.1f' "$(echo "${TARBALL_SIZE}/1024/1024" | bc -l)") MB)"

# ── 5. Verify checksum ──────────────────────────────────────────────
echo ""
echo "→ Verifying checksum"
EXPECTED="${DB_CHECKSUM#sha256:}"
if command -v shasum >/dev/null 2>&1; then
  ACTUAL=$(shasum -a 256 "${TARBALL_FILE}" | awk '{print $1}')
else
  ACTUAL=$(sha256sum "${TARBALL_FILE}" | awk '{print $1}')
fi
if [ "${EXPECTED}" != "${ACTUAL}" ]; then
  echo "ERROR: checksum mismatch" >&2
  echo "  expected: ${EXPECTED}" >&2
  echo "  actual:   ${ACTUAL}" >&2
  exit 1
fi
echo "  ✓ sha256 matches listing"

# ── 6. Upload both files to Artifactory ─────────────────────────────
echo ""
echo "→ Uploading to Artifactory"

_upload_file() {
  local src="$1" dst_path="$2" content_type="$3"
  local sha1 sha256
  if command -v shasum >/dev/null 2>&1; then
    sha1=$(shasum -a 1 "${src}" | awk '{print $1}')
    sha256=$(shasum -a 256 "${src}" | awk '{print $1}')
  else
    sha1=$(sha1sum "${src}" | awk '{print $1}')
    sha256=$(sha256sum "${src}" | awk '{print $1}')
  fi
  local url="${MIRROR_BASE}/${dst_path}"
  local code
  code=$(curl -sS -o "${TMPDIR}/upload-response.txt" -w "%{http_code}" \
    -X PUT -u "${ARTIFACTORY_USER}:${ART_SECRET}" \
    -H "Content-Type: ${content_type}" \
    -H "X-Checksum-Sha1: ${sha1}" \
    -H "X-Checksum-Sha256: ${sha256}" \
    --data-binary "@${src}" \
    "${url}")
  if [ "${code}" = "201" ] || [ "${code}" = "200" ]; then
    echo "  ✓ ${dst_path} (HTTP ${code})"
  else
    echo "  ✗ ${dst_path} failed (HTTP ${code})" >&2
    cat "${TMPDIR}/upload-response.txt" >&2
    return 1
  fi
}

# Upload tarball FIRST (so consumers that fetch listing.json always
# find a tarball ready — avoid races where listing is fresh but
# tarball upload is still in flight).
_upload_file "${TARBALL_FILE}" "${DB_PATH}" "application/zstd"
_upload_file "${LISTING_FILE}" "$(basename "${SOURCE_URL}")" "application/json"

# ── 7. Print the URL that Grype should use ──────────────────────────
MIRROR_LISTING_URL="${MIRROR_BASE}/$(basename "${SOURCE_URL}")"
echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  Mirror complete. Set in CI:"
echo ""
echo "    GRYPE_DB_UPDATE_URL=${MIRROR_LISTING_URL}"
echo "════════════════════════════════════════════════════════════════"
