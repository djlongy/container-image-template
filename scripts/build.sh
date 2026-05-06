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
#   REMEDIATE           default: false  — set true to run scripts/remediate/${DISTRO}.sh
#                       (apk upgrade for alpine, apt-get upgrade for debian/ubuntu).
#                       Default flipped from true → false to make the bare-minimum
#                       build path safe: "pull → retag → push" with no surprises
#                       when image.env is missing.
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
# Debug logging
# ════════════════════════════════════════════════════════════════════
# Set BUILD_DEBUG=true to get verbose, "why did this happen?" echoes
# at every decision point — which file was sourced, which env var
# came from where, why a default was applied, why a tool install was
# attempted, etc. Off by default to keep normal build logs clean.
#
# Usage:
#   BUILD_DEBUG=true ./scripts/build.sh --push
#
# In CI: set BUILD_DEBUG=true as a plan/pipeline variable to flip it
# without editing image.env.
_dbg() {
  [ "${BUILD_DEBUG:-false}" = "true" ] && echo "  [debug] $*" >&2
  return 0
}

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

Customisation (fork-owned, no template edits required):

  scripts/extend/customise.sh   optional shell hook. Runs as root
                                after remediate, before the final
                                USER flip. Use for apk/apt installs,
                                chown, writing generated configs, etc.
                                Failures fail the build (set -eu).

  scripts/extend/files/         optional directory. Contents copy
                                verbatim to /opt/app/ in the image
                                (cp -a, permissions preserved). Use
                                for static configs, entrypoint shims,
                                prebuilt binaries.

  Both are optional; missing = no-op. Hook runs AFTER files/ is copied,
  so it can reference /opt/app/ freely. See scripts/extend/README.md
  for the full contract.

All behavioural toggles are env-driven. See image.env.example for the
full list. Commonly-used flags:

  REGISTRY_KIND=artifactory   use scripts/push-backends/artifactory.sh
  REMEDIATE=false             skip scripts/remediate/\${DISTRO}.sh
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
# PHASE 1 — Config loading
# ════════════════════════════════════════════════════════════════════
# image.env is the single source of truth. Three-layer precedence:
#   1. image.env.example  — committed reference template
#   2. image.env          — committed canonical config (preferred)
#   3. Shell / CI env     — always wins, for pipeline-level overrides
#
# Bamboo bonus: any env var named `bamboo_FOO` is auto-imported as
# `FOO` before the snapshot, so plan vars and global vars Just Work
# without a hand-written relay block in bamboo.yaml. Bamboo exposes
# both plan vars and System → Global vars under the same prefix.
#
# We snapshot the shell env first, then source image.env, then
# re-apply the snapshot so exports still take precedence.

# Translate every shell variable named `bamboo_<NAME>` into a bare
# `<NAME>` export, so build.sh can be invoked as `./scripts/build.sh
# --push` from a Bamboo task without a hand-written relay block.
#
# Only auto-imports vars that aren't already set under the bare name
# (so an explicit `export REMEDIATE=true` in the task script wins
# over a bamboo_REMEDIATE plan var, matching the precedence the rest
# of the script assumes).
#
# For renamed vars (e.g. shared global `svc_artifactory_token` →
# script-expected `ARTIFACTORY_TOKEN`), still write a one-line
# `export ARTIFACTORY_TOKEN="${bamboo_svc_artifactory_token:-}"` in
# the bamboo.yaml task — the auto-import only handles exact-match.
_build_import_bamboo_vars() {
  # Only relevant in Bamboo (where bamboo_* env vars are set). On a
  # GitLab runner or local shell this is a fast no-op.
  local __bv __bare __count=0
  while IFS= read -r __bv; do
    [ -z "${__bv}" ] && continue
    __bare="${__bv#bamboo_}"
    # Don't override an already-set bare var (explicit shell export
    # wins over Bamboo plan-var auto-import).
    if [ -n "${!__bare-}" ]; then
      _dbg "bamboo import skip: ${__bare} already set in shell"
      continue
    fi
    # Use indirect expansion to read the bamboo_* value.
    eval "export ${__bare}=\"\${${__bv}}\""
    __count=$((__count+1))
    _dbg "bamboo import: ${__bv} → ${__bare}"
  done < <(env | grep -oE '^bamboo_[A-Za-z_][A-Za-z0-9_]*' || true)

  if [ "${__count}" -gt 0 ]; then
    echo "→ Auto-imported ${__count} bamboo_* env var(s) → bare names"
    _dbg "(set BUILD_DEBUG=true to see the per-var breakdown)"
  fi
}

