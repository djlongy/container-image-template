#!/usr/bin/env bash
# Single-image build + push driver.
#
# Computes a semver-qualified tag from VERSION + upstream tag + git SHA,
# pulls the upstream base digest for supply-chain labels, invokes
# `docker buildx build` with the full OCI label set, optionally pushes,
# and emits build.env for downstream CI stages.
#
# Usage:
#   ./scripts/build.sh            # build only, load into local daemon
#   ./scripts/build.sh --push     # build + push to PUSH_REGISTRY
#
# Required env (fail fast if any are missing on --push):
#   PUSH_REGISTRY       destination registry host
#   PUSH_PROJECT        destination project / path prefix
#
# Optional env (with defaults):
#   UPSTREAM_REGISTRY   default: docker.io/library
#   UPSTREAM_IMAGE      default: nginx
#   UPSTREAM_TAG        default: read from Dockerfile's `ARG UPSTREAM_TAG=...`
#   IMAGE_NAME          default: value of UPSTREAM_IMAGE
#   INJECT_CERTS        default: false  — set true to run the certs-true stage
#   REMEDIATE           default: true   — set false to skip apk upgrade
#   ORIGINAL_USER       default: root
#   VENDOR              default: example.com
#   CA_CERT             PEM content of a CA cert to inject (writes to certs/
#                       before build, picked up by the COPY in Dockerfile)
#   PLATFORM            default: linux/amd64
#   SBOM_ATTEST         default: false — scaffolded for future cosign attest-sbom;
#                       the active SBOM workflow is driven by .gitlab-ci.yml
#                       calling syft/grype on the pushed image directly.
#   REGISTRY_KIND       when unset (default), --push does a plain
#                       `docker push` to PUSH_REGISTRY (Harbor baseline).
#                       Set to "artifactory" to delegate the push step
#                       to scripts/push-backends/artifactory.sh, which
#                       handles layout-template resolution, jf rt bp
#                       build info, and property tagging. Same pattern
#                       as the monorepo — the image is built locally
#                       (--load), then the backend retags and pushes.
#
# Everything else is derived: VERSION from the VERSION file, GIT_SHA
# from git, CREATED from `date -u`, BASE_DIGEST from `crane digest` on
# the upstream reference.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

# ── Config resolution ────────────────────────────────────────────────

UPSTREAM_REGISTRY="${UPSTREAM_REGISTRY:-docker.io/library}"
UPSTREAM_IMAGE="${UPSTREAM_IMAGE:-nginx}"

# Read the default UPSTREAM_TAG out of the Dockerfile if not overridden.
# This keeps Renovate's `# renovate: datasource=docker ...` comment as
# the canonical upstream version pin.
if [ -z "${UPSTREAM_TAG:-}" ]; then
  UPSTREAM_TAG=$(awk -F'=' '/^ARG UPSTREAM_TAG=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' Dockerfile)
  if [ -z "${UPSTREAM_TAG}" ]; then
    echo "ERROR: UPSTREAM_TAG not set and no default found in Dockerfile" >&2
    exit 1
  fi
fi

IMAGE_NAME="${IMAGE_NAME:-${UPSTREAM_IMAGE}}"
INJECT_CERTS="${INJECT_CERTS:-false}"
REMEDIATE="${REMEDIATE:-true}"
ORIGINAL_USER="${ORIGINAL_USER:-root}"
VENDOR="${VENDOR:-example.com}"
PLATFORM="${PLATFORM:-linux/amd64}"

# ── Versioning ───────────────────────────────────────────────────────
# Two independent version axes:
#   - VERSION file: internal semver, human-bumped via PR
#   - UPSTREAM_TAG: upstream version pin, Renovate-bumped via the
#                   `# renovate:` hint in the Dockerfile
# Final tag embeds both plus the commit SHA for bit-for-bit traceability.

if [ ! -f VERSION ]; then
  echo "ERROR: VERSION file missing" >&2
  exit 1
fi
VERSION=$(tr -d '[:space:]' < VERSION)

if ! git rev-parse HEAD >/dev/null 2>&1; then
  GIT_SHA="unknown"
  GIT_SHORT="unknown"
else
  GIT_SHA=$(git rev-parse HEAD)
  GIT_SHORT=$(git rev-parse --short=7 HEAD)
fi

CREATED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
FULL_TAG="${VERSION}-${UPSTREAM_TAG}-${GIT_SHORT}"

