#!/usr/bin/env bash
# push-backend: JFrog Artifactory (JCR Free baseline + Pro opt-in).
#
# Sourced by scripts/build.sh when REGISTRY_KIND=artifactory. Exposes
# a single entry point — push_to_backend() — that pushes the built
# image to Artifactory, publishes build info, and tags the manifest
# with structured properties.
#
# ── WHERE DO THE ARTIFACTORY_* ENV VARS COME FROM? ───────────────────
#
# Any of these three paths work — build.sh resolves them in this
# precedence order before it sources this backend:
#
#   1. image.env.example  (tracked, canonical defaults)
#   2. image.env          (gitignored, local dev override)
#   3. Shell / CI env     (always wins — GitLab/Bamboo pipeline vars,
#                          `export ARTIFACTORY_URL=… ./scripts/build.sh`,
#                          etc.)
#
# Nothing here REQUIRES image.env specifically; CI pipelines typically
# never touch image.env and set everything as masked group/project
# variables. Local dev typically uses image.env to avoid re-exporting
# on every shell. Either pattern (or mixing them) is supported.
#
# → See image.env.example for the authoritative list of every variable,
#   what it does, its default, and copy-and-uncomment templates.
#
# The sections below re-list the variables that affect THIS backend's
# behavior for quick on-file reference, but image.env.example is the
# source of truth. If you're adding a new variable, document it there
# first, then add a one-line summary here.
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
# | Property tagging      | jf rt set-props per-layer loop + manifest props | Automatic on all layers via jf docker push + manifest custom props |
#
# ── Variables this backend reads (set in image.env / image.env.example) ─
#
# Required (both tiers):
#   ARTIFACTORY_URL, ARTIFACTORY_USER,
#   ARTIFACTORY_TOKEN | ARTIFACTORY_PASSWORD,
#   ARTIFACTORY_TEAM
#
# Optional (both tiers):
#   ARTIFACTORY_ENVIRONMENT, ARTIFACTORY_PUSH_HOST,
#   ARTIFACTORY_IMAGE_REF, ARTIFACTORY_MANIFEST_PATH,
#   ARTIFACTORY_BUILD_NAME, ARTIFACTORY_BUILD_NUMBER,
#   ARTIFACTORY_PROPERTIES, ARTIFACTORY_SBOM_REPO
#
# Pro-only (ignored when ARTIFACTORY_PRO is unset/false):
#   ARTIFACTORY_PRO, ARTIFACTORY_PROJECT,
#   ARTIFACTORY_XRAY_PRESCAN, ARTIFACTORY_XRAY_POSTSCAN,
#   ARTIFACTORY_XRAY_FAIL_ON_VIOLATIONS
#
# Auto-install (air-gap support):
#   JF_BINARY_URL, JF_DEB_URL, JF_RPM_URL, JF_INSTALL_DIR
#
# See image.env.example for what each variable does and its default.

set -uo pipefail

# ════════════════════════════════════════════════════════════════════
# Structure
# ════════════════════════════════════════════════════════════════════
# push_to_backend() is a thin orchestrator. All the real work lives
# in named phase helpers below. The Pro/Free split is handled by two
# flow functions (_artifactory_pro_flow / _artifactory_free_flow),
# each calling the steps in order. Xray policy-violation handling
# propagates a well-defined return code instead of `return 0` to
# "skip the rest" — that pattern caused a subtle bug where the
# post-scan path would silently drop build.env emission.

# Normalise the three Xray-related booleans plus ARTIFACTORY_PRO.
_artifactory_normalise_bools() {
  ARTIFACTORY_PRO="$(printf '%s' "${ARTIFACTORY_PRO:-false}"                                 | tr '[:upper:]' '[:lower:]')"
  ARTIFACTORY_XRAY_FAIL_ON_VIOLATIONS="$(printf '%s' "${ARTIFACTORY_XRAY_FAIL_ON_VIOLATIONS:-false}" | tr '[:upper:]' '[:lower:]')"
  ARTIFACTORY_XRAY_PRESCAN="$(printf '%s' "${ARTIFACTORY_XRAY_PRESCAN:-false}"               | tr '[:upper:]' '[:lower:]')"
  ARTIFACTORY_XRAY_POSTSCAN="$(printf '%s' "${ARTIFACTORY_XRAY_POSTSCAN:-true}"               | tr '[:upper:]' '[:lower:]')"
}

