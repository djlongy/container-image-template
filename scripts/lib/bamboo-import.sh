#!/usr/bin/env bash
# scripts/lib/bamboo-import.sh — Bamboo plan-var auto-import
#
# DELETABLE FILE. The rest of the codebase tolerates this file being
# absent — load-image-env.sh's stub of `import_bamboo_vars` is a
# no-op when this file isn't sourced. Removing Bamboo support is:
#
#   rm bamboo-specs/bamboo.yaml
#   rm scripts/lib/bamboo-import.sh
#   (optional) rm bamboo-related scenarios from scripts/test/regression.sh
#
# Nothing else needs to change.
#
# ── What this provides ──────────────────────────────────────────────
#
# Bamboo exposes plan vars and System → Global vars to script tasks
# as env vars prefixed `bamboo_` (dots in the var name become
# underscores). This script translates each `bamboo_FOO` to a bare
# `FOO` export before image.env loading, so plan vars Just Work
# without per-var relay shims in bamboo.yaml.
#
# Doesn't override an already-set bare var — explicit shell export
# wins over Bamboo plan-var auto-import. Use that to keep a
# script-local override even when a `bamboo_FOO` value exists.
#
# For renamed vars (e.g. shared global `svc_artifactory_token` →
# script-expected `ARTIFACTORY_TOKEN`), still write a one-line shim
# in the bamboo.yaml task — auto-import only handles exact-match.

# shellcheck disable=SC2148
# (sourced, not executed — no shebang interpretation needed)

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