# ── Cert materialisation ─────────────────────────────────────────────
# If CA_CERT is set, write it to certs/ so the certs-true stage can
# COPY it. Overwrites any file with the same name — intentional, CI
# runs should be reproducible. A trailing `touch .gitkeep` keeps the
# directory non-empty even when no cert is injected.

mkdir -p certs
: > certs/.gitkeep
if [ -n "${CA_CERT:-}" ]; then
  echo "${CA_CERT}" > certs/ci-injected.crt
  echo "→ Wrote CA_CERT to certs/ci-injected.crt ($(wc -c < certs/ci-injected.crt) bytes)"
  # Auto-flip INJECT_CERTS on if a cert was provided — caller clearly
  # wants it injected.
  INJECT_CERTS=true
fi

# ── Upstream base digest (optional but preferred) ───────────────────
# `crane digest` queries the upstream registry without pulling the
# image. Used only for the org.opencontainers.image.base.digest label.
# If crane isn't installed or the registry is unreachable, build still
# succeeds — the base.digest label just ends up empty.

UPSTREAM_REF="${UPSTREAM_REGISTRY}/${UPSTREAM_IMAGE}:${UPSTREAM_TAG}"
BASE_DIGEST=""
if command -v crane >/dev/null 2>&1; then
  BASE_DIGEST=$(crane digest "${UPSTREAM_REF}" 2>/dev/null || echo "")
fi

# ── Push target ──────────────────────────────────────────────────────

WANT_PUSH=0
if [ "${1:-}" = "--push" ]; then
  WANT_PUSH=1
  if [ -z "${PUSH_REGISTRY:-}" ] || [ -z "${PUSH_PROJECT:-}" ]; then
    echo "ERROR: PUSH_REGISTRY and PUSH_PROJECT must be set for --push" >&2
    exit 1
  fi
fi

# Full image reference for tagging. Whether we push or not, this is
# what gets baked into labels and emitted to build.env.
if [ -n "${PUSH_REGISTRY:-}" ] && [ -n "${PUSH_PROJECT:-}" ]; then
  FULL_IMAGE="${PUSH_REGISTRY}/${PUSH_PROJECT}/${IMAGE_NAME}:${FULL_TAG}"
else
  FULL_IMAGE="${IMAGE_NAME}:${FULL_TAG}"
fi

# ── Source / URL labels ──────────────────────────────────────────────
# Prefer CI-supplied values (GitLab sets CI_PROJECT_URL; Bamboo sets
# bamboo_planRepository_1_repositoryUrl). Fall back to the first git
# remote URL if available.

SOURCE_URL="${CI_PROJECT_URL:-${bamboo_planRepository_1_repositoryUrl:-}}"
if [ -z "${SOURCE_URL}" ] && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  SOURCE_URL=$(git config --get remote.origin.url 2>/dev/null || echo "")
fi

# ── Report resolved config ───────────────────────────────────────────

echo ""
echo "=========================================="
echo "  container-image-template build"
echo "=========================================="
echo "  Image:              ${FULL_IMAGE}"
echo "  Upstream:           ${UPSTREAM_REF}"
echo "  Upstream digest:    ${BASE_DIGEST:-<not resolved>}"
echo "  Internal version:   ${VERSION}"
echo "  Git commit:         ${GIT_SHORT} (${GIT_SHA})"
echo "  Created (UTC):      ${CREATED}"
echo "  Platform:           ${PLATFORM}"
echo "  Remediate:          ${REMEDIATE}"
echo "  Inject certs:       ${INJECT_CERTS}"
echo "  Original user:      ${ORIGINAL_USER}"
echo "  Vendor:             ${VENDOR}"
echo "  Source URL:         ${SOURCE_URL:-<none>}"
echo "=========================================="
echo ""

# ── Build ────────────────────────────────────────────────────────────
# Dynamic OCI labels passed via --label (the DevSecOps-recommended
# approach). Anything already in the Dockerfile's LABEL block is
# static and survives; --label values here are added on top.

BUILD_ARGS=(
  --build-arg "UPSTREAM_REGISTRY=${UPSTREAM_REGISTRY}"
  --build-arg "UPSTREAM_IMAGE=${UPSTREAM_IMAGE}"
  --build-arg "UPSTREAM_TAG=${UPSTREAM_TAG}"
  --build-arg "INJECT_CERTS=${INJECT_CERTS}"
  --build-arg "REMEDIATE=${REMEDIATE}"
  --build-arg "ORIGINAL_USER=${ORIGINAL_USER}"
)

