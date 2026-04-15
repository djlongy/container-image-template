#!/usr/bin/env bash
# push-backend: JFrog Artifactory (JCR Free and Pro-compatible).
#
# Sourced by scripts/build.sh when REGISTRY_KIND=artifactory. Exposes
# a single entry point — push_to_backend() — that retags the built
# image to the Artifactory-resolved target, docker-pushes it,
# publishes build info via the `jf rt bp` LCD pattern, and tags the
# manifest with structured properties for Xray / search queries.
#
# Same layout template system as ../container-images (the monorepo).
# Set ARTIFACTORY_IMAGE_REF and ARTIFACTORY_MANIFEST_PATH to shell-
# parameter-expansion templates to pick your repo layout. Fallback
# default mirrors the monorepo's Layout A (per-team repo).
#
# Template variables available inside ARTIFACTORY_IMAGE_REF /
# ARTIFACTORY_MANIFEST_PATH:
#   ${ARTIFACTORY_PUSH_HOST}    docker push host
#   ${ARTIFACTORY_TEAM}         team acronym (runtime only)
#   ${ARTIFACTORY_ENVIRONMENT}  dev|prod, optional
#   ${ARTIFACTORY_REPO_SUFFIX}  dev→local, prod→prod (legacy helper)
#   ${IMAGE_NAME}               image short name
#   ${IMAGE_TAG}                full computed tag
#
# Required env:
#   ARTIFACTORY_URL           https://artifactory.example.com
#   ARTIFACTORY_USER          team user with Deploy rights
#   ARTIFACTORY_TOKEN | ARTIFACTORY_PASSWORD   secret
#   ARTIFACTORY_TEAM          team acronym (if your template references it)
#
# Optional env:
#   ARTIFACTORY_PUSH_HOST     docker push hostname (defaults to host
#                             portion of ARTIFACTORY_URL)
#   ARTIFACTORY_IMAGE_REF     image URL template
#   ARTIFACTORY_MANIFEST_PATH REST manifest-path template (for jf rt set-props)
#   ARTIFACTORY_ENVIRONMENT   dev | prod (default: dev)
#   ARTIFACTORY_BUILD_NAME    defaults to ${IMAGE_NAME}
#   ARTIFACTORY_BUILD_NUMBER  defaults to CI_JOB_ID / CI_PIPELINE_ID /
#                             BUILD_NUMBER / GITHUB_RUN_ID / timestamp
#   ARTIFACTORY_PROPERTIES    extra ;-separated props, e.g.
#                             "security.scan=pending;hardened=false"

set -uo pipefail

