#!/usr/bin/env bash
# scripts/bootstrap/build-cert-builder.sh
# ────────────────────────────────────────
# One-off builder for the corp-CA-trusting alpine image that the main
# Dockerfile's cert sidecar (CERT_BUILDER_IMAGE) consumes on every
# container build.
#
# Run this ONCE per CA rotation (typically annually). The result is
# pushed to your internal registry; every fork of this template then
# sets CERT_BUILDER_IMAGE in image.env to point at it.
#
# Usage
# ─────
#   ./scripts/bootstrap/build-cert-builder.sh \
#       --ca-cert /path/to/corp-ca.pem \
#       --target  artifactory.example.com/library/alpine-with-corp-ca:3.20
#
# Optional flags
# ──────────────
#   --base       <image>   default: docker.io/library/alpine:3.20
#                          In airgap, point at your internal mirror, e.g.
#                            artifactory.example.com/dockerhub/library/alpine:3.20
#   --apk-mirror <url>     default: ""  (use upstream alpine repos)
#                          In airgap, point at your alpine package mirror, e.g.
#                            https://artifactory.example.com/artifactory/alpine-main
#                          When set, /etc/apk/repositories is rewritten BEFORE
#                          apk add ca-certificates runs.
#   --platform   <plat>    default: linux/amd64 (most CI runners are amd64)
#   --dry-run              build the image locally but don't push
#   --help                 print this help and exit
#
# Requirements
# ────────────
#   - docker (or podman aliased) on PATH
#   - already logged in to the --target registry (push happens as
#     whoever the daemon is currently authenticated as). The script
#     itself doesn't do `docker login` — that's a one-time platform
#     team ritual outside the script's scope.
#
# Why this exists
# ───────────────
# The main Dockerfile's cert sidecar needs a SHELL-bearing builder
# image with ca-certificates installed. In airgap, doing that install
# on every build creates a chicken-and-egg ("need internal CA to pull
# ca-certificates from internal mirror"). By baking the corp-trusting
# alpine image ONCE and pushing it to your internal Artifactory, every
# subsequent container build skips the install + network attempt
# entirely — the builder image is already trusted + already has the
# rebuild tools.
#
# Pipeline integration
# ────────────────────
# Adopt this pattern by either:
#   a) Running this script from a platform team operator's laptop on
#      CA rotation day, or
#   b) Wiring it into a scheduled CI pipeline that re-runs on a cron
#      and on every push to the bootstrap branch (rare).
# Either way, every fork of the main template just sets:
#     CERT_BUILDER_IMAGE="artifactory.example.com/library/alpine-with-corp-ca:3.20"

set -euo pipefail

# ── Argument parsing ────────────────────────────────────────────────
CA_CERT=""
TARGET=""
BASE_IMAGE="docker.io/library/alpine:3.20"
APK_MIRROR=""
PLATFORM="linux/amd64"
DRY_RUN=0

_usage() { sed -nE 's/^# ?//p' "${BASH_SOURCE[0]}" | head -50; }

while [ $# -gt 0 ]; do
  case "$1" in
    --ca-cert)     CA_CERT="$2";    shift 2 ;;
    --target)      TARGET="$2";     shift 2 ;;
    --base)        BASE_IMAGE="$2"; shift 2 ;;
    --apk-mirror)  APK_MIRROR="$2"; shift 2 ;;
    --platform)    PLATFORM="$2";   shift 2 ;;
    --dry-run)     DRY_RUN=1;       shift   ;;
    --help|-h)     _usage; exit 0   ;;
    *)
      echo "ERROR: unknown flag '$1'" >&2
      echo "" >&2
      _usage >&2
      exit 1
      ;;
  esac
done

# ── Validation ──────────────────────────────────────────────────────
if [ -z "${CA_CERT}" ]; then
  echo "ERROR: --ca-cert <file> is required" >&2
  exit 1
fi
if [ -z "${TARGET}" ]; then
  echo "ERROR: --target <registry/repo:tag> is required" >&2
  exit 1
fi
if [ ! -f "${CA_CERT}" ]; then
  echo "ERROR: --ca-cert file not found: ${CA_CERT}" >&2
  exit 1
