#
# Single-image template Dockerfile.
#
# The build shape is: upstream base → optional cert injection → optional
# CVE remediation → final user restoration. Each stage is ARG-gated, and
# the final stage is selected at build time via `FROM stage-${ARG}` so
# unused branches never run. BuildKit prunes the unselected graph.
#
# This file ships tuned for Alpine-based upstream images (nginx is the
# demo). For Debian/Ubuntu/UBI bases, swap the `apk` line in the
# remediate-true stage for the appropriate package manager. Everything
# else stays the same.
#
# Dynamic OCI labels (version, revision, created, base.digest, source,
# etc.) are intentionally NOT set here with LABEL. They're passed by
# scripts/build.sh via `docker build --label ...`, which is the
# DevSecOps-recommended pattern: Dockerfiles hold static provenance
# (title, vendor, licenses), build invocation holds dynamic provenance
# (commit SHA, timestamp, base digest). Checking the Dockerfile into
# source control shouldn't require bumping commit SHAs in LABEL lines.

# ── Global ARGs (available to FROM lines of all stages) ──────────────
#
# No hardcoded defaults. Values are supplied by scripts/build.sh from
# image.env. The Renovate hint for UPSTREAM_TAG lives in image.env
# (matched by a customManagers regex in renovate.json), not here —
# keeping all image-specific values in one place.
# Defaults here are only used if build.sh doesn't pass --build-arg
# (e.g. running `docker build .` directly without the script).
# build.sh always passes these from image.env, so the defaults below
# are just to suppress BuildKit's InvalidDefaultArgInFrom warning.
ARG UPSTREAM_REGISTRY=docker.io/library
ARG UPSTREAM_IMAGE=nginx
ARG UPSTREAM_TAG=latest
ARG INJECT_CERTS=false
ARG REMEDIATE=true
ARG ORIGINAL_USER=root
ARG DISTRO=alpine
ARG APK_MIRROR=""
ARG APT_MIRROR=""

# ── Upstream base ────────────────────────────────────────────────────
FROM ${UPSTREAM_REGISTRY}/${UPSTREAM_IMAGE}:${UPSTREAM_TAG} AS base

# ── Label policy: preserve upstream, append ours ─────────────────────
#
# We intentionally do NOT set static LABEL lines here. Docker's label
# inheritance model is "later LABELs override earlier ones by key" —
# so any LABEL we wrote would silently clobber whatever the upstream
# image already carried (maintainer strings, upstream title,
# maintainer-authored annotations, license declarations, etc).
#
# Instead, all labels are added via `docker build --label ...`
# in scripts/build.sh, which ALSO follows override semantics but is
# a much shorter list of explicitly-chosen keys:
#
#   - ours: vendor, authors (team identity — we intentionally override)
#   - dynamic: version, revision, created, base.name, base.digest,
#              source, url (never collide with upstream in practice)
#
# Upstream labels for title, description, licenses, documentation,
# maintainer, and any image-specific ones flow through untouched.
# Forkers can add their own LABEL lines here if they want to override
# a specific upstream value — but the default is to preserve.

# ── Cert injection (optional) ────────────────────────────────────────
# When INJECT_CERTS=true, copy everything from certs/ into the system
# trust store. The raw append to ca-certificates.crt covers Alpine and
# distroless cases where `update-ca-certificates` isn't present; the
# later `update-ca-certificates` call rebuilds the merged bundle on
# Debian/Ubuntu/RHEL-family images. Both paths handled without distro
# detection — whichever works, works.
FROM base AS certs-false

FROM base AS certs-true
USER root
COPY certs/ /tmp/certs/
RUN set -eux; \
    found=0; \
    for f in /tmp/certs/*.crt /tmp/certs/*.pem; do \
      [ -f "$f" ] || continue; \
      cat "$f" >> /etc/ssl/certs/ca-certificates.crt 2>/dev/null || true; \
      cat "$f" >> /etc/ssl/cert.pem 2>/dev/null || true; \
      found=$((found + 1)); \
    done; \
    echo "Injected ${found} CA cert(s)"; \
    rm -rf /tmp/certs; \
    if command -v update-ca-certificates >/dev/null 2>&1; then \
      update-ca-certificates 2>/dev/null || true; \
    fi

ARG INJECT_CERTS
FROM certs-${INJECT_CERTS} AS with-certs

# ── CVE remediation (optional, distro-aware) ─────────────────────────
# When REMEDIATE=true, copies the scripts/remediate/ directory into
# the image and executes /tmp/remediate/${DISTRO}.sh. Four distros
# ship in the template by default: alpine, debian, ubuntu, ubi.
# Add a new distro by dropping a script at scripts/remediate/<name>.sh
# and setting DISTRO=<name> in image.env.
#
# The script inherits APK_MIRROR and APT_MIRROR as env vars so a
# single CI variable can point all upgrade operations at a
# closed-network proxy.
FROM with-certs AS remediate-false

FROM with-certs AS remediate-true
ARG DISTRO
ARG APK_MIRROR
ARG APT_MIRROR
USER root
# Inject CA certs BEFORE remediation so apk/apt trust internal mirrors.
# This runs regardless of INJECT_CERTS — the flag controls whether certs
# persist in the FINAL shipped image, but the build always needs to trust
# the mirror during package upgrades. Matches the monorepo pattern.
COPY certs/ /tmp/build-certs/
RUN set -eux; \
    for f in /tmp/build-certs/*.crt /tmp/build-certs/*.pem; do \
      [ -f "$f" ] || continue; \
      cat "$f" >> /etc/ssl/certs/ca-certificates.crt 2>/dev/null || true; \
    done; \
    rm -rf /tmp/build-certs
COPY scripts/remediate/ /tmp/remediate/
RUN set -eux; \
    chmod +x /tmp/remediate/${DISTRO}.sh; \
    APK_MIRROR="${APK_MIRROR}" APT_MIRROR="${APT_MIRROR}" \
      /tmp/remediate/${DISTRO}.sh; \
    rm -rf /tmp/remediate

ARG REMEDIATE
FROM remediate-${REMEDIATE} AS final

# Restore whatever USER the upstream image ran as. Required for images
# whose entrypoint expects a specific UID (e.g. nginx's entrypoint
# chowns paths only if run as root, then drops privs itself).
ARG ORIGINAL_USER
USER ${ORIGINAL_USER}
