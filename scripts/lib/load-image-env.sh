#!/usr/bin/env bash
# scripts/lib/load-image-env.sh — single source of truth for image.env loading
#
# Sourced by every script that needs to read behavioural config —
# build.sh, every scan/* script, sbom-post.sh, etc. Add a new
# script that needs config? Just `. scripts/lib/load-image-env.sh
# && load_image_env` at the top.
#
# Provides:
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
#                           vars don't (so a stray `VAR=` in the agent
#                           env can't clobber the file value).
#                           Snapshot list is AUTO-DERIVED from image.env
#                           (greps `^[# ]*VAR=` patterns) plus a small
#                           EXTRAS list for shell-only vars — adding a
#                           new var to image.env is one-place edit.
#
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
# _redact_value — censor secret values in load-time logging
# ════════════════════════════════════════════════════════════════════
# Vars whose name matches secret-ish patterns (TOKEN/PASSWORD/SECRET/
# AUTH/KEY/CA_CERT) print as "[redacted, N chars]" so the log shows
# WHETHER a secret was loaded without leaking its contents. Everything
# else prints in full so the operator can verify URLs, hostnames,
# tags, project paths, etc. landed correctly.
_redact_value() {
  local __name="$1" __value="$2"
  case "${__name}" in
    *TOKEN*|*PASSWORD*|*SECRET*|*AUTH*|*_KEY|*_KEY_*|CA_CERT|COSIGN_KEY)
      if [ -z "${__value}" ]; then
        printf '<empty>'
      else
        printf '[redacted, %d chars]' "${#__value}"
      fi
      ;;
    *) printf '%s' "${__value}" ;;
  esac
}

# ════════════════════════════════════════════════════════════════════
# import_bamboo_vars — sourced from scripts/lib/bamboo-import.sh
# ════════════════════════════════════════════════════════════════════
# The actual Bamboo auto-import logic lives in a SEPARATE file
# (scripts/lib/bamboo-import.sh) so the codebase remains modular —
# Bamboo support can be removed by deleting that one file plus
# bamboo-specs/bamboo.yaml. The stub below provides a safe no-op
# function when bamboo-import.sh isn't present, so callers that do
# `import_bamboo_vars` keep working unchanged.
_bamboo_lib="$(dirname "${BASH_SOURCE[0]}")/bamboo-import.sh"
if [ -f "${_bamboo_lib}" ]; then
  # shellcheck source=./bamboo-import.sh
  . "${_bamboo_lib}"
else
  # Bamboo support removed. Stub keeps the API stable for callers.
  import_bamboo_vars() { :; }
fi
unset _bamboo_lib

# ════════════════════════════════════════════════════════════════════
# load_image_env — source ./image.env with snapshot/restore semantics
# ════════════════════════════════════════════════════════════════════
# Three-step:
#   1. Snapshot all known config vars that are SET AND NON-EMPTY in
#      the caller's shell. (Empty-set is intentionally excluded —
#      a stray `VAR=` exported by the runner shouldn't override
#      the file's VAR=<real-value>.)
#   2. Source image.env from the caller's CWD. Fail if missing.
#   3. Re-export the snapshot so shell values win over file values.
#
# Pre-fail behaviour: the caller's shell may have run import_bamboo_vars
# already, which means `bamboo_VENDOR=foo` becomes a bare `VENDOR=foo`
# BEFORE this function snapshots. So plan-var values survive the
# snapshot/restore round-trip and override the file.
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
    echo "    \$EDITOR image.env       # adjust UPSTREAM_TAG, REGISTRY_KIND, etc." >&2
    echo "    git add image.env && git commit -m 'add image.env'" >&2
    echo "" >&2
    echo "  image.env is committed (intentionally — it's the per-fork config)." >&2
    echo "  Keep secrets OUT of image.env; pass tokens via CI plan vars." >&2
    return 1
  fi

  # ── Build the snapshot list ─────────────────────────────────────
  # Auto-derive from image.env itself by grepping every line that
  # mentions a `VAR=` (active or commented). That way ADDING A NEW
  # VAR TO image.env IS A ONE-PLACE EDIT — no need to also update
  # this loader. Only true for vars that exist in image.env (the
  # one file actually sourced); image.env.example is a template
  # only and is intentionally NOT scanned.
  #
  # Augmented with an EXTRAS list for vars that flow only via shell
  # / CI (never appear in image.env as a `VAR=` line) but still need
  # shell-precedence over file values when they DO get set:
  #   - CA_CERT (CI-only secret)
  #   - IMAGE_REF / IMAGE_DIGEST / IMAGE_TAG / UPSTREAM_REF
  #     (build.env outputs / build.sh derived values)
  #   - SBOM_SCAN_REF / TRIVY_SCAN_REF / TRIVY_SEVERITY_FILTER
  #     (scan-time overrides documented in scan-script docstrings)
  #   - XRAY_ARTIFACTORY_PASSWORD (alternative to TOKEN, masked CI var)
  #   - XRAY_SCAN_FORMAT (scan-time override)
  # Add to EXTRAS when a new var is ONLY set in shell/CI, never in image.env.
  local __extras="CA_CERT \
                  IMAGE_REF IMAGE_DIGEST IMAGE_TAG UPSTREAM_REF \
                  SBOM_SCAN_REF TRIVY_SCAN_REF TRIVY_SEVERITY_FILTER \
                  XRAY_ARTIFACTORY_PASSWORD XRAY_SCAN_FORMAT"

  local __v __line __SHELL_OVERRIDES=""
  local __known
  __known=$(
    {
      grep -oE '^[# ]*[A-Z][A-Z0-9_]+=' image.env 2>/dev/null \
        | sed -E 's/^[# ]*//; s/=$//'
      printf '%s\n' ${__extras}
    } | sort -u
  )
  for __v in ${__known}; do
    if [ -n "${!__v-}" ]; then
      __SHELL_OVERRIDES="${__SHELL_OVERRIDES}${__v}=$(printf '%q' "${!__v}")"$'\n'
      _dbg "shell-set override captured: ${__v}"
    fi
  done

  echo "→ Sourcing image.env"
  _dbg "image.env present in $(pwd)"
  # shellcheck disable=SC1091
  . ./image.env

  # Track which keys were overridden from the shell vs. taken straight
  # from image.env so the per-var log can annotate the source. The set
  # is built from __SHELL_OVERRIDES (one line per override).
  local __overridden=""
  if [ -n "${__SHELL_OVERRIDES}" ]; then
    _dbg "re-applying shell-set overrides on top of image.env"
    while IFS= read -r __line; do
      [ -z "${__line}" ] && continue
      eval "export ${__line}"
      __overridden="${__overridden} ${__line%%=*}"
    done <<< "${__SHELL_OVERRIDES}"
  fi

  # ── Visibility: enumerate every loaded var ──────────────────────
  # Always printed (not _dbg-gated) because operators need to verify
  # config landed correctly when a job fails — having to re-run with
  # BUILD_DEBUG=true is too slow. Secrets are redacted by _redact_value
  # so logs are safe to share. Values shown for everything else so
  # hostname / project / tag mismatches surface immediately.
  echo "→ Loaded config (image.env + shell-overrides):"
  for __v in ${__known}; do
    if [ -n "${!__v-}" ]; then
      local __source="image.env"
      case " ${__overridden} " in *" ${__v} "*) __source="shell-override" ;; esac
      echo "    ${__v}=$(_redact_value "${__v}" "${!__v}")  [${__source}]"
    fi
  done
}
