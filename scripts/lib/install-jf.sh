#!/usr/bin/env bash
# install-jf.sh — single source of truth for JFrog CLI installation.
#
# Sourced by scripts/build.sh, scripts/push-backends/artifactory.sh,
# bamboo-specs/bamboo.yaml, and .gitlab-ci.yml. Keeping the install
# logic in one place means the "no sudo" + "honour internal mirror"
# policy is consistent everywhere.
#
# Provides one function: install_jf
#
#   install_jf            # install jf if not on PATH; return 0 on success.
#
# THREE install paths, in precedence order. Set ONE of these to point
# at a file in your local Artifactory generic repo. None set = the
# function fails loudly with a hint — no internet fallback (the
# public installer requires sudo to land in /usr/local/bin and that
# was the original Bamboo blocker).
#
#   JF_BINARY_URL    Direct URL to the standalone `jf` binary.
#                    Preferred — fastest, simplest, OS-agnostic. The
#                    binary is statically-linked and runs anywhere.
#                    Example:
#                      https://artifactory.example.com/artifactory/
#                      jfrog-releases-remote/jfrog-cli/v2-jf/2.81.0/
#                      jfrog-cli-linux-amd64/jf
#
#   JF_DEB_URL       URL to a JFrog CLI .deb package. We DON'T
#                    `dpkg -i` it (would need sudo) — we extract the
#                    archive with `dpkg-deb -x` (sudoless, ships with
#                    every Debian-family system) and copy /usr/bin/jf
#                    out of the extracted tree.
#                    Example:
#                      https://artifactory.example.com/artifactory/
#                      jfrog-debs/pool/jfrog-cli-v2-jf_2.81.0_amd64.deb
#
#   JF_RPM_URL       URL to a JFrog CLI .rpm package. Same trick as
#                    .deb: `rpm2cpio | cpio` extracts contents without
#                    installing, no sudo required. Needs `rpm2cpio` +
#                    `cpio` on the agent (default on RHEL/Alma/Rocky).
#                    Example:
#                      https://artifactory.example.com/artifactory/
#                      jfrog-rpms/jfrog-cli-v2-jf-2.81.0.x86_64.rpm
#
# Common knob:
#   JF_INSTALL_DIR   Where the binary lands on PATH. Default:
#                      ${HOME}/.local/bin
#                    Always defaulted to a user-writable path so CI
#                    agents don't need sudo. Override to /usr/local/bin
#                    only when you specifically want it system-wide
#                    AND have root or passwordless sudo configured.
#
# Why no public installer fallback?
# The script at install-cli.jfrog.io drops the binary into /tmp then
# runs `mv jf /usr/local/bin/`. That mv prompts for sudo, which is
# fatal in a non-interactive Bamboo task. Forcing one of the three
# explicit URLs above ensures the install path is predictable in CI.
# For local dev, set JF_BINARY_URL=https://releases.jfrog.io/artifactory/jfrog-cli/v2-jf/[RELEASE]/jfrog-cli-linux-amd64/jf

# shellcheck disable=SC2148
# (sourced, not executed — no shebang interpretation needed)

# Internal: download a URL into a destination file. Wraps curl with
# the same flags / timeout everywhere.
_jf_curl() {
  local url="$1" dest="$2"
  curl -fsSL --max-time 180 -o "${dest}" "${url}"
}

# Internal: extract /usr/bin/jf (or wherever) from an extracted .deb /
# .rpm tree rooted at $1, copy to $2. Returns 0 on success.
_jf_locate_and_copy() {
  local root="$1" dest="$2"
  local found
  found="$(find "${root}" -type f -name jf -perm -u+x 2>/dev/null | head -1)"
  if [ -z "${found}" ]; then
    found="$(find "${root}" -type f -name jf 2>/dev/null | head -1)"
  fi
  if [ -z "${found}" ]; then
    echo "  ✗ no 'jf' binary found inside extracted package" >&2
    [ "${BUILD_DEBUG:-false}" = "true" ] && find "${root}" -type f >&2
    return 1
  fi
  cp "${found}" "${dest}"
  chmod +x "${dest}"
}

# Method A — direct binary
_jf_install_binary() {
  local install_dir="$1" url="$2"
  echo "→ installing jf from JF_BINARY_URL → ${install_dir}/jf"
  [ "${BUILD_DEBUG:-false}" = "true" ] && echo "  [debug] curl ${url}"
  if _jf_curl "${url}" "${install_dir}/jf" && chmod +x "${install_dir}/jf"; then
    return 0
  fi
  echo "  ✗ jf binary download failed from JF_BINARY_URL" >&2
  return 1
}

