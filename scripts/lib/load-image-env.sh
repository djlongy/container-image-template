#!/usr/bin/env bash
# scripts/lib/load-image-env.sh — single source of truth for image.env loading
#
# Sourced by every script that needs to read behavioural config:
#   build.sh
#   scan/xray-vuln.sh
#   scan/xray-sbom.sh
#   sbom-post.sh
#
# Provides three functions and one logging helper:
#
#   _dbg <msg>            — print '[debug] msg' to stderr when
#                           BUILD_DEBUG=true; otherwise no-op. Safe under
#                           `set -e` (returns 0 either way).
#
#   import_bamboo_vars    — translate every `bamboo_FOO` env var to a
#                           bare `FOO` export. Skips vars already set in
#                           the shell (explicit export wins). No-op when
#                           not running under Bamboo.
#
#   load_image_env        — source ./image.env from the caller's CWD.
#                           Fails fast (return 1) if the file is missing.
#                           image.env.example is intentionally NOT a
#                           fallback — it's a template only. Snapshot/
#                           restore semantics: shell-set non-empty vars
#                           override image.env values; empty-set shell
#                           vars don't (so a stray `INJECT_CERTS=` in
#                           the agent env can't clobber the file value).
#
# Why a shared library: the old build.sh had this logic inline as
# `_build_load_image_env` and `_build_import_bamboo_vars`, and other
# scripts (xray-scan-post.sh etc.) had to either inline a copy or
# rely on the calling shell to have already exported what they needed.
# Centralising means each script self-loads its config — same precedence
# everywhere, same debug logs everywhere, same "fail with clear hint"
# message when image.env is missing.

# shellcheck disable=SC2148
# (sourced, not executed — no shebang interpretation needed)

# ════════════════════════════════════════════════════════════════════
# _dbg — opt-in debug echo
# ════════════════════════════════════════════════════════════════════
# Set BUILD_DEBUG=true (env or image.env) to surface verbose decision
# logs from scripts that source this lib. Off by default to keep CI
# logs clean. The `return 0` keeps the call site `set -e` safe.
_dbg() {
  [ "${BUILD_DEBUG:-false}" = "true" ] && echo "  [debug] $*" >&2
  return 0
}

# ════════════════════════════════════════════════════════════════════
# import_bamboo_vars — Bamboo plan-var auto-import
# ════════════════════════════════════════════════════════════════════
# Bamboo exposes plan vars and global vars to script tasks as env
# vars prefixed `bamboo_` (dots in the var name become underscores).
# Translate each to its bare name before image.env loading so plan
# vars Just Work without a hand-written relay block in bamboo.yaml.
#
# Doesn't override an already-set bare var — explicit shell export
# wins over Bamboo plan-var auto-import. Use that to keep a
# script-local override even when a bamboo_FOO value exists.
#
# For renamed vars (e.g. shared global `svc_artifactory_token` →
# script-expected `ARTIFACTORY_TOKEN`), still write a one-line shim
# in the bamboo.yaml task — auto-import only handles exact-match.
import_bamboo_vars() {
  local __bv __bare __count=0
  while IFS= read -r __bv; do
    [ -z "${__bv}" ] && continue
    __bare="${__bv#bamboo_}"
    if [ -n "${!__bare-}" ]; then
      _dbg "bamboo import skip: ${__bare} already set in shell"
      continue
    fi
    eval "export ${__bare}=\"\${${__bv}}\""
    __count=$((__count+1))
    _dbg "bamboo import: ${__bv} → ${__bare}"
  done < <(env | grep -oE '^bamboo_[A-Za-z_][A-Za-z0-9_]*' || true)

  if [ "${__count}" -gt 0 ]; then
    echo "→ Auto-imported ${__count} bamboo_* env var(s) → bare names"
    _dbg "(set BUILD_DEBUG=true to see the per-var breakdown)"
  fi
}

