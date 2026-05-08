#
# Single-image template Dockerfile.
#
# Build shape: upstream base → optional cert injection → fork-owned
# extension → final user restoration. The cert stage is ARG-gated, and
# the final stage is selected at build time via `FROM stage-${ARG}` so
# unused branches never run. BuildKit prunes the unselected graph.
#
# This Dockerfile is intentionally MINIMAL. Bamboo's docker plugin and
# some older buildx versions don't reliably resolve nested ARG-gated
# stages, so we keep exactly one toggle here (INJECT_CERTS). All
# bespoke per-image work — package upgrades, extra installs, file
# drops, healthchecks, ENV — goes directly into the marked
# "FORK EDITS GO HERE" region below. Editing the Dockerfile is the
# expected fork pattern; there is no separate extension surface.
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
# build.sh passes these from image.env via --build-arg. The defaults
# below only apply when someone runs `docker build .` directly without
# the script — they exist to suppress BuildKit's InvalidDefaultArgInFrom
# warning, not as canonical values. The Renovate hint for UPSTREAM_TAG
# lives in image.env (matched by a customManagers regex in
# renovate.json), keeping all image-specific values in one place.
ARG UPSTREAM_REGISTRY=docker.io/library
ARG UPSTREAM_IMAGE=nginx
ARG UPSTREAM_TAG=1.29.8-alpine
ARG INJECT_CERTS=false
ARG ORIGINAL_USER=root

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
# trust store. The logic below auto-detects the right drop-in path at
# build time (no DISTRO arg needed), so the same Dockerfile works
# across alpine / debian / ubuntu / ubi / distroless:
#
#   1. /usr/local/share/ca-certificates/  — alpine / debian / ubuntu;
#      followed by `update-ca-certificates` to rebuild the merged bundle.
#   2. /etc/pki/ca-trust/source/anchors/  — UBI / RHEL / Fedora;
#      followed by `update-ca-trust` to rebuild.
#   3. Direct cat-append to /etc/ssl/certs/ca-certificates.crt and
#      /etc/ssl/cert.pem — fallback for distroless / scratch / busybox
#      images that lack both rebuild tools.
#
# Earlier versions of this stage append-then-rebuilt, which wiped our
# certs because update-ca-certificates rebuilds the bundle from
# /usr/local/share/ca-certificates/ — anything appended directly was
# lost. Putting the cert in the rebuild source first guarantees it
# survives.
FROM base AS certs-false

FROM base AS certs-true
USER root
COPY certs/ /tmp/certs/
RUN set -eux; \
    if [ -d /usr/local/share/ca-certificates ]; then \
      DROP_DIR=/usr/local/share/ca-certificates; \
      REBUILD=update-ca-certificates; \
    elif [ -d /etc/pki/ca-trust/source/anchors ]; then \
      DROP_DIR=/etc/pki/ca-trust/source/anchors; \
      REBUILD=update-ca-trust; \
    else \
      DROP_DIR=""; \
      REBUILD=""; \
    fi; \
    found=0; \
    for f in /tmp/certs/*.crt /tmp/certs/*.pem; do \
      [ -f "$f" ] || continue; \
      base="$(basename "$f")"; \
      case "${base}" in \
        *.crt|*.pem) base="${base%.*}" ;; \
      esac; \
      # Append to the bundle directly — this is what most TLS apps actually
      # read (OPENSSL_DEFAULT_CA_FILE = /etc/ssl/cert.pem on alpine, which
      # symlinks to /etc/ssl/certs/ca-certificates.crt). Alpine's
      # update-ca-certificates only manages the per-cert symlinks under
      # /etc/ssl/certs/*.pem and does NOT regenerate the bundle file from
      # the package, so direct append is the only reliable way to inject
      # there. On Debian/Ubuntu/UBI, update-ca-certificates regenerates
      # the bundle from anchors below, which re-includes our cert via the
      # drop-in step that follows — the append is redundant but harmless.
      cat "$f" >> /etc/ssl/certs/ca-certificates.crt 2>/dev/null || true; \
      cat "$f" >> /etc/ssl/cert.pem 2>/dev/null || true; \
      # Drop into the distro-aware anchors dir so update-ca-certificates /
      # update-ca-trust create the per-cert symlinks (alpine) or rebuild
      # the bundle including our cert (debian/ubuntu/ubi). For distroless
      # / scratch images both DROP_DIR and REBUILD stay empty and only
      # the bundle append above runs — still works.
      [ -n "${DROP_DIR}" ] && cp "$f" "${DROP_DIR}/${base}.crt"; \
      found=$((found + 1)); \
    done; \
    echo "Injected ${found} CA cert(s) (drop_dir=${DROP_DIR:-fallback-append-only})"; \
    rm -rf /tmp/certs; \
    if [ -n "${REBUILD}" ] && command -v "${REBUILD}" >/dev/null 2>&1; then \
      "${REBUILD}" 2>/dev/null || true; \
    fi

ARG INJECT_CERTS
FROM certs-${INJECT_CERTS} AS final

# ═══════════════════════════════════════════════════════════════════
# ▼▼▼  FORK EDITS GO HERE  ▼▼▼
# ═══════════════════════════════════════════════════════════════════
#
# This region is the ONLY place forks should add bespoke RUN / COPY /
# ENV / HEALTHCHECK lines. Everything above is template-owned and
# updates cleanly when you pull from upstream; everything here is
# yours. We're already running as root (left over from the certs
# stage), so apk/apt commands work without an explicit USER root.
#
# Common patterns:
#
#   # CVE remediation — package upgrades. Pick the line that matches
#   # your upstream's distro (alpine / debian / ubi); delete the rest.
#   RUN apk update && apk upgrade --no-cache
#   # RUN apt-get update && apt-get -y --only-upgrade upgrade && rm -rf /var/lib/apt/lists/*
#   # RUN microdnf -y update && microdnf clean all
#
#   # Extra packages
#   # RUN apk add --no-cache curl jq
#
#   # Static config drop-ins
#   # COPY config/nginx.conf /etc/nginx/nginx.conf
#
#   # Health check
#   # HEALTHCHECK --interval=30s --timeout=3s CMD wget -qO- http://localhost/ || exit 1
#
# Keep edits minimal — this template is not the place for
# multi-hundred-line image customisation. If your image needs that
# much bespoke logic, fork the template and own it.
#
# ═══════════════════════════════════════════════════════════════════
# ▲▲▲  END FORK EDITS  ▲▲▲
# ═══════════════════════════════════════════════════════════════════

# Restore whatever USER the upstream image ran as. Required for images
# whose entrypoint expects a specific UID (e.g. nginx's entrypoint
# chowns paths only if run as root, then drops privs itself).
ARG ORIGINAL_USER
USER ${ORIGINAL_USER}
