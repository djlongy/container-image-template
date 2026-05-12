# cert-builder.Dockerfile — bake a corp-CA-trusting alpine image
#
# Used ONCE by scripts/bootstrap/build-cert-builder.sh to produce the
# image that the main Dockerfile's cert sidecar (CERT_BUILDER_IMAGE)
# points at on every container build.
#
# Build inputs (all via build-args):
#   BASE_IMAGE      e.g. docker.io/library/alpine:3.20
#                   In airgap, point at your internal Artifactory:
#                     artifactory.example.com/dockerhub/library/alpine:3.20
#   APK_MIRROR      Optional. e.g. https://artifactory.example.com/artifactory/alpine-main
#                   When set, /etc/apk/repositories is rewritten to use
#                   this mirror BEFORE apk add ca-certificates runs.
#                   Required for true airgap where dl-cdn.alpinelinux.org
#                   is unreachable.
#
# Build context:   scripts/bootstrap/
#   The wrapper script (build-cert-builder.sh) materialises the CA PEM
#   into ${context}/corp-ca.crt before invoking docker build.

ARG BASE_IMAGE=docker.io/library/alpine:3.20
FROM ${BASE_IMAGE}

ARG APK_MIRROR=""

# Replace alpine repositories with the airgap mirror BEFORE apk add.
# Skipped when APK_MIRROR is empty (default — uses upstream alpine repos).
RUN set -eux; \
    if [ -n "${APK_MIRROR}" ]; then \
      echo "→ rewriting /etc/apk/repositories to use APK_MIRROR=${APK_MIRROR}"; \
      printf '%s/main\n%s/community\n' "${APK_MIRROR}" "${APK_MIRROR}" \
        > /etc/apk/repositories; \
    fi

# Drop the corp CA into the trust anchors dir BEFORE installing
# ca-certificates — that way update-ca-certificates picks it up on
# its very first run + the rebuilt bundle includes it. This is the
# "trust the mirror's TLS" prerequisite for any subsequent apk add
# against an Artifactory-proxied repo with internal cert chain.
COPY corp-ca.crt /usr/local/share/ca-certificates/corp-ca.crt

RUN set -eux; \
    apk add --no-cache ca-certificates; \
    update-ca-certificates; \
    # Sanity: confirm our CA made it into the bundle.
    grep -qF "$(head -2 /usr/local/share/ca-certificates/corp-ca.crt | tail -1)" \
        /etc/ssl/certs/ca-certificates.crt \
      || (echo "ERROR: corp CA not in rebuilt bundle — investigate" >&2; exit 1); \
    echo "✓ corp CA trusted in this builder image"
