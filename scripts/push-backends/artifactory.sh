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

    # Build info WITH module linkage — works on JCR Free by manually
    # constructing the build info JSON with module/artifact data from
    # the storage API. This replicates what jf docker push does on Pro
    # but using only APIs available on Free (storage checksums + PUT
    # /api/build). The module linkage makes the image appear under
    # Packages → Builds → "Produced By" in the Artifactory UI.
    _artifactory_build_publish_free_with_modules \
      "${build_name}" "${build_number}" "${manifest_path}" "${target}"

    # Set build.name + build.number on ALL layers (not just manifest).
    # This is the other half of the cross-link that Pro's jf docker push
    # does automatically.
    _artifactory_set_props_all_layers "${manifest_path}" \
      "${build_name}" "${build_number}"

    # Custom metadata props on the manifest.
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

# FREE-tier build info publish WITH module linkage.
#
# Replaces the old LCD-only jf rt bp with a two-step approach:
#   1. jf rt bp --collect-env --collect-git-info (captures env + git)
#   2. Manually construct and PUT a module-enriched build info JSON
#      with artifact checksums from the Artifactory storage API
#
# This replicates what jf docker push does on Pro using only APIs
# available on JCR Free (storage checksums + PUT /api/build).
# The module linkage makes the image appear under Packages → Builds →
# "Produced By" in the Artifactory UI.
_artifactory_build_publish_free_with_modules() {
  local build_name="$1" build_number="$2" manifest_path="$3" target="$4"
  local secret="${ARTIFACTORY_TOKEN:-${ARTIFACTORY_PASSWORD}}"
  local _url="${ARTIFACTORY_URL%/}"
  _url="${_url%/artifactory}"
  local art_base="${_url}/artifactory"

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

  # Extract filenames from the listing
  local files_list
  files_list=$(echo "${listing}" | grep -o '"uri" *: *"/[^"]*"' | sed 's/"uri" *: *"\/\([^"]*\)"/\1/' | grep -v '^$')

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

  # Count upstream base image layers so we can split dependencies
  # (base layers we consumed) from our additions. Uses docker inspect
  # on the upstream image which is in the local daemon after the build.
  local upstream_layer_count=0
  if [ -n "${UPSTREAM_REF:-}" ]; then
    upstream_layer_count=$(docker inspect "${UPSTREAM_REF}" --format '{{len .RootFS.Layers}}' 2>/dev/null || echo 0)
    echo "  upstream base layers: ${upstream_layer_count} (from docker inspect ${UPSTREAM_REF})"
  fi

  # Copy the fetched build info into the tmpdir for Python to read
  if [ -n "${_bi_tmpfile}" ] && [ -f "${_bi_tmpfile}" ]; then
    mv "${_bi_tmpfile}" "${tmpdir}/published-bi.json"
  fi

  # Assemble the build info JSON with Python — merges modules into
  # the jf-published record (preserving env vars + git + VCS from jf).
  python3 - "${tmpdir}" "${file_count}" "${tag_subpath}" \
    "${build_name}" "${build_number}" "${target}" \
    "${IMAGE_NAME}" "${IMAGE_TAG}" "${git_rev}" "${git_url}" \
    "${started}" "${upstream_layer_count}" <<'PYEOF'
import json, sys, os

tmpdir = sys.argv[1]
file_count = int(sys.argv[2])
tag_subpath = sys.argv[3]
build_name, build_number, target = sys.argv[4], sys.argv[5], sys.argv[6]
image_name, image_tag = sys.argv[7], sys.argv[8]
git_rev, git_url, started = sys.argv[9], sys.argv[10], sys.argv[11]
upstream_layer_count = int(sys.argv[12]) if len(sys.argv) > 12 else 0

# Load the published build info (from jf rt bp) if available.
# This has the properly-filtered env vars + git context.
published_path = os.path.join(tmpdir, "published-bi.json")
base_bi = {}
if os.path.exists(published_path):
    try:
        resp = json.load(open(published_path))
        base_bi = resp.get("buildInfo", {})

        # Post-filter: strip env vars matching custom exclusion patterns.
        # jf's --collect-env already filters PASSWORD/TOKEN/KEY, but orgs
        # may have additional patterns (CLAUDE_*, internal tool vars, etc).
        # Add patterns here as needed — matched case-insensitively against
        # the env var name (after the buildInfo.env. prefix).
        # Only keep build-relevant env vars. Everything else is noise.
        # Two filter strategies combined:
        #   INCLUDE_PREFIXES: if set, ONLY vars matching these survive
        #   EXCLUDE_PREFIXES: vars matching these are always stripped
        # Include-first is safer — new random env vars don't leak in.
        INCLUDE_PREFIXES = [
            # Build pipeline context
            "REGISTRY_KIND", "PUSH_REGISTRY", "PUSH_PROJECT",
            "ARTIFACTORY_",  # all Artifactory config (jf already strips secrets)
            "IMAGE_", "UPSTREAM_", "DISTRO", "REMEDIATE", "INJECT_CERTS",
            "ORIGINAL_USER", "VENDOR", "PLATFORM",
            "APK_MIRROR", "APT_MIRROR",
            "BASE_DIGEST", "GIT_SHA", "CREATED",
            # CI context
            "CI_", "GITLAB_", "GITHUB_", "BAMBOO_", "BUILD_",
            "RUNNER_", "JOB_", "PIPELINE_",
            # Runtime identity
            "USER", "HOME", "SHELL", "PWD", "PATH", "LANG",
            "HOSTNAME", "LOGNAME",
            # Docker / container
            "DOCKER_", "BUILDKIT",
            # Vault
            "VAULT_ADDR",
        ]
        EXCLUDE_PREFIXES = [
            # Always strip regardless of include match
            "CLAUDE",         # Claude Code / AI tool internals
            "CLAUDECODE",
        ]

        props = base_bi.get("properties", {})
        filtered = {}
        kept = 0
        stripped = 0
        for k, v in props.items():
            if k.startswith("buildInfo.env."):
                varname = k[len("buildInfo.env."):]
                vupper = varname.upper()
                # Exclude always wins
                if any(vupper.startswith(p.upper()) for p in EXCLUDE_PREFIXES):
                    stripped += 1
                    continue
                # Include check — must match at least one prefix
                if not any(vupper.startswith(p.upper()) for p in INCLUDE_PREFIXES):
                    stripped += 1
                    continue
                kept += 1
            filtered[k] = v
        base_bi["properties"] = filtered

        print(f"  merged from jf rt bp: {kept} env vars kept, {stripped} stripped, {len(base_bi.get('vcs',[]))} vcs entries")
    except:
        pass

artifacts = []
all_blobs = []  # layer blobs only (not manifest/config)

for i in range(file_count):
    name_file = os.path.join(tmpdir, f"name_{i}.txt")
    info_file = os.path.join(tmpdir, f"file_{i}.json")
    if not os.path.exists(name_file) or not os.path.exists(info_file):
        continue
    fname = open(name_file).read().strip()
    try:
        info = json.load(open(info_file))
    except:
        continue
    cs = info.get("checksums", {})
    if not cs.get("sha256"):
        continue

    ftype = "json" if fname == "manifest.json" else "gz"
    artifacts.append({
        "type": ftype,
        "sha1": cs.get("sha1", ""),
        "sha256": cs["sha256"],
        "md5": cs.get("md5", ""),
        "name": fname,
        "path": f"{tag_subpath}/{fname}"
    })

    if fname != "manifest.json" and fname.startswith("sha256__"):
        all_blobs.append({
            "id": fname,
            "sha1": cs.get("sha1", ""),
            "sha256": cs["sha256"],
            "md5": cs.get("md5", "")
        })

# Dependencies = the upstream base image layers (first N blobs).
# If we know the upstream layer count, take that many. Otherwise
# include all blobs (better than 0, slightly over-counts).
if upstream_layer_count > 0 and upstream_layer_count <= len(all_blobs):
    dependencies = all_blobs[:upstream_layer_count]
else:
    dependencies = all_blobs  # fallback: all blobs as deps

# Build the final build info by merging modules into the published
# record. This preserves jf's filtered env vars, git context, VCS
# info, and agent metadata. We only override the modules array and
# ensure type=DOCKER is set.
build_info = base_bi.copy() if base_bi else {}
build_info.update({
    "version": "1.0.1",
    "name": build_name,
    "number": build_number,
    "type": "DOCKER",
    "started": base_bi.get("started", started),
    "buildAgent": base_bi.get("buildAgent", {"name": "container-image-template", "version": "1.0"}),
    "agent": base_bi.get("agent", {"name": "build.sh", "version": "free-lcd"}),
    "properties": base_bi.get("properties", {}),
    "vcs": base_bi.get("vcs", [{"revision": git_rev, "url": git_url}] if git_rev else []),
    "modules": [{
        "properties": {
            "docker.image.tag": target,
            "docker.image.id": ""
        },
        "type": "docker",
        "id": f"{image_name}:{image_tag}",
        "artifacts": artifacts,
        "dependencies": dependencies
    }]
})

outfile = os.path.join(tmpdir, "build-info.json")
with open(outfile, "w") as f:
    json.dump(build_info, f)

print(f"  artifacts: {len(artifacts)}, dependencies: {len(dependencies)}")
PYEOF

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
  while IFS= read -r fname; do
    [ -z "${fname}" ] && continue
    jf rt set-props "${tag_dir}/${fname}" "${props}" 2>/dev/null && count=$((count + 1))
  done < <(echo "${listing}" | grep -o '"uri" *: *"/[^"]*"' | sed 's/"uri" *: *"\/\([^"]*\)"/\1/' | grep -v '^$')

  echo "  ✓ build.name/build.number set on ${count} files"
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