# Split the locally-built ref (e.g. reg/proj/nginx:1.25-abc) into the
# short IMAGE_NAME + IMAGE_TAG the layout templates expect, derive
# ARTIFACTORY_PUSH_HOST + ARTIFACTORY_REPO_SUFFIX, and export the lot.
_artifactory_decompose_ref() {
  local built_local_ref="$1"
  local image_repo_tag="${built_local_ref##*/}"

  export IMAGE_NAME="${image_repo_tag%:*}"
  export IMAGE_TAG="${image_repo_tag##*:}"
  export ARTIFACTORY_TEAM

  : "${ARTIFACTORY_ENVIRONMENT:=dev}"
  case "${ARTIFACTORY_ENVIRONMENT}" in
    prod|production) export ARTIFACTORY_REPO_SUFFIX="prod"  ;;
    *)               export ARTIFACTORY_REPO_SUFFIX="local" ;;
  esac
  export ARTIFACTORY_ENVIRONMENT

  if [ -z "${ARTIFACTORY_PUSH_HOST:-}" ]; then
    local _host="${ARTIFACTORY_URL#https://}"
    _host="${_host#http://}"
    _host="${_host%%/*}"
    ARTIFACTORY_PUSH_HOST="${_host}"
  fi
  export ARTIFACTORY_PUSH_HOST
}

# Resolve layout templates to concrete `target` + `manifest_path`.
# Writes to the calling function's local vars via nameref-style echo:
# caller captures into variables by calling via $(... template_call ...).
# Simpler approach here: write to well-known globals that the flow
# orchestrators + set-props calls consume.
_artifactory_resolve_templates() {
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

  _ART_TARGET=$(_artifactory_expand_template "${image_ref_tpl}")
  _ART_MANIFEST_PATH=$(_artifactory_expand_template "${manifest_path_tpl}")
  _ART_BUILD_NAME="${ARTIFACTORY_BUILD_NAME:-${IMAGE_NAME}-build}"
  # Build-number resolution chain (highest precedence first):
  #   ARTIFACTORY_BUILD_NUMBER  explicit override (image.env / CI var)
  #   CI_JOB_ID                 GitLab job id
  #   CI_PIPELINE_ID            GitLab pipeline id
  #   BUILD_NUMBER              Jenkins (and generic CI convention)
  #   bamboo_buildNumber        Bamboo — what ${bamboo.buildNumber} resolves to
  #                             in the agent shell. Bare-name `buildNumber`
  #                             would also exist after import_bamboo_vars,
  #                             but `bamboo_buildNumber` is what the
  #                             agent always exports, so reference that
  #                             directly to stay independent of the
  #                             import-order in build.sh.
  #   GITHUB_RUN_ID             GitHub Actions
  #   <UTC timestamp>           last-resort fallback so a missing CI
  #                             context never blocks a local push
  _ART_BUILD_NUMBER="${ARTIFACTORY_BUILD_NUMBER:-${CI_JOB_ID:-${CI_PIPELINE_ID:-${BUILD_NUMBER:-${bamboo_buildNumber:-${GITHUB_RUN_ID:-$(date -u +"%Y-%m-%dT%H-%M-%SZ")}}}}}}"
  _ART_IS_PRO="${ARTIFACTORY_PRO}"
  _ART_PROJECT_KEY="${ARTIFACTORY_PROJECT:-${ARTIFACTORY_TEAM:-}}"
  _ART_PROJECT_FLAG=""
  if [ "${_ART_IS_PRO}" = "true" ] && [ -n "${_ART_PROJECT_KEY}" ]; then
    _ART_PROJECT_FLAG="--project=${_ART_PROJECT_KEY}"
  fi
}

_artifactory_print_banner() {
  local built_local_ref="$1"
  echo ""
  echo "=== Artifactory push ==="
  echo "  Source (local):  ${built_local_ref}"
  echo "  Target:          ${_ART_TARGET}"
  echo "  Push host:       ${ARTIFACTORY_PUSH_HOST}"
  echo "  Manifest path:   ${_ART_MANIFEST_PATH}"
  echo "  Build name:      ${_ART_BUILD_NAME}"
  echo "  Build number:    ${_ART_BUILD_NUMBER}"
  if [ "${_ART_IS_PRO}" = "true" ]; then
    if [ "${_ART_SKIP_BUILD_SCAN:-0}" = "1" ]; then
      echo "  Tier:            PRO (downgraded — project '${_ART_PROJECT_KEY}' missing; build-info goes to global namespace, scans skipped)"
    else
      echo "  Tier:            PRO (project=${_ART_PROJECT_KEY})"
    fi
  else
    echo "  Tier:            FREE (baseline — no Pro features)"
  fi
}