push_to_backend() {
  local built_local_ref="$1"

  _artifactory_require_env   || return 1
  _artifactory_require_tools || return 1

  # The caller passed us the locally-built image reference. Split
  # into bare name and tag so templates can reference them.
  local image_repo_tag="${built_local_ref##*/}"
  local _img_name="${image_repo_tag%:*}"
  local _img_tag="${image_repo_tag##*:}"

  export IMAGE_NAME="${_img_name}"
  export IMAGE_TAG="${_img_tag}"
  export ARTIFACTORY_TEAM

  : "${ARTIFACTORY_ENVIRONMENT:=dev}"
  case "${ARTIFACTORY_ENVIRONMENT}" in
    prod|production) export ARTIFACTORY_REPO_SUFFIX="prod"  ;;
    *)               export ARTIFACTORY_REPO_SUFFIX="local" ;;
  esac
  export ARTIFACTORY_ENVIRONMENT

  if [ -z "${ARTIFACTORY_PUSH_HOST:-}" ]; then
    local _url_host="${ARTIFACTORY_URL#https://}"
    _url_host="${_url_host#http://}"
    _url_host="${_url_host%%/*}"
    ARTIFACTORY_PUSH_HOST="${_url_host}"
  fi
  export ARTIFACTORY_PUSH_HOST

  # Resolve the two layout templates — shell parameter expansion via
  # eval. Trust boundary matches the rest of build.sh (values come
  # from gitignored configs / shell env).
  local image_ref_tpl manifest_path_tpl
  if [ -n "${ARTIFACTORY_IMAGE_REF:-}" ]; then
    image_ref_tpl="${ARTIFACTORY_IMAGE_REF}"
  else
    image_ref_tpl='${ARTIFACTORY_PUSH_HOST}/${ARTIFACTORY_TEAM}/${IMAGE_NAME}:${IMAGE_TAG}'
  fi
  if [ -n "${ARTIFACTORY_MANIFEST_PATH:-}" ]; then
    manifest_path_tpl="${ARTIFACTORY_MANIFEST_PATH}"
  else
    manifest_path_tpl='${ARTIFACTORY_TEAM}-docker-${ARTIFACTORY_REPO_SUFFIX}/${IMAGE_NAME}/${IMAGE_TAG}/manifest.json'
  fi

  local target manifest_path
  eval "target=\"${image_ref_tpl}\""
  eval "manifest_path=\"${manifest_path_tpl}\""

  echo ""
  echo "=== Artifactory push ==="
  echo "  Source (local):  ${built_local_ref}"
  echo "  Target:          ${target}"
  echo "  Push host:       ${ARTIFACTORY_PUSH_HOST}"
  echo "  Manifest path:   ${manifest_path}"

  _artifactory_jf_config || return 1
  _artifactory_docker_login "${ARTIFACTORY_PUSH_HOST}" || return 1

  docker tag "${built_local_ref}" "${target}"
  local push_output
  push_output=$(docker push "${target}" 2>&1) || {
    echo "${push_output}" >&2
    echo "ERROR: docker push to Artifactory failed" >&2
    return 1
  }
  echo "${push_output}"

  # Resolve the pushed digest for downstream cosign sign + build.env.
  local push_digest=""
  if command -v crane >/dev/null 2>&1; then
    push_digest=$(crane digest "${target}" 2>/dev/null || echo "")
  fi
  if [ -z "${push_digest}" ]; then
    push_digest=$(echo "${push_output}" | awk '/digest: sha256:/{print $3}' | head -1)
  fi

  # Emit build.env for the pipeline — same fields the default path
  # writes, so downstream stages don't care which backend ran.
  local image_ref_bare="${target%:*}"
  local digest_ref=""
  [ -n "${push_digest}" ] && digest_ref="${image_ref_bare}@${push_digest}"

  cat > build.env <<EOF
IMAGE_REF=${target}
IMAGE_TAG=${IMAGE_TAG}
IMAGE_DIGEST=${digest_ref}
IMAGE_NAME=${IMAGE_NAME}
UPSTREAM_TAG=${UPSTREAM_TAG:-unknown}
UPSTREAM_REF=${UPSTREAM_REF:-unknown}
BASE_DIGEST=${BASE_DIGEST:-}
GIT_SHA=${GIT_SHA:-unknown}
CREATED=${CREATED:-}
EOF

  local build_name build_number
  build_name="${ARTIFACTORY_BUILD_NAME:-${IMAGE_NAME}}"
  build_number="${ARTIFACTORY_BUILD_NUMBER:-${CI_JOB_ID:-${CI_PIPELINE_ID:-${BUILD_NUMBER:-${GITHUB_RUN_ID:-$(date +%s)}}}}}"

  _artifactory_build_publish "${build_name}" "${build_number}"
  _artifactory_set_props "${manifest_path}" "${build_name}" "${build_number}" "${ARTIFACTORY_ENVIRONMENT}"

  echo "Pushed: ${target}"
}

# ── Internals ────────────────────────────────────────────────────────

