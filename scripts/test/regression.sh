#!/usr/bin/env bash
# scripts/test/regression.sh — local regression suite for build.sh + scan scripts
#
# Exercises every behavioural permutation we've shipped so far. Catches
# the "pristine green CI hides regressions" class of bug — every scenario
# below has either bitten us or could plausibly bite us next.
#
# Each scenario:
#   1. Snapshots the live image.env
#   2. Mutates env / image.env to the scenario's shape
#   3. Runs build.sh --dry-run (or other script) capturing stdout+stderr
#   4. Asserts expected markers appear (or absent) in the output
#   5. Restores image.env from the snapshot
#
# Run with:
#   bash scripts/test/regression.sh                  # all scenarios
#   bash scripts/test/regression.sh inject-certs     # filter by name substring
#
# Exit 0 if every scenario passes, non-zero with summary otherwise.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

FILTER="${1:-}"
FAILURES=()
PASSES=0
CURRENT_NAME=""
TMP_DIR=$(mktemp -d)
SNAPSHOT="${TMP_DIR}/image.env.snapshot"
cp image.env "${SNAPSHOT}"
trap 'cp "${SNAPSHOT}" image.env; rm -rf "${TMP_DIR}"' EXIT

# Quiet-mode dry-run: just resolves config and stops before docker build
_run() {
  local out="${TMP_DIR}/out"
  ( "$@" ) > "${out}" 2>&1
  local rc=$?
  cat "${out}"
  return ${rc}
}

# Assert STDOUT contains a substring; mark failure otherwise.
_must_contain() {
  local what="$1"
  if ! grep -qF -- "${what}" "${TMP_DIR}/out" 2>/dev/null; then
    FAILURES+=("${CURRENT_NAME}: expected to find: ${what}")
    return 1
  fi
  return 0
}

# Assert STDOUT does NOT contain a substring.
_must_not_contain() {
  local what="$1"
  if grep -qF -- "${what}" "${TMP_DIR}/out" 2>/dev/null; then
    FAILURES+=("${CURRENT_NAME}: should NOT contain: ${what}")
    return 1
  fi
  return 0
}

scenario() {
  local name="$1"
  CURRENT_NAME="${name}"
  if [ -n "${FILTER}" ] && [[ "${name}" != *"${FILTER}"* ]]; then
    return 0
  fi
  printf '\n══════════════════════════════════════════════════════════════════\n'
  printf '  Scenario: %s\n' "${name}"
  printf '══════════════════════════════════════════════════════════════════\n'
  cp "${SNAPSHOT}" image.env  # reset
}

end_scenario() {
  local pre_failures=0
  if [ "${#FAILURES[@]}" -gt 0 ]; then
    pre_failures=$(printf '%s\n' "${FAILURES[@]}" | grep -c "^${CURRENT_NAME}:" || true)
  fi
  if [ "${pre_failures}" -eq 0 ]; then
    printf '  ✓ PASS\n'
    PASSES=$((PASSES + 1))
  else
    printf '  ✗ FAIL (%d assertion(s) failed)\n' "${pre_failures}" >&2
  fi
}

# ════════════════════════════════════════════════════════════════════
# image.env precedence + sourcing
# ════════════════════════════════════════════════════════════════════

scenario "missing-image-env"
mv image.env image.env.tmp
out=$(env -i HOME="$HOME" PATH="$PATH" ./scripts/build.sh --dry-run 2>&1) ; rc=$?
mv image.env.tmp image.env
echo "${out}" > "${TMP_DIR}/out"
echo "${out}" | head -10
[ "${rc}" -ne 0 ] || FAILURES+=("${CURRENT_NAME}: expected non-zero exit")
_must_contain "ERROR: image.env not found"
_must_contain "cp image.env.example image.env"
end_scenario

scenario "default-no-overrides"
_run env -i HOME="$HOME" PATH="$PATH" ./scripts/build.sh --dry-run >/dev/null
_must_contain "→ Sourcing image.env"
_must_contain "Inject certs:       false"
_must_not_contain "ERROR"
end_scenario

scenario "build-debug-flag-on"
_run env -i HOME="$HOME" PATH="$PATH" BUILD_DEBUG=true ./scripts/build.sh --dry-run >/dev/null
_must_contain "[debug]"
# A reliable [debug] line that's always present regardless of image.env contents:
# the resolved-config summary fires after defaults+normalisation.
_must_contain "[debug] resolved: INJECT_CERTS="
end_scenario

