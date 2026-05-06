#!/usr/bin/env bash
# scripts/lib/docker-login.sh — multi-registry docker login for scan jobs
#
# Sourced by scripts/scan/xray-vuln.sh and scripts/scan/xray-sbom.sh
# (and any future scan script that needs to `docker pull` private
# images). Logs the daemon into every registry whose credentials it
# finds in env, so the subsequent `docker pull` of either the upstream
# OR the rebuilt image just works.
#
# Provides one function:
#
#   docker_login_for_xray_scan
#     Attempts a non-fatal docker login against three potential hosts:
#     - PUSH_REGISTRY                (default Harbor backend)
#     - ARTIFACTORY_PUSH_HOST        (when REGISTRY_KIND=artifactory)
#     - XRAY_ARTIFACTORY_URL host    (when scan-side ≠ push-side)
#
#     Each login is independent: failure of one doesn't block the
#     others. Hosts without configured creds are silently skipped.
#     A failed individual login logs WARN but continues — public
#     images (e.g. docker.io/library/* for prescan) are still
#     pullable without auth.
#
# Why a separate lib instead of doing this inline:
#   - build.sh has its own narrower _build_docker_login that targets
#     ONE host (the push target). This lib targets MULTIPLE hosts
#     because a postscan job may need to pull from PUSH_REGISTRY
#     (built image) AND the upstream registry (cached locally maybe,
#     or if you're scanning multiple images in one job).
#   - Reused across xray-vuln + xray-sbom. Keeps the per-script logic
#     focused on its single responsibility (scan + ship).
#
# shellcheck disable=SC2148
# (sourced, not executed)

docker_login_for_xray_scan() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "  WARN: docker CLI not on PATH — skipping login (subsequent pull will likely fail)" >&2
    return 0
  fi

  local _attempts=0 _failures=0

  # ── PUSH_REGISTRY (Harbor / default backend) ───────────────────
  if [ -n "${PUSH_REGISTRY:-}" ] && [ -n "${PUSH_REGISTRY_USER:-}" ] && [ -n "${PUSH_REGISTRY_PASSWORD:-}" ]; then
    _attempts=$((_attempts + 1))
    echo "→ docker login ${PUSH_REGISTRY} (PUSH_REGISTRY)"
    if printf '%s' "${PUSH_REGISTRY_PASSWORD}" \
         | docker login "${PUSH_REGISTRY}" -u "${PUSH_REGISTRY_USER}" --password-stdin >/dev/null 2>/tmp/docker-login.err; then
      echo "  ✓ logged in"
    else
      echo "  WARN: login failed — ${PUSH_REGISTRY} pulls will be unauthenticated" >&2
      sed 's/^/    /' /tmp/docker-login.err >&2 || true
      _failures=$((_failures + 1))
    fi
  fi

  # ── ARTIFACTORY_PUSH_HOST (when REGISTRY_KIND=artifactory) ─────
  if [ -n "${ARTIFACTORY_PUSH_HOST:-}" ] && [ -n "${ARTIFACTORY_USER:-}" ]; then
    local _secret="${ARTIFACTORY_TOKEN:-${ARTIFACTORY_PASSWORD:-}}"
    if [ -n "${_secret}" ]; then
      _attempts=$((_attempts + 1))
      echo "→ docker login ${ARTIFACTORY_PUSH_HOST} (ARTIFACTORY_PUSH_HOST)"
      if printf '%s' "${_secret}" \
           | docker login "${ARTIFACTORY_PUSH_HOST}" -u "${ARTIFACTORY_USER}" --password-stdin >/dev/null 2>/tmp/docker-login.err; then
        echo "  ✓ logged in"
      else
        echo "  WARN: login failed — ${ARTIFACTORY_PUSH_HOST} pulls will be unauthenticated" >&2
        sed 's/^/    /' /tmp/docker-login.err >&2 || true
        _failures=$((_failures + 1))
      fi
    fi
  fi

  # ── Scan-side Artifactory (host derived from XRAY_ARTIFACTORY_URL) ─
  if [ -n "${XRAY_ARTIFACTORY_URL:-}" ] && [ -n "${XRAY_ARTIFACTORY_USER:-}" ]; then
    local _xhost="${XRAY_ARTIFACTORY_URL#https://}"
    _xhost="${_xhost#http://}"
    _xhost="${_xhost%%/*}"
    local _xsecret="${XRAY_ARTIFACTORY_TOKEN:-${XRAY_ARTIFACTORY_PASSWORD:-}}"
    if [ -n "${_xsecret}" ] && [ "${_xhost}" != "${PUSH_REGISTRY:-}" ] && [ "${_xhost}" != "${ARTIFACTORY_PUSH_HOST:-}" ]; then
      _attempts=$((_attempts + 1))
      echo "→ docker login ${_xhost} (XRAY_ARTIFACTORY)"
      if printf '%s' "${_xsecret}" \
           | docker login "${_xhost}" -u "${XRAY_ARTIFACTORY_USER}" --password-stdin >/dev/null 2>/tmp/docker-login.err; then
        echo "  ✓ logged in"
      else
        echo "  WARN: login failed — ${_xhost} pulls will be unauthenticated" >&2
        sed 's/^/    /' /tmp/docker-login.err >&2 || true
        _failures=$((_failures + 1))
      fi
    fi
  fi

  if [ "${_attempts}" -eq 0 ]; then
    echo "  NOTE: no registry credentials in env — relying on existing daemon auth + public pulls" >&2
  fi
  # Always return 0 — failed logins shouldn't block the script;
  # pull-failure is a separate concern handled by the caller.
  return 0
}
