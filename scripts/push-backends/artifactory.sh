#!/usr/bin/env bash
# push-backend: JFrog Artifactory (JCR Free baseline + Pro opt-in).
#
# Sourced by scripts/build.sh when REGISTRY_KIND=artifactory. Exposes
# a single entry point — push_to_backend() — that pushes the built
# image to Artifactory, publishes build info, and tags the manifest
# with structured properties.
#
# ── FREE vs PRO ──────────────────────────────────────────────────────
#
# Set ARTIFACTORY_PRO=true to enable Pro-tier features. When unset or
# false, the backend uses only commands available on JCR Free so the
# same code works on both tiers without changes.
#
# | Step                  | FREE (baseline)                     | PRO (ARTIFACTORY_PRO=true)                          |
# |-----------------------|-------------------------------------|-----------------------------------------------------|
# | Docker push           | docker push (plain)                 | jf docker push --build-name --build-number --project |
# | Build info collect    | jf rt bp --collect-env --collect-git | jf build-collect-env + jf build-add-git (richer)     |
# | Build info publish    | jf rt bp → artifactory-build-info   | jf build-publish --project → <project>-build-info    |
# | Module linkage        | None (plain push, no layer capture)  | Automatic (jf docker push captures layers+manifests) |
# | Xray build scan       | N/A (no Xray on Free)               | jf build-scan --project (returns CVE table)          |
# | Project scoping       | N/A                                 | --project on all jf commands                         |
# | Property tagging      | jf rt set-props (manifest only)     | Automatic on all layers + manual custom props        |
#
# Required env:
#   ARTIFACTORY_URL           https://artifactory.example.com
#   ARTIFACTORY_USER          team user with Deploy rights
#   ARTIFACTORY_TOKEN | ARTIFACTORY_PASSWORD   secret
#
# Optional env (both tiers):
#   ARTIFACTORY_TEAM          team acronym (referenced by layout templates)
#   ARTIFACTORY_PUSH_HOST     docker push hostname (defaults to host
#                             portion of ARTIFACTORY_URL)
#   ARTIFACTORY_IMAGE_REF     image URL template (see global.env.example in monorepo)
#   ARTIFACTORY_MANIFEST_PATH REST manifest-path template (for jf rt set-props)
#   ARTIFACTORY_ENVIRONMENT   dev | prod (default: dev)
#   ARTIFACTORY_BUILD_NAME    defaults to ${IMAGE_NAME}
#   ARTIFACTORY_BUILD_NUMBER  defaults to CI_JOB_ID / CI_PIPELINE_ID / timestamp
#   ARTIFACTORY_PROPERTIES    extra ;-separated props
#
# Pro-only env (ignored when ARTIFACTORY_PRO is unset):
#   ARTIFACTORY_PRO           "true" to enable Pro features
#   ARTIFACTORY_PROJECT       project key for --project flag (defaults to
#                             ARTIFACTORY_TEAM). Scopes build info to
#                             <project>-build-info instead of global.

set -uo pipefail

