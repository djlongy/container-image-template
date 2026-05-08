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
#   ORIGINAL_USER       default: root
#   VENDOR              default: example.com
#   CA_CERT             PEM content of a CA cert to inject (writes to certs/
#                       before build, picked up by the COPY in Dockerfile).
#                       Typical CI source: curl from an Artifactory generic
#                       repo into a CI variable.
#                       Package upgrades / extra installs / file drops are
#                       NOT a build.sh concern — add those directly to the
#                       Dockerfile in the marked fork-edit region.
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
#
# ── Structure ───────────────────────────────────────────────────────
# The script is organised into small, named phases. Each phase is one
# function; the orchestrator at the bottom of this file calls them in
# order. Phases never skip downstream work — if a helper needs to
# surface a failure, it returns non-zero and the orchestrator handles
# the rollup. This shape is a deliberate response to a class of bug
# where a `return 0` in a nested skip-block silently dropped downstream
# steps like build.env emission.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

# ════════════════════════════════════════════════════════════════════
# Shared lib: image.env loader + bamboo_* importer + _dbg
# ════════════════════════════════════════════════════════════════════
# scripts/lib/load-image-env.sh provides:
#   _dbg <msg>            — debug echo (BUILD_DEBUG=true to enable)
#   import_bamboo_vars    — translate bamboo_* env vars to bare names
#   load_image_env        — source ./image.env (REQUIRED), apply
#                           shell-set overrides on top
#
# Sourced once here. Other scripts (scan/xray-vuln.sh, scan/xray-sbom.sh,
# sbom-post.sh) source the same lib so all config loading goes through
# the same code path — same precedence, same debug logs, same fail-fast
# message on missing image.env.
# shellcheck source=lib/load-image-env.sh
. "${REPO_ROOT}/scripts/lib/load-image-env.sh"

# ════════════════════════════════════════════════════════════════════
# PHASE 0 — Argument parsing
# ════════════════════════════════════════════════════════════════════
# Runs first, before any work. Sets WANT_PUSH and WANT_DRY_RUN for
# later phases. Unknown flags fail loud with a usage hint instead of
# being silently ignored (which let e.g. `--list` trigger a full build
# when the user was just probing for options).