scenario "shell-empty-inject-certs-vs-file-true"
# Sets INJECT_CERTS='' in shell + INJECT_CERTS=true in image.env.
# This was the empty-string snapshot bug; file value should win.
sed -i.bak -E 's|^INJECT_CERTS=.*|INJECT_CERTS="true"|' image.env && rm image.env.bak
_run env -i HOME="$HOME" PATH="$PATH" INJECT_CERTS='' ./scripts/build.sh --dry-run >/dev/null
_must_contain "Inject certs:       true"
_must_not_contain "Inject certs:       false"
end_scenario

scenario "shell-set-inject-certs-overrides-file"
# Explicit non-empty INJECT_CERTS in shell beats image.env (correct precedence).
sed -i.bak -E 's|^INJECT_CERTS=.*|INJECT_CERTS="true"|' image.env && rm image.env.bak
_run env -i HOME="$HOME" PATH="$PATH" INJECT_CERTS=false ./scripts/build.sh --dry-run >/dev/null
_must_contain "Inject certs:       false"
end_scenario

# ════════════════════════════════════════════════════════════════════
# INJECT_CERTS flag behaviour
# ════════════════════════════════════════════════════════════════════

scenario "inject-certs-true-no-cert-files"
# INJECT_CERTS=true with empty certs/ dir — Dockerfile certs-true stage
# would COPY but find nothing; build.sh just reports the flag's value.
sed -i.bak -E 's|^INJECT_CERTS=.*|INJECT_CERTS="true"|' image.env && rm image.env.bak
_run env -i HOME="$HOME" PATH="$PATH" ./scripts/build.sh --dry-run >/dev/null
_must_contain "Inject certs:       true"
end_scenario

scenario "inject-certs-true-with-cert-file"
sed -i.bak -E 's|^INJECT_CERTS=.*|INJECT_CERTS="true"|' image.env && rm image.env.bak
echo "-----BEGIN CERTIFICATE-----" > certs/_test.crt
echo "MIICert..." >> certs/_test.crt
echo "-----END CERTIFICATE-----" >> certs/_test.crt
_run env -i HOME="$HOME" PATH="$PATH" ./scripts/build.sh --dry-run >/dev/null
rm -f certs/_test.crt
_must_contain "Inject certs:       true"
end_scenario

scenario "ca-cert-env-auto-flips-inject-certs"
# Setting CA_CERT in env should write certs/ci-injected.crt AND
# auto-flip INJECT_CERTS to true even if image.env says false.
sed -i.bak -E 's|^INJECT_CERTS=.*|INJECT_CERTS="false"|' image.env && rm image.env.bak
CA_PEM="$(printf -- '-----BEGIN CERTIFICATE-----\nMIITest\n-----END CERTIFICATE-----\n')"
_run env -i HOME="$HOME" PATH="$PATH" CA_CERT="${CA_PEM}" ./scripts/build.sh --dry-run >/dev/null
rm -f certs/ci-injected.crt
_must_contain "→ Wrote CA_CERT to certs/ci-injected.crt"
_must_contain "Inject certs:       true"
end_scenario

# ════════════════════════════════════════════════════════════════════
# APPEND_GIT_SHORT flag — tag-shape control
# ════════════════════════════════════════════════════════════════════

scenario "append-git-short-default-true"
_run env -i HOME="$HOME" PATH="$PATH" ./scripts/build.sh --dry-run >/dev/null
# Default tag should have -<sha7> suffix on the configured upstream tag
_must_contain "1.25.3-alpine-"
end_scenario

scenario "append-git-short-false"
_run env -i HOME="$HOME" PATH="$PATH" APPEND_GIT_SHORT=false ./scripts/build.sh --dry-run >/dev/null
# Tag should end at the upstream tag with no SHA suffix, regardless
# of whether PUSH_REGISTRY / PUSH_PROJECT are set in image.env.
_must_contain "1.25.3-alpine"
_must_not_contain "1.25.3-alpine-"  # no SHA suffix
end_scenario

scenario "append-git-short-FALSE-uppercase"
_run env -i HOME="$HOME" PATH="$PATH" APPEND_GIT_SHORT=FALSE ./scripts/build.sh --dry-run >/dev/null
_must_not_contain "1.25.3-alpine-"
end_scenario

scenario "append-git-short-zero"
_run env -i HOME="$HOME" PATH="$PATH" APPEND_GIT_SHORT=0 ./scripts/build.sh --dry-run >/dev/null
_must_not_contain "1.25.3-alpine-"
end_scenario