# ════════════════════════════════════════════════════════════════════
# load_image_env — source ./image.env with snapshot/restore semantics
# ════════════════════════════════════════════════════════════════════
# Three-step:
#   1. Snapshot all known config vars that are SET AND NON-EMPTY in
#      the caller's shell. (Empty-set is intentionally excluded —
#      a stray `INJECT_CERTS=` exported by the runner shouldn't override
#      the file's INJECT_CERTS=true.)
#   2. Source image.env from the caller's CWD. Fail if missing.
#   3. Re-export the snapshot so shell values win over file values.
#
# Pre-fail behaviour: the caller's shell may have run import_bamboo_vars
# already, which means `bamboo_INJECT_CERTS=true` becomes a bare
# `INJECT_CERTS=true` BEFORE this function snapshots. So plan-var values
# survive the snapshot/restore round-trip and override the file.
load_image_env() {
  if [ ! -f image.env ]; then
    echo "ERROR: image.env not found at $(pwd)/image.env" >&2
    echo "" >&2
    echo "  image.env is the single source of truth for this build." >&2
    echo "  image.env.example is a TEMPLATE — it is NOT sourced as a" >&2
    echo "  fallback (was previously, but that masked config drift" >&2
    echo "  between dev local edits and CI's untouched template)." >&2
    echo "" >&2
    echo "  To fix:" >&2
    echo "    cp image.env.example image.env" >&2
    echo "    \$EDITOR image.env       # adjust UPSTREAM_TAG, INJECT_CERTS, etc." >&2
    echo "    git add image.env && git commit -m 'add image.env'" >&2
    echo "" >&2
    echo "  image.env is committed (intentionally — it's the per-fork config)." >&2
    echo "  Keep secrets OUT of image.env; pass tokens via CI plan vars." >&2
    return 1
  fi

  local __v __line __SHELL_OVERRIDES=""
  for __v in IMAGE_NAME \
             UPSTREAM_REGISTRY UPSTREAM_IMAGE UPSTREAM_TAG UPSTREAM_REF \
             INJECT_CERTS ORIGINAL_USER \
             HARBOR_REGISTRY HARBOR_PROJECT HARBOR_USER HARBOR_PASSWORD \
             VENDOR AUTHORS BUILD_DEBUG \
             CA_CERT \
             REGISTRY_KIND \
             ARTIFACTORY_URL ARTIFACTORY_USER ARTIFACTORY_PASSWORD ARTIFACTORY_TOKEN \
             ARTIFACTORY_PRO ARTIFACTORY_PROJECT \
             ARTIFACTORY_TEAM ARTIFACTORY_ENVIRONMENT ARTIFACTORY_PUSH_HOST \
             ARTIFACTORY_IMAGE_REF ARTIFACTORY_MANIFEST_PATH \
             ARTIFACTORY_BUILD_NAME ARTIFACTORY_BUILD_NUMBER ARTIFACTORY_PROPERTIES \
             ARTIFACTORY_SBOM_REPO ARTIFACTORY_SBOM_ARCHIVE_REPO \
             ARTIFACTORY_GRYPE_DB_REPO \
             ARTIFACTORY_XRAY_FAIL_ON_VIOLATIONS \
             ARTIFACTORY_BUILD_XRAY_PRESCAN ARTIFACTORY_BUILD_XRAY_POSTSCAN \
             XRAY_ARTIFACTORY_URL XRAY_ARTIFACTORY_USER \
             XRAY_ARTIFACTORY_PASSWORD XRAY_ARTIFACTORY_TOKEN \
             XRAY_GENERATE_SBOM XRAY_SCAN_FORMAT \
             XRAY_SCAN_REF SBOM_SCAN_REF XRAY_FAIL_ON_SEVERITY \
             IMAGE_REF IMAGE_DIGEST IMAGE_TAG \
             CRANE_URL SYFT_INSTALLER_URL SYFT_VERSION \
             GRYPE_INSTALLER_URL GRYPE_VERSION \
             GRYPE_FAIL_ON_SEVERITY GRYPE_DB_MIRROR_SUBPATH \
             TRIVY_VERSION TRIVY_INSTALLER_URL TRIVY_BINARY_URL \
             TRIVY_FAIL_ON_SEVERITY TRIVY_SCAN_REF TRIVY_SEVERITY_FILTER \
             JF_BINARY_URL JF_DEB_URL JF_RPM_URL JF_INSTALL_DIR \
             SBOM_TARGET SBOM_FILE VULN_SCAN_FILE \
             APPEND_GIT_SHORT \
             SBOM_WEBHOOK_URL SBOM_WEBHOOK_AUTH_HEADER \
             DEPENDENCY_TRACK_URL DEPENDENCY_TRACK_API_KEY DEPENDENCY_TRACK_PROJECT \
             SPLUNK_HEC_URL SPLUNK_HEC_TOKEN SPLUNK_HEC_INDEX \
             SPLUNK_HEC_SOURCETYPE SPLUNK_SBOM_SOURCETYPE SPLUNK_HEC_INSECURE \
             SPLUNK_SOURCE; do
    if [ -n "${!__v-}" ]; then
      __SHELL_OVERRIDES="${__SHELL_OVERRIDES}${__v}=$(printf '%q' "${!__v}")"$'\n'
      _dbg "shell-set override captured: ${__v}"
    fi
  done

  echo "→ Sourcing image.env"
  _dbg "image.env present in $(pwd)"
  # shellcheck disable=SC1091
  . ./image.env

  if [ -n "${__SHELL_OVERRIDES}" ]; then
    _dbg "re-applying shell-set overrides on top of image.env"
    while IFS= read -r __line; do
      [ -z "${__line}" ] && continue
      eval "export ${__line}"
    done <<< "${__SHELL_OVERRIDES}"
  fi
}
