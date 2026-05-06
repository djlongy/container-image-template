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
#   bash scripts/test/regression.sh remediate        # filter by name substring
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
_must_contain "Remediate:          false"
_must_contain "Inject certs:       false"
_must_not_contain "ERROR"
end_scenario

scenario "build-debug-flag-on"
_run env -i HOME="$HOME" PATH="$PATH" BUILD_DEBUG=true ./scripts/build.sh --dry-run >/dev/null
_must_contain "[debug]"
# A reliable [debug] line that's always present regardless of image.env contents:
# the resolved-config summary fires after defaults+normalisation.
_must_contain "[debug] resolved: REMEDIATE="
end_scenario

scenario "shell-empty-remediate-vs-file-true"
# Sets REMEDIATE='' in shell + REMEDIATE=true in image.env.
# This was the empty-string snapshot bug; file value should win.
sed -i.bak -E 's|^REMEDIATE=.*|REMEDIATE="true"|' image.env && rm image.env.bak
_run env -i HOME="$HOME" PATH="$PATH" REMEDIATE='' ./scripts/build.sh --dry-run >/dev/null
_must_contain "Remediate:          true"
_must_not_contain "Remediate:          false"
end_scenario

scenario "shell-set-remediate-overrides-file"
# Explicit non-empty REMEDIATE in shell beats image.env (correct precedence).
sed -i.bak -E 's|^REMEDIATE=.*|REMEDIATE="true"|' image.env && rm image.env.bak
_run env -i HOME="$HOME" PATH="$PATH" REMEDIATE=false ./scripts/build.sh --dry-run >/dev/null
_must_contain "Remediate:          false"
end_scenario

# ════════════════════════════════════════════════════════════════════
# REMEDIATE flag behaviour
# ════════════════════════════════════════════════════════════════════

scenario "remediate-true-alpine-supported"
sed -i.bak -E 's|^REMEDIATE=.*|REMEDIATE="true"|' image.env && rm image.env.bak
_run env -i HOME="$HOME" PATH="$PATH" ./scripts/build.sh --dry-run >/dev/null
_must_contain "Remediate:          true (scripts/remediate/alpine.sh)"
end_scenario

scenario "remediate-true-unsupported-distro"
# Bad DISTRO with REMEDIATE=true should fail-fast with a list of supported
sed -i.bak -E 's|^REMEDIATE=.*|REMEDIATE="true"|' image.env && rm image.env.bak
sed -i.bak -E 's|^DISTRO=.*|DISTRO="windows"|' image.env && rm image.env.bak
out=$(env -i HOME="$HOME" PATH="$PATH" ./scripts/build.sh --dry-run 2>&1) ; rc=$?
echo "${out}" > "${TMP_DIR}/out"
echo "${out}" | head -10
[ "${rc}" -ne 0 ] || FAILURES+=("${CURRENT_NAME}: expected non-zero exit on bad distro")
_must_contain "scripts/remediate/windows.sh does not exist"
_must_contain "Available distros:"
end_scenario

scenario "remediate-true-but-distro-default-alpine-script-exists"
# Even when DISTRO is unset, default kicks in to alpine
sed -i.bak -E 's|^REMEDIATE=.*|REMEDIATE="true"|' image.env && rm image.env.bak
sed -i.bak -E '/^DISTRO=/d' image.env && rm image.env.bak
_run env -i HOME="$HOME" PATH="$PATH" ./scripts/build.sh --dry-run >/dev/null
_must_contain "Distro:             alpine"
_must_contain "Remediate:          true"
end_scenario

scenario "remediate-FALSE-uppercase"
# Boolean normalisation: TRUE/True/true/false/0 all accepted
sed -i.bak -E 's|^REMEDIATE=.*|REMEDIATE="FALSE"|' image.env && rm image.env.bak
_run env -i HOME="$HOME" PATH="$PATH" ./scripts/build.sh --dry-run >/dev/null
_must_contain "Remediate:          false"
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
end_scenario

# ════════════════════════════════════════════════════════════════════
# bamboo_* auto-import
# ════════════════════════════════════════════════════════════════════

scenario "bamboo-auto-import"
_run env -i HOME="$HOME" PATH="$PATH" \
  bamboo_REMEDIATE=true \
  bamboo_INJECT_CERTS=true \
  ./scripts/build.sh --dry-run >/dev/null
_must_contain "Auto-imported"
_must_contain "Remediate:          true"
_must_contain "Inject certs:       true"
end_scenario

scenario "bamboo-auto-import-shell-wins"
# Explicit shell export should beat bamboo_* import
_run env -i HOME="$HOME" PATH="$PATH" \
  bamboo_REMEDIATE=true \
  REMEDIATE=false \
  ./scripts/build.sh --dry-run >/dev/null
_must_contain "Remediate:          false"
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