scenario "append-git-short-no"
_run env -i HOME="$HOME" PATH="$PATH" APPEND_GIT_SHORT=no ./scripts/build.sh --dry-run >/dev/null
_must_not_contain "1.25.3-alpine-"
end_scenario

# ════════════════════════════════════════════════════════════════════
# Required-field validation
# ════════════════════════════════════════════════════════════════════

scenario "missing-upstream-tag-fails"
sed -i.bak -E '/^UPSTREAM_TAG=/d' image.env && rm image.env.bak
out=$(env -i HOME="$HOME" PATH="$PATH" ./scripts/build.sh --dry-run 2>&1) ; rc=$?
echo "${out}" > "${TMP_DIR}/out"
echo "${out}" | head -5
[ "${rc}" -ne 0 ] || FAILURES+=("${CURRENT_NAME}: expected non-zero exit")
_must_contain "UPSTREAM_TAG must be set"
end_scenario

scenario "missing-upstream-image-fails"
sed -i.bak -E '/^UPSTREAM_IMAGE=/d' image.env && rm image.env.bak
out=$(env -i HOME="$HOME" PATH="$PATH" ./scripts/build.sh --dry-run 2>&1) ; rc=$?
echo "${out}" > "${TMP_DIR}/out"
echo "${out}" | head -5
[ "${rc}" -ne 0 ] || FAILURES+=("${CURRENT_NAME}: expected non-zero exit")
_must_contain "UPSTREAM_IMAGE must be set"
end_scenario

scenario "push-without-push-registry-fails"
# Strip PUSH_REGISTRY/PROJECT (and ARTIFACTORY_PUSH_HOST in case
# auto-derive would kick in) from image.env so the test starts from
# the unconfigured state regardless of what's currently committed.
sed -i.bak -E '/^(PUSH_REGISTRY|PUSH_PROJECT|ARTIFACTORY_URL|ARTIFACTORY_PUSH_HOST)=/d' image.env && rm image.env.bak
out=$(env -i HOME="$HOME" PATH="$PATH" ./scripts/build.sh --push 2>&1) ; rc=$?
echo "${out}" > "${TMP_DIR}/out"
echo "${out}" | head -10
[ "${rc}" -ne 0 ] || FAILURES+=("${CURRENT_NAME}: expected non-zero exit on --push without PUSH_REGISTRY")
_must_contain "PUSH_REGISTRY and PUSH_PROJECT must be set"
end_scenario

scenario "argv-extra-args-rejected"
out=$(env -i HOME="$HOME" PATH="$PATH" ./scripts/build.sh --push extra 2>&1) ; rc=$?
echo "${out}" > "${TMP_DIR}/out"
[ "${rc}" -ne 0 ] || FAILURES+=("${CURRENT_NAME}: expected non-zero exit on extra args")
_must_contain "too many arguments"
end_scenario

scenario "argv-unknown-flag-rejected"
out=$(env -i HOME="$HOME" PATH="$PATH" ./scripts/build.sh --bogus 2>&1) ; rc=$?
echo "${out}" > "${TMP_DIR}/out"
[ "${rc}" -ne 0 ] || FAILURES+=("${CURRENT_NAME}: expected non-zero exit on unknown flag")
_must_contain "unknown flag"
end_scenario

scenario "help-flag"
out=$(env -i HOME="$HOME" PATH="$PATH" ./scripts/build.sh --help 2>&1) ; rc=$?
echo "${out}" > "${TMP_DIR}/out"
[ "${rc}" -eq 0 ] || FAILURES+=("${CURRENT_NAME}: --help should exit 0, got ${rc}")
_must_contain "Usage:"
_must_contain "--push"
_must_contain "--dry-run"
end_scenario

# ════════════════════════════════════════════════════════════════════
# Backend selector
# ════════════════════════════════════════════════════════════════════

scenario "registry-kind-artifactory-needs-creds-on-push"
# Strip BOTH push-side and Artifactory derivation sources from
# image.env so the test starts from an unconfigured state. With
# REGISTRY_KIND=artifactory but no derivation source, --push must fail.
sed -i.bak -E '/^(PUSH_REGISTRY|PUSH_PROJECT|ARTIFACTORY_URL|ARTIFACTORY_PUSH_HOST|ARTIFACTORY_TEAM|REGISTRY_KIND)=/d' image.env && rm image.env.bak
echo 'REGISTRY_KIND="artifactory"' >> image.env
out=$(env -i HOME="$HOME" PATH="$PATH" ./scripts/build.sh --push 2>&1) ; rc=$?
echo "${out}" > "${TMP_DIR}/out"
echo "${out}" | head -10
[ "${rc}" -ne 0 ] || FAILURES+=("${CURRENT_NAME}: expected non-zero exit")
_must_contain "PUSH_REGISTRY and PUSH_PROJECT must be set"
_must_contain "ARTIFACTORY_PUSH_HOST"  # tip pointing at the right vars
end_scenario

