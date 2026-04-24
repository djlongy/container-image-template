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
#   ARTIFACTORY_BUILD_NAME    defaults to ${IMAGE_NAME}-build (suffix
#                             distinguishes build-info from the image
#                             and its packages in Artifactory UI)
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

  # Normalise boolean env vars to lowercase so TRUE/True/true all
  # match consistently. Same pattern as build.sh for REMEDIATE / SBOM_*.
  ARTIFACTORY_PRO="$(printf '%s' "${ARTIFACTORY_PRO:-false}" | tr '[:upper:]' '[:lower:]')"
  ARTIFACTORY_XRAY_FAIL_ON_VIOLATIONS="$(printf '%s' "${ARTIFACTORY_XRAY_FAIL_ON_VIOLATIONS:-false}" | tr '[:upper:]' '[:lower:]')"

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
  target=$(_artifactory_expand_template "${image_ref_tpl}")
  manifest_path=$(_artifactory_expand_template "${manifest_path_tpl}")

  local build_name build_number
  build_name="${ARTIFACTORY_BUILD_NAME:-${IMAGE_NAME}-build}"
  build_number="${ARTIFACTORY_BUILD_NUMBER:-${CI_JOB_ID:-${CI_PIPELINE_ID:-${BUILD_NUMBER:-${GITHUB_RUN_ID:-$(date -u +"%Y-%m-%dT%H-%M-%SZ")}}}}}"

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
    # Exit codes from jf build-scan:
    #   0  clean
    #   3  watch policy violation (scan succeeded, findings tripped --fail)
    #   *  Xray unreachable / unlicensed / build not yet indexed
    #
    # Violation-handling policy is driven by ARTIFACTORY_XRAY_FAIL_ON_VIOLATIONS:
    #   unset | "false" | "warn"   → warn and proceed (default — matches
    #                                the rest of the push steps where the
    #                                image is already uploaded)
    #   "true"  | "strict"         → return non-zero so CI marks the job
    #                                failed and downstream promote jobs
    #                                don't advance. Image is still pushed;
    #                                this gates promotion, not publish.
    # Non-3 exits (licensing / unreachable / indexing) always stay warnings —
    # those aren't policy decisions, just scanner availability blips.
    echo ""
    echo "── Pro: Xray build scan ──"
    local xray_fail_mode="${ARTIFACTORY_XRAY_FAIL_ON_VIOLATIONS:-false}"
    # shellcheck disable=SC2086
    jf build-scan "${build_name}" "${build_number}" ${project_flag} 2>&1
    local xray_rc=$?
    case "${xray_rc}" in
      0)
        echo "  ✓ Xray clean (no policy violations)"
        ;;
      3)
        case "${xray_fail_mode}" in
          true|strict)
            echo "" >&2
            echo "  ERROR: Xray policy violations detected — failing build" >&2
            echo "         (ARTIFACTORY_XRAY_FAIL_ON_VIOLATIONS=${xray_fail_mode})" >&2
            echo "         The image has been pushed, but this run is being" >&2
            echo "         rejected so downstream promote/deploy stages don't" >&2
            echo "         advance. Review findings in Artifactory →" >&2
            echo "         Builds → ${build_name}/${build_number} → Xray Data." >&2
            return 1
            ;;
          *)
            echo "  WARN: Xray reported policy violations — continuing (warn mode)" >&2
            echo "        Set ARTIFACTORY_XRAY_FAIL_ON_VIOLATIONS=true to hard-fail the build." >&2
            ;;
        esac
        ;;
      *)
        echo "  WARN: Xray scan exit ${xray_rc} (unlicensed, unreachable, or still indexing)" >&2
        ;;
    esac

    # Resolve digest from the pushed image
    local push_digest=""
    push_digest=$(crane digest "${target}" 2>/dev/null || echo "")
    if [ -z "${push_digest}" ]; then
      push_digest=$(docker inspect --format='{{index .RepoDigests 0}}' "${target}" 2>/dev/null | grep -oE 'sha256:[0-9a-f]{64}' || echo "")
    fi

    local image_ref_bare="${target%:*}"
    local digest_ref=""
    [ -n "${push_digest}" ] && digest_ref="${image_ref_bare}@${push_digest}"

    # Export IMAGE_DIGEST/IMAGE_REF so the parent build.sh can consume
    # them (SBOM generation scans by digest when available).
    export IMAGE_REF="${target}"
    export IMAGE_DIGEST="${digest_ref}"

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

    # Export IMAGE_DIGEST/IMAGE_REF so the parent build.sh can consume
    # them (SBOM generation scans by digest when available).
    export IMAGE_REF="${target}"
    export IMAGE_DIGEST="${digest_ref}"

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

    # Build info WITH module linkage — constructs artifacts[] and
    # dependencies[] from storage-API checksums + the final/upstream
    # manifests we side-load. Same data shape jf docker push writes on
    # Pro. Note: the Packages → Produced By UI hyperlink depends on
    # /api/search/buildArtifacts which is Pro-licensed; the linkage
    # data is still correctly stored here so it surfaces in the Build's
    # own tabs (Artifacts / Dependencies / Env / Properties).
    _artifactory_build_publish_free_with_modules \
      "${build_name}" "${build_number}" "${manifest_path}" "${target}"

    # Set build.name + build.number on every blob so layer details show
    # "Used by Build" backlinks in the UI (Pro's jf docker push does
    # this automatically on push; Free has to iterate).
    _artifactory_set_props_all_layers "${manifest_path}" \
      "${build_name}" "${build_number}"

    # Custom metadata props on the manifest.
    _artifactory_set_props "${manifest_path}" \
      "${build_name}" "${build_number}" "${ARTIFACTORY_ENVIRONMENT}"
  fi

  echo "Pushed: ${target}"
}