push_to_backend() {
  local built_local_ref="$1"

  _artifactory_require_env   || return 1
  _artifactory_require_tools || return 1

  # ── Decompose the locally-built image reference ──
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

  # ── Resolve layout templates ──
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

  local build_name build_number
  build_name="${ARTIFACTORY_BUILD_NAME:-${IMAGE_NAME}}"
  build_number="${ARTIFACTORY_BUILD_NUMBER:-${CI_JOB_ID:-${CI_PIPELINE_ID:-${BUILD_NUMBER:-${GITHUB_RUN_ID:-$(date +%s)}}}}}"

  # Pro features toggle
  local is_pro="false"
  if [ "${ARTIFACTORY_PRO:-false}" = "true" ]; then
    is_pro="true"
  fi
  local project_key="${ARTIFACTORY_PROJECT:-${ARTIFACTORY_TEAM:-}}"

  echo ""
  echo "=== Artifactory push ==="
  echo "  Source (local):  ${built_local_ref}"
  echo "  Target:          ${target}"
  echo "  Push host:       ${ARTIFACTORY_PUSH_HOST}"
  echo "  Manifest path:   ${manifest_path}"
  echo "  Build name:      ${build_name}"
  echo "  Build number:    ${build_number}"
  echo "  Tier:            $([ "${is_pro}" = "true" ] && echo "PRO (project=${project_key})" || echo "FREE (LCD baseline)")"

  _artifactory_jf_config || return 1
  _artifactory_docker_login "${ARTIFACTORY_PUSH_HOST}" || return 1

  # ════════════════════════════════════════════════════════════════════
  # PRO PATH: jf docker push with full build info enrichment
  # ════════════════════════════════════════════════════════════════════
  if [ "${is_pro}" = "true" ]; then
    echo ""
    echo "── Pro: enriching build info before push ──"

    local project_flag=""
    if [ -n "${project_key}" ]; then
      project_flag="--project=${project_key}"
    fi

    # Collect CI environment variables into build info
    # shellcheck disable=SC2086
    jf rt build-collect-env "${build_name}" "${build_number}" ${project_flag} 2>&1

    # Collect git context (commit, branch, remote URL)
    # shellcheck disable=SC2086
    jf rt build-add-git "${build_name}" "${build_number}" ${project_flag} 2>&1

    # Push via jf CLI — captures module linkage (layers, manifests,
    # digests) into build info automatically. Also sets build.name +
    # build.number properties on every layer, not just the manifest.
    docker tag "${built_local_ref}" "${target}"
    # shellcheck disable=SC2086
    jf docker push "${target}" \
      --build-name="${build_name}" \
      --build-number="${build_number}" \
      ${project_flag} || {
        echo "ERROR: jf docker push failed" >&2
        return 1
      }

    # Publish the enriched build info to <project>-build-info
    echo ""
    echo "── Pro: publishing build info ──"
    # shellcheck disable=SC2086
    jf rt build-publish "${build_name}" "${build_number}" ${project_flag} 2>&1 | tail -5

    # Xray build scan — triggers CVE analysis on the published build.
    # Returns a CVE table + pass/fail against the project's Xray watches.
    # Non-fatal: if Xray isn't configured or the build isn't indexed yet,
    # the push still succeeded and properties are still set.
    echo ""
    echo "── Pro: Xray build scan ──"
    # shellcheck disable=SC2086
    jf build-scan "${build_name}" "${build_number}" ${project_flag} 2>&1 || {
      echo "  WARN: jf build-scan returned non-zero (Xray may still be indexing)" >&2
    }

    # Resolve digest from the pushed image
    local push_digest=""
    push_digest=$(crane digest "${target}" 2>/dev/null || echo "")
    if [ -z "${push_digest}" ]; then
      push_digest=$(docker inspect --format='{{index .RepoDigests 0}}' "${target}" 2>/dev/null | grep -oE 'sha256:[0-9a-f]{64}' || echo "")
    fi

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

    # Custom properties on top of what jf docker push already set.
    # jf docker push sets build.name + build.number on all layers;
    # we add our custom metadata on the manifest only.
    _artifactory_set_props "${manifest_path}" \
      "${build_name}" "${build_number}" "${ARTIFACTORY_ENVIRONMENT}"

  # ════════════════════════════════════════════════════════════════════
  # FREE PATH: plain docker push + LCD build info (JCR Free compatible)
  # ════════════════════════════════════════════════════════════════════
  else
    docker tag "${built_local_ref}" "${target}"
    local push_output
    push_output=$(docker push "${target}" 2>&1) || {
      echo "${push_output}" >&2
      echo "ERROR: docker push to Artifactory failed" >&2
      return 1
    }
    echo "${push_output}"

    # Resolve digest
    local push_digest=""
    if command -v crane >/dev/null 2>&1; then
      push_digest=$(crane digest "${target}" 2>/dev/null || echo "")
    fi
    if [ -z "${push_digest}" ]; then
      push_digest=$(echo "${push_output}" | awk '/digest: sha256:/{print $3}' | head -1)
    fi

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

    # LCD build info — works on both JCR Free and Pro.
    # Uses jf rt bp which captures env + git in one shot but does NOT
    # capture module linkage (layers, manifests). That's a Pro-only
    # capability via jf docker push.
    _artifactory_build_publish_free "${build_name}" "${build_number}"

    # Manual property tagging (jf docker push does this automatically
    # on Pro, but on Free we need to do it ourselves).
    _artifactory_set_props "${manifest_path}" \
      "${build_name}" "${build_number}" "${ARTIFACTORY_ENVIRONMENT}"
  fi

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

  # Sanitize ARTIFACTORY_URL: strip trailing slashes, validate scheme,
  # avoid doubling /artifactory suffix.
  local _url="${ARTIFACTORY_URL%/}"
  if [[ ! "${_url}" =~ ^https?:// ]]; then
    echo "ERROR: ARTIFACTORY_URL must start with http:// or https://" >&2
    echo "       Got: ${_url}" >&2
    echo "       Example: https://artifactory.example.com" >&2
    return 1
  fi
  local _art_url
  if [[ "${_url}" == */artifactory ]]; then
    _art_url="${_url}"
    _url="${_url%/artifactory}"
  else
    _art_url="${_url}/artifactory"
  fi

  if [ -n "${ARTIFACTORY_TOKEN:-}" ]; then
    auth_flag="--access-token=${secret}"
  else
    auth_flag="--password=${secret}"
  fi
  # shellcheck disable=SC2086
  jf config add container-image-template-artifactory \
    --url="${_url}" \
    --artifactory-url="${_art_url}" \
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

# FREE-tier build info publish. LCD pattern — works on JCR Free and Pro.
# Captures env vars and git info but NOT module linkage (layer digests).
# On JCR Free, requires Deploy permission on the global
# artifactory-build-info repo (admin grants once). On Pro, this writes
# to the global repo; use ARTIFACTORY_PRO=true for project-scoped writes.
_artifactory_build_publish_free() {
  local build_name="$1" build_number="$2"
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
  # Link to SBOM artifact if sbom-post.sh will upload to a generic repo.
  # Consumers can find the SBOM via jf rt search --props='sbom.path=...'
  if [ -n "${ARTIFACTORY_SBOM_REPO:-}" ] && [ -n "${IMAGE_NAME:-}" ]; then
    props="${props};sbom.path=${ARTIFACTORY_SBOM_REPO}/${IMAGE_NAME}/${IMAGE_TAG}/sbom.cdx.json"
  fi
  [ -n "${ARTIFACTORY_PROPERTIES:-}" ] && props="${props};${ARTIFACTORY_PROPERTIES}"

  if ! jf rt set-props "${manifest_path}" "${props}" 2>/dev/null; then
    echo "  WARN: 'jf rt set-props' failed for ${manifest_path}" >&2
    echo "        (check manifest path matches the repo storage layout)" >&2
  fi
}