scenario "registry-kind-artifactory-derives-from-push-host"
# Strip image.env push config first, then provide ARTIFACTORY_PUSH_HOST
# via shell to test the auto-derive path.
sed -i.bak -E '/^(PUSH_REGISTRY|PUSH_PROJECT|ARTIFACTORY_URL|ARTIFACTORY_PUSH_HOST|ARTIFACTORY_TEAM|REGISTRY_KIND)=/d' image.env && rm image.env.bak
echo 'REGISTRY_KIND="artifactory"' >> image.env
_run env -i HOME="$HOME" PATH="$PATH" \
  ARTIFACTORY_PUSH_HOST="example.jfrog.io" \
  ARTIFACTORY_TEAM="test" \
  ./scripts/build.sh --push 2>/dev/null || true
_must_contain "Image:              example.jfrog.io/test/nginx:"
end_scenario

# ════════════════════════════════════════════════════════════════════
# Scan scripts — graceful no-op when creds missing
# ════════════════════════════════════════════════════════════════════

scenario "xray-vuln-no-creds-noop"
_run env -i HOME="$HOME" PATH="$PATH" ./scripts/scan/xray-vuln.sh 2>/dev/null || true
_must_contain "Xray-side Artifactory creds unset — no-op"
end_scenario

scenario "xray-sbom-no-creds-noop"
_run env -i HOME="$HOME" PATH="$PATH" ./scripts/scan/xray-sbom.sh 2>/dev/null || true
_must_contain "Xray-side Artifactory creds unset — no-op"
end_scenario

scenario "xray-sbom-opt-out-via-flag"
_run env -i HOME="$HOME" PATH="$PATH" XRAY_GENERATE_SBOM=false ./scripts/scan/xray-sbom.sh 2>/dev/null || true
_must_contain "XRAY_GENERATE_SBOM=false — skipping"
end_scenario

scenario "xray-vuln-target-resolution-image-digest-wins"
# When IMAGE_DIGEST is set (post-build), it should be the scan target
# (NOT UPSTREAM_REF, even though image.env defines that too).
_run env -i HOME="$HOME" PATH="$PATH" \
  IMAGE_DIGEST="harbor.example.com/team/img@sha256:abc" \
  ./scripts/scan/xray-vuln.sh 2>/dev/null || true
_must_contain "→ Scan target: harbor.example.com/team/img@sha256:abc"
_must_not_contain "→ Scan target: docker.io/library/nginx:1.25.3-alpine"
end_scenario

scenario "xray-vuln-target-resolution-positional-arg-wins"
# Positional arg beats every env / image.env value.
_run env -i HOME="$HOME" PATH="$PATH" \
  IMAGE_DIGEST="should-be-ignored@sha256:def" \
  ./scripts/scan/xray-vuln.sh "explicit:override" 2>/dev/null || true
_must_contain "→ Scan target: explicit:override"
end_scenario

scenario "xray-vuln-target-resolution-xray-scan-ref-wins-over-upstream"
# XRAY_SCAN_REF beats UPSTREAM_REF (prescan use case).
_run env -i HOME="$HOME" PATH="$PATH" \
  XRAY_SCAN_REF="prescan:target" \
  ./scripts/scan/xray-vuln.sh 2>/dev/null || true
_must_contain "→ Scan target: prescan:target"
end_scenario

scenario "xray-vuln-target-resolution-fallback-to-upstream"
# When neither IMAGE_DIGEST nor XRAY_SCAN_REF nor positional arg are
# set, fall back to UPSTREAM_REF (or assembled UPSTREAM_*). Confirms
# the prescan-without-build case still works.
_run env -i HOME="$HOME" PATH="$PATH" ./scripts/scan/xray-vuln.sh 2>/dev/null || true
_must_contain "→ Scan target: docker.io/library/nginx:1.25.3-alpine"
end_scenario