_build_print_usage() {
  cat <<EOF
Usage: ./scripts/build.sh [--push | --dry-run | --help]

  (no args)    Build locally, load into Docker daemon, don't push.
  --push       Build, then push to PUSH_REGISTRY/PUSH_PROJECT (or via
               the Artifactory backend when REGISTRY_KIND=artifactory).
  --dry-run    Resolve config + base digest, print the report block,
               stop before docker build. No image produced. Useful for
               "what would this build with my current env?"
  --help, -h   This message.

Per-fork customisation: edit the Dockerfile directly, in the
"FORK EDITS GO HERE" region between the cert-injection stage and
the final USER flip. Use that region for RUN \`apk upgrade\`/\`apt-get
upgrade\` (CVE remediation), package installs, COPY of static configs,
ENV/HEALTHCHECK lines, etc.

All behavioural toggles are env-driven. See image.env.example for the
full list. Commonly-used flags:

  REGISTRY_KIND=artifactory   use scripts/push-backends/artifactory.sh
  INJECT_CERTS=true           bake certs/*.crt into the trust store
  SBOM_GENERATE=true          emit <image>-<tag>.cdx.json after build
  ARTIFACTORY_PRO=true        enable Pro-tier push path
  ARTIFACTORY_XRAY_PRESCAN=true
                              jf docker scan BEFORE push (admin gate)
  ARTIFACTORY_XRAY_FAIL_ON_VIOLATIONS=true
                              fail build on Xray policy violation
EOF
}

_build_parse_args() {
  WANT_PUSH=0
  WANT_DRY_RUN=0

  # Zero or one arg. More than one is rejected — keeps the contract
  # simple and discourages drift where people invent combinations.
  if [ $# -gt 1 ]; then
    echo "ERROR: too many arguments (got $#, expected 0 or 1)" >&2
    echo "" >&2
    _build_print_usage >&2
    return 1
  fi

  case "${1:-}" in
    "")            ;;
    --push)        WANT_PUSH=1 ;;
    --dry-run)     WANT_DRY_RUN=1 ;;
    --help|-h)     _build_print_usage; exit 0 ;;
    *)
      echo "ERROR: unknown flag '$1'" >&2
      echo "" >&2
      _build_print_usage >&2
      return 1
      ;;
  esac
}

# ════════════════════════════════════════════════════════════════════
# PHASE 1 — Config loading (delegated to scripts/lib/load-image-env.sh)
# ════════════════════════════════════════════════════════════════════
# image.env is the SINGLE source of truth. It MUST exist or the build
# fails — image.env.example is a TEMPLATE you copy from on first
# checkout, never sourced as real config.
#
# Two-layer precedence:
#   1. image.env          — committed canonical config (REQUIRED)
#   2. Shell / CI env     — always wins, for pipeline-level overrides
#
# Bamboo bonus: any env var named `bamboo_FOO` is auto-imported as
# `FOO` before the snapshot via import_bamboo_vars (also in the lib).
#
# Implementation lives in scripts/lib/load-image-env.sh and is shared
# by all scripts that read image.env (xray-vuln.sh, xray-sbom.sh,
# sbom-post.sh, etc.). See that file for the snapshot/restore details.

# Validate required fields + apply defaults + lowercase-normalise
# booleans so TRUE/True/true all work. Fails fast on missing required.
# INJECT_CERTS MUST be lowercase for the Dockerfile FROM selector
# (certs-${INJECT_CERTS}) to match its stage.
_build_apply_defaults_and_normalise() {
  : "${UPSTREAM_REGISTRY:?UPSTREAM_REGISTRY must be set in image.env}"
  : "${UPSTREAM_IMAGE:?UPSTREAM_IMAGE must be set in image.env}"
  : "${UPSTREAM_TAG:?UPSTREAM_TAG must be set in image.env}"

  # Defaults are SAFE-BY-DEFAULT: every optional behaviour is OFF
  # unless explicitly turned on. The bare-minimum build path is
  # "pull → retag → push" with no cert injection, no Xray, no SBOM.
  # Anything bespoke (package upgrades, extra installs, file drops)
  # goes directly in the Dockerfile's fork-edit region — never sneaks
  # into the upstream template path via env-var toggles.
  [ -z "${IMAGE_NAME:-}"     ] && _dbg "default applied: IMAGE_NAME=${UPSTREAM_IMAGE} (was unset)"
  [ -z "${INJECT_CERTS:-}"   ] && _dbg "default applied: INJECT_CERTS=false (was unset/empty)"
  [ -z "${ORIGINAL_USER:-}"  ] && _dbg "default applied: ORIGINAL_USER=root (was unset)"
  [ -z "${VENDOR:-}"         ] && _dbg "default applied: VENDOR=example.com (was unset)"

  IMAGE_NAME="${IMAGE_NAME:-${UPSTREAM_IMAGE}}"
  INJECT_CERTS="${INJECT_CERTS:-false}"
  ORIGINAL_USER="${ORIGINAL_USER:-root}"
  VENDOR="${VENDOR:-example.com}"

  INJECT_CERTS="$(printf '%s' "${INJECT_CERTS}"          | tr '[:upper:]' '[:lower:]')"
  SBOM_GENERATE="$(printf '%s' "${SBOM_GENERATE:-false}" | tr '[:upper:]' '[:lower:]')"
  SBOM_TARGET="$(printf '%s'   "${SBOM_TARGET:-image}"   | tr '[:upper:]' '[:lower:]')"

  _dbg "resolved: INJECT_CERTS=${INJECT_CERTS} SBOM_GENERATE=${SBOM_GENERATE}"
}

# ════════════════════════════════════════════════════════════════════
# PHASE 2 — Tag computation + source URL
# ════════════════════════════════════════════════════════════════════
# Tag format matches the container-images monorepo:
#   <UPSTREAM_TAG>-<gitShort>
# The upstream tag IS the semver; the git SHA differentiates builds
# of the same upstream version. No internal version axis.

_build_compute_tag() {
  if ! git rev-parse HEAD >/dev/null 2>&1; then
    GIT_SHA="unknown"
    GIT_SHORT="unknown"
  else
    GIT_SHA=$(git rev-parse HEAD)
    GIT_SHORT=$(git rev-parse --short=7 HEAD)
  fi
  CREATED=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # APPEND_GIT_SHORT controls whether the pushed tag carries the
  # git short SHA. Default true (build differentiation matters when
  # rebuilding the same upstream tag). Set to false/0/no to keep the
  # raw upstream tag — useful when UPSTREAM_TAG is a moving alias
  # like "latest" or "stable" and you want the local image tag to
  # mirror that exactly. Falsy values: false/False/FALSE/0/no/No/NO.
  local _append="${APPEND_GIT_SHORT:-true}"
  case "$(printf '%s' "${_append}" | tr '[:upper:]' '[:lower:]')" in
    false|0|no|off)
      FULL_TAG="${UPSTREAM_TAG}"
      _dbg "APPEND_GIT_SHORT=${_append} → tag=${FULL_TAG} (no SHA suffix)"
      ;;
    *)
      FULL_TAG="${UPSTREAM_TAG}-${GIT_SHORT}"
      _dbg "APPEND_GIT_SHORT=${_append} → tag=${FULL_TAG}"
      ;;
  esac
}

# CI-supplied source URL (GitLab / Bamboo) or git remote fallback.
_build_resolve_source_url() {
  SOURCE_URL="${CI_PROJECT_URL:-${bamboo_planRepository_1_repositoryUrl:-}}"
  if [ -z "${SOURCE_URL}" ] && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    SOURCE_URL=$(git config --get remote.origin.url 2>/dev/null || echo "")
  fi
}

# ════════════════════════════════════════════════════════════════════
# PHASE 3 — Cert materialisation
# ════════════════════════════════════════════════════════════════════
# If CA_CERT is set (CI secret), write it to certs/ so the certs-true
# Dockerfile stage can COPY it, and flip INJECT_CERTS to "true" so the
# correct stage is selected. Overwrites are intentional — CI runs
# should be reproducible. Typical CI source: curl from an Artifactory
# generic repo into the CA_CERT variable (or set the variable's value
# to the PEM directly).

_build_materialise_certs() {
  mkdir -p certs
  : > certs/.gitkeep

  if [ -n "${CA_CERT:-}" ]; then
    echo "${CA_CERT}" > certs/ci-injected.crt
    echo "→ Wrote CA_CERT to certs/ci-injected.crt ($(wc -c < certs/ci-injected.crt) bytes)"
    _dbg "CA_CERT was set in env → flipping INJECT_CERTS to true"
    INJECT_CERTS=true
    return 0
  fi

  _dbg "no CA_CERT in env — using certs/ on disk as-is (empty dir = no injection)"
}

# ════════════════════════════════════════════════════════════════════
# PHASE 4 — Push target derivation
# ════════════════════════════════════════════════════════════════════
# When REGISTRY_KIND=artifactory, PUSH_REGISTRY/PUSH_PROJECT are only
# used for the intermediate local tag (the backend retags via its own
# layout template). Auto-derive from Artifactory vars so users don't
# set redundant values. Also parses --push and computes FULL_IMAGE +
# UPSTREAM_REF.

_build_resolve_push_target() {
  REGISTRY_KIND_LC="$(echo "${REGISTRY_KIND:-}" | tr '[:upper:]' '[:lower:]')"
  _dbg "REGISTRY_KIND=${REGISTRY_KIND:-<unset>} → backend=${REGISTRY_KIND_LC:-default-harbor-style}"

  if [ "${REGISTRY_KIND_LC}" = "artifactory" ]; then
    if [ -z "${PUSH_REGISTRY:-}" ] && [ -n "${ARTIFACTORY_PUSH_HOST:-}" ]; then
      PUSH_REGISTRY="${ARTIFACTORY_PUSH_HOST}"
      _dbg "PUSH_REGISTRY auto-derived from ARTIFACTORY_PUSH_HOST=${PUSH_REGISTRY}"
    elif [ -z "${PUSH_REGISTRY:-}" ] && [ -n "${ARTIFACTORY_URL:-}" ]; then
      PUSH_REGISTRY="${ARTIFACTORY_URL#https://}"
      PUSH_REGISTRY="${PUSH_REGISTRY#http://}"
      PUSH_REGISTRY="${PUSH_REGISTRY%%/*}"
      _dbg "PUSH_REGISTRY auto-derived from ARTIFACTORY_URL=${PUSH_REGISTRY}"
    fi
    # Reverse derivation: if only PUSH_REGISTRY is set (homelab /
    # single-host on-prem case where the same FQDN serves both Docker
    # registry and REST API), populate ARTIFACTORY_URL from it so the
    # backend's API calls have a target.
    #
    # NOT safe on JFrog Cloud SaaS — Cloud splits the hosts (REST at
    # mycorp.jfrog.io, docker at mycorp-docker.jfrog.io). On Cloud,
    # set ARTIFACTORY_URL explicitly in image.env so this branch is
    # skipped.
    if [ -z "${ARTIFACTORY_URL:-}" ] && [ -n "${PUSH_REGISTRY:-}" ]; then
      ARTIFACTORY_URL="https://${PUSH_REGISTRY}"
      _dbg "ARTIFACTORY_URL auto-derived from PUSH_REGISTRY=${ARTIFACTORY_URL} (homelab/single-host pattern; set explicitly on JFrog Cloud)"
    fi
    if [ -z "${PUSH_PROJECT:-}" ] && [ -n "${ARTIFACTORY_TEAM:-}" ]; then
      PUSH_PROJECT="${ARTIFACTORY_TEAM}"
      _dbg "PUSH_PROJECT auto-derived from ARTIFACTORY_TEAM=${PUSH_PROJECT}"
    fi
  fi

  # WANT_PUSH was set by _build_parse_args; validate push target only
  # when push is actually requested.
  if [ "${WANT_PUSH}" -eq 1 ]; then
    if [ -z "${PUSH_REGISTRY:-}" ] || [ -z "${PUSH_PROJECT:-}" ]; then
      echo "ERROR: PUSH_REGISTRY and PUSH_PROJECT must be set for --push" >&2
      if [ "${REGISTRY_KIND_LC}" = "artifactory" ]; then
        echo "       (tip: set ARTIFACTORY_PUSH_HOST + ARTIFACTORY_TEAM and they'll" >&2
        echo "        auto-derive PUSH_REGISTRY + PUSH_PROJECT for the local tag)" >&2
      fi
      return 1
    fi
  fi

  if [ -n "${PUSH_REGISTRY:-}" ] && [ -n "${PUSH_PROJECT:-}" ]; then
    FULL_IMAGE="${PUSH_REGISTRY}/${PUSH_PROJECT}/${IMAGE_NAME}:${FULL_TAG}"
  else
    FULL_IMAGE="${IMAGE_NAME}:${FULL_TAG}"
  fi

  UPSTREAM_REF="${UPSTREAM_REGISTRY}/${UPSTREAM_IMAGE}:${UPSTREAM_TAG}"
}

# ════════════════════════════════════════════════════════════════════
# PHASE 5 — Report resolved config
# ════════════════════════════════════════════════════════════════════
# Printed BEFORE the upstream digest is resolved — the user sees
# progress immediately. Digest resolution runs next and can take a few
# seconds against slow/air-gapped registries.

_build_print_config_report() {
  echo ""
  echo "=========================================="
  echo "  container-image-template build"
  echo "=========================================="
  echo "  Image:              ${FULL_IMAGE}"
  echo "  Upstream:           ${UPSTREAM_REF}"
  echo "  Upstream digest:    <resolving...>"
  echo "  Git commit:         ${GIT_SHORT} (${GIT_SHA})"
  echo "  Created (UTC):      ${CREATED}"
  echo "  Inject certs:       ${INJECT_CERTS}"
  echo "  Original user:      ${ORIGINAL_USER}"
  echo "  Vendor:             ${VENDOR}"
  echo "  Source URL:         ${SOURCE_URL:-<none>}"
  echo "=========================================="
  echo ""
}

# ════════════════════════════════════════════════════════════════════
# PHASE 6 — Upstream base digest resolution
# ════════════════════════════════════════════════════════════════════
# Used for the org.opencontainers.image.base.digest OCI label. Strategy:
#   1. crane digest                       — fast, manifest-only
#   2. auto-install crane from CRANE_URL  — if not on PATH
#   3. docker buildx imagetools inspect   — fallback
# Empty BASE_DIGEST is non-fatal — the build still succeeds.

# If no CRANE_URL is set, derive one matching host OS/arch.
_build_derive_crane_url() {
  [ -n "${CRANE_URL:-}" ] && return 0

  local _os="" _arch=""
  case "$(uname -s)" in
    Linux)  _os="Linux" ;;
    Darwin) _os="Darwin" ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64)   _arch="x86_64" ;;
    aarch64|arm64)  _arch="arm64" ;;
  esac
  if [ -n "${_os}" ] && [ -n "${_arch}" ]; then
    CRANE_URL="https://github.com/google/go-containerregistry/releases/download/v0.20.2/go-containerregistry_${_os}_${_arch}.tar.gz"
  fi
}

# Try to install crane into ${REPO_ROOT}/.bin from CRANE_URL. Never
# fatal — returns 0 on success, 1 on failure (caller falls back).
_build_install_crane() {
  if command -v crane >/dev/null 2>&1; then
    _dbg "crane already on PATH: $(command -v crane)"
    return 0
  fi
  _build_derive_crane_url

  if [ -z "${CRANE_URL:-}" ]; then
    echo "  NOTE: crane not on PATH and CRANE_URL not set — skipping install" >&2
    echo "        (will fall back to docker buildx imagetools inspect)" >&2
    _dbg "uname=$(uname -s)/$(uname -m) didn't match a known crane release URL"
    return 1
  fi

  echo "→ crane not on PATH — installing from ${CRANE_URL}"
  mkdir -p "${REPO_ROOT}/.bin"
  if curl -fSL --progress-bar --max-time 120 "${CRANE_URL}" \
       | tar xz -C "${REPO_ROOT}/.bin" crane 2>/dev/null \
     && [ -x "${REPO_ROOT}/.bin/crane" ]; then
    export PATH="${REPO_ROOT}/.bin:${PATH}"
    echo "  ✓ crane installed to ${REPO_ROOT}/.bin/crane ($(${REPO_ROOT}/.bin/crane version 2>&1 | head -1))"
    return 0
  fi

  echo "  WARN: crane install failed — URL unreachable or tarball invalid" >&2
  echo "        (will fall back to docker buildx imagetools inspect)" >&2
  return 1
}

_build_resolve_with_crane() {
  command -v crane >/dev/null 2>&1 || return 1

  echo "→ Resolving upstream digest: crane digest ${UPSTREAM_REF}"
  local _out _rc
  _out=$(crane digest "${UPSTREAM_REF}" 2>&1) && _rc=0 || _rc=$?
  if [ "${_rc}" -eq 0 ]; then
    BASE_DIGEST="${_out}"
    echo "  ✓ ${BASE_DIGEST}"
    return 0
  fi
  echo "  WARN: crane digest failed (rc=${_rc}) for ${UPSTREAM_REF}" >&2
  printf '%s\n' "${_out}" | head -2 | sed 's/^/        /' >&2
  return 1
}

_build_resolve_with_buildx() {
  command -v docker >/dev/null 2>&1 || return 1

  echo "→ Resolving upstream digest: docker buildx imagetools inspect ${UPSTREAM_REF}"
  BASE_DIGEST=$(docker buildx imagetools inspect "${UPSTREAM_REF}" --format '{{.Digest}}' 2>/dev/null || echo "")
  if [ -n "${BASE_DIGEST}" ]; then
    echo "  ✓ ${BASE_DIGEST}"
    return 0
  fi
  echo "  WARN: docker buildx imagetools inspect also failed" >&2
  echo "        (base.digest label will be empty — image build unaffected)" >&2
  return 1
}

_build_resolve_base_digest() {
  BASE_DIGEST=""
  _build_install_crane || true
  _build_resolve_with_crane && return 0
  _build_resolve_with_buildx || true
  return 0
}

# ════════════════════════════════════════════════════════════════════
# PHASE 7 — docker build
# ════════════════════════════════════════════════════════════════════
# Dynamic OCI labels passed via --label. Label policy: preserve
# upstream, append ours. See Dockerfile for the reasoning — we
# explicitly own only the dynamic provenance labels and team
# identity; everything else flows through untouched.

_build_docker_build() {
  local build_args=(
    --build-arg "UPSTREAM_REGISTRY=${UPSTREAM_REGISTRY}"
    --build-arg "UPSTREAM_IMAGE=${UPSTREAM_IMAGE}"
    --build-arg "UPSTREAM_TAG=${UPSTREAM_TAG}"
    --build-arg "INJECT_CERTS=${INJECT_CERTS}"
    --build-arg "ORIGINAL_USER=${ORIGINAL_USER}"
  )
  local label_args=(
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
    label_args+=(--label "org.opencontainers.image.base.digest=${BASE_DIGEST}")
  fi
  if [ -n "${SOURCE_URL}" ]; then
    label_args+=(--label "org.opencontainers.image.source=${SOURCE_URL}")
    label_args+=(--label "org.opencontainers.image.url=${SOURCE_URL}")
  fi

  # --provenance=false --sbom=false: force buildx to emit a FLAT
  # single-arch v2 distribution manifest (config + layers in the tag
  # dir) instead of an OCI image index wrapping the manifest +
  # attestation manifest. The latter happens by default on:
  #
  #   - Docker Desktop / Colima (vz-rosetta) with the containerd
  #     image store enabled — supports native index storage
  #   - buildx >= 0.13 — defaults to `--provenance=mode=min`
  #
  # The index landing in JFrog as <tag>/list.manifest.json puts the
  # actual layer blobs in <repo>/<image>/sha256:<digest>/ rather than
  # in the tag dir, which makes our Free-tier build-info merger
  # (lib/build-info-merge.py) see one file in the tag dir and report
  # "1 artifact, 0 dependencies (fallback)" instead of the proper
  # "manifest + config + N layers" count.
  #
  # We don't consume buildx's provenance/SBOM attestations — Xray
  # scans cover provenance separately and Syft + sbom-post.sh cover
  # SBOMs separately — so disabling these flags is no real loss.
  # If you ever want the buildx-generated attestations back AND
  # correct artifact counts, the alternative is teaching the merger
  # to walk the OCI index → resolve per-arch manifest → fetch blobs
  # from the digest path (see scripts/lib/build-info-merge.py
  # `_compute_inherited_blob_digests`).
  echo "→ docker build"
  docker build --provenance=false --sbom=false \
    "${build_args[@]}" "${label_args[@]}" -t "${FULL_IMAGE}" .
  echo "→ build complete: ${FULL_IMAGE}"

  # Export derived values so the sourced backend script can pull them
  # in via parameter expansion when building build.env.
  export UPSTREAM_TAG UPSTREAM_REF BASE_DIGEST GIT_SHA CREATED
}

# ════════════════════════════════════════════════════════════════════
# PHASE 8 — Push + build.env
# ════════════════════════════════════════════════════════════════════
# REGISTRY_KIND=artifactory delegates to the backend, which handles
# retag, push, build-info, property tagging, AND writes build.env.
# Default (unset) is a plain docker push with a local build.env write.

_build_push_artifactory() {
  local backend="${REPO_ROOT}/scripts/push-backends/artifactory.sh"
  if [ ! -f "${backend}" ]; then
    echo "ERROR: REGISTRY_KIND=artifactory but ${backend} not found" >&2
    return 1
  fi
  # shellcheck disable=SC1090
  . "${backend}"
  push_to_backend "${FULL_IMAGE}" || return 1
}

_build_push_default() {
  echo ""
  echo "→ docker push ${FULL_IMAGE}"
  local push_output push_digest
  push_output=$(docker push "${FULL_IMAGE}" 2>&1) || {
    echo "${push_output}" >&2
    echo "ERROR: docker push failed" >&2
    return 1
  }
  echo "${push_output}"

  IMAGE_DIGEST=""
  push_digest=$(printf '%s' "${push_output}" | grep -oE 'sha256:[0-9a-f]{64}' | head -1)
  if [ -n "${push_digest}" ]; then
    IMAGE_DIGEST="${PUSH_REGISTRY}/${PUSH_PROJECT}/${IMAGE_NAME}@${push_digest}"
    echo "→ pushed: ${IMAGE_DIGEST}"
  fi
  # Export for downstream SBOM generation without re-parsing build.env.
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
}

# ════════════════════════════════════════════════════════════════════
# PHASE 7.5 — Docker login (image.env values, not just CI shell env)
# ════════════════════════════════════════════════════════════════════
# Login is done HERE in build.sh (not in the CI yaml's before_script)
# so credentials can flow from image.env → load_image_env → push.
# Previously the CI yaml's before_script hardcoded the login using its
# own shell env, which meant PUSH_REGISTRY/USER/PASSWORD HAD to be CI
# variables — image.env values for those would never reach the login
# step. Moving the login here makes image.env the canonical source for
# everything except the password (which still belongs in CI as a
# masked secret).
#
# Two paths matched to the push backend selector:
#   REGISTRY_KIND=artifactory → login to ARTIFACTORY_PUSH_HOST
#   anything else            → login to PUSH_REGISTRY (Harbor baseline)
#
# Both no-op cleanly when the corresponding USER/PASSWORD pair is
# empty (e.g. unauthenticated pulls / scratchpad runs).
_build_docker_login() {
  if [ "${WANT_PUSH}" -ne 1 ]; then
    _dbg "WANT_PUSH=0 — skipping docker login"
    return 0
  fi
  if ! command -v docker >/dev/null 2>&1; then
    _dbg "docker CLI not on PATH — skipping login (push will fail)"
    return 0
  fi

  if [ "${REGISTRY_KIND_LC}" = "artifactory" ]; then
    local _host="${ARTIFACTORY_PUSH_HOST:-${PUSH_REGISTRY:-}}"
    local _user="${ARTIFACTORY_USER:-}"
    local _secret="${ARTIFACTORY_TOKEN:-${ARTIFACTORY_PASSWORD:-}}"
    if [ -n "${_host}" ] && [ -n "${_user}" ] && [ -n "${_secret}" ]; then
      echo "→ docker login ${_host} (Artifactory backend)"
      printf '%s' "${_secret}" | docker login "${_host}" -u "${_user}" --password-stdin
    else
      _dbg "Artifactory creds incomplete (host=${_host} user=${_user:+set}) — skipping login"
    fi
  else
    if [ -n "${PUSH_REGISTRY:-}" ] && [ -n "${PUSH_REGISTRY_USER:-}" ] && [ -n "${PUSH_REGISTRY_PASSWORD:-}" ]; then
      echo "→ docker login ${PUSH_REGISTRY} (default backend)"
      printf '%s' "${PUSH_REGISTRY_PASSWORD}" | docker login "${PUSH_REGISTRY}" -u "${PUSH_REGISTRY_USER}" --password-stdin
    else
      _dbg "Default-backend creds incomplete (registry=${PUSH_REGISTRY:-} user=${PUSH_REGISTRY_USER:+set}) — skipping login"
    fi
  fi
}

_build_push_and_emit_env() {
  if [ "${WANT_PUSH}" -ne 1 ]; then
    _dbg "WANT_PUSH=0 (no --push flag) — skipping push + build.env emission"
    return 0
  fi

  _dbg "dispatching push: backend=${REGISTRY_KIND_LC:-default} target=${FULL_IMAGE}"
  if [ "${REGISTRY_KIND_LC}" = "artifactory" ]; then
    _build_push_artifactory || return 1
  else
    _build_push_default || return 1
  fi

  echo "→ wrote build.env"
  sed 's/^/    /' build.env
}

# ════════════════════════════════════════════════════════════════════
# PHASE 9 — SBOM generation (opt-in, decoupled from shipping)
# ════════════════════════════════════════════════════════════════════
# Emits a CycloneDX JSON next to the built image. Filename follows
# Artifactory Xray's expected <name>.cdx.json convention so it's
# auto-indexed when whichever stage does the upload picks it up.
#
# Off by default on purpose — the CI pipeline already has a dedicated
# `sbom` stage (see .gitlab-ci.yml) that does this against the pushed
# digest, and a separate `sbom-ingest` stage that ships via
# scripts/sbom-post.sh. Running both would duplicate work.
#
# Turn SBOM_GENERATE=true on for:
#   - Local dev runs where you want a scanable BOM without the pipeline
#   - Forks that build non-docker artifacts (Ansible, pip, npm, go
#     source) and don't have a separate sbom CI stage
#
# Shipping stays the domain of scripts/sbom-post.sh as a standalone
# stage — do not chain it here.

_build_install_syft() {
  command -v syft >/dev/null 2>&1 && return 0

  local _url="${SYFT_INSTALLER_URL:-https://raw.githubusercontent.com/anchore/syft/main/install.sh}"
  local _ver="${SYFT_VERSION:-v1.14.0}"
  echo ""
  echo "→ syft not on PATH — installing ${_ver} from ${_url}"
  mkdir -p "${REPO_ROOT}/.bin"
  if curl -fsSL --max-time 120 "${_url}" \
       | sh -s -- -b "${REPO_ROOT}/.bin" "${_ver}" >/dev/null 2>&1 \
     && [ -x "${REPO_ROOT}/.bin/syft" ]; then
    export PATH="${REPO_ROOT}/.bin:${PATH}"
    echo "  ✓ syft installed ($(${REPO_ROOT}/.bin/syft version 2>&1 | head -1))"
    return 0
  fi
  echo "  WARN: syft install failed — skipping SBOM generation" >&2
  return 1
}

_build_generate_sbom() {
  [ "${SBOM_GENERATE}" = "true" ] || return 0

  _build_install_syft || return 0
  command -v syft >/dev/null 2>&1 || return 0

  local basename scan_target
  basename="${IMAGE_NAME##*/}-${FULL_TAG}"
  SBOM_FILE="${SBOM_FILE:-${basename}.cdx.json}"

  case "${SBOM_TARGET}" in
    source)  scan_target="dir:${REPO_ROOT}" ;;
    image|*) scan_target="${IMAGE_DIGEST:-${FULL_IMAGE}}" ;;
  esac

  echo ""
  echo "→ syft: generating CycloneDX SBOM for ${scan_target}"
  if ! syft "${scan_target}" -o cyclonedx-json="${SBOM_FILE}"; then
    echo "  WARN: syft failed — no SBOM produced" >&2
    return 0
  fi

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
}

# ════════════════════════════════════════════════════════════════════
# Orchestrator
# ════════════════════════════════════════════════════════════════════
# One phase per line. Phase helpers never skip downstream work — any
# failure returns non-zero here and the orchestrator exits.

_build_parse_args "$@"
import_bamboo_vars   # from scripts/lib/load-image-env.sh
load_image_env       # from scripts/lib/load-image-env.sh
_build_apply_defaults_and_normalise

_build_compute_tag
_build_resolve_source_url
_build_materialise_certs
_build_resolve_push_target

_build_print_config_report
_build_resolve_base_digest

# --dry-run stops here: config resolved, digest fetched, no image built.
if [ "${WANT_DRY_RUN}" -eq 1 ]; then
  echo "→ --dry-run: stopping before docker build"
  exit 0
fi

_build_docker_build
_build_docker_login
_build_push_and_emit_env

_build_generate_sbom
