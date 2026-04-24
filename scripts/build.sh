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
#   SBOM_GENERATE       default: false — opt-in. When true, syft emits a
#                       CycloneDX JSON next to the built image. Generation
#                       and shipping are intentionally decoupled: this
#                       script ONLY writes the file. scripts/sbom-post.sh
#                       is a separate, standalone stage (wired in as the
#                       sbom-ingest job in .gitlab-ci.yml). Leave this
#                       off when CI's dedicated sbom stage is already
#                       running — turn it on for local dev and for
#                       non-docker forks (Ansible / pip / npm source).
#   SBOM_TARGET         default: image — scan the built image (needs push
#                       to resolve IMAGE_DIGEST, falls back to FULL_IMAGE).
#                       Set to "source" to scan the working directory
#                       instead — useful for forks that ship Ansible,
#                       pip, npm or go source rather than container images.
#   SBOM_FILE           default: <image>-<tag>.cdx.json — override if
#                       you need a specific filename. Suffix must remain
#                       .cdx.json for Artifactory Xray SBOM-import.
#   CRANE_URL           default: auto-detected for host OS/arch —
#                       override to point at an internal mirror for
#                       air-gapped runners.
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
           ARTIFACTORY_SBOM_REPO ARTIFACTORY_GRYPE_DB_REPO \
           ARTIFACTORY_XRAY_FAIL_ON_VIOLATIONS \
           ARTIFACTORY_XRAY_PRESCAN ARTIFACTORY_XRAY_POSTSCAN \
           CRANE_URL SYFT_INSTALLER_URL SYFT_VERSION \
           SBOM_GENERATE SBOM_TARGET SBOM_FILE \
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

# Normalise boolean env vars to lowercase so TRUE/True/true all work
# identically. The Dockerfile FROM selectors (certs-${INJECT_CERTS},
# remediate-${REMEDIATE}) MUST see lowercase values — without this,
# a user setting REMEDIATE=TRUE in image.env would silently fail to
# match any stage and the build would break in a confusing way. Same
# pattern as REGISTRY_KIND_LC below.
REMEDIATE="$(printf '%s' "${REMEDIATE}"      | tr '[:upper:]' '[:lower:]')"
INJECT_CERTS="$(printf '%s' "${INJECT_CERTS}" | tr '[:upper:]' '[:lower:]')"
SBOM_GENERATE="$(printf '%s' "${SBOM_GENERATE:-false}" | tr '[:upper:]' '[:lower:]')"
SBOM_TARGET="$(printf '%s'   "${SBOM_TARGET:-image}"   | tr '[:upper:]' '[:lower:]')"

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

UPSTREAM_REF="${UPSTREAM_REGISTRY}/${UPSTREAM_IMAGE}:${UPSTREAM_TAG}"

# ── Source / URL labels ──────────────────────────────────────────────
# Prefer CI-supplied values (GitLab sets CI_PROJECT_URL; Bamboo sets
# bamboo_planRepository_1_repositoryUrl). Fall back to the first git
# remote URL if available.

SOURCE_URL="${CI_PROJECT_URL:-${bamboo_planRepository_1_repositoryUrl:-}}"
if [ -z "${SOURCE_URL}" ] && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  SOURCE_URL=$(git config --get remote.origin.url 2>/dev/null || echo "")
fi

# ── Report resolved config ───────────────────────────────────────────
# Printed BEFORE resolving the upstream digest so the user sees
# progress immediately. Digest resolution (next section) can take a
# few seconds against slow/air-gapped registries and was previously
# the source of "hung with no output" reports.

echo ""
echo "=========================================="
echo "  container-image-template build"
echo "=========================================="
echo "  Image:              ${FULL_IMAGE}"
echo "  Upstream:           ${UPSTREAM_REF}"
echo "  Upstream digest:    <resolving...>"
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