_build_load_image_env() {
  local __v __line
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
             JF_BINARY_URL JF_DEB_URL JF_RPM_URL JF_INSTALL_DIR \
             SBOM_GENERATE SBOM_TARGET SBOM_FILE \
             APPEND_GIT_SHORT \
             SPLUNK_HEC_URL SPLUNK_HEC_TOKEN SPLUNK_HEC_INDEX SPLUNK_HEC_SOURCETYPE \
             VAULT_KV_MOUNT VAULT_CA_PATH; do
    # Snapshot only when the var is set AND non-empty. Using the bare
    # `+set` test let an empty-string export from the agent shell
    # clobber a non-empty image.env value on replay. Empty-set vars
    # carry no signal of intent, so let image.env win for those.
    if [ -n "${!__v-}" ]; then
      __SHELL_OVERRIDES="${__SHELL_OVERRIDES}${__v}=$(printf '%q' "${!__v}")"$'\n'
      _dbg "shell-set override captured: ${__v}"
    fi
  done

  local _image_env_file=""
  if [ -f image.env ]; then
    _image_env_file="image.env"
    _dbg "image.env present in $(pwd)"
  elif [ -f image.env.example ]; then
    _image_env_file="image.env.example"
    _dbg "image.env not found — falling back to image.env.example"
  else
    echo "ERROR: neither image.env nor image.env.example found at repo root" >&2
    echo "       cwd=$(pwd)" >&2
    echo "       One of these files declares what image the repo builds." >&2
    return 1
  fi
  echo "→ Sourcing ${_image_env_file}"
  # shellcheck disable=SC1090
  . "./${_image_env_file}"

  if [ -n "${__SHELL_OVERRIDES}" ]; then
    _dbg "re-applying shell-set overrides on top of ${_image_env_file}"
    while IFS= read -r __line; do
      [ -z "${__line}" ] && continue
      eval "export ${__line}"
    done <<< "${__SHELL_OVERRIDES}"
  fi
  unset __SHELL_OVERRIDES
}

