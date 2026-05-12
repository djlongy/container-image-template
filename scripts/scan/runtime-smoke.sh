#!/usr/bin/env bash
# scripts/scan/runtime-smoke.sh — start the built image, verify it boots
#
# Purpose: catch the class of bug where the build succeeds + the image
# pushes cleanly but the cert sidecar / editable region somehow
# corrupted the image so it crashes on first start. Scans + push tell
# us nothing about whether the container actually RUNS.
#
# Logic (generic enough for daemons + one-shot tools):
#
#   1. docker create + docker start (NOT --rm, so we can inspect after)
#   2. Wait RUNTIME_SMOKE_SECONDS (default 5s — enough for most images
#      to either crash or settle into Running)
#   3. Check `docker inspect .State.Status`:
#        running                          → ✓ daemon-style, alive
#        exited + ExitCode 0              → ✓ one-shot tool, clean exit
#        exited + ExitCode non-zero       → ✗ crashed
#        dead / created / restarting      → ✗ broken
#   4. Stream the last N log lines for diagnostics regardless of result
#   5. Optionally honour the image's HEALTHCHECK: if one is defined and
#      RUNTIME_SMOKE_HEALTHCHECK=true, wait up to RUNTIME_HEALTH_TIMEOUT
#      for State.Health.Status to become "healthy" (otherwise fail).
#   6. Tear down: docker rm -f
#
# Required env (from build.env or shell):
#   IMAGE_DIGEST  preferred — pulls by digest, immutable
#   IMAGE_REF     fallback when IMAGE_DIGEST isn't set
#
# Optional env:
#   RUNTIME_SMOKE_SECONDS       wait window before status check (default 5)
#   RUNTIME_SMOKE_HEALTHCHECK   "true" to enforce HEALTHCHECK if defined (default true)
#   RUNTIME_HEALTH_TIMEOUT      max seconds to wait for "healthy" (default 60)
#   RUNTIME_SMOKE_LOGS          tail N log lines on failure (default 50)
#   RUNTIME_SMOKE_ENV           extra `-e KEY=VALUE` flags for `docker run`
#                               (space-separated, e.g. "FOO=bar BAZ=qux")
#
# Exit codes:
#   0  image started / exited cleanly (incl. when no health gate set)
#   1  image crashed, dead, or healthcheck failed within timeout

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

# shellcheck source=../lib/load-image-env.sh
. "${REPO_ROOT}/scripts/lib/load-image-env.sh"
import_bamboo_vars
load_image_env

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker CLI not on PATH — runtime smoke needs local docker daemon" >&2
  exit 1
fi

TARGET="${IMAGE_DIGEST:-${IMAGE_REF:-}}"
if [ -z "${TARGET}" ]; then
  echo "ERROR: no IMAGE_DIGEST or IMAGE_REF available" >&2
  echo "  Source build.env first: . ./build.env  (or pass IMAGE_DIGEST in env)" >&2
  exit 1
fi
echo "→ Runtime smoke target: ${TARGET}"

WAIT_SECONDS="${RUNTIME_SMOKE_SECONDS:-5}"
HEALTH_TIMEOUT="${RUNTIME_HEALTH_TIMEOUT:-60}"
LOG_LINES="${RUNTIME_SMOKE_LOGS:-50}"
ENFORCE_HEALTH="${RUNTIME_SMOKE_HEALTHCHECK:-true}"

# Container name uses image leaf + git short SHA for uniqueness across
# parallel runs of the same image.
_leaf="${TARGET##*/}"; _leaf="${_leaf%%[:@]*}"
_sha="$(printf '%s' "${TARGET}" | sha256sum | cut -c1-8)"
SMOKE_NAME="smoke-${_leaf}-${_sha}"
echo "  Container name:  ${SMOKE_NAME}"
echo "  Wait window:     ${WAIT_SECONDS}s"

# Pre-clean any stale container with the same name (safe — we own it).
docker rm -f "${SMOKE_NAME}" >/dev/null 2>&1 || true

