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
#
# Config comes from three layers, in increasing precedence:
#
#   1. Dockerfile ARG defaults   — upstream pin (UPSTREAM_REGISTRY,
#                                  UPSTREAM_IMAGE, UPSTREAM_TAG with
#                                  Renovate's `# renovate:` hint)
#   2. image.env                 — per-image toggles (IMAGE_NAME,
#                                  REMEDIATE, INJECT_CERTS, ORIGINAL_USER)
#   3. Shell environment / CI    — anything exported before running
#                                  build.sh wins over the other two,
#                                  useful for CI overrides and testing
#
# We snapshot the shell env first, then source image.env, then re-apply
# the snapshot so user exports still take precedence. If an image.env
# isn't present, we error — a fresh fork of this template MUST have
# one because it's where "what this image is" gets declared.

__SHELL_OVERRIDES=""
for __v in IMAGE_NAME REMEDIATE INJECT_CERTS ORIGINAL_USER \
           UPSTREAM_REGISTRY UPSTREAM_IMAGE UPSTREAM_TAG \
           VENDOR PLATFORM APK_MIRROR CA_CERT \
           REGISTRY_KIND \
           ARTIFACTORY_URL ARTIFACTORY_USER ARTIFACTORY_PASSWORD ARTIFACTORY_TOKEN \
           ARTIFACTORY_TEAM ARTIFACTORY_ENVIRONMENT ARTIFACTORY_PUSH_HOST \
           ARTIFACTORY_IMAGE_REF ARTIFACTORY_MANIFEST_PATH \
           ARTIFACTORY_BUILD_NAME ARTIFACTORY_BUILD_NUMBER ARTIFACTORY_PROPERTIES; do
  if [ "${!__v+set}" = "set" ]; then
    __SHELL_OVERRIDES="${__SHELL_OVERRIDES}${__v}=$(printf '%q' "${!__v}")"$'\n'
  fi
done
unset __v

# image.env resolution: prefer a local (gitignored) image.env for
# per-dev overrides, fall back to the tracked image.env.example.
# This lets fresh clones build without any cp step AND lets devs
# experiment locally without touching committed state.
_image_env_file=""
if [ -f image.env ]; then
  _image_env_file="image.env"
elif [ -f image.env.example ]; then
  _image_env_file="image.env.example"
else
  echo "ERROR: neither image.env nor image.env.example found at repo root" >&2
  echo "       One of these files declares what image the repo builds." >&2
  echo "       See image.env.example in the template for the expected shape." >&2
  exit 1
fi
echo "→ Sourcing ${_image_env_file}"
# shellcheck disable=SC1090
. "./${_image_env_file}"
unset _image_env_file

# Re-apply shell overrides on top of the image.env values.
if [ -n "${__SHELL_OVERRIDES}" ]; then
  while IFS= read -r __line; do
    [ -z "${__line}" ] && continue
    eval "export ${__line}"
  done <<< "${__SHELL_OVERRIDES}"
  unset __line
fi
unset __SHELL_OVERRIDES

# Upstream pin defaults — read out of the Dockerfile so the `# renovate:`
# hint on ARG UPSTREAM_TAG stays the canonical version source. Shell env
# still wins (set above via the snapshot) if someone overrides them.
_read_arg_default() {
  awk -F'=' -v name="$1" '$0 ~ "^ARG "name"=" { gsub(/[[:space:]]/,"",$2); print $2; exit }' Dockerfile
}
UPSTREAM_REGISTRY="${UPSTREAM_REGISTRY:-$(_read_arg_default UPSTREAM_REGISTRY)}"
UPSTREAM_REGISTRY="${UPSTREAM_REGISTRY:-docker.io/library}"
UPSTREAM_IMAGE="${UPSTREAM_IMAGE:-$(_read_arg_default UPSTREAM_IMAGE)}"
UPSTREAM_IMAGE="${UPSTREAM_IMAGE:-nginx}"
UPSTREAM_TAG="${UPSTREAM_TAG:-$(_read_arg_default UPSTREAM_TAG)}"
if [ -z "${UPSTREAM_TAG}" ]; then
  echo "ERROR: UPSTREAM_TAG not set and no default in Dockerfile" >&2
  exit 1
fi

# Required-from-image.env sanity check (all of these should come from
# image.env; error if the file was edited badly).
: "${IMAGE_NAME:?IMAGE_NAME must be set in image.env}"
: "${REMEDIATE:=true}"
: "${INJECT_CERTS:=false}"
: "${ORIGINAL_USER:=root}"

# Org-wide defaults (can be set via CI variable instead of image.env).
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
  --build-arg "APK_MIRROR=${APK_MIRROR:-}"
)

# Label policy: preserve upstream, append ours. See Dockerfile for
# the reasoning. We explicitly set only the labels we want to own:
#   - dynamic provenance (version/revision/created/base.*/source/url)
#   - team identity (vendor/authors) which is intentional override
# Everything else from the upstream image flows through untouched.
LABEL_ARGS=(
  --label "org.opencontainers.image.version=${VERSION}"
  --label "org.opencontainers.image.revision=${GIT_SHA}"
  --label "org.opencontainers.image.created=${CREATED}"
  --label "org.opencontainers.image.base.name=${UPSTREAM_REF}"
  --label "org.opencontainers.image.vendor=${VENDOR}"
  --label "org.opencontainers.image.authors=${AUTHORS:-Platform Engineering}"
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
