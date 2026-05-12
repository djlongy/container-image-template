# container-image-template

Build one container image from an upstream base through a DevSecOps
pipeline. Ships with a working nginx example. Modular by design —
swap any push backend or scan tool by changing one script name.

**Features**
- **Pluggable push backends**: `harbor.sh` (default plain v2 registry)
  or `artifactory.sh` (JCR Free + Pro). Pick via `REGISTRY_KIND`.
- **Pluggable scan tools** (each its own CI job): Syft / Xray / Trivy
  for SBOM; Grype / Xray / Trivy for vuln. All write canonical
  `sbom.cdx.json` / `vuln-scan.json` so downstream stages work
  regardless of which producer ran.
- **Cert injection**: drop `*.crt` in `certs/` or set `CA_CERT` (PEM
  string) at build time — distro-agnostic stage.
- **Per-image customisation in the Dockerfile**: edit the marked
  editable region directly. No env-toggle abstractions.
- **Upstream-version tagging**: `<image>:<UPSTREAM_TAG>-<gitShort>`
  (e.g. `nginx:1.25.3-alpine-a1b2c3d`). Renovate auto-bumps the
  upstream pin via the `# renovate:` hint in `image.env`.
- **5 SBOM sinks** (sbom-post.sh): generic webhook, OWASP
  Dependency-Track, Artifactory Xray-indexed, Artifactory plain
  archive, Splunk HEC. All opt-in, all no-op when unset.
- **Cosign scaffold** (dormant — uncomment to restore).
- **GitLab + Bamboo at 1:1 parity**, both inline (no template
  indirection).

## Quick start

```bash
# 1. Clone
git clone <this-repo-url> my-app && cd my-app

# 2. Copy template, edit
cp image.env.example image.env
$EDITOR image.env
#   UPSTREAM_REGISTRY  docker.io/library (or your Artifactory proxy)
#   UPSTREAM_IMAGE     nginx
#   UPSTREAM_TAG       1.25.3-alpine  (Renovate auto-bumps)
#   REGISTRY_KIND      harbor (default) | artifactory
#   HARBOR_*  OR  ARTIFACTORY_*  per the chosen backend
#   INJECT_CERTS       true / false (default false)

# 3. (Optional) bespoke work in Dockerfile's marked editable region
#    Drop in RUN apk upgrade, extra packages, COPY config, HEALTHCHECK

# 4. Sanity check
./scripts/build.sh --dry-run

# 5. Build + push
./scripts/build.sh --push
```

Every knob is documented next to its variable in `image.env.example`.

## Required CI variables — secrets only

`image.env` is the single source of truth for everything except
**secrets**. Hostnames, project paths, layout templates, sourcetypes
all live in `image.env` (committed). Only the items below need to be
masked CI variables.

Pick the row matching your `REGISTRY_KIND` — `HARBOR_*` and
`ARTIFACTORY_*` are mutually exclusive (the unselected backend
ignores its namespace entirely).

| Variable | When required |
|---|---|
| `HARBOR_PASSWORD` | `REGISTRY_KIND=harbor` |
| `ARTIFACTORY_TOKEN` *or* `ARTIFACTORY_PASSWORD` | `REGISTRY_KIND=artifactory` |
| `XRAY_ARTIFACTORY_TOKEN` | scan-side Artifactory differs from push-side |
| `SPLUNK_HEC_TOKEN` | shipping events to Splunk |
| `DEPENDENCY_TRACK_API_KEY` | shipping SBOMs to Dependency-Track |
| `SBOM_WEBHOOK_AUTH_HEADER` | generic SBOM webhook needs auth |
| `COSIGN_KEY` (file-type) | restoring the dormant cosign-sign job |