# Pro preflight: confirm the Artifactory Project exists. If it doesn't,
# graceful-downgrade the run instead of failing — the user's typical
# observation when this is missing is "first build for a new team
# pushes the image fine but BP and scan both fail mid-flow." Cleaner
# behavior:
#
#   - image push still proceeds → docker/<team>/<image>:<tag> lands
#   - build-info still publishes, but to GLOBAL artifactory-build-info
#     (no --project flag) so it doesn't 404
#   - jf docker scan / jf build-scan are SKIPPED — running them without
#     the project flag would evaluate the wrong watch set and produce
#     misleading "all clear" results, worse than no scan
#   - the postscan stage's xray-vuln.sh / xray-sbom.sh still cover
#     vuln visibility (they scan IMAGE_DIGEST, not the build-info)
#
# When the admin eventually creates the project (curl snippet printed
# in the warning), the next run flips back to full Pro flow with no
# code or env-var change.
#
# Sets globals when project is missing:
#   _ART_PROJECT_FLAG=""       drops --project from all subsequent jf calls
#   _ART_SKIP_BUILD_SCAN=1     read by _artifactory_pro_xray_postscan
#   _ART_SKIP_PRESCAN=1        read by _artifactory_pro_xray_prescan
_artifactory_preflight_project() {
  _ART_SKIP_BUILD_SCAN=0
  _ART_SKIP_PRESCAN=0

  # Only relevant on Pro path with a non-empty project key.
  [ "${_ART_IS_PRO}" = "true" ] || return 0
  [ -n "${_ART_PROJECT_KEY}" ] || return 0

  # /access/api/v1/* requires Bearer auth (Basic returns 401 even with
  # the same access token that works against /artifactory/api/*). Fall
  # back to Basic only when ARTIFACTORY_TOKEN is unset and we're using
  # ARTIFACTORY_PASSWORD instead — that's basic-auth-only by definition.
  local url="${ARTIFACTORY_URL%/}/access/api/v1/projects/${_ART_PROJECT_KEY}"
  local code
  if [ -n "${ARTIFACTORY_TOKEN:-}" ]; then
    code=$(curl -sS -o /dev/null -w "%{http_code}" \
      -H "Authorization: Bearer ${ARTIFACTORY_TOKEN}" \
      "${url}" 2>/dev/null) || code=000
  else
    code=$(curl -sS -o /dev/null -w "%{http_code}" \
      -u "${ARTIFACTORY_USER}:${ARTIFACTORY_PASSWORD:-}" \
      "${url}" 2>/dev/null) || code=000
  fi

  case "${code}" in
    200)
      _dbg "project preflight: '${_ART_PROJECT_KEY}' exists (HTTP 200) — full Pro flow"
      return 0
      ;;
    404)
      cat >&2 <<EOF