# ── Upstream base digest (optional but preferred) ───────────────────
# Used for the org.opencontainers.image.base.digest OCI label — lets
# consumers verify exactly which upstream content this image was built
# from. Resolution strategy:
#   1. crane digest        (fast — manifest-only, no image pull)
#   2. auto-install crane  (from CRANE_URL) if not on PATH
#   3. docker buildx imagetools inspect  (fallback if crane install fails)
# Empty is fine — the build still succeeds, just without the
# provenance label.

BASE_DIGEST=""

# Auto-install crane when missing and CRANE_URL is set (matches the
# CI install step). Makes the CRANE_URL env var actually useful on
# developer machines too.
if ! command -v crane >/dev/null 2>&1; then
  # Default URL picks the binary matching the host OS/arch. Override
  # CRANE_URL when mirroring to an internal generic repo.
  if [ -z "${CRANE_URL:-}" ]; then
    case "$(uname -s)" in
      Linux)  _crane_os="Linux" ;;
      Darwin) _crane_os="Darwin" ;;
      *)      _crane_os="" ;;
    esac
    case "$(uname -m)" in
      x86_64|amd64)   _crane_arch="x86_64" ;;
      aarch64|arm64)  _crane_arch="arm64" ;;
      *)              _crane_arch="" ;;
    esac
    if [ -n "${_crane_os}" ] && [ -n "${_crane_arch}" ]; then
      CRANE_URL="https://github.com/google/go-containerregistry/releases/download/v0.20.2/go-containerregistry_${_crane_os}_${_crane_arch}.tar.gz"
    fi
    unset _crane_os _crane_arch
  fi

  if [ -n "${CRANE_URL:-}" ]; then
    echo "→ crane not on PATH — installing from ${CRANE_URL}"
    mkdir -p "${REPO_ROOT}/.bin"
    if curl -fSL --progress-bar --max-time 120 "${CRANE_URL}" \
         | tar xz -C "${REPO_ROOT}/.bin" crane 2>/dev/null \
       && [ -x "${REPO_ROOT}/.bin/crane" ]; then
      export PATH="${REPO_ROOT}/.bin:${PATH}"
      echo "  ✓ crane installed to ${REPO_ROOT}/.bin/crane ($(${REPO_ROOT}/.bin/crane version 2>&1 | head -1))"
    else
      echo "  WARN: crane install failed — URL unreachable or tarball invalid" >&2
      echo "        (will fall back to docker buildx imagetools inspect)" >&2
    fi
  else
    echo "  NOTE: crane not on PATH and CRANE_URL not set — skipping install" >&2
    echo "        (will fall back to docker buildx imagetools inspect)" >&2
  fi
fi

if command -v crane >/dev/null 2>&1; then
  echo "→ Resolving upstream digest: crane digest ${UPSTREAM_REF}"
  _crane_output=$(crane digest "${UPSTREAM_REF}" 2>&1) && _crane_rc=0 || _crane_rc=$?
  if [ "${_crane_rc}" -eq 0 ]; then
    BASE_DIGEST="${_crane_output}"
    echo "  ✓ ${BASE_DIGEST}"
  else
    echo "  WARN: crane digest failed (rc=${_crane_rc}) for ${UPSTREAM_REF}" >&2
    printf '%s\n' "${_crane_output}" | head -2 | sed 's/^/        /' >&2
  fi
  unset _crane_output _crane_rc
fi

if [ -z "${BASE_DIGEST}" ] && command -v docker >/dev/null 2>&1; then
  echo "→ Resolving upstream digest: docker buildx imagetools inspect ${UPSTREAM_REF}"
  BASE_DIGEST=$(docker buildx imagetools inspect "${UPSTREAM_REF}" --format '{{.Digest}}' 2>/dev/null || echo "")
  if [ -n "${BASE_DIGEST}" ]; then
    echo "  ✓ ${BASE_DIGEST}"
  else
    echo "  WARN: docker buildx imagetools inspect also failed" >&2
    echo "        (base.digest label will be empty — image build unaffected)" >&2
  fi
fi

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
    # Export so downstream steps (e.g. SBOM generation) can read it
    # without re-parsing build.env.
    export IMAGE_DIGEST IMAGE_REF="${FULL_IMAGE}"

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