scenario "xray-vuln-fails-loudly-when-pull-fails"
# Regression for the silent-fail bug: previously, if docker pull
# failed (e.g. unauthorized to a private registry), the script would
# WARN and exit 0 — CI showed the job as success even though no
# scan ran. Now it must exit non-zero so CI marks the job failed.
# We trigger this by passing a definitely-unreachable digest with
# Xray creds present (so Phase 1 passes through) and no docker login.
out=$(env -i HOME="$HOME" PATH="$PATH" \
  ARTIFACTORY_URL="https://example.invalid" \
  ARTIFACTORY_USER="x" \
  ARTIFACTORY_TOKEN="x" \
  ./scripts/scan/xray-vuln.sh "harbor.invalid/nope/nope@sha256:0000000000000000000000000000000000000000000000000000000000000000" 2>&1) ; rc=$?
echo "${out}" > "${TMP_DIR}/out"
[ "${rc}" -ne 0 ] || FAILURES+=("${CURRENT_NAME}: expected non-zero exit on docker pull / scan failure")
# We may exit at jf install (no JF_BINARY_URL), at docker pull, or at
# scan — any of those is a valid loud-failure point. Just confirm it's
# not pretending to succeed.
end_scenario

scenario "sbom-post-no-sinks-and-no-file"
out=$(env -i HOME="$HOME" PATH="$PATH" ./scripts/sbom-post.sh /nonexistent.cdx.json 2>&1) ; rc=$?
echo "${out}" > "${TMP_DIR}/out"
[ "${rc}" -ne 0 ] || FAILURES+=("${CURRENT_NAME}: expected non-zero on missing input file")
_must_contain "SBOM file not found"
end_scenario

scenario "sbom-post-no-sinks-with-valid-file"
echo '{"bomFormat":"CycloneDX","specVersion":"1.6","components":[]}' > "${TMP_DIR}/test.cdx.json"
out=$(env -i HOME="$HOME" PATH="$PATH" ./scripts/sbom-post.sh "${TMP_DIR}/test.cdx.json" 2>&1) ; rc=$?
echo "${out}" > "${TMP_DIR}/out"
[ "${rc}" -eq 0 ] || FAILURES+=("${CURRENT_NAME}: expected zero exit when no sinks configured, got ${rc}")
_must_contain "no sinks configured"
# Both Artifactory sinks must appear in the hint list so users know
# the difference between Xray-indexed and plain archive.
_must_contain "ARTIFACTORY_SBOM_REPO"
_must_contain "ARTIFACTORY_SBOM_ARCHIVE_REPO"
end_scenario

scenario "sbom-post-archive-sink-graceful-skip"
# SINK 4 must skip cleanly when ARTIFACTORY_SBOM_ARCHIVE_REPO unset.
echo '{"bomFormat":"CycloneDX","specVersion":"1.6","components":[]}' > "${TMP_DIR}/test.cdx.json"
out=$(env -i HOME="$HOME" PATH="$PATH" ./scripts/sbom-post.sh "${TMP_DIR}/test.cdx.json" 2>&1) ; rc=$?
echo "${out}" > "${TMP_DIR}/out"
_must_contain "artifactory-archive  skip"
end_scenario

# ════════════════════════════════════════════════════════════════════
# Modular push backends — REGISTRY_KIND dispatch
# ════════════════════════════════════════════════════════════════════

scenario "modular-harbor-backend-exists"
[ -f scripts/push-backends/harbor.sh ] || FAILURES+=("${CURRENT_NAME}: scripts/push-backends/harbor.sh missing")
bash -n scripts/push-backends/harbor.sh || FAILURES+=("${CURRENT_NAME}: harbor.sh fails bash -n")
grep -q '^push_to_backend()' scripts/push-backends/harbor.sh \
  || FAILURES+=("${CURRENT_NAME}: harbor.sh must export push_to_backend()")
echo "harbor.sh present + push_to_backend() defined" > "${TMP_DIR}/out"
end_scenario

scenario "modular-artifactory-backend-exists"
[ -f scripts/push-backends/artifactory.sh ] || FAILURES+=("${CURRENT_NAME}: scripts/push-backends/artifactory.sh missing")
bash -n scripts/push-backends/artifactory.sh || FAILURES+=("${CURRENT_NAME}: artifactory.sh fails bash -n")
grep -q '^push_to_backend()' scripts/push-backends/artifactory.sh \
  || FAILURES+=("${CURRENT_NAME}: artifactory.sh must export push_to_backend()")