──────────────────────────────────────────────────────────────────────
  WARN: Artifactory project '${_ART_PROJECT_KEY}' does not exist.
  Continuing with a GRACEFUL DOWNGRADE for this run:
    ✓ image push proceeds to docker/${ARTIFACTORY_TEAM}/${IMAGE_NAME}
    ✓ build-info publishes to GLOBAL artifactory-build-info
    ✗ jf docker scan / jf build-scan are SKIPPED (project-scoped
      watches don't exist; running scans without scope would
      evaluate the wrong watch set)

  To enable full Pro flow on the next build, have an admin create
  the project once via REST:

    curl -H "Authorization: Bearer \$ADMIN_TOKEN" -X POST \\
      "${ARTIFACTORY_URL%/}/access/api/v1/projects" \\
      -H "Content-Type: application/json" \\
      -d '{
            "project_key":"${_ART_PROJECT_KEY}",
            "display_name":"${_ART_PROJECT_KEY}",
            "admin_privileges":{"manage_members":true,"manage_resources":true,"index_resources":true},
            "storage_quota_bytes":-1
          }'

  Or via UI: Administration → Platform Configuration → Projects → New.

  Naming note (JFrog Cloud SaaS, may differ on self-hosted Pro): the
  project_key must be lowercase letters / digits / dashes only. If
  '${_ART_PROJECT_KEY}' contains uppercase letters, the create call
  above returns 400 — pick an all-lowercase key and update
  ARTIFACTORY_PROJECT in image.env (or your CI vars) to match.

  Auth note: /access/api/v1/* endpoints require Bearer auth; Basic auth
  with the same token returns 401 even for admins.
──────────────────────────────────────────────────────────────────────
EOF
      _ART_PROJECT_FLAG=""
      _ART_SKIP_BUILD_SCAN=1
      _ART_SKIP_PRESCAN=1
      return 0
      ;;
    401|403)
      echo "WARN: project preflight HTTP ${code} for '${_ART_PROJECT_KEY}' — token may lack project read scope." >&2
      echo "      Continuing as Pro with --project=${_ART_PROJECT_KEY}; if BP fails downstream, check admin rights." >&2
      return 0
      ;;
    000)
      echo "WARN: project preflight failed (Artifactory unreachable / curl error) for '${_ART_PROJECT_KEY}'." >&2
      echo "      Continuing as Pro with --project=${_ART_PROJECT_KEY}." >&2
      return 0
      ;;
    *)
      echo "WARN: project preflight returned HTTP ${code} for '${_ART_PROJECT_KEY}' — unexpected response." >&2
      echo "      Continuing as Pro with --project=${_ART_PROJECT_KEY}." >&2
      return 0
      ;;
  esac
}

# Single source of truth for digest resolution after a push. Prefers
# crane (manifest-only, fast) then falls back to docker inspect. Takes
# an optional push_output parameter to mine for "digest: sha256:…"
# lines left by `docker push` on the Free path. Echoes the digest or
# empty string to stdout.
_artifactory_resolve_push_digest() {
  local target="$1" push_output="${2:-}"
  local digest=""
  if command -v crane >/dev/null 2>&1; then
    digest=$(crane digest "${target}" 2>/dev/null || echo "")
  fi
  if [ -z "${digest}" ]; then
    digest=$(docker inspect --format='{{index .RepoDigests 0}}' "${target}" 2>/dev/null | grep -oE 'sha256:[0-9a-f]{64}' || echo "")
  fi
  if [ -z "${digest}" ] && [ -n "${push_output}" ]; then
    digest=$(printf '%s' "${push_output}" | awk '/digest: sha256:/{print $3}' | head -1)
  fi
  printf '%s' "${digest}"
}

# Export IMAGE_REF + IMAGE_DIGEST to the parent shell (build.sh reads
# them for SBOM generation), then write build.env for downstream CI.
_artifactory_write_build_env() {
  local target="$1" push_digest="$2"
  local image_ref_bare="${target%:*}"
  local digest_ref=""
  [ -n "${push_digest}" ] && digest_ref="${image_ref_bare}@${push_digest}"

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
}

# ── Pro phase helpers ───────────────────────────────────────────────
#
# Each Pro helper has one job. Helpers that may surface a policy
# failure return non-zero; the flow orchestrator translates the code
# into whatever action the user's fail-mode policy dictates.

_artifactory_pro_enrich_build_info() {
  echo ""
  echo "── Pro: enriching build info before push ──"
  # shellcheck disable=SC2086
  jf rt build-collect-env "${_ART_BUILD_NAME}" "${_ART_BUILD_NUMBER}" ${_ART_PROJECT_FLAG} 2>&1
  # shellcheck disable=SC2086
  jf rt build-add-git "${_ART_BUILD_NAME}" "${_ART_BUILD_NUMBER}" ${_ART_PROJECT_FLAG} 2>&1
}

# Optional pre-push Xray gate. When ARTIFACTORY_XRAY_PRESCAN=true, runs
# `jf docker scan` against the locally-tagged image BEFORE pushing.
# Returns:
#   0  scan clean / scanner unavailable / disabled entirely
#   0  violations in warn mode (prints WARN, caller proceeds)
#   1  violations in strict mode (caller must abort before push)
#
# Benefits over post-push scanning:
#   1. Violations in strict mode keep the image OUT of Artifactory
#      entirely — no cleanup, no bad digest in prod-local.
#   2. Only talks to internal Artifactory/Xray — no outbound to
#      anchore.io or other public sources. Good for air-gapped runs.
#
# Caveat: Xray needs a scope (`--watches` / `--project` / `--repo-path`)
# to return exit 3 on violations. Without one the scan is informational
# only. We pass the project flag we've already computed.
_artifactory_pro_xray_prescan() {
  if [ "${_ART_SKIP_PRESCAN:-0}" = "1" ]; then
    echo ""
    echo "── Pro: Xray pre-push scan SKIPPED (project '${_ART_PROJECT_KEY}' missing — preflight downgrade) ──"
    return 0
  fi

  [ "${ARTIFACTORY_XRAY_PRESCAN}" = "true" ] || return 0

  if [ -z "${_ART_PROJECT_FLAG}" ]; then
    echo "" >&2
    echo "  WARN: ARTIFACTORY_XRAY_PRESCAN=true but project_flag is empty" >&2
    echo "        (no ARTIFACTORY_PROJECT or ARTIFACTORY_TEAM set). Scan will" >&2
    echo "        be informational only — set a project to enforce violations." >&2
  fi
  echo ""
  echo "── Pro: Xray pre-push scan (jf docker scan ${_ART_TARGET}) ──"
  # shellcheck disable=SC2086
  jf docker scan "${_ART_TARGET}" ${_ART_PROJECT_FLAG} --fail=true 2>&1
  local rc=$?

  case "${rc}" in
    0)
      echo "  ✓ Xray pre-push clean"
      return 0
      ;;
    3)
      case "${ARTIFACTORY_XRAY_FAIL_ON_VIOLATIONS}" in
        true|strict)
          echo "" >&2
          echo "  ERROR: Xray pre-push scan reported policy violations" >&2
          echo "         — refusing to push (ARTIFACTORY_XRAY_FAIL_ON_VIOLATIONS=${ARTIFACTORY_XRAY_FAIL_ON_VIOLATIONS})" >&2
          echo "         The image is NOT in Artifactory. Review the scanner" >&2
          echo "         output above, remediate, rebuild, and retry." >&2
          return 1
          ;;
        *)
          echo "  WARN: Xray pre-push scan found violations — pushing anyway (warn mode)" >&2
          echo "        Set ARTIFACTORY_XRAY_FAIL_ON_VIOLATIONS=true to block push on violations." >&2
          return 0
          ;;
      esac
      ;;
    *)
      echo "  WARN: Xray pre-push scan exit ${rc} (unlicensed, unreachable, or indexing) — continuing with push" >&2
      return 0
      ;;
  esac
}

# Pro docker push with full build-info module linkage.
_artifactory_pro_push() {
  # shellcheck disable=SC2086
  jf docker push "${_ART_TARGET}" \
    --build-name="${_ART_BUILD_NAME}" \
    --build-number="${_ART_BUILD_NUMBER}" \
    ${_ART_PROJECT_FLAG} || {
      echo "ERROR: jf docker push failed" >&2
      return 1
    }
}

_artifactory_pro_publish_build_info() {
  echo ""
  echo "── Pro: publishing build info ──"
  # shellcheck disable=SC2086
  jf rt build-publish "${_ART_BUILD_NAME}" "${_ART_BUILD_NUMBER}" ${_ART_PROJECT_FLAG} 2>&1 | tail -5
}

# Optional post-push Xray build scan. Toggled by ARTIFACTORY_XRAY_POSTSCAN
# (default true — preserves historical behaviour). Same return-code
# contract as the pre-scan above:
#   0  clean / disabled / scanner unavailable / warn-mode violations
#   1  strict-mode violations (caller propagates; image is already in
#      Artifactory at this point — the failure gates promote/deploy)
#
# Non-3 exits (licensing / unreachable / indexing) always stay
# warnings regardless of fail-mode — those are scanner availability
# blips, not policy decisions.
_artifactory_pro_xray_postscan() {
  if [ "${_ART_SKIP_BUILD_SCAN:-0}" = "1" ]; then
    echo ""
    echo "── Pro: Xray build scan SKIPPED (project '${_ART_PROJECT_KEY}' missing — preflight downgrade) ──"
    return 0
  fi
  if [ "${ARTIFACTORY_XRAY_POSTSCAN}" != "true" ]; then
    echo ""
    echo "── Pro: Xray build scan skipped (ARTIFACTORY_XRAY_POSTSCAN=${ARTIFACTORY_XRAY_POSTSCAN}) ──"
    return 0
  fi

  echo ""
  echo "── Pro: Xray build scan ──"
  # shellcheck disable=SC2086
  jf build-scan "${_ART_BUILD_NAME}" "${_ART_BUILD_NUMBER}" ${_ART_PROJECT_FLAG} 2>&1
  local rc=$?

  case "${rc}" in
    0)
      echo "  ✓ Xray clean (no policy violations)"
      return 0
      ;;
    3)
      case "${ARTIFACTORY_XRAY_FAIL_ON_VIOLATIONS}" in
        true|strict)
          echo "" >&2
          echo "  ERROR: Xray policy violations detected — failing build" >&2
          echo "         (ARTIFACTORY_XRAY_FAIL_ON_VIOLATIONS=${ARTIFACTORY_XRAY_FAIL_ON_VIOLATIONS})" >&2
          echo "         The image has been pushed, but this run is being" >&2
          echo "         rejected so downstream promote/deploy stages don't" >&2
          echo "         advance. Review findings in Artifactory →" >&2
          echo "         Builds → ${_ART_BUILD_NAME}/${_ART_BUILD_NUMBER} → Xray Data." >&2
          return 1
          ;;
        *)
          echo "  WARN: Xray reported policy violations — continuing (warn mode)" >&2
          echo "        Set ARTIFACTORY_XRAY_FAIL_ON_VIOLATIONS=true to hard-fail the build." >&2
          return 0
          ;;
      esac
      ;;
    *)
      echo "  WARN: Xray scan exit ${rc} (unlicensed, unreachable, or still indexing)" >&2
      return 0
      ;;
  esac
}

# ── Flow orchestrators ──────────────────────────────────────────────
#
# Each flow reads top-to-bottom. A helper returning non-zero means
# "stop the flow and propagate" — the orchestrator chains with
# `|| return 1` instead of swallowing failures with `return 0`.

_artifactory_pro_flow() {
  local built_local_ref="$1"
  # Preflight is run by push_to_backend before this, so _ART_PROJECT_FLAG
  # and the skip flags already reflect the project's presence/absence.
  _artifactory_pro_enrich_build_info

  docker tag "${built_local_ref}" "${_ART_TARGET}"
  _artifactory_pro_xray_prescan || return 1

  _artifactory_pro_push || return 1
  _artifactory_pro_publish_build_info
  _artifactory_pro_xray_postscan || return 1

  # After this point the image is in Artifactory and has passed both
  # scan gates (or scans were disabled/warned). Resolve digest, write
  # build.env, tag custom properties on the manifest.
  local push_digest
  push_digest=$(_artifactory_resolve_push_digest "${_ART_TARGET}")
  _artifactory_write_build_env "${_ART_TARGET}" "${push_digest}"

  # Custom properties on the manifest. jf docker push already set
  # build.name + build.number on all layers — we only add our custom
  # metadata on the manifest file itself.
  _artifactory_set_props "${_ART_MANIFEST_PATH}" \
    "${_ART_BUILD_NAME}" "${_ART_BUILD_NUMBER}" "${ARTIFACTORY_ENVIRONMENT}"
}

_artifactory_free_flow() {
  local built_local_ref="$1"
  docker tag "${built_local_ref}" "${_ART_TARGET}"

  local push_output
  push_output=$(docker push "${_ART_TARGET}" 2>&1) || {
    echo "${push_output}" >&2
    echo "ERROR: docker push to Artifactory failed" >&2
    return 1
  }
  echo "${push_output}"

  local push_digest
  push_digest=$(_artifactory_resolve_push_digest "${_ART_TARGET}" "${push_output}")
  _artifactory_write_build_env "${_ART_TARGET}" "${push_digest}"

  # Build info WITH module linkage — constructs artifacts[] and
  # dependencies[] from storage-API checksums + side-loaded manifests.
  # Same data shape jf docker push writes on Pro. The Packages →
  # Produced By UI hyperlink is Pro-gated; the linkage data is still
  # correctly stored and surfaces in the Build's own tabs.
  _artifactory_build_publish_free_with_modules \
    "${_ART_BUILD_NAME}" "${_ART_BUILD_NUMBER}" "${_ART_MANIFEST_PATH}" "${_ART_TARGET}"

  # Set build.name + build.number on every blob for "Used by Build"
  # UI backlinks. Pro's jf docker push does this automatically — on
  # Free we iterate manually.
  _artifactory_set_props_all_layers "${_ART_MANIFEST_PATH}" \
    "${_ART_BUILD_NAME}" "${_ART_BUILD_NUMBER}"

  # Custom metadata props on the manifest.
  _artifactory_set_props "${_ART_MANIFEST_PATH}" \
    "${_ART_BUILD_NAME}" "${_ART_BUILD_NUMBER}" "${ARTIFACTORY_ENVIRONMENT}"
}

# ── Entry point ─────────────────────────────────────────────────────

push_to_backend() {
  local built_local_ref="$1"

  _artifactory_require_env   || return 1
  _artifactory_require_tools || return 1

  _artifactory_normalise_bools
  _artifactory_decompose_ref "${built_local_ref}"
  _artifactory_resolve_templates

  _artifactory_jf_config || return 1
  _artifactory_docker_login "${ARTIFACTORY_PUSH_HOST}" || return 1

  # Preflight needs creds (curl /access/api/v1/projects). Runs BEFORE
  # the banner so the "Tier:" line correctly reflects whether this run
  # is full-Pro or downgraded.
  _artifactory_preflight_project

  _artifactory_print_banner "${built_local_ref}"

  if [ "${_ART_IS_PRO}" = "true" ]; then
    _artifactory_pro_flow "${built_local_ref}" || return 1
  else
    _artifactory_free_flow "${built_local_ref}" || return 1
  fi

  echo "Pushed: ${_ART_TARGET}"
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
  # python3 is ONLY needed by the Free-tier flow's hand-merged build-info
  # publish (lib/build-info-merge.py + 5 inline `python3 -c '...'` JSON
  # parsers). Pro tier uses `jf docker push` + `jf build-publish` which
  # handle build-info natively — no python3 needed. Check matches the
  # FREE/PRO dispatch in push_to_backend().
  if [ "${ARTIFACTORY_PRO:-false}" != "true" ] && ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: 'python3' required for the Free-tier build-info merge flow" >&2
    echo "       (build-info-merge.py + JSON parsers in artifactory.sh)" >&2
    echo "       Install python3 (alpine: apk add python3) OR set ARTIFACTORY_PRO=true" >&2
    echo "       if you have a Pro / Cloud Artifactory licence — that path uses jf's" >&2
    echo "       native build-info publishing and doesn't need python3." >&2
    missing=1
  fi
  return "${missing}"
}

# Auto-install the JFrog CLI if not present. Delegates to the shared
# helper at scripts/lib/install-jf.sh so Bamboo, GitLab CI, and the
# backend all install the same way (no sudo, JF_BINARY_URL takes
# precedence, falls back to the public installer). See that file for
# JF_BINARY_URL / JF_DEB_URL / JF_RPM_URL / JF_INSTALL_DIR documentation.
_artifactory_install_jf() {
  # shellcheck source=../lib/install-jf.sh
  . "$(dirname "${BASH_SOURCE[0]}")/../lib/install-jf.sh"
  install_jf
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
    # Swallow jf's per-call `{"status":"success",...}` stdout blob —
    # on the Free path we iterate over every blob in the tag dir and
    # the repetition is just noise. The trailing "set on N files" line
    # below is the one user-facing summary.
    jf rt set-props "${tag_dir}/${fname}" "${props}" >/dev/null 2>&1 && count=$((count + 1))
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

  # FINAL manifest = our pushed image, in our Artifactory. Basic auth
  # via the existing curl helper works because we already have
  # ARTIFACTORY_USER + ARTIFACTORY_TOKEN/PASSWORD in env.
  local final_body
  final_body=$(_artifactory_curl_manifest "${target}")
  [ -n "${final_body}" ] && printf '%s' "${final_body}" > "${tmpdir}/final-manifest.json"

  [ -z "${UPSTREAM_REF:-}" ] && return 0

  # UPSTREAM config = whatever public registry the user pulls from
  # (docker.io / gcr / ghcr / mcr / quay / private mirror). The earlier
  # curl path failed silently for docker.io because:
  #
  #   1. docker.io is not the registry — registry-1.docker.io is
  #      (docker.io/v2/... returns HTTP 302 redirect to the website)
  #   2. registry-1.docker.io requires a bearer token from
  #      auth.docker.io, not basic auth with Artifactory creds
  #
  # When the upstream fetch failed, the merger fell into "fallback"
  # mode — counting ALL non-config sha256 blobs as dependencies, which
  # over-counts by the number of layers we added on top of upstream.
  #
  # Using `crane config <upstream-ref>` skips both problems: it
  # handles each registry's auth transparently (bearer for docker hub,
  # static for gcr/ghcr/mcr/quay public, basic from
  # ~/.docker/config.json for private), AND auto-resolves multi-arch
  # indices to the local-platform manifest in one call. It returns the
  # config JSON directly — we extract rootfs.diff_ids from it. Crane
  # is already on PATH (build.sh installs it for the BASE_DIGEST OCI
  # label resolution), so no new dependency.
  #
  # Falls through to the legacy curl-then-walk path if crane is
  # somehow missing — that path still works for upstreams hosted in
  # the same Artifactory as the push target (proxy / remote repo).
  if command -v crane >/dev/null 2>&1; then
    if crane config "${UPSTREAM_REF}" 2>/dev/null \
         | python3 -c "
import json, sys
cfg = json.load(sys.stdin)
json.dump(cfg.get('rootfs', {}).get('diff_ids', []), sys.stdout)" \
         > "${tmpdir}/upstream-diffids.json" 2>/dev/null \
       && [ -s "${tmpdir}/upstream-diffids.json" ]; then
      return 0
    fi
    rm -f "${tmpdir}/upstream-diffids.json"
  fi

  # ── Fallback: legacy curl path ────────────────────────────────────
  # Works when upstream is on the same Artifactory as the push (proxy
  # repos with our auth). Doesn't work for direct public docker.io
  # without bearer-auth handling — that's covered by the crane branch.
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

# Multi-arch builds (any buildx output that produces an OCI image index)
# store the manifest at <tag>/list.manifest.json, NOT <tag>/manifest.json.
# Single-arch builds use manifest.json. The ARTIFACTORY_MANIFEST_PATH
# template can't predict which the user's build produces, so probe the
# tag directory and return whichever exists. Echoes the resolved path
# (or the input path on probe failure — caller's set-props will then
# emit its existing WARN).
_artifactory_resolve_manifest_filename() {
  local manifest_path="$1"
  local tag_dir="${manifest_path%/manifest.json}"
  local secret="${ARTIFACTORY_TOKEN:-${ARTIFACTORY_PASSWORD:-}}"
  local _url="${ARTIFACTORY_URL%/}"
  _url="${_url%/artifactory}"

  local listing
  listing=$(curl -fsSL -u "${ARTIFACTORY_USER}:${secret}" \
    "${_url}/artifactory/api/storage/${tag_dir}" 2>/dev/null) || {
    printf '%s' "${manifest_path}"
    return 0
  }

  # Walk children, prefer list.manifest.json (multi-arch index) since
  # that's what consumers pull by tag. Fall back to manifest.json.
  local resolved
  resolved=$(printf '%s' "${listing}" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    files = [c.get('uri','').lstrip('/') for c in d.get('children', [])]
    for candidate in ('list.manifest.json', 'manifest.json'):
        if candidate in files:
            print(candidate); break
except json.JSONDecodeError:
    pass
" 2>/dev/null)

  if [ -n "${resolved}" ]; then
    printf '%s/%s' "${tag_dir}" "${resolved}"
  else
    printf '%s' "${manifest_path}"
  fi
}

_artifactory_set_props() {
  local manifest_path="$1" build_name="$2" build_number="$3" env="$4"
  # Resolve manifest.json → list.manifest.json for multi-arch images.
  manifest_path=$(_artifactory_resolve_manifest_filename "${manifest_path}")

  local props="environment=${env};build.name=${build_name};build.number=${build_number}"
  [ -n "${ARTIFACTORY_TEAM:-}" ] && props="${props};team=${ARTIFACTORY_TEAM}"
  [ -n "${GIT_SHA:-}" ]          && props="${props};git.commit=${GIT_SHA}"
  [ -n "${UPSTREAM_TAG:-}" ]     && props="${props};upstream.tag=${UPSTREAM_TAG}"
  # NOTE: sbom.path is NOT set here — it's set by sbom-post.sh AFTER
  # the SBOM upload succeeds, so the property always points to a real
  # artifact rather than a speculative path.
  [ -n "${ARTIFACTORY_PROPERTIES:-}" ] && props="${props};${ARTIFACTORY_PROPERTIES}"

  if ! jf rt set-props "${manifest_path}" "${props}" >/dev/null 2>&1; then
    echo "  WARN: 'jf rt set-props' failed for ${manifest_path}" >&2
    echo "        (check manifest path matches the repo storage layout)" >&2
  fi
}
