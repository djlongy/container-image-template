#!/usr/bin/env bash
# scripts/lib/splunk-hec.sh — generic Splunk HEC event poster
#
# Sourced by scripts that ship JSON events to Splunk HTTP Event
# Collector (xray-vuln.sh, sbom-post.sh, future scan emitters).
#
# Provides one function:
#
#   splunk_hec_post <event-content-file> <sourcetype>
#     event-content-file:  path to a JSON file containing the EVENT
#                          PAYLOAD (whatever shape you want under
#                          `event`). The lib wraps it in HEC metadata
#                          (sourcetype/index/host/source) — it does
#                          NOT prescribe the event's internal shape.
#                          Callers build the event JSON themselves so
#                          they can nest BOMs/scans/whatever under any
#                          key they want (event.cyclonedx, event.xray,
#                          event.grype, etc.).
#     sourcetype:          Splunk sourcetype tag (e.g. jfrog:xray:scan,
#                          cyclonedx:json — see the platform team's HEC
#                          handoff doc for the canonical list).
#
#   Returns 0 on success (HTTP 2xx), 1 on failure. Splunk POST failure
#   is intended to be non-fatal at the caller — audit shipping is a
#   side-effect, not the build's purpose.
#
# Reads from env (see image.env.example for full descriptions):
#   SPLUNK_HEC_URL          full base URL — /services/collector appended
#                           if not already in the URL
#   SPLUNK_HEC_TOKEN        HEC token — sent as Authorization: Splunk <tok>
#   SPLUNK_HEC_INDEX        target index (default: main)
#   SPLUNK_HEC_INSECURE     "true" → curl -k (self-signed cert)
#   SPLUNK_SOURCE           envelope `source` prefix (default: pipeline);
#                           the lib appends "-job" to mimic the
#                           /var/log/<source>-job.log convention so the
#                           Splunk view groups events per pipeline.
#                           e.g. SPLUNK_SOURCE=cdss → "cdss-job"
#   HOSTNAME                envelope `host` field; defaults to uname -n
#
# Why a separate lib: xray-vuln.sh and sbom-post.sh both ship to HEC
# with slightly different envelope shapes. Centralising the curl call,
# /services/collector handling, --insecure flag, and 2xx parsing means
# only one place knows about Splunk wire format. Each caller just
# builds its event JSON and calls splunk_hec_post.

# shellcheck disable=SC2148

# Internal: tmp dir per process for intermediate envelopes. Caller
# trap cleans up; the file lifetime matches the curl call.
_SPLUNK_TMPDIR="${TMPDIR:-/tmp}/splunk-hec-$$"

splunk_hec_post() {
  local event_content_file="$1"
  local sourcetype="$2"

  if [ -z "${SPLUNK_HEC_URL:-}" ] || [ -z "${SPLUNK_HEC_TOKEN:-}" ]; then
    echo "→ Splunk HEC: SPLUNK_HEC_URL or SPLUNK_HEC_TOKEN unset — not shipped"
    return 0
  fi

  if [ ! -s "${event_content_file}" ]; then
    echo "  ✗ splunk_hec_post: event content file ${event_content_file} missing or empty" >&2
    return 1
  fi

  if ! command -v jq >/dev/null 2>&1; then
    echo "  ✗ splunk_hec_post: jq required for HEC envelope construction" >&2
    return 1
  fi

  mkdir -p "${_SPLUNK_TMPDIR}"
  local envelope="${_SPLUNK_TMPDIR}/$(basename "${event_content_file}").hec.json"

  # Sanitise URL: strip trailing slash, append /services/collector if absent.
  local hec_url="${SPLUNK_HEC_URL%/}"
  case "${hec_url}" in
    */services/collector|*/services/collector/event) ;;
    *) hec_url="${hec_url}/services/collector" ;;
  esac

  local index="${SPLUNK_HEC_INDEX:-main}"
  local insecure_flag=""
  [ "${SPLUNK_HEC_INSECURE:-false}" = "true" ] && insecure_flag="-k"

  # Wrap the caller's event content (whatever JSON shape it is) in
  # the HEC envelope. Written to a tmp FILE — inline --data-binary
  # "$VAR" hits ARG_MAX on bodies >~500 KB which is normal for SBOMs.
  jq -nc \
    --arg sourcetype "${sourcetype}" \
    --arg index      "${index}" \
    --arg source     "${SPLUNK_SOURCE:-pipeline}-job" \
    --arg host       "${HOSTNAME:-$(uname -n)}" \
    --slurpfile event "${event_content_file}" \
    '{
       sourcetype: $sourcetype,
       index:      $index,
       source:     $source,
       host:       $host,
       event:      $event[0]
     }' > "${envelope}"

  echo "→ POST → ${hec_url} (sourcetype=${sourcetype} index=${index})"

  local http_code
  http_code=$(curl -sS -o "${_SPLUNK_TMPDIR}/hec-response.txt" \
    -w '%{http_code}' \
    ${insecure_flag} \
    -X POST "${hec_url}" \
    -H "Authorization: Splunk ${SPLUNK_HEC_TOKEN}" \
    -H 'Content-Type: application/json' \
    --data-binary "@${envelope}" \
    || echo '000')

  case "${http_code}" in
    2*)
      echo "  ✓ posted (HTTP ${http_code})"
      return 0
      ;;
    *)
      echo "  WARN: Splunk HEC POST failed (HTTP ${http_code}) — continuing" >&2
      sed 's/^/    /' "${_SPLUNK_TMPDIR}/hec-response.txt" >&2 2>/dev/null || true
      return 1
      ;;
  esac
}
