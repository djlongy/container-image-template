#
# Single-image template Dockerfile.
#
# Build shape: upstream base → cert sidecar (uses a shell-bearing
# builder image so it works on shell-less / distroless / chainguard
# bases too) → final stage that re-bases FROM base so USER stays
# whatever upstream had → editable region → restore upstream USER.
#
# Dynamic OCI labels (version, revision, created, base.digest, source)
# are set by scripts/build.sh via `docker build --label ...` rather
# than LABEL lines here; commit SHAs don't need to land in source.

# ── Global ARGs ──────────────────────────────────────────────────────
# build.sh passes these from image.env via --build-arg. ORIGINAL_USER
# is auto-detected from the upstream image at build time via
# `crane config` and passed as a build-arg. CERT_BUILDER_IMAGE is the
# image used to PREPARE certs (defaults to alpine — overridable for
# air-gap, where you'd point it at your Artifactory mirror).
# Defaults below only apply when someone runs `docker build .`
# directly without the script.
ARG UPSTREAM_REGISTRY=docker.io/library
ARG UPSTREAM_IMAGE=nginx
ARG UPSTREAM_TAG=1.29.8-alpine
ARG ORIGINAL_USER=root
ARG CERT_BUILDER_IMAGE=docker.io/library/alpine:3.20

# ── Upstream base ────────────────────────────────────────────────────
FROM ${UPSTREAM_REGISTRY}/${UPSTREAM_IMAGE}:${UPSTREAM_TAG} AS base

# ── Label policy: preserve upstream, append ours ─────────────────────
# We intentionally do NOT set static LABEL lines here. Docker's label
# inheritance is "later LABELs override earlier by key" — anything we
# wrote would silently clobber upstream's maintainer / title / license
# annotations. Dynamic labels come from build.sh's `--label` flags.

# ── Cert sidecar (uses shell-bearing alpine builder) ─────────────────
# Runs in a SEPARATE image so cert prep works regardless of whether
# the upstream base has a shell. This is the fix for shell-less
# bases (chainguard FIPS, distroless static, scratch) where running
# RUN inside the upstream image would fail with "exec /bin/sh: no
# such file".
#
# The builder produces an updated trust store containing alpine's
# system roots + the corp CAs from certs/. The final stage COPYs
# those files over the upstream's filesystem.
#
# Trade-off: this REPLACES the upstream's /etc/ssl/certs/ca-certificates.crt
# and /etc/ssl/cert.pem with alpine's bundle (plus our corp CA).
# For most images this is fine — alpine's bundle is a superset of the
# Mozilla CA list. For images that ship a heavily-customised FIPS
# trust policy and don't want alpine's full set, fork this Dockerfile.
#
# When certs/ is empty (most images that don't call out — postgres,
# redis, etc.), the builder still runs but the trust store is just
# alpine's defaults. The final-stage COPY brings that bundle over.
# If your image doesn't need our corp CA, you can leave certs/ empty
# and accept the bundle replacement — usually invisible since alpine's
# bundle covers everything most apps need.
FROM ${CERT_BUILDER_IMAGE} AS certs-source
USER root

# Best-effort install of ca-certificates IF the rebuild tools aren't
# already present. Skip the install entirely when update-ca-certificates
# or update-ca-trust already exists — that's the airgap-safe path and
# avoids a network attempt the build doesn't actually need.
#
# Cat-append (in the next RUN) is the runtime trust mechanism and
# works without any package install or rebuild. The rebuild tool is
# only nice-to-have for re-deriving the bundle from the drop-in dir.
#
# For TRUE air-gap: bake your corp CA into a custom builder image
# upfront and point CERT_BUILDER_IMAGE at it (e.g.
# artifactory.<domain>/library/alpine-with-corp-ca:3.20). That
# eliminates the install attempt entirely + ensures the builder
# trusts your internal Artifactory's TLS.
RUN if ! command -v update-ca-certificates >/dev/null 2>&1 \
    && ! command -v update-ca-trust       >/dev/null 2>&1; then \
      apk add --no-cache ca-certificates 2>/dev/null \
      || (command -v dnf      >/dev/null && dnf install -y ca-certificates 2>/dev/null) \
      || (command -v apt-get  >/dev/null && apt-get update -qq 2>/dev/null && apt-get install -y ca-certificates 2>/dev/null) \
      || (command -v microdnf >/dev/null && microdnf install -y ca-certificates 2>/dev/null && microdnf clean all 2>/dev/null) \
      || true; \
    fi