_artifactory_require_env() {
  local missing=0 var
  for var in ARTIFACTORY_URL ARTIFACTORY_USER; do
    if [ -z "${!var:-}" ]; then
      echo "ERROR: ${var} is required when REGISTRY_KIND=artifactory" >&2
      missing=1
    fi
  done
  if [ -z "${ARTIFACTORY_TOKEN:-}" ] && [ -z "${ARTIFACTORY_PASSWORD:-}" ]; then
    echo "ERROR: set either ARTIFACTORY_TOKEN (preferred) or ARTIFACTORY_PASSWORD" >&2
    missing=1
  fi
  return "${missing}"
}

_artifactory_require_tools() {
  local missing=0
  if ! command -v jf >/dev/null 2>&1; then
    echo "ERROR: 'jf' CLI not found on PATH" >&2
    echo "  Install: https://jfrog.com/getcli/ — or" >&2
    echo "    brew install jfrog-cli" >&2
    echo "    curl -fL https://install-cli.jfrog.io | sh" >&2
    missing=1
  fi
  if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: 'docker' CLI not found on PATH" >&2
    missing=1
  fi
  return "${missing}"
}

_artifactory_jf_config() {
  local secret="${ARTIFACTORY_TOKEN:-${ARTIFACTORY_PASSWORD}}"
  local auth_flag
  if [ -n "${ARTIFACTORY_TOKEN:-}" ]; then
    auth_flag="--access-token=${secret}"
  else
    auth_flag="--password=${secret}"
  fi
  # shellcheck disable=SC2086
  jf config add container-image-template-artifactory \
    --url="${ARTIFACTORY_URL}" \
    --artifactory-url="${ARTIFACTORY_URL}/artifactory" \
    --user="${ARTIFACTORY_USER}" \
    ${auth_flag} \
    --interactive=false \
    --overwrite=true >/dev/null || {
      echo "ERROR: 'jf config add' failed" >&2
      return 1
    }
  jf config use container-image-template-artifactory >/dev/null
}

_artifactory_docker_login() {
  local host="$1"
  printf '%s' "${ARTIFACTORY_TOKEN:-${ARTIFACTORY_PASSWORD}}" \
    | docker login "${host}" -u "${ARTIFACTORY_USER}" --password-stdin >/dev/null || {
      echo "ERROR: 'docker login ${host}' failed" >&2
      return 1
    }
}

_artifactory_build_publish() {
  local build_name="$1" build_number="$2"
  # Best-effort — requires Deploy on the system-wide
  # artifactory-build-info repo. JCR Free team users often lack this.
  local stderr
  stderr=$(jf rt bp "${build_name}" "${build_number}" \
             --collect-env --collect-git-info 2>&1 >/dev/null) || {
    echo "  WARN: 'jf rt bp' failed — build info not published" >&2
    if echo "${stderr}" | grep -q 'not permitted to deploy.*artifactory-build-info'; then
      echo "        Cause: ${ARTIFACTORY_USER} lacks Deploy on the system" >&2
      echo "        'artifactory-build-info' repo. Property-based" >&2
      echo "        traceability (below) still works regardless." >&2
    else
      echo "        ${stderr}" | head -5 >&2
    fi
    return 0  # non-fatal
  }
}

_artifactory_set_props() {
  local manifest_path="$1" build_name="$2" build_number="$3" env="$4"
  local props="environment=${env};build.name=${build_name};build.number=${build_number}"
  [ -n "${ARTIFACTORY_TEAM:-}" ] && props="${props};team=${ARTIFACTORY_TEAM}"
  [ -n "${GIT_SHA:-}" ]          && props="${props};git.commit=${GIT_SHA}"
  [ -n "${UPSTREAM_TAG:-}" ]     && props="${props};upstream.tag=${UPSTREAM_TAG}"
  [ -n "${ARTIFACTORY_PROPERTIES:-}" ] && props="${props};${ARTIFACTORY_PROPERTIES}"

  if ! jf rt set-props "${manifest_path}" "${props}" 2>/dev/null; then
    echo "  WARN: 'jf rt set-props' failed for ${manifest_path}" >&2
    echo "        (check manifest path matches the repo storage layout)" >&2
  fi
}