LABEL_ARGS=(
  --label "org.opencontainers.image.version=${VERSION}"
  --label "org.opencontainers.image.revision=${GIT_SHA}"
  --label "org.opencontainers.image.created=${CREATED}"
  --label "org.opencontainers.image.base.name=${UPSTREAM_REF}"
  --label "org.opencontainers.image.vendor=${VENDOR}"
)
if [ -n "${BASE_DIGEST}" ]; then
  LABEL_ARGS+=(--label "org.opencontainers.image.base.digest=${BASE_DIGEST}")
fi
if [ -n "${SOURCE_URL}" ]; then
  LABEL_ARGS+=(--label "org.opencontainers.image.source=${SOURCE_URL}")
  LABEL_ARGS+=(--label "org.opencontainers.image.url=${SOURCE_URL}")
fi

# Ensure buildx builder is available. `docker buildx` is present in
# modern Docker Desktop / docker-ce. CI images (docker:27-cli) have it
# as a plugin.
if ! docker buildx version >/dev/null 2>&1; then
  echo "ERROR: docker buildx is required (install Docker 20.10+)" >&2
  exit 1
fi

# Use a dedicated builder if one isn't active. Container driver gives
# us consistent behaviour across Docker Desktop and CI dind.
if ! docker buildx inspect template-builder >/dev/null 2>&1; then
  docker buildx create --name template-builder --driver docker-container --use >/dev/null
else
  docker buildx use template-builder >/dev/null
fi

# Output mode:
#   - Default (no REGISTRY_KIND): --push goes straight to PUSH_REGISTRY
#     via buildx. --load for build-only runs.
#   - REGISTRY_KIND=artifactory: always --load first, then the backend
#     retags and pushes. buildx doesn't know about the artifactory
#     layout template system, so we hand the image off after loading.
REGISTRY_KIND_LC="$(echo "${REGISTRY_KIND:-}" | tr '[:upper:]' '[:lower:]')"

OUTPUT_FLAG="--load"
if [ ${WANT_PUSH} -eq 1 ] && [ -z "${REGISTRY_KIND_LC}" ]; then
  OUTPUT_FLAG="--push"
fi

echo "→ docker buildx build (${OUTPUT_FLAG})"
docker buildx build \
  --platform "${PLATFORM}" \
  "${BUILD_ARGS[@]}" \
  "${LABEL_ARGS[@]}" \
  -t "${FULL_IMAGE}" \
  ${OUTPUT_FLAG} \
  .

echo "→ build complete: ${FULL_IMAGE}"

# Export derived values so the backend script can pull them in via
# parameter expansion when building build.env.
export VERSION UPSTREAM_TAG UPSTREAM_REF BASE_DIGEST GIT_SHA CREATED

# ── Push + emit build.env ────────────────────────────────────────────

if [ ${WANT_PUSH} -eq 1 ]; then
  if [ "${REGISTRY_KIND_LC}" = "artifactory" ]; then
    # Delegate to the artifactory backend. It handles retag, docker
    # push, build info, set-props, AND writes build.env with the
    # resolved target + digest.
    BACKEND="${REPO_ROOT}/scripts/push-backends/artifactory.sh"
    if [ ! -f "${BACKEND}" ]; then
      echo "ERROR: REGISTRY_KIND=artifactory but ${BACKEND} not found" >&2
      exit 1
    fi
    # shellcheck disable=SC1090
    . "${BACKEND}"
    push_to_backend "${FULL_IMAGE}" || exit 1
  else
    # Default path: plain docker push already handled by buildx
    # --push above. Just emit build.env with the locally-known values.
    IMAGE_DIGEST=""
    if command -v crane >/dev/null 2>&1; then
      IMAGE_DIGEST=$(crane digest "${FULL_IMAGE}" 2>/dev/null || echo "")
      if [ -n "${IMAGE_DIGEST}" ]; then
        IMAGE_DIGEST="${PUSH_REGISTRY}/${PUSH_PROJECT}/${IMAGE_NAME}@${IMAGE_DIGEST}"
      fi
    fi

    cat > build.env <<EOF
IMAGE_REF=${FULL_IMAGE}
IMAGE_TAG=${FULL_TAG}
IMAGE_DIGEST=${IMAGE_DIGEST}
IMAGE_NAME=${IMAGE_NAME}
INTERNAL_VERSION=${VERSION}
UPSTREAM_TAG=${UPSTREAM_TAG}
UPSTREAM_REF=${UPSTREAM_REF}
BASE_DIGEST=${BASE_DIGEST}
GIT_SHA=${GIT_SHA}
CREATED=${CREATED}
EOF
  fi

  echo "→ wrote build.env"
  cat build.env | sed 's/^/    /'
fi