COPY certs/ /tmp/certs/
RUN set -eux; \
    if [ -d /usr/local/share/ca-certificates ]; then \
      DROP_DIR=/usr/local/share/ca-certificates; \
      REBUILD=update-ca-certificates; \
    elif [ -d /etc/pki/ca-trust/source/anchors ]; then \
      DROP_DIR=/etc/pki/ca-trust/source/anchors; \
      REBUILD=update-ca-trust; \
    else \
      DROP_DIR=/usr/local/share/ca-certificates; \
      mkdir -p "${DROP_DIR}"; \
      REBUILD=""; \
    fi; \
    found=0; \
    for f in /tmp/certs/*.crt /tmp/certs/*.pem; do \
      [ -f "$f" ] || continue; \
      name="$(basename "$f")"; \
      case "${name}" in *.crt|*.pem) name="${name%.*}" ;; esac; \
      # Append to the bundle directly — what most TLS apps actually
      # read at runtime (alpine's /etc/ssl/cert.pem symlinks to
      # ca-certificates.crt). Alpine's update-ca-certificates only
      # manages per-cert symlinks under /etc/ssl/certs/*.pem and
      # does NOT regenerate the bundle from anchors, so direct
      # append is the only reliable injection here.
      cat "$f" >> /etc/ssl/certs/ca-certificates.crt 2>/dev/null || true; \
      cat "$f" >> /etc/ssl/cert.pem 2>/dev/null || true; \
      cp "$f" "${DROP_DIR}/${name}.crt"; \
      found=$((found + 1)); \
    done; \
    echo "Injected ${found} CA cert(s) (drop_dir=${DROP_DIR})"; \
    rm -rf /tmp/certs; \
    if [ -n "${REBUILD}" ] && command -v "${REBUILD}" >/dev/null 2>&1; then \
      "${REBUILD}" 2>/dev/null || true; \
    fi; \
    # Ensure both drop-in dirs EXIST in the builder image so final's
    # COPY --from below never fails on a missing source path.
    mkdir -p /usr/local/share/ca-certificates /etc/pki/ca-trust/source/anchors

# ── Final image ──────────────────────────────────────────────────────
# Re-bases FROM base — USER stays whatever upstream had. COPY --from
# pulls the prepared trust files out of the alpine builder. No RUN
# directives below the cert COPYs (until the editable region), so
# this works for shell-less bases.
#
# IMPORTANT for shell-less bases (chainguard FIPS, distroless, scratch):
# leave the editable region BELOW empty. RUN commands need a shell;
# those bases don't have one. The cert COPYs above are pure file
# operations and work regardless.
FROM base AS final
COPY --from=certs-source /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=certs-source /etc/ssl/cert.pem                  /etc/ssl/cert.pem
COPY --from=certs-source /usr/local/share/ca-certificates   /usr/local/share/ca-certificates
COPY --from=certs-source /etc/pki/ca-trust/source/anchors   /etc/pki/ca-trust/source/anchors

# ═══════════════════════════════════════════════════════════════════
# ▼▼▼  FORK EDITS GO HERE  ▼▼▼
# ═══════════════════════════════════════════════════════════════════
#
# Bespoke per-image work goes here: package upgrades, extra installs,
# config drops, healthchecks, ENV.
#
# IMPORTANT: RUN commands need a shell in the upstream base. For
# shell-less bases (chainguard FIPS, distroless static, scratch),
# leave this region EMPTY — those images ship their own runtime and
# can't apk/apt anything anyway.
#
# When you DO add a RUN, prepend `USER root` so apk/apt have write
# permission, and let the `USER ${ORIGINAL_USER}` directive at the
# bottom restore the upstream's user automatically.
#
# Common patterns (all OPTIONAL — uncomment what you need):
#
#   USER root
#   # CVE remediation — pick the line that matches your upstream distro
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

# Restore the upstream image's USER. build.sh auto-detects this via
# `crane config "${UPSTREAM_REF}" | jq -r .config.User` and passes it
# as --build-arg, so the user almost never sets ORIGINAL_USER manually.
# Defaults to "root" only as the safety net for direct `docker build`
# runs without the script.
ARG ORIGINAL_USER
USER ${ORIGINAL_USER}