echo "artifactory.sh present + push_to_backend() defined" > "${TMP_DIR}/out"
end_scenario

scenario "registry-kind-default-resolves-to-harbor"
# When REGISTRY_KIND is unset, dispatch must resolve to harbor.sh.
# Strip Artifactory-derivation sources so the test exercises the
# default (Harbor) path. Use --push to actually trigger dispatch.
sed -i.bak -E '/^(PUSH_REGISTRY|PUSH_PROJECT|ARTIFACTORY_URL|ARTIFACTORY_PUSH_HOST|ARTIFACTORY_TEAM|REGISTRY_KIND)=/d' image.env && rm image.env.bak
echo 'PUSH_REGISTRY="harbor.example.com"' >> image.env
echo 'PUSH_PROJECT="apps/test"'           >> image.env
out=$(env -i HOME="$HOME" PATH="$PATH" BUILD_DEBUG=true ./scripts/build.sh --push 2>&1) ; rc=$?
echo "${out}" > "${TMP_DIR}/out"
echo "${out}" | grep -E "(dispatching push|Harbor push|harbor\.sh)" | head -5
# We expect the build to fail later (no docker daemon access in
# regression env), but it must reach the dispatch step naming harbor.
_must_contain "backend=harbor"
end_scenario

scenario "registry-kind-explicit-harbor"
sed -i.bak -E '/^(PUSH_REGISTRY|PUSH_PROJECT|REGISTRY_KIND)=/d' image.env && rm image.env.bak
echo 'PUSH_REGISTRY="harbor.example.com"' >> image.env
echo 'PUSH_PROJECT="apps/test"'           >> image.env
echo 'REGISTRY_KIND="harbor"'             >> image.env
out=$(env -i HOME="$HOME" PATH="$PATH" BUILD_DEBUG=true ./scripts/build.sh --push 2>&1) ; rc=$?
echo "${out}" > "${TMP_DIR}/out"
_must_contain "backend=harbor"
end_scenario

scenario "registry-kind-unknown-fails-with-listing"
# REGISTRY_KIND set to a backend that doesn't exist must fail loudly
# AND list the available backends so the user sees the typo.
sed -i.bak -E '/^(PUSH_REGISTRY|PUSH_PROJECT|REGISTRY_KIND)=/d' image.env && rm image.env.bak
echo 'PUSH_REGISTRY="harbor.example.com"' >> image.env
echo 'PUSH_PROJECT="apps/test"'           >> image.env
echo 'REGISTRY_KIND="nexus"'              >> image.env
out=$(env -i HOME="$HOME" PATH="$PATH" ./scripts/build.sh --push 2>&1) ; rc=$?
echo "${out}" > "${TMP_DIR}/out"
echo "${out}" | tail -10
[ "${rc}" -ne 0 ] || FAILURES+=("${CURRENT_NAME}: expected non-zero exit on unknown backend")
_must_contain "REGISTRY_KIND='nexus'"
_must_contain "Available backends:"
_must_contain "harbor"
_must_contain "artifactory"
end_scenario

# ════════════════════════════════════════════════════════════════════
# Canonical artifact filenames (scripts/lib/artifact-names.sh)
# ════════════════════════════════════════════════════════════════════

scenario "artifact-names-lib-defines-defaults"
out=$(bash -c '. scripts/lib/artifact-names.sh; echo "SBOM_FILE=${SBOM_FILE} VULN_SCAN_FILE=${VULN_SCAN_FILE}"')
echo "${out}" > "${TMP_DIR}/out"
echo "${out}"
_must_contain "SBOM_FILE=sbom.cdx.json"
_must_contain "VULN_SCAN_FILE=vuln-scan.json"
end_scenario

scenario "artifact-names-shell-override-wins"
# Shell-set value must win over the lib's default — that's how forks
# customise per-job (e.g. running both Trivy and Xray in one pipeline).
out=$(SBOM_FILE=alt.json VULN_SCAN_FILE=alt-vuln.json bash -c '. scripts/lib/artifact-names.sh; echo "SBOM_FILE=${SBOM_FILE} VULN_SCAN_FILE=${VULN_SCAN_FILE}"')
echo "${out}" > "${TMP_DIR}/out"
_must_contain "SBOM_FILE=alt.json"
_must_contain "VULN_SCAN_FILE=alt-vuln.json"
end_scenario