# ── SBOM generation (opt-in, decoupled from SBOM shipping) ──────────
# Emits a CycloneDX JSON next to the built image. Filename follows
# Artifactory Xray's expected <name>.cdx.json convention so it's
# auto-indexed when whichever stage does the upload picks it up.
#
# Off by default on purpose — the CI pipeline already has a dedicated
# `sbom` stage (see .gitlab-ci.yml) that does this against the pushed
# digest, and a separate `sbom-ingest` stage that ships via
# scripts/sbom-post.sh. Running both would duplicate work.
#
# Turn this on (SBOM_GENERATE=true) for:
#   - Local dev runs where you want a scanable BOM without a full pipeline
#   - Forks that build non-docker artifacts (Ansible, pip, npm, go
#     source) and don't have a separate sbom CI stage
#
# Two scan targets:
#   SBOM_TARGET=image   (default)  — built/pushed image content. Uses
#                                    IMAGE_DIGEST when available (with
#                                    --push), else FULL_IMAGE.
#   SBOM_TARGET=source             — the repo working directory. Fits
#                                    Ansible roles, requirements.txt,
#                                    package.json, go.mod, etc.
#
# Shipping stays the domain of scripts/sbom-post.sh as a standalone
# stage — do not chain it here. Downstream callers decide when and how
# to ingest the produced file.

if [ "${SBOM_GENERATE}" = "true" ]; then
  if ! command -v syft >/dev/null 2>&1; then
    _syft_url="${SYFT_INSTALLER_URL:-https://raw.githubusercontent.com/anchore/syft/main/install.sh}"
    _syft_ver="${SYFT_VERSION:-v1.14.0}"
    echo ""
    echo "→ syft not on PATH — installing ${_syft_ver} from ${_syft_url}"
    mkdir -p "${REPO_ROOT}/.bin"
    if curl -fsSL --max-time 120 "${_syft_url}" \
         | sh -s -- -b "${REPO_ROOT}/.bin" "${_syft_ver}" >/dev/null 2>&1 \
       && [ -x "${REPO_ROOT}/.bin/syft" ]; then
      export PATH="${REPO_ROOT}/.bin:${PATH}"
      echo "  ✓ syft installed ($(${REPO_ROOT}/.bin/syft version 2>&1 | head -1))"
    else
      echo "  WARN: syft install failed — skipping SBOM generation" >&2
    fi
    unset _syft_url _syft_ver
  fi

  if command -v syft >/dev/null 2>&1; then
    _sbom_basename="${IMAGE_NAME##*/}-${FULL_TAG}"
    SBOM_FILE="${SBOM_FILE:-${_sbom_basename}.cdx.json}"

    case "${SBOM_TARGET}" in
      source)
        _scan_target="dir:${REPO_ROOT}"
        ;;
      image|*)
        _scan_target="${IMAGE_DIGEST:-${FULL_IMAGE}}"
        ;;
    esac

    echo ""
    echo "→ syft: generating CycloneDX SBOM for ${_scan_target}"
    if syft "${_scan_target}" -o cyclonedx-json="${SBOM_FILE}"; then
      echo "→ SBOM: ${SBOM_FILE} ($(wc -c < "${SBOM_FILE}") bytes)"
      if command -v jq >/dev/null 2>&1; then
        echo "        components: $(jq '.components | length' "${SBOM_FILE}")"
      fi
      # Expose SBOM_FILE to downstream stages (sbom-ingest, etc.) via
      # build.env when it exists. No shipping here — sbom-post.sh runs
      # as its own stage.
      if [ -f build.env ] && ! grep -q "^SBOM_FILE=" build.env; then
        echo "SBOM_FILE=${SBOM_FILE}" >> build.env
      fi
      echo "  (ship via scripts/sbom-post.sh ${SBOM_FILE} in a separate stage)"
    else
      echo "  WARN: syft failed — no SBOM produced" >&2
    fi
    unset _sbom_basename _scan_target
  fi
fi