# Validate required fields + apply defaults + lowercase-normalise
# booleans so TRUE/True/true all work. Fails fast on missing required.
# REMEDIATE/INJECT_CERTS MUST be lowercase for Dockerfile FROM selectors
# (certs-${INJECT_CERTS}, remediate-${REMEDIATE}) to match their stages.
_build_apply_defaults_and_normalise() {
  : "${UPSTREAM_REGISTRY:?UPSTREAM_REGISTRY must be set in image.env}"
  : "${UPSTREAM_IMAGE:?UPSTREAM_IMAGE must be set in image.env}"
  : "${UPSTREAM_TAG:?UPSTREAM_TAG must be set in image.env}"

  # Defaults are SAFE-BY-DEFAULT: every optional behaviour is OFF
  # unless explicitly turned on. The bare-minimum build path is
  # "pull → retag → push" with no remediation, no cert injection,
  # no Xray, no SBOM. This is deliberate — past versions defaulted
  # REMEDIATE=true and people got surprise package upgrades when
  # image.env was missing (e.g. fresh Bamboo checkouts where
  # image.env was gitignored). Opt in via image.env, never have to
  # opt out via troubleshooting.
  [ -z "${IMAGE_NAME:-}"     ] && _dbg "default applied: IMAGE_NAME=${UPSTREAM_IMAGE} (was unset)"
  [ -z "${DISTRO:-}"         ] && _dbg "default applied: DISTRO=alpine (was unset)"
  [ -z "${REMEDIATE:-}"      ] && _dbg "default applied: REMEDIATE=false (was unset/empty — set REMEDIATE=true in image.env to run apk/apt upgrade)"
  [ -z "${INJECT_CERTS:-}"   ] && _dbg "default applied: INJECT_CERTS=false (was unset/empty)"
  [ -z "${ORIGINAL_USER:-}"  ] && _dbg "default applied: ORIGINAL_USER=root (was unset)"
  [ -z "${VENDOR:-}"         ] && _dbg "default applied: VENDOR=example.com (was unset)"

  IMAGE_NAME="${IMAGE_NAME:-${UPSTREAM_IMAGE}}"
  DISTRO="${DISTRO:-alpine}"
  REMEDIATE="${REMEDIATE:-false}"
  INJECT_CERTS="${INJECT_CERTS:-false}"
  ORIGINAL_USER="${ORIGINAL_USER:-root}"
  VENDOR="${VENDOR:-example.com}"

  REMEDIATE="$(printf '%s' "${REMEDIATE}"               | tr '[:upper:]' '[:lower:]')"
  INJECT_CERTS="$(printf '%s' "${INJECT_CERTS}"          | tr '[:upper:]' '[:lower:]')"
  SBOM_GENERATE="$(printf '%s' "${SBOM_GENERATE:-false}" | tr '[:upper:]' '[:lower:]')"
  SBOM_TARGET="$(printf '%s'   "${SBOM_TARGET:-image}"   | tr '[:upper:]' '[:lower:]')"

  _dbg "resolved: REMEDIATE=${REMEDIATE} INJECT_CERTS=${INJECT_CERTS} DISTRO=${DISTRO} SBOM_GENERATE=${SBOM_GENERATE}"

  if [ "${REMEDIATE}" = "true" ] && [ ! -f "scripts/remediate/${DISTRO}.sh" ]; then
    echo "ERROR: REMEDIATE=true but scripts/remediate/${DISTRO}.sh does not exist" >&2
    echo "       Available distros: $(ls scripts/remediate/ | sed 's/\.sh$//' | tr '\n' ' ')" >&2
    echo "       Either add a script for '${DISTRO}', set DISTRO to a supported" >&2
    echo "       value in image.env, or set REMEDIATE=false." >&2
    return 1
  fi
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
# Dockerfile stage can COPY it. If VAULT_CA_PATH is set and `vault` is
# available, pull from Vault instead. Either path flips INJECT_CERTS
# to "true" so the correct stage is selected. Overwrites are
# intentional — CI runs should be reproducible.

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

  if [ -n "${VAULT_CA_PATH:-}" ] && command -v vault >/dev/null 2>&1; then
    _dbg "VAULT_CA_PATH=${VAULT_CA_PATH} and vault CLI available — attempting pull"
    if vault kv get -mount="${VAULT_KV_MOUNT:-secret}" \
         -field=certificate "${VAULT_CA_PATH}" \
         > certs/vault-ca.crt 2>/dev/null; then
      echo "→ Pulled CA cert from Vault (${VAULT_KV_MOUNT:-secret}/${VAULT_CA_PATH})"
      INJECT_CERTS=true
    else
      echo "  WARN: Vault pull failed — falling back to certs/ on disk" >&2
      rm -f certs/vault-ca.crt
    fi
  else
    _dbg "no CA_CERT in env and (VAULT_CA_PATH unset or vault CLI missing) — using certs/ on disk as-is"
  fi
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
    --build-arg "REMEDIATE=${REMEDIATE}"
    --build-arg "ORIGINAL_USER=${ORIGINAL_USER}"
    --build-arg "DISTRO=${DISTRO}"
    --build-arg "APK_MIRROR=${APK_MIRROR:-}"
    --build-arg "APT_MIRROR=${APT_MIRROR:-}"
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

  echo "→ docker build"
  docker build "${build_args[@]}" "${label_args[@]}" -t "${FULL_IMAGE}" .
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
_build_import_bamboo_vars
_build_load_image_env
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
_build_push_and_emit_env

_build_generate_sbom