# ── Internals ────────────────────────────────────────────────────────

# Expand ${VAR} references in a template string using bash parameter
# expansion. Only the whitelisted variables below are substituted —
# anything else is left untouched. Safer than `eval` because it can't
# execute arbitrary code if a variable value contains backticks, $(...),
# or semicolons.
_artifactory_expand_template() {
  local tpl="$1"
  local v
  for v in ARTIFACTORY_PUSH_HOST ARTIFACTORY_TEAM ARTIFACTORY_ENVIRONMENT \
           ARTIFACTORY_REPO_SUFFIX IMAGE_NAME IMAGE_TAG; do
    tpl="${tpl//\$\{${v}\}/${!v:-}}"
  done
  printf '%s' "${tpl}"
}

_artifactory_require_env() {
  local missing=0 var
  for var in ARTIFACTORY_URL ARTIFACTORY_USER ARTIFACTORY_TEAM; do
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
    _artifactory_install_jf || { missing=1; }
  fi
  if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: 'docker' CLI not found on PATH" >&2
    missing=1
  fi
  return "${missing}"
}

# Auto-install the JFrog CLI if not present.
#
# Two environment variables control where jf is fetched from:
#
#   JF_BINARY_URL     Direct URL to the jf binary (Method 1 — fastest).
#                     e.g. https://artifactory.example.com/artifactory/
#                          jfrog-releases-remote/jfrog-cli/v2-jf/
#                          [RELEASE]/jfrog-cli-linux-amd64/jf
#
#   JF_INSTALLER_URL  URL to the JFrog CLI installer script (Method 2).
#                     Default: https://install.jfrog.io
#                     For air-gap: proxy this through an Artifactory
#                     generic-remote repo.
#
# Neither set? Falls back to JFrog's public installer.
_artifactory_install_jf() {
  echo "  jf CLI not found — auto-installing..."
  local install_dir="${JF_INSTALL_DIR:-/usr/local/bin}"

  # Method 1: direct binary URL (fastest, works in CI containers)
  if [ -n "${JF_BINARY_URL:-}" ]; then
    echo "  → downloading jf binary from JF_BINARY_URL"
    if curl -fsSL "${JF_BINARY_URL}" -o "${install_dir}/jf" && chmod +x "${install_dir}/jf"; then
      echo "  ✓ jf installed: $(jf --version 2>/dev/null || echo 'unknown version')"
      return 0
    fi
    echo "  ✗ binary download failed" >&2
    return 1
  fi

  # Method 2: installer script (variable-driven, air-gap safe)
  local installer_url="${JF_INSTALLER_URL:-https://install.jfrog.io}"
  echo "  → running installer from ${installer_url}"
  if curl -fsSL "${installer_url}" | bash -s 2>/dev/null; then
    if command -v jf >/dev/null 2>&1; then
      echo "  ✓ jf installed: $(jf --version 2>/dev/null)"
      return 0
    fi
  fi

  echo "ERROR: 'jf' CLI not found and auto-install failed" >&2
  echo "  Install manually: https://jfrog.com/getcli/" >&2
  echo "  For air-gap: set JF_BINARY_URL or JF_INSTALLER_URL" >&2
  return 1
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

# FREE-tier build info publish WITH module linkage.
#
# Two-step publish so we get jf's sensitive-value env filter AND our
# module data on a tier without jf docker push:
#   1. `jf rt bp --collect-env --collect-git-info` publishes a skeletal
#      build record with env + git, using jf's own secret redaction
#      (more comprehensive than a regex).
#   2. We GET that record back, side-load the final + upstream manifests
#      via the curl helpers, and hand everything to build-info-merge.py
#      which writes a modules-enriched JSON PUT to /api/build.
#
# Caveat: Packages → Produced By in the Artifactory UI is Pro-gated
# (calls /api/search/buildArtifacts, which returns HTTP 400 on Free).
# The build record itself — Artifacts, Dependencies, Env, Properties
# tabs — renders correctly.
_artifactory_build_publish_free_with_modules() {
  local build_name="$1" build_number="$2" manifest_path="$3" target="$4"
  local secret="${ARTIFACTORY_TOKEN:-${ARTIFACTORY_PASSWORD}}"
  local _url="${ARTIFACTORY_URL%/}"
  _url="${_url%/artifactory}"
  local art_base="${_url}/artifactory"

  # Capture epoch-ms at the start so the Python merger can compute
  # durationMillis for the build-info UI "Duration" field.
  local started_ms
  started_ms=$(python3 -c 'import time; print(int(time.time()*1000))')

  # Step 1: jf rt bp publishes build info with env + git, using jf's
  # own sensitive-value filtering (more comprehensive than regex).
  echo ""
  echo "── Free: publishing baseline build info via jf rt bp ──"
  jf rt bp "${build_name}" "${build_number}" \
    --collect-env --collect-git-info 2>/dev/null || true

  # Step 2: GET the published record back so we can merge modules
  # into it (preserving jf's filtered env vars + git context).
  echo "── Free: fetching published build info for merge ──"
  # Write directly to file instead of capturing in a shell variable —
  # the JSON can contain special characters in env var values that
  # break shell variable assignment.
  local _bi_tmpfile
  _bi_tmpfile=$(mktemp)
  local _bi_http_code
  _bi_http_code=$(curl -sSL -o "${_bi_tmpfile}" -w "%{http_code}" \
    -u "${ARTIFACTORY_USER}:${secret}" \
    "${art_base}/api/build/${build_name}/${build_number}" 2>/dev/null)
  if [ "${_bi_http_code}" = "200" ] && [ -s "${_bi_tmpfile}" ]; then
    echo "  ✓ fetched (HTTP ${_bi_http_code}, $(wc -c < "${_bi_tmpfile}" | tr -d ' ') bytes)"
  else
    echo "  WARN: fetch returned HTTP ${_bi_http_code} — env vars won't be merged" >&2
    rm -f "${_bi_tmpfile}"
    _bi_tmpfile=""
  fi

  echo "── Free: building module linkage from storage API ──"

  # Get the tag directory path (strip manifest.json from the end)
  local tag_dir="${manifest_path%/manifest.json}"
  local repo_name="${tag_dir%%/*}"
  local tag_subpath="${tag_dir#*/}"

  # List all files in the tag directory and build the module JSON
  # using Python for reliable JSON construction (sed-based assembly
  # was producing malformed JSON with special characters in paths).
  local listing
  listing=$(curl -fsSL -u "${ARTIFACTORY_USER}:${secret}" \
    "${art_base}/api/storage/${tag_dir}" 2>/dev/null) || {
    echo "  WARN: could not list ${tag_dir} — skipping module linkage" >&2
    return 0
  }

  # Extract filenames from the listing (proper JSON parse, not sed/grep)
  local files_list
  files_list=$(printf '%s' "${listing}" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    for child in d.get('children', []):
        uri = child.get('uri', '').lstrip('/')
        if uri:
            print(uri)
except json.JSONDecodeError:
    pass
")

  if [ -z "${files_list}" ]; then
    echo "  WARN: no files found in ${tag_dir} — skipping module linkage" >&2
    return 0
  fi

  # Fetch checksums for each file and build the JSON via Python.
  # Write one JSON line per file to a temp file, then assemble.
  local tmpdir
  tmpdir=$(mktemp -d)
  local file_count=0

  while IFS= read -r fname; do
    [ -z "${fname}" ] && continue
    curl -fsSL -u "${ARTIFACTORY_USER}:${secret}" \
      "${art_base}/api/storage/${tag_dir}/${fname}" \
      > "${tmpdir}/file_${file_count}.json" 2>/dev/null && \
      echo "${fname}" > "${tmpdir}/name_${file_count}.txt"
    file_count=$((file_count + 1))
  done <<< "${files_list}"

  # Get git info
  local git_rev="" git_url=""
  if git rev-parse HEAD >/dev/null 2>&1; then
    git_rev=$(git rev-parse HEAD)
    git_url=$(git config --get remote.origin.url 2>/dev/null || echo "")
  fi

  local started
  started=$(date -u +"%Y-%m-%dT%H:%M:%S.000+0000")

  # Side-load final + upstream manifests for accurate per-blob
  # dependency classification. Two small registry calls (~2 KB each)
  # replace the old "first N blobs" heuristic, which was wrong whenever
  # the storage listing order didn't match the layer order or when the
  # upstream wasn't locally tagged under the expected ref.
  _artifactory_fetch_manifests_for_merge "${target}" "${tmpdir}"

  # Copy the fetched build info into the tmpdir for Python to read
  if [ -n "${_bi_tmpfile}" ] && [ -f "${_bi_tmpfile}" ]; then
    mv "${_bi_tmpfile}" "${tmpdir}/published-bi.json"
  fi

  # Assemble the build info JSON with Python — merges modules into
  # the jf-published record (preserving env vars + git + VCS from jf).
  local _backend_dir
  _backend_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # docker.image.id = config blob digest of the local tagged image.
  # Pro's jf docker push populates this automatically; on Free we read
  # it from the Docker daemon while the image is still present.
  local docker_image_id
  docker_image_id=$(docker inspect --format '{{.Id}}' "${target}" 2>/dev/null || echo "")

  python3 "${_backend_dir}/../lib/build-info-merge.py" \
    "${tmpdir}" "${file_count}" "${tag_subpath}" \
    "${build_name}" "${build_number}" "${target}" \
    "${IMAGE_NAME}" "${IMAGE_TAG}" "${git_rev}" "${git_url}" \
    "${started}" \
    "${repo_name}" "${started_ms}" "${docker_image_id}"

  # PUT to /api/build
  echo "── Free: publishing enriched build info ──"
  local http_code
  http_code=$(curl -fsSL -o /dev/null -w "%{http_code}" \
    -X PUT -u "${ARTIFACTORY_USER}:${secret}" \
    -H "Content-Type: application/json" \
    --data-binary "@${tmpdir}/build-info.json" \
    "${art_base}/api/build" 2>/dev/null) || true

  if [ "${http_code}" = "204" ]; then
    echo "  ✓ build info published with module linkage"
  else
    echo "  WARN: enriched build info publish returned HTTP ${http_code}" >&2
    echo "        (modules may not appear in the Packages UI)" >&2
  fi

  rm -rf "${tmpdir}"
}

# Set build.name + build.number props on ALL files in a tag directory.
# On Pro, jf docker push does this automatically. On Free, we iterate.
_artifactory_set_props_all_layers() {
  local manifest_path="$1" build_name="$2" build_number="$3"
  local tag_dir="${manifest_path%/manifest.json}"
  local props="build.name=${build_name};build.number=${build_number}"
  local secret="${ARTIFACTORY_TOKEN:-${ARTIFACTORY_PASSWORD}}"
  local _url="${ARTIFACTORY_URL%/}"
  _url="${_url%/artifactory}"
  local art_base="${_url}/artifactory"

  local listing
  listing=$(curl -fsSL -u "${ARTIFACTORY_USER}:${secret}" \
    "${art_base}/api/storage/${tag_dir}" 2>/dev/null) || return 0

  local count=0
  local files_list
  files_list=$(printf '%s' "${listing}" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    for child in d.get('children', []):
        uri = child.get('uri', '').lstrip('/')
        if uri:
            print(uri)
except json.JSONDecodeError:
    pass
")
  while IFS= read -r fname; do
    [ -z "${fname}" ] && continue
    jf rt set-props "${tag_dir}/${fname}" "${props}" 2>/dev/null && count=$((count + 1))
  done <<< "${files_list}"

  echo "  ✓ build.name/build.number set on ${count} files"
}

# Fetch a v2 distribution manifest via curl. ARTIFACTORY creds are used
# (push target and upstream proxy both live on the same Artifactory in
# our topology; public upstreams ignore the auth header). Empty stdout
# on failure.
_artifactory_curl_manifest() {
  local ref="$1"
  local secret="${ARTIFACTORY_TOKEN:-${ARTIFACTORY_PASSWORD:-}}"
  local host repo_ref repo reference
  host="${ref%%/*}"
  repo_ref="${ref#*/}"
  if [[ "${repo_ref}" == *"@"* ]]; then
    repo="${repo_ref%@*}"
    reference="${repo_ref#*@}"
  else
    repo="${repo_ref%:*}"
    reference="${repo_ref##*:}"
  fi
  local accept="application/vnd.oci.image.index.v1+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.docker.distribution.manifest.v2+json"
  local auth=()
  [ -n "${secret}" ] && auth=(-u "${ARTIFACTORY_USER:-}:${secret}")
  curl -fsSL "${auth[@]}" -H "Accept: ${accept}" \
    "https://${host}/v2/${repo}/manifests/${reference}" 2>/dev/null
}

# Fetch a blob by digest. Used to pull the upstream image config so we
# can read rootfs.diff_ids (stable across docker re-compression).
_artifactory_curl_blob() {
  local ref="$1" digest="$2"
  local secret="${ARTIFACTORY_TOKEN:-${ARTIFACTORY_PASSWORD:-}}"
  local host repo_ref repo
  host="${ref%%/*}"
  repo_ref="${ref#*/}"
  repo="${repo_ref%@*}"
  repo="${repo%:*}"
  local auth=()
  [ -n "${secret}" ] && auth=(-u "${ARTIFACTORY_USER:-}:${secret}")
  curl -fsSL "${auth[@]}" \
    "https://${host}/v2/${repo}/blobs/${digest}" 2>/dev/null
}

# Side-load the data build-info-merge.py needs to classify blobs
# accurately on the Free path without any post-push round trip through
# the merger. Two files end up in <tmpdir>:
#
#   final-manifest.json   distribution v2 manifest of what we pushed
#                         (config.digest + layers[].digest in order)
#   upstream-diffids.json upstream's rootfs.diff_ids, used only for its
#                         length (= upstream layer count)
#
# Python then marks the first N entries of final-manifest.layers[] as
# dependencies, where N = len(upstream-diffids). This matches what Pro's
# `jf docker push` records on the Pro path — same semantics, same data
# shape — just derived from REST rather than the internal Go pipeline.
# Handles multi-arch upstream by resolving the manifest list to the
# PLATFORM-matching child (default linux/amd64). Silent on any failure
# — Python falls back to "all non-config blobs are dependencies".
_artifactory_fetch_manifests_for_merge() {
  local target="$1" tmpdir="$2"

  local final_body
  final_body=$(_artifactory_curl_manifest "${target}")
  [ -n "${final_body}" ] && printf '%s' "${final_body}" > "${tmpdir}/final-manifest.json"

  [ -z "${UPSTREAM_REF:-}" ] && return 0

  local upstream_body
  upstream_body=$(_artifactory_curl_manifest "${UPSTREAM_REF}")
  [ -z "${upstream_body}" ] && return 0

  local upstream_effective_ref="${UPSTREAM_REF}"
  if printf '%s' "${upstream_body}" | grep -q '"manifests"'; then
    local plat="${PLATFORM:-linux/amd64}"
    local plat_digest
    plat_digest=$(printf '%s' "${upstream_body}" | python3 -c "
import json, sys
d = json.load(sys.stdin)
os_, arch = '${plat}'.split('/', 1)
for m in d.get('manifests', []):
    p = m.get('platform', {})
    if p.get('os') == os_ and p.get('architecture') == arch:
        print(m.get('digest', '')); break
" 2>/dev/null)
    [ -z "${plat_digest}" ] && {
      echo "  WARN: upstream manifest list has no ${plat} variant" >&2
      return 0
    }
    local upstream_base="${UPSTREAM_REF%:*}"
    upstream_effective_ref="${upstream_base}@${plat_digest}"
    upstream_body=$(_artifactory_curl_manifest "${upstream_effective_ref}")
    [ -z "${upstream_body}" ] && return 0
  fi

  local upstream_config_digest
  upstream_config_digest=$(printf '%s' "${upstream_body}" | python3 -c "
import json, sys
print(json.load(sys.stdin).get('config', {}).get('digest', ''))" 2>/dev/null)
  [ -z "${upstream_config_digest}" ] && return 0

  _artifactory_curl_blob "${upstream_effective_ref}" "${upstream_config_digest}" \
    | python3 -c "
import json, sys
cfg = json.load(sys.stdin)
json.dump(cfg.get('rootfs', {}).get('diff_ids', []), sys.stdout)" \
    > "${tmpdir}/upstream-diffids.json" 2>/dev/null || \
    rm -f "${tmpdir}/upstream-diffids.json"
}

_artifactory_set_props() {
  local manifest_path="$1" build_name="$2" build_number="$3" env="$4"
  local props="environment=${env};build.name=${build_name};build.number=${build_number}"
  [ -n "${ARTIFACTORY_TEAM:-}" ] && props="${props};team=${ARTIFACTORY_TEAM}"
  [ -n "${GIT_SHA:-}" ]          && props="${props};git.commit=${GIT_SHA}"
  [ -n "${UPSTREAM_TAG:-}" ]     && props="${props};upstream.tag=${UPSTREAM_TAG}"
  # NOTE: sbom.path is NOT set here — it's set by sbom-post.sh AFTER
  # the SBOM upload succeeds, so the property always points to a real
  # artifact rather than a speculative path.
  [ -n "${ARTIFACTORY_PROPERTIES:-}" ] && props="${props};${ARTIFACTORY_PROPERTIES}"

  if ! jf rt set-props "${manifest_path}" "${props}" 2>/dev/null; then
    echo "  WARN: 'jf rt set-props' failed for ${manifest_path}" >&2
    echo "        (check manifest path matches the repo storage layout)" >&2
  fi
}
