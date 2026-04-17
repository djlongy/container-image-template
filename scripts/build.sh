#!/usr/bin/env bash
# Single-image build + push driver.
#
# Computes the pushed tag as <UPSTREAM_TAG>-<gitShort>, pulls the
# upstream base digest for supply-chain labels, invokes
# `docker build` with the full OCI label set, optionally pushes,
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
#   SBOM_ATTEST         default: false — scaffolded for future cosign attest-sbom;
#                       the active SBOM workflow is driven by .gitlab-ci.yml
#                       calling syft/grype on the pushed image directly.
#   REGISTRY_KIND       when unset (default), --push does a plain
#                       `docker push` to PUSH_REGISTRY (Harbor baseline).
#                       Set to "artifactory" to delegate the push step
#                       to scripts/push-backends/artifactory.sh, which
#                       handles layout-template resolution, jf rt bp
#                       build info, and property tagging. Same pattern
#                       as the monorepo — the image is built locally,
#                       then the backend retags and pushes.
#
# Everything else is derived: GIT_SHA from git, CREATED from
# `date -u`, BASE_DIGEST from `crane digest` on the upstream reference.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

# ── Config resolution ────────────────────────────────────────────────
#
# image.env is the single source of truth for everything about the
# image: IMAGE_NAME, UPSTREAM_REGISTRY, UPSTREAM_IMAGE, UPSTREAM_TAG,
# REMEDIATE, INJECT_CERTS, ORIGINAL_USER. One file, three-layer
# precedence:
#
#   1. image.env.example  — tracked, canonical, the template
#   2. image.env          — gitignored, local override for dev work
#   3. Shell / CI env     — always wins, for pipeline overrides
#
# We snapshot the shell env first, then source image.env, then
# re-apply the snapshot so exports still take precedence.

__SHELL_OVERRIDES=""
for __v in IMAGE_NAME DISTRO \
           UPSTREAM_REGISTRY UPSTREAM_IMAGE UPSTREAM_TAG \
           REMEDIATE INJECT_CERTS ORIGINAL_USER \
           PUSH_REGISTRY PUSH_PROJECT VENDOR AUTHORS \
           APK_MIRROR APT_MIRROR CA_CERT \
           REGISTRY_KIND \
           ARTIFACTORY_URL ARTIFACTORY_USER ARTIFACTORY_PASSWORD ARTIFACTORY_TOKEN \
           ARTIFACTORY_PRO ARTIFACTORY_PROJECT \
           ARTIFACTORY_TEAM ARTIFACTORY_ENVIRONMENT ARTIFACTORY_PUSH_HOST \
           ARTIFACTORY_IMAGE_REF ARTIFACTORY_MANIFEST_PATH \
           ARTIFACTORY_BUILD_NAME ARTIFACTORY_BUILD_NUMBER ARTIFACTORY_PROPERTIES \
           ARTIFACTORY_SBOM_REPO \
           VAULT_KV_MOUNT VAULT_CA_PATH; do
  if [ "${!__v+set}" = "set" ]; then
    __SHELL_OVERRIDES="${__SHELL_OVERRIDES}${__v}=$(printf '%q' "${!__v}")"$'\n'
  fi
done
unset __v

_image_env_file=""
if [ -f image.env ]; then
  _image_env_file="image.env"
elif [ -f image.env.example ]; then
  _image_env_file="image.env.example"
else
  echo "ERROR: neither image.env nor image.env.example found at repo root" >&2
  echo "       One of these files declares what image the repo builds." >&2
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

# Required fields — hard-fail with a clear message if image.env is
# missing any of these.
: "${UPSTREAM_REGISTRY:?UPSTREAM_REGISTRY must be set in image.env}"
: "${UPSTREAM_IMAGE:?UPSTREAM_IMAGE must be set in image.env}"
: "${UPSTREAM_TAG:?UPSTREAM_TAG must be set in image.env}"

# Optional with sane defaults.
IMAGE_NAME="${IMAGE_NAME:-${UPSTREAM_IMAGE}}"
DISTRO="${DISTRO:-alpine}"
REMEDIATE="${REMEDIATE:-true}"
INJECT_CERTS="${INJECT_CERTS:-false}"
ORIGINAL_USER="${ORIGINAL_USER:-root}"
VENDOR="${VENDOR:-example.com}"

# Validate DISTRO against the scripts shipped in scripts/remediate/.
# Forkers can add a new distro by dropping scripts/remediate/<name>.sh
# and referencing it from image.env — no build.sh edit needed.
if [ "${REMEDIATE}" = "true" ] && [ ! -f "scripts/remediate/${DISTRO}.sh" ]; then
  echo "ERROR: REMEDIATE=true but scripts/remediate/${DISTRO}.sh does not exist" >&2
  echo "       Available distros: $(ls scripts/remediate/ | sed 's/\.sh$//' | tr '\n' ' ')" >&2
  echo "       Either add a script for '${DISTRO}', set DISTRO to a supported" >&2
  echo "       value in image.env, or set REMEDIATE=false." >&2
  exit 1