scenario "load-image-env-snapshot-includes-canonical-names"
# Confirm the loader's snapshot list includes SBOM_FILE / VULN_SCAN_FILE
# so a shell override survives the `. ./image.env` round-trip.
grep -E '\bSBOM_FILE\b' scripts/lib/load-image-env.sh > "${TMP_DIR}/out"
grep -E '\bVULN_SCAN_FILE\b' scripts/lib/load-image-env.sh >> "${TMP_DIR}/out"
_must_contain "SBOM_FILE"
_must_contain "VULN_SCAN_FILE"
end_scenario

# ════════════════════════════════════════════════════════════════════
# Modular scan scripts — existence + syntax + canonical wiring
# ════════════════════════════════════════════════════════════════════

scenario "scan-scripts-exist-and-parse"
all_ok=1
for s in syft-sbom xray-sbom xray-vuln grype-vuln trivy-vuln trivy-sbom; do
  if [ ! -f "scripts/scan/${s}.sh" ]; then
    FAILURES+=("${CURRENT_NAME}: scripts/scan/${s}.sh missing"); all_ok=0; continue
  fi
  if ! bash -n "scripts/scan/${s}.sh" 2>/dev/null; then
    FAILURES+=("${CURRENT_NAME}: scripts/scan/${s}.sh fails bash -n"); all_ok=0
  fi
done
[ "${all_ok}" -eq 1 ] && echo "all 6 scan scripts present + parse" > "${TMP_DIR}/out" \
                       || echo "scan-scripts check: see failures" > "${TMP_DIR}/out"
end_scenario

scenario "scan-scripts-source-artifact-names"
# Every scan producer must source the canonical names so a single
# rename in artifact-names.sh propagates everywhere.
all_ok=1
for s in syft-sbom xray-sbom xray-vuln grype-vuln trivy-vuln trivy-sbom; do
  if ! grep -q 'lib/artifact-names.sh' "scripts/scan/${s}.sh"; then
    FAILURES+=("${CURRENT_NAME}: scripts/scan/${s}.sh doesn't source artifact-names.sh"); all_ok=0
  fi
done
[ "${all_ok}" -eq 1 ] && echo "all scan scripts source artifact-names.sh" > "${TMP_DIR}/out" \
                       || echo "scan-scripts artifact-names wiring check: see failures" > "${TMP_DIR}/out"
end_scenario

scenario "syft-sbom-no-target-fails-loudly"
# Strip image.env's UPSTREAM_* so resolution chain has nothing to
# fall back to — script must exit non-zero with the chain message.
sed -i.bak -E '/^UPSTREAM_(REGISTRY|IMAGE|TAG)=/d' image.env && rm image.env.bak
out=$(env -i HOME="$HOME" PATH="$PATH" ./scripts/scan/syft-sbom.sh 2>&1) ; rc=$?
echo "${out}" > "${TMP_DIR}/out"
[ "${rc}" -ne 0 ] || FAILURES+=("${CURRENT_NAME}: expected non-zero exit when no target available")
_must_contain "no scan target available"
_must_contain "Resolution chain"
end_scenario

scenario "syft-sbom-target-resolution-image-digest-wins"
# IMAGE_DIGEST (build.env) beats UPSTREAM_REF — same chain as Xray.
out=$(env -i HOME="$HOME" PATH="$PATH" \
  IMAGE_DIGEST="harbor.example.com/team/img@sha256:abc" \
  ./scripts/scan/syft-sbom.sh 2>&1 | head -3) ; rc=$?
echo "${out}" > "${TMP_DIR}/out"
_must_contain "→ Scan target: harbor.example.com/team/img@sha256:abc"
end_scenario

scenario "syft-sbom-source-target-mode"
# SBOM_TARGET=source switches to dir:${REPO_ROOT} so forks scanning
# Ansible/pip/npm sources still work.
out=$(env -i HOME="$HOME" PATH="$PATH" \
  SBOM_TARGET=source \
  ./scripts/scan/syft-sbom.sh 2>&1 | head -3) ; rc=$?
echo "${out}" > "${TMP_DIR}/out"
_must_contain "→ Scan target: dir:"
end_scenario

scenario "grype-vuln-missing-sbom-fails"
# Grype needs an SBOM as input — must exit non-zero with a useful hint.
out=$(env -i HOME="$HOME" PATH="$PATH" \
  SBOM_FILE="/tmp/definitely-not-here.cdx.json" \
  ./scripts/scan/grype-vuln.sh 2>&1) ; rc=$?