# Build the docker run flags. RUNTIME_SMOKE_ENV is "K=V K=V" → "-e K=V -e K=V"
EXTRA_ENV_FLAGS=()
if [ -n "${RUNTIME_SMOKE_ENV:-}" ]; then
  for kv in ${RUNTIME_SMOKE_ENV}; do
    EXTRA_ENV_FLAGS+=(-e "${kv}")
  done
fi

# Start the container in the background. Don't use --rm so we can
# inspect post-mortem. The `${arr[@]+"${arr[@]}"}` dance is needed
# because bash 3.2 (macOS) errors on an empty-array expansion under
# `set -u`.
echo ""
echo "→ docker run -d --name ${SMOKE_NAME} ${TARGET}"
if ! docker run -d --name "${SMOKE_NAME}" ${EXTRA_ENV_FLAGS[@]+"${EXTRA_ENV_FLAGS[@]}"} "${TARGET}" >/dev/null 2>/tmp/smoke.start.err; then
  echo "ERROR: docker run failed to start the container" >&2
  echo "── start error ──" >&2
  sed 's/^/  /' /tmp/smoke.start.err >&2 || true
  exit 1
fi

# Cleanup on any exit path.
_smoke_cleanup() {
  echo ""
  echo "──── container logs (last ${LOG_LINES} lines) ────"
  docker logs --tail "${LOG_LINES}" "${SMOKE_NAME}" 2>&1 | sed 's/^/  /' || true
  echo "─────────────────────────────────────────────────"
  docker rm -f "${SMOKE_NAME}" >/dev/null 2>&1 || true
}
trap _smoke_cleanup EXIT

echo "→ waiting ${WAIT_SECONDS}s for the container to settle"
sleep "${WAIT_SECONDS}"

STATUS="$(docker inspect --format='{{.State.Status}}' "${SMOKE_NAME}" 2>/dev/null || echo "unknown")"
EXIT_CODE="$(docker inspect --format='{{.State.ExitCode}}' "${SMOKE_NAME}" 2>/dev/null || echo "?")"
HAS_HEALTH="$(docker inspect --format='{{if .Config.Healthcheck}}yes{{end}}' "${SMOKE_NAME}" 2>/dev/null || echo "no")"

echo ""
echo "→ Post-${WAIT_SECONDS}s state:"
echo "    Status:     ${STATUS}"
echo "    ExitCode:   ${EXIT_CODE}"
echo "    Healthcheck: ${HAS_HEALTH:-no}"

case "${STATUS}" in
  running)
    echo "  ✓ container is RUNNING (daemon-style image)"
    if [ "${ENFORCE_HEALTH}" = "true" ] && [ "${HAS_HEALTH}" = "yes" ]; then
      echo ""
      echo "→ Enforcing HEALTHCHECK (timeout ${HEALTH_TIMEOUT}s)"
      _waited=0
      while [ "${_waited}" -lt "${HEALTH_TIMEOUT}" ]; do
        _h="$(docker inspect --format='{{.State.Health.Status}}' "${SMOKE_NAME}" 2>/dev/null || echo "unknown")"
        case "${_h}" in
          healthy)
            echo "  ✓ healthcheck reported healthy after ${_waited}s"
            exit 0
            ;;
          unhealthy)
            echo "  ✗ healthcheck reported UNHEALTHY after ${_waited}s" >&2
            exit 1
            ;;
          starting|*)
            sleep 3
            _waited=$((_waited + 3))
            ;;
        esac
      done
      echo "  ✗ healthcheck did not reach healthy within ${HEALTH_TIMEOUT}s (last status: ${_h:-unknown})" >&2
      exit 1
    fi
    exit 0
    ;;
  exited)
    if [ "${EXIT_CODE}" = "0" ]; then
      echo "  ✓ container exited cleanly (one-shot tool image)"
      exit 0
    fi
    echo "  ✗ container exited with non-zero code ${EXIT_CODE}" >&2
    exit 1
    ;;
  dead|restarting|created)
    echo "  ✗ container is in '${STATUS}' state — image is broken" >&2
    exit 1
    ;;
  *)
    echo "  ✗ unexpected container state '${STATUS}'" >&2
    exit 1
    ;;
esac