fi

# ── Tag computation ──────────────────────────────────────────────────
# Tag format matches the container-images monorepo:
#   <UPSTREAM_TAG>-<gitShort>
# The upstream tag IS the semver; the git SHA differentiates builds
# of the same upstream version (remediation changes, cert rotation,
# etc). No internal version axis.

if ! git rev-parse HEAD >/dev/null 2>&1; then
  GIT_SHA="unknown"
  GIT_SHORT="unknown"
else
  GIT_SHA=$(git rev-parse HEAD)
  GIT_SHORT=$(git rev-parse --short=7 HEAD)
fi

CREATED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
FULL_TAG="${UPSTREAM_TAG}-${GIT_SHORT}"

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
  INJECT_CERTS=true
elif [ -n "${VAULT_CA_PATH:-}" ] && command -v vault >/dev/null 2>&1; then
  # Vault is opt-in — only attempt the pull when VAULT_CA_PATH is
  # explicitly set. VAULT_ADDR must already be exported by the caller
  # (or ~/.vault-token configured) so the CLI has a target.
  if vault kv get -mount="${VAULT_KV_MOUNT:-secret}" \
       -field=certificate "${VAULT_CA_PATH}" \
       > certs/vault-ca.crt 2>/dev/null; then
    echo "→ Pulled CA cert from Vault (${VAULT_KV_MOUNT:-secret}/${VAULT_CA_PATH})"
    INJECT_CERTS=true
  else
    echo "  WARN: Vault pull failed — falling back to certs/ on disk" >&2
    rm -f certs/vault-ca.crt
  fi
fi

# ── Upstream base digest (optional but preferred) ───────────────────
# Used for the org.opencontainers.image.base.digest OCI label — lets
# consumers verify exactly which upstream content this image was built
# from. Tries crane first (fast, no pull needed), then docker CLI
# inspect (works if the image was already pulled). Empty is fine — the
# build still succeeds, just without the provenance label.

UPSTREAM_REF="${UPSTREAM_REGISTRY}/${UPSTREAM_IMAGE}:${UPSTREAM_TAG}"
BASE_DIGEST=""
if command -v crane >/dev/null 2>&1; then
  # Capture stderr alongside stdout — exit code distinguishes success/failure
  _crane_output=$(crane digest "${UPSTREAM_REF}" 2>&1)
  if [ $? -eq 0 ]; then
    BASE_DIGEST="${_crane_output}"
  else
    echo "  WARN: crane digest failed for ${UPSTREAM_REF}" >&2
    printf '%s\n' "${_crane_output}" | head -2 | sed 's/^/        /' >&2
    echo "        (base.digest label will be empty — image build unaffected)" >&2
  fi
else
  # Fallback: try docker buildx imagetools inspect (available with
  # modern Docker, no extra binary needed).
  if docker buildx imagetools inspect --raw "${UPSTREAM_REF}" >/dev/null 2>&1; then
    BASE_DIGEST=$(docker buildx imagetools inspect "${UPSTREAM_REF}" --format '{{.Digest}}' 2>/dev/null || echo "")
  fi
  if [ -z "${BASE_DIGEST}" ]; then
    echo "  NOTE: crane not found and docker fallback didn't resolve upstream digest" >&2
    echo "        Install crane for supply-chain base.digest label:" >&2
    echo "          brew install crane   OR   go install github.com/google/go-containerregistry/cmd/crane@latest" >&2
  fi
fi

# ── Push target ──────────────────────────────────────────────────────
# When REGISTRY_KIND=artifactory, PUSH_REGISTRY and PUSH_PROJECT are
# only used for the intermediate local tag (the backend retags to the
# Artifactory target via its own template). Auto-derive them from
# Artifactory vars so users don't have to set redundant values.

REGISTRY_KIND_LC="$(echo "${REGISTRY_KIND:-}" | tr '[:upper:]' '[:lower:]')"

if [ "${REGISTRY_KIND_LC}" = "artifactory" ]; then
  if [ -z "${PUSH_REGISTRY:-}" ] && [ -n "${ARTIFACTORY_PUSH_HOST:-}" ]; then
    PUSH_REGISTRY="${ARTIFACTORY_PUSH_HOST}"
  elif [ -z "${PUSH_REGISTRY:-}" ] && [ -n "${ARTIFACTORY_URL:-}" ]; then
    PUSH_REGISTRY="${ARTIFACTORY_URL#https://}"
    PUSH_REGISTRY="${PUSH_REGISTRY#http://}"
    PUSH_REGISTRY="${PUSH_REGISTRY%%/*}"
  fi
  if [ -z "${PUSH_PROJECT:-}" ] && [ -n "${ARTIFACTORY_TEAM:-}" ]; then
    PUSH_PROJECT="${ARTIFACTORY_TEAM}"
  fi