echo "${out}" > "${TMP_DIR}/out"
echo "${out}" | head -5
[ "${rc}" -ne 0 ] || FAILURES+=("${CURRENT_NAME}: expected non-zero exit on missing SBOM input")
_must_contain "SBOM not found"
_must_contain "syft-sbom.sh"  # pointer to a producer
end_scenario

scenario "trivy-version-safety-guard"
# Hard-coded check in both trivy scripts must refuse compromised
# v0.69.4-v0.69.6. Confirm by grepping the script source.
all_ok=1
for s in scripts/scan/trivy-vuln.sh scripts/scan/trivy-sbom.sh; do
  if ! grep -q '0\.69\.4|0\.69\.5|0\.69\.6' "${s}"; then
    FAILURES+=("${CURRENT_NAME}: ${s} missing compromised-version guard"); all_ok=0
  fi
  if ! grep -q 'TRIVY_VERSION:-0\.69\.3' "${s}"; then
    FAILURES+=("${CURRENT_NAME}: ${s} not pinned to safe v0.69.3 default"); all_ok=0
  fi
done
[ "${all_ok}" -eq 1 ] && echo "trivy scripts pinned + guarded" > "${TMP_DIR}/out" \
                       || echo "trivy safety check: see failures" > "${TMP_DIR}/out"
end_scenario

scenario "trivy-vuln-no-target-fails-loudly"
sed -i.bak -E '/^UPSTREAM_(REGISTRY|IMAGE|TAG)=/d' image.env && rm image.env.bak
out=$(env -i HOME="$HOME" PATH="$PATH" ./scripts/scan/trivy-vuln.sh 2>&1) ; rc=$?
echo "${out}" > "${TMP_DIR}/out"
[ "${rc}" -ne 0 ] || FAILURES+=("${CURRENT_NAME}: expected non-zero exit when no target")
_must_contain "no scan target available"
end_scenario

scenario "scan-scripts-write-canonical-filenames"
# Verify each producer script's output-resolution code references the
# canonical env var (SBOM_FILE for SBOM producers, VULN_SCAN_FILE for
# vuln scanners). Catches future regressions where someone hardcodes a
# custom name and breaks the swap-out contract.
all_ok=1
for s in syft-sbom xray-sbom trivy-sbom; do
  if ! grep -q '"\${SBOM_FILE}"' "scripts/scan/${s}.sh"; then
    FAILURES+=("${CURRENT_NAME}: scripts/scan/${s}.sh doesn't honour \${SBOM_FILE}"); all_ok=0
  fi
done
for s in xray-vuln grype-vuln trivy-vuln; do
  if ! grep -q '"\${VULN_SCAN_FILE}"' "scripts/scan/${s}.sh"; then
    FAILURES+=("${CURRENT_NAME}: scripts/scan/${s}.sh doesn't honour \${VULN_SCAN_FILE}"); all_ok=0
  fi
done
[ "${all_ok}" -eq 1 ] && echo "all scan scripts honour canonical names" > "${TMP_DIR}/out" \
                       || echo "canonical-names wiring check: see failures" > "${TMP_DIR}/out"
end_scenario

# ════════════════════════════════════════════════════════════════════
# bamboo_* auto-import
# ════════════════════════════════════════════════════════════════════

scenario "bamboo-auto-import"
_run env -i HOME="$HOME" PATH="$PATH" \
  bamboo_INJECT_CERTS=true \
  ./scripts/build.sh --dry-run >/dev/null
_must_contain "Auto-imported"
_must_contain "Inject certs:       true"
end_scenario

scenario "bamboo-auto-import-shell-wins"
# Explicit shell export should beat bamboo_* import
_run env -i HOME="$HOME" PATH="$PATH" \
  bamboo_INJECT_CERTS=true \
  INJECT_CERTS=false \
  ./scripts/build.sh --dry-run >/dev/null
_must_contain "Inject certs:       false"
end_scenario

# ════════════════════════════════════════════════════════════════════
# Summary
# ════════════════════════════════════════════════════════════════════

printf '\n══════════════════════════════════════════════════════════════════\n'
printf '  Regression summary\n'
printf '══════════════════════════════════════════════════════════════════\n'
printf '  Passed:  %d\n' "${PASSES}"
printf '  Failed:  %d\n' "${#FAILURES[@]}"
if [ "${#FAILURES[@]}" -gt 0 ]; then
  printf '\nFailures:\n'
  for f in "${FAILURES[@]}"; do
    printf '  - %s\n' "${f}"
  done
  exit 1
fi
echo "  ALL PASS"
exit 0