Plus 3 CI-runtime images that YAML reads at pipeline-load time
(can't come from `image.env`): `ALPINE_IMAGE`, `DOCKER_CLI_IMAGE`,
`DOCKER_DIND_IMAGE`. Defaults work in a public-internet runner.

**Bare-minimum to push via Artifactory**: export `ARTIFACTORY_USER`
and `ARTIFACTORY_TOKEN`, set everything else in `image.env`, then
`./scripts/build.sh --push`. The backend handles its own docker login.

## Pipeline flow

```
prescan        →   build    →   postscan                →   ingest
─────────────      ─────        ──────────────────────      ──────────
xray-vuln-…        build →      syft-sbom-postscan ─┐
xray-sbom-…        build.env    xray-sbom-postscan  │
syft-sbom-…                     xray-vuln-postscan  │
                                grype-vuln          │
                                grype-db-sync       ↓
(prescan = scan UPSTREAM_REF)   (postscan = scan      sbom-ingest →
                                 IMAGE_DIGEST)         configured sinks
```

Every scan job is single-purpose and parallel within its stage.
Swap script names to swap producers — downstream stages keep working
because they consume canonical `${SBOM_FILE}` / `${VULN_SCAN_FILE}`
from `build.env`.

`cosign-sign` is dormant (commented blocks in both CI files). Restore
by uncommenting the job AND the `- sign` stage entry, then setting
`COSIGN_KEY` (file-type CI variable, ideally Vault transit / KMS).

`trivy-{vuln,sbom}-{pre,post}scan` are dormant scaffolds for when
Trivy is re-permitted. Pinned to v0.69.3 (last safe pre-compromise
binary; refuses v0.69.4–v0.69.6 even if the mirror serves them).

### Promoting to production

Promotion is **not** in the CI pipeline by design. After dev
validation, a human promotes via Artifactory's native copy:

```bash
# Option A — UI: Browse → <repo>/<image>/<dev-tag> → Copy.
# Option B — CLI (scriptable, same digest):
crane auth login <prod-registry> -u <user> -p <password>
crane copy \
  <dev-registry>/<project>/<image>@sha256:<digest-from-build.env> \
  <prod-registry>/<project>/<image>:<tag>
```

The dev pipeline keeps `build.env` as a 1-month artifact —
`IMAGE_DIGEST` is what to copy. Cosign attestations transfer to the
prod tag because the digest is preserved.

## Editing the Dockerfile

There is **no extension surface**, **no DISTRO selector**, **no
remediate stage**. Bespoke per-image work goes between the cert
stage and the final `USER ${ORIGINAL_USER}` flip:

```dockerfile
# ═══════════════════════════════════════════════════════════════════
# ▼▼▼  FORK EDITS GO HERE  ▼▼▼
# ═══════════════════════════════════════════════════════════════════
RUN apk update && apk upgrade --no-cache
# RUN apt-get update && apt-get -y --only-upgrade upgrade && rm -rf /var/lib/apt/lists/*
# RUN microdnf -y update && microdnf clean all

RUN apk add --no-cache curl jq
COPY config/nginx.conf /etc/nginx/nginx.conf
HEALTHCHECK --interval=30s --timeout=3s CMD wget -qO- http://localhost/ || exit 1
# ═══════════════════════════════════════════════════════════════════
# ▲▲▲  END FORK EDITS  ▲▲▲
# ═══════════════════════════════════════════════════════════════════
```

The region inherits `USER root` from the certs stage above it; the
`ORIGINAL_USER` flip happens AFTER your edits. For distroless /
scratch / busybox bases where OS upgrades don't apply, leave it empty.

## Tagging convention

```
<registry>/<project>/<image>:<UPSTREAM_TAG>-<gitShort>
# e.g. harbor.example.com/apps/platform/nginx:1.25.3-alpine-a1b2c3d
```

- `UPSTREAM_TAG` — the upstream release this started from. Bumped by
  Renovate via the `# renovate:` hint in `image.env`.
- `gitShort` — 7-char commit SHA. Every commit gets its own tag, so
  cert rotation, label tweaks etc. each produce a traceable artifact
  even when the upstream tag is unchanged.

The OCI `org.opencontainers.image.version` label is also set to
`<UPSTREAM_TAG>-<gitShort>` so tools can tell at a glance that this
is a rebuild, not the upstream.

## OCI labels

build.sh adds dynamic labels via `docker buildx build --label`.
Upstream labels (e.g. `maintainer`) flow through untouched.

| Label | Source |
|---|---|
| `org.opencontainers.image.version` / `.ref.name` | `${UPSTREAM_TAG}-${gitShort}` |
| `org.opencontainers.image.revision` | `git rev-parse HEAD` |
| `org.opencontainers.image.created` | `date -u` at build time |
| `org.opencontainers.image.base.name` | `UPSTREAM_REGISTRY/UPSTREAM_IMAGE:UPSTREAM_TAG` |
| `org.opencontainers.image.base.digest` | `crane digest` of the upstream ref |
| `org.opencontainers.image.source` / `.url` | `CI_PROJECT_URL` / git remote |
| `org.opencontainers.image.vendor` | `VENDOR` |
| `org.opencontainers.image.authors` | `AUTHORS` (default `Platform Engineering`) |
| `promoted.from` / `promoted.tag` | base.name / version |

## Closed-network / air-gap

Every runtime download is variable-driven. Override these to point
at internal Artifactory / Nexus mirrors:

| Variable | Default |
|---|---|
| `DOCKER_CLI_IMAGE` / `DOCKER_DIND_IMAGE` / `ALPINE_IMAGE` | Docker Hub library |
| `UPSTREAM_REGISTRY` | `docker.io/library` |
| `CRANE_URL` | github.com/google/go-containerregistry release |
| `SYFT_INSTALLER_URL` / `SYFT_VERSION` | raw.githubusercontent.com/anchore/syft |
| `GRYPE_INSTALLER_URL` / `GRYPE_VERSION` | raw.githubusercontent.com/anchore/grype |
| `TRIVY_INSTALLER_URL` / `TRIVY_BINARY_URL` / `TRIVY_VERSION` | aquasec install.sh / pinned to v0.69.3 |
| `JF_BINARY_URL` / `JF_DEB_URL` / `JF_RPM_URL` | none — set ONE of these |

For Grype's CVE database, mirror it once via
`./scripts/mirror-grype-db.sh` (set `ARTIFACTORY_GRYPE_DB_REPO` first)
and the `grype-vuln` job will pull from your mirror automatically.

## Repository structure

```
container-image-template/
├── image.env                  # ★ Per-fork canonical config (REQUIRED, committed)
├── image.env.example          # Template — copy to image.env. NEVER sourced
├── Dockerfile                 # base → certs-{false,true} → editable region → USER
├── renovate.json              # Tracks UPSTREAM_TAG via custom manager
├── certs/                     # Gitignored *.crt; populated at build time
├── scripts/
│   ├── build.sh               # Orchestrator: tags + OCI labels + buildx, dispatches push backend
│   ├── sbom-post.sh           # 5 SBOM sinks
│   ├── mirror-grype-db.sh     # Mirror Anchore Grype DB to Artifactory
│   ├── lib/
│   │   ├── load-image-env.sh  # image.env loader + bamboo_* importer + _dbg
│   │   ├── artifact-names.sh  # Canonical SBOM_FILE / VULN_SCAN_FILE contract
│   │   ├── install-jf.sh      # Sudoless jf installer (binary | .deb | .rpm)
│   │   ├── docker-login.sh    # Multi-registry login for scan jobs
│   │   ├── splunk-hec.sh      # Generic Splunk HEC envelope poster
│   │   └── build-info-merge.py  # Free-tier build-info merger (Pro skips it)
│   ├── push-backends/         # ★ Pick one via REGISTRY_KIND, delete the rest
│   │   ├── harbor.sh
│   │   └── artifactory.sh
│   ├── scan/                  # ★ Pick the producer per stage, delete unused
│   │   ├── syft-sbom.sh       │   ├── xray-sbom.sh   │   ├── trivy-sbom.sh   (dormant)
│   │   ├── grype-vuln.sh      │   ├── xray-vuln.sh   │   └── trivy-vuln.sh   (dormant)
│   └── test/regression.sh     # 50+ scenarios — bash scripts/test/regression.sh
├── .gitlab-ci.yml             # GitLab pipeline — prescan → build → postscan → ingest
├── bamboo-specs/bamboo.yaml   # Bamboo plan spec (1:1 parity with GitLab)
├── .gitignore  └  LICENSE  └  README.md
```

## Local build

```bash
# 1. First time
cp image.env.example image.env  &&  $EDITOR image.env

# 2. Dry-run (no docker pull, no build)
./scripts/build.sh --dry-run

# 3. Build locally
./scripts/build.sh

# 4. Build + push (creds via env or pre-existing daemon login)
#    Harbor backend:
export HARBOR_PASSWORD='...'
./scripts/build.sh --push
#    Artifactory backend (image.env: REGISTRY_KIND="artifactory"):
export ARTIFACTORY_USER='svc-deploy' ARTIFACTORY_TOKEN='...'
./scripts/build.sh --push

# Verbose:
BUILD_DEBUG=true ./scripts/build.sh --dry-run
```

## Local regression testing

Before pushing changes that touch `build.sh`, `scan/*`, `sbom-post.sh`,
or `lib/*`:

```bash
bash scripts/test/regression.sh                  # full suite
bash scripts/test/regression.sh inject-certs     # filter by name substring
```

50+ scenarios covering: INJECT_CERTS variants + boolean normalisation,
shell-vs-file precedence, CA_CERT auto-flip, APPEND_GIT_SHORT toggle,
required-field validation, argv handling, REGISTRY_KIND backend
dispatch, HARBOR_* / ARTIFACTORY_* independence, bamboo_* auto-import,
canonical artifact names propagation, scan-target resolution chain,
and the silent-fail regression.

## License

MIT — see `LICENSE`.