fi
if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: 'docker' CLI not on PATH" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONTEXT="${REPO_ROOT}/scripts/bootstrap"
DOCKERFILE="${CONTEXT}/cert-builder.Dockerfile"

if [ ! -f "${DOCKERFILE}" ]; then
  echo "ERROR: ${DOCKERFILE} not found" >&2
  exit 1
fi

# ── Pre-flight report ───────────────────────────────────────────────
echo ""
echo "=========================================="
echo "  cert-builder bootstrap"
echo "=========================================="
echo "  Base image:    ${BASE_IMAGE}"
echo "  Target:        ${TARGET}"
echo "  Platform:      ${PLATFORM}"
echo "  CA cert:       ${CA_CERT} ($(wc -c < "${CA_CERT}") bytes)"
echo "  APK mirror:    ${APK_MIRROR:-<unset — upstream alpine repos>}"
echo "  Mode:          $([ "${DRY_RUN}" -eq 1 ] && echo 'DRY RUN — no push' || echo 'BUILD + PUSH')"
echo "=========================================="
echo ""

# ── Materialise the CA into the build context ──────────────────────
# The Dockerfile's COPY corp-ca.crt requires the file in the build
# context (not at an arbitrary --ca-cert path). Stage it under
# scripts/bootstrap/corp-ca.crt for the duration of the build.
STAGED_CA="${CONTEXT}/corp-ca.crt"
cp "${CA_CERT}" "${STAGED_CA}"
trap 'rm -f "${STAGED_CA}"' EXIT
echo "→ staged CA at ${STAGED_CA}"

# ── Build ───────────────────────────────────────────────────────────
build_args=(
  --build-arg "BASE_IMAGE=${BASE_IMAGE}"
  --build-arg "APK_MIRROR=${APK_MIRROR}"
)

# Use buildx if available (cleaner provenance handling); otherwise
# fall back to plain docker build. Same toggle pattern as build.sh.
if docker buildx version >/dev/null 2>&1; then
  build_cmd=(docker buildx build
    --provenance=false --sbom=false
    --platform "${PLATFORM}"
    --load)
  echo "→ docker buildx build (provenance/sbom disabled, --load)"
else
  build_cmd=(docker build)
  echo "→ docker build (buildx not detected)"
fi

"${build_cmd[@]}" \
  "${build_args[@]}" \
  -f "${DOCKERFILE}" \
  -t "${TARGET}" \
  "${CONTEXT}"

echo ""
echo "→ build complete: ${TARGET}"
echo ""
echo "=== inspect: USER + Cmd + bundle bytes ==="
docker inspect "${TARGET}" --format='{{json .Config}}' \
  | python3 -c 'import json,sys; c=json.load(sys.stdin); print(f"  User: {c.get(\"User\") or \"(unset)\"}\n  Cmd:  {c.get(\"Cmd\")}")' \
  2>/dev/null || true
docker run --rm --entrypoint /bin/sh "${TARGET}" -c \
  'printf "  /etc/ssl/certs/ca-certificates.crt: %d bytes\n" "$(wc -c < /etc/ssl/certs/ca-certificates.crt)"' \
  2>/dev/null || true

# ── Push ────────────────────────────────────────────────────────────
if [ "${DRY_RUN}" -eq 1 ]; then
  echo ""
  echo "→ DRY RUN: skipping push"
  echo "  Image is loaded into local Docker as ${TARGET}"
  echo "  Re-run without --dry-run to push to the registry."
  exit 0
fi

echo ""
echo "→ docker push ${TARGET}"
docker push "${TARGET}" || {
  echo "ERROR: docker push failed — make sure you're logged in to the target registry" >&2
  echo "       (docker login $(printf '%s' "${TARGET}" | cut -d/ -f1) -u <user>)" >&2
  exit 1
}

echo ""
echo "✓ cert-builder published: ${TARGET}"
echo ""
echo "Set this in your image.env (or as a CI variable in fork projects):"
echo ""
echo "    CERT_BUILDER_IMAGE=\"${TARGET}\""
echo ""