# Method B — .deb extraction (sudoless)
_jf_install_deb() {
  local install_dir="$1" url="$2"
  echo "→ installing jf from JF_DEB_URL (extract, no dpkg -i) → ${install_dir}/jf"
  [ "${BUILD_DEBUG:-false}" = "true" ] && echo "  [debug] curl ${url}"

  local tmp deb
  tmp="$(mktemp -d)" || return 1
  deb="${tmp}/jf.deb"

  if ! _jf_curl "${url}" "${deb}"; then
    echo "  ✗ .deb download failed" >&2
    rm -rf "${tmp}"
    return 1
  fi

  if command -v dpkg-deb >/dev/null 2>&1; then
    [ "${BUILD_DEBUG:-false}" = "true" ] && echo "  [debug] dpkg-deb -x ${deb} ${tmp}/extract"
    mkdir -p "${tmp}/extract"
    if ! dpkg-deb -x "${deb}" "${tmp}/extract" 2>/dev/null; then
      echo "  ✗ dpkg-deb extraction failed" >&2
      rm -rf "${tmp}"
      return 1
    fi
  else
    # Fallback — POSIX `ar` + `tar`. Works on Alpine / busybox where
    # dpkg isn't installed (jf is statically linked, so cross-distro
    # extraction is fine).
    [ "${BUILD_DEBUG:-false}" = "true" ] && echo "  [debug] dpkg-deb missing, falling back to ar/tar"
    if ! command -v ar >/dev/null 2>&1; then
      echo "  ✗ neither dpkg-deb nor ar available — cannot extract .deb" >&2
      echo "    (install dpkg or binutils, or use JF_BINARY_URL instead)" >&2
      rm -rf "${tmp}"
      return 1
    fi
    mkdir -p "${tmp}/extract"
    ( cd "${tmp}" \
        && ar x "${deb}" \
        && for d in data.tar.*; do [ -f "${d}" ] && tar xf "${d}" -C "${tmp}/extract"; done
    ) || {
      echo "  ✗ ar/tar extraction failed" >&2
      rm -rf "${tmp}"
      return 1
    }
  fi

  _jf_locate_and_copy "${tmp}/extract" "${install_dir}/jf" || {
    rm -rf "${tmp}"
    return 1
  }
  rm -rf "${tmp}"
}

# Method C — .rpm extraction (sudoless)
_jf_install_rpm() {
  local install_dir="$1" url="$2"
  echo "→ installing jf from JF_RPM_URL (extract, no rpm -i) → ${install_dir}/jf"
  [ "${BUILD_DEBUG:-false}" = "true" ] && echo "  [debug] curl ${url}"

  if ! command -v rpm2cpio >/dev/null 2>&1 || ! command -v cpio >/dev/null 2>&1; then
    echo "  ✗ rpm2cpio + cpio required to extract .rpm without root" >&2
    echo "    (install rpm + cpio, or use JF_BINARY_URL instead)" >&2
    return 1
  fi

  local tmp rpm
  tmp="$(mktemp -d)" || return 1
  rpm="${tmp}/jf.rpm"

  if ! _jf_curl "${url}" "${rpm}"; then
    echo "  ✗ .rpm download failed" >&2
    rm -rf "${tmp}"
    return 1
  fi

  mkdir -p "${tmp}/extract"
  ( cd "${tmp}/extract" && rpm2cpio "${rpm}" | cpio -idm --quiet ) || {
    echo "  ✗ rpm2cpio | cpio extraction failed" >&2
    rm -rf "${tmp}"
    return 1
  }

  _jf_locate_and_copy "${tmp}/extract" "${install_dir}/jf" || {
    rm -rf "${tmp}"
    return 1
  }
  rm -rf "${tmp}"
}

install_jf() {
  if command -v jf >/dev/null 2>&1; then
    [ "${BUILD_DEBUG:-false}" = "true" ] && echo "  [debug] jf already on PATH: $(command -v jf)"
    return 0
  fi

  local install_dir="${JF_INSTALL_DIR:-${HOME}/.local/bin}"
  mkdir -p "${install_dir}"

  if [ -n "${JF_BINARY_URL:-}" ]; then
    _jf_install_binary "${install_dir}" "${JF_BINARY_URL}" || return 1
  elif [ -n "${JF_DEB_URL:-}" ]; then
    _jf_install_deb "${install_dir}" "${JF_DEB_URL}" || return 1
  elif [ -n "${JF_RPM_URL:-}" ]; then
    _jf_install_rpm "${install_dir}" "${JF_RPM_URL}" || return 1
  else
    echo "ERROR: jf not on PATH and no install source configured." >&2
    echo "  Set ONE of these to point at a file in your Artifactory:" >&2
    echo "    JF_BINARY_URL  — direct binary (preferred)" >&2
    echo "    JF_DEB_URL     — Debian package (extracted, no dpkg -i)" >&2
    echo "    JF_RPM_URL     — RPM package (extracted, no rpm -i)" >&2
    echo "  Public installer fallback was removed because it requires" >&2
    echo "  sudo to mv the binary into /usr/local/bin." >&2
    return 1
  fi

  export PATH="${install_dir}:${PATH}"
  echo "  ✓ jf installed: $("${install_dir}/jf" --version 2>/dev/null || echo 'unknown version')"
  return 0
}