fi

WANT_PUSH=0
if [ "${1:-}" = "--push" ]; then
  WANT_PUSH=1
  if [ -z "${PUSH_REGISTRY:-}" ] || [ -z "${PUSH_PROJECT:-}" ]; then
    echo "ERROR: PUSH_REGISTRY and PUSH_PROJECT must be set for --push" >&2
    if [ "${REGISTRY_KIND_LC}" = "artifactory" ]; then
      echo "       (tip: set ARTIFACTORY_PUSH_HOST + ARTIFACTORY_TEAM and they'll" >&2
      echo "        auto-derive PUSH_REGISTRY + PUSH_PROJECT for the local tag)" >&2
    fi
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
echo "  Git commit:         ${GIT_SHORT} (${GIT_SHA})"
echo "  Created (UTC):      ${CREATED}"
echo "  Distro:             ${DISTRO}"
echo "  Remediate:          ${REMEDIATE}$([ "${REMEDIATE}" = "true" ] && echo " (scripts/remediate/${DISTRO}.sh)" || echo "")"
echo "  Inject certs:       ${INJECT_CERTS}"
echo "  Original user:      ${ORIGINAL_USER}"
echo "  APK mirror:         ${APK_MIRROR:-<none>}"
echo "  APT mirror:         ${APT_MIRROR:-<none>}"
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
  --build-arg "DISTRO=${DISTRO}"
  --build-arg "APK_MIRROR=${APK_MIRROR:-}"
  --build-arg "APT_MIRROR=${APT_MIRROR:-}"
)

# Label policy: preserve upstream, append ours. See Dockerfile for
# the reasoning. We explicitly set only the labels we want to own:
#   - dynamic provenance (version/revision/created/base.*/source/url)
#   - team identity (vendor/authors) which is intentional override
# Everything else from the upstream image flows through untouched.
LABEL_ARGS=(
  --label "org.opencontainers.image.vendor=${VENDOR}"
  --label "org.opencontainers.image.authors=${AUTHORS:-Platform Engineering}"
  --label "org.opencontainers.image.created=${CREATED}"
  --label "org.opencontainers.image.revision=${GIT_SHA}"
  --label "org.opencontainers.image.version=${FULL_TAG}"
  --label "org.opencontainers.image.ref.name=${FULL_TAG}"
  --label "org.opencontainers.image.base.name=${UPSTREAM_REF}"
  --label "promoted.from=${UPSTREAM_REF}"
  --label "promoted.tag=${FULL_TAG}"
)
if [ -n "${BASE_DIGEST}" ]; then
  LABEL_ARGS+=(--label "org.opencontainers.image.base.digest=${BASE_DIGEST}")
fi
if [ -n "${SOURCE_URL}" ]; then
  LABEL_ARGS+=(--label "org.opencontainers.image.source=${SOURCE_URL}")
  LABEL_ARGS+=(--label "org.opencontainers.image.url=${SOURCE_URL}")
fi

# REGISTRY_KIND_LC already set above (push target section)

echo "→ docker build"
docker build \
  "${BUILD_ARGS[@]}" \
  "${LABEL_ARGS[@]}" \
  -t "${FULL_IMAGE}" \
  .

echo "→ build complete: ${FULL_IMAGE}"

# Export derived values so the backend script can pull them in via
# parameter expansion when building build.env.
export UPSTREAM_TAG UPSTREAM_REF BASE_DIGEST GIT_SHA CREATED

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
    echo ""
    echo "→ docker push ${FULL_IMAGE}"
    PUSH_OUTPUT=$(docker push "${FULL_IMAGE}" 2>&1) || {
      echo "${PUSH_OUTPUT}" >&2
      echo "ERROR: docker push failed" >&2
      exit 1
    }
    echo "${PUSH_OUTPUT}"
    IMAGE_DIGEST=""
    PUSH_DIGEST=$(printf '%s' "${PUSH_OUTPUT}" | grep -oE 'sha256:[0-9a-f]{64}' | head -1)
    if [ -n "${PUSH_DIGEST}" ]; then
      IMAGE_DIGEST="${PUSH_REGISTRY}/${PUSH_PROJECT}/${IMAGE_NAME}@${PUSH_DIGEST}"
      echo "→ pushed: ${IMAGE_DIGEST}"
    fi

    cat > build.env <<EOF
IMAGE_REF=${FULL_IMAGE}
IMAGE_TAG=${FULL_TAG}
IMAGE_DIGEST=${IMAGE_DIGEST}
IMAGE_NAME=${IMAGE_NAME}
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
