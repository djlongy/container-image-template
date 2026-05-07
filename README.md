# container-image-template

A minimal, fork-per-image template for building **one** container image
through a DevSecOps pipeline. Ships with a working nginx example that
exercises the full flow: upstream pull, optional CVE remediation,
optional cert injection, OCI labels via BuildKit, dual SBOM tracks
(Syft and JFrog Xray), Grype + Xray vulnerability scans, optional
cosign signing scaffold, and pluggable SBOM/scan ingestion (Splunk
HEC, Dependency-Track, Artifactory, generic webhook).

**When to fork this repo vs. use the monorepo** ([container-images](../container-images)):

| Situation | Use |
|---|---|
| You are re-tagging N ready-made upstream images and want shared pipeline logic | **container-images** (monorepo) |
| You have a bespoke / custom-built image that needs image-specific Dockerfile work | **this template** (fork per image) |
| N > 3 | monorepo |
| N = 1 and the Dockerfile is non-trivial | this template |

Features — everything in the monorepo's fleet pipeline, minus the
fleet fabric:

- **Remediate**: distro-aware CVE package upgrade stage. Four
  distros ship in the template (`alpine`, `debian`, `ubuntu`, `ubi`),
  each with its own script under `scripts/remediate/`. Pick which
  one runs via `DISTRO` in `image.env`
- **Cert injection**: optional CA cert stage, picks up anything in
  `certs/` or a PEM string from the `CA_CERT` CI variable
- **Upstream-version tagging**: pushes at
  `<image>:<UPSTREAM_TAG>-<gitShort>` (e.g. `nginx:1.25.3-alpine-a1b2c3d`).
  The upstream tag IS the version — no second version axis. Matches
  the container-images monorepo convention exactly.
- **Full OCI label coverage via BuildKit**: static labels in the
  Dockerfile, dynamic labels (revision, created, base.digest, source)
  passed via `docker buildx build --label`
- **CycloneDX SBOM (dual track)**: Syft (when approved) and JFrog
  Xray both produce CycloneDX 1.6 BOMs as pipeline artifacts. Either
  flows through the vendor-neutral `scripts/sbom-post.sh` to whatever
  sinks you configure. Xray is always available; Syft is opt-in
  through your security team
- **Vulnerability scans**: Grype reads the Syft SBOM (when present);
  JFrog Xray scans the built image directly via `jf docker scan`,
  producing simple-json with Advanced Security applicability data.
  Both are pipeline artifacts. Xray supports an optional fail-on-
  severity policy gate (`XRAY_FAIL_ON_SEVERITY=critical,high`)
- **Dormant scaffold for cosign**: signing block exists but is
  commented out by default. Restore when KMS/Vault transit infra
  is in place
- **SBOM/scan ingestion** (pluggable, multi-sink):
  `scripts/sbom-post.sh` ships any CycloneDX file to Splunk HEC,
  OWASP Dependency-Track, Artifactory Xray import, OR a generic
  webhook. `scripts/scan/xray-vuln.sh` ships scan JSON to Splunk
  HEC. All are no-ops if their sink config is unset — safe to leave
  enabled before infrastructure is provisioned
- **Renovate-ready**: the `# renovate: datasource=docker depName=...`
  hint above `UPSTREAM_TAG` in `image.env` lets Renovate auto-bump
  upstream version pins
- **GitLab + Bamboo**: two inline pipelines at 1:1 parity, both
  invoke the same `scripts/build.sh` and `scripts/scan/*.sh` —
  add stages by adding YAML, never by forking the script logic

## Quick start — fork and rebrand

**One file defines what this repo builds.** Everything about the
image — upstream registry/image/tag, behavior toggles — lives in
`image.env`. The Dockerfile and `scripts/build.sh` are generic; they
read this file and pass values through as `--build-arg`. The upstream
tag IS the version; the pushed tag is `<UPSTREAM_TAG>-<gitShort>`.
No internal semver.

`image.env.example` is a **template only**. The build never reads it
— if `image.env` doesn't exist the build fails fast with a clear "copy
the template" message. (Previous versions silently fell back, which
masked dev-vs-CI config drift; we made it strict on purpose.)

```bash
# 1. Clone as a new per-image repo
git clone <this-repo-url> my-app
cd my-app

# 2. Materialise image.env from the template, then edit
cp image.env.example image.env
$EDITOR image.env
#    UPSTREAM_REGISTRY    docker.io/library (or your Artifactory proxy)
#    UPSTREAM_IMAGE       nginx
#    UPSTREAM_TAG         1.25.3-alpine  (Renovate auto-bumps via hint)
#    IMAGE_NAME           optional — defaults to UPSTREAM_IMAGE
#    DISTRO               alpine | debian | ubuntu | ubi
#    REMEDIATE            true / false  (default false — opt in)
#    INJECT_CERTS         true / false  (default false)
#    ORIGINAL_USER        root / nginx / whatever upstream expects

# 3. (Optional) If your upstream uses a distro family not covered
#    by the four shipped scripts, drop a new
#    scripts/remediate/<distro>.sh and set DISTRO=<distro>.
#    The Dockerfile doesn't need any edit.

# 4. Commit image.env (it's the per-fork canonical config)
git add image.env && git commit -m 'add image.env for <my-image>'

# 5. Sanity-check locally (no push)
./scripts/build.sh

# 6. Push to GitLab / Bamboo / GitHub and set CI variables
#    (secrets only — PUSH_REGISTRY_PASSWORD etc. — see below)
```

### image.env resolution order

| Layer | Source | Purpose |
|---|---|---|
| 1 (base) | `image.env` *(committed, REQUIRED)* | Per-fork canonical config |
| 2 (top) | shell / CI environment | Always wins; used by CI variable overrides |

`image.env.example` is **not** in the resolution order — it's a
template you copy from on first checkout. If you delete `image.env`,
the build fails. Secrets stay in CI plan vars (never committed to
`image.env`).

### What you edit when forking, vs. what stays generic

| File | Edit when forking? | Notes |
|---|---|---|
| `image.env` | **Always** (created from `image.env.example`) | The whole image definition lives here |
| `image.env.example` | Only when adding new template-level documentation | Template / reference only — never sourced |
| `scripts/extend/` | When you need app-specific RUN/COPY | Drop a `customise.sh` hook and/or `files/` directory — see `scripts/extend/README.md`. One surface for all fork-owned customisation |
| `Dockerfile` | Only for rare multi-stage `COPY --from=…` patterns | Otherwise generic; extensions go in `scripts/extend/` |
| `scripts/build.sh` | Never | Reads `image.env`, invokes buildx, handles backend dispatch |
| `scripts/sbom-post.sh` | Only to add new SBOM sinks | Generic; 4 sinks built in (webhook, DT, Artifactory, Splunk HEC) |
| `scripts/push-backends/artifactory.sh` | Never | Ported from monorepo, same layout templates |
| `.gitlab-ci.yml`, `bamboo-specs/bamboo.yaml` | Only to change pipeline structure | Default flow: build → [sbom, grype, xray-vuln, xray-sbom] → sbom-ingest |
| `renovate.json` | Only to add more Renovate hints | Custom manager already wired for `UPSTREAM_TAG` in `image.env` |

## Required CI variables — only secrets

`image.env` is the canonical source of truth for everything except
**secrets**. Move all the URLs, registries, layout templates, vendor
strings etc. into `image.env` (committed) and only the items below
need to live as masked CI variables. This works identically for GitLab
and Bamboo — the pipeline reads them from the shell env regardless of
where they came from.

**Truly secret (must be CI-vars, masked, never committed):**

| Variable | Required | Purpose |
|---|---|---|
| `PUSH_REGISTRY_PASSWORD` | ✅ (masked) | Push password or token for `PUSH_REGISTRY` |
| `ARTIFACTORY_PASSWORD` or `ARTIFACTORY_TOKEN` | ⬜ (masked) | Required when `REGISTRY_KIND=artifactory`. Token preferred |
| `XRAY_ARTIFACTORY_TOKEN` | ⬜ (masked) | Only when scan-side Artifactory differs from push-side |
| `SPLUNK_HEC_TOKEN` | ⬜ (masked) | Only when shipping events to Splunk |
| `DEPENDENCY_TRACK_API_KEY` | ⬜ (masked) | Only when shipping SBOMs to Dependency-Track |
| `SBOM_WEBHOOK_AUTH_HEADER` | ⬜ (masked) | Only when the generic SBOM webhook needs auth |
| `COSIGN_KEY` | ⬜ (masked, file-type) | Only when restoring the dormant cosign-sign job |

**CI-runtime images (must be CI-vars — YAML reads at pipeline-load time):**

| Variable | Default | Purpose |
|---|---|---|
| `ALPINE_IMAGE` | `alpine:3.20` | Image used by scan / ingest / promote jobs |
| `DOCKER_CLI_IMAGE` | `docker:27-cli` | Image used by build job (docker CLI) |
| `DOCKER_DIND_IMAGE` | `docker:27-dind` | Image used by build / xray-* jobs (docker daemon sidecar) |

**Everything else lives in `image.env`** — `PUSH_REGISTRY`, `PUSH_PROJECT`,
`PUSH_REGISTRY_USER`, `VENDOR`, `ARTIFACTORY_URL/USER/TEAM/ENVIRONMENT/
PUSH_HOST/IMAGE_REF/MANIFEST_PATH`, `XRAY_ARTIFACTORY_URL/USER`,
`SPLUNK_HEC_URL/INSECURE/INDEX/SOURCETYPE`, `JF_BINARY_URL/DEB_URL/RPM_URL`,
`SBOM_WEBHOOK_URL`, `DEPENDENCY_TRACK_URL/PROJECT`, `ARTIFACTORY_SBOM_REPO`,
`UPSTREAM_*`, `REMEDIATE`, `INJECT_CERTS`, `DISTRO`, `APPEND_GIT_SHORT`,
`XRAY_GENERATE_SBOM`, `XRAY_FAIL_ON_SEVERITY`, etc. Each is documented
in `image.env.example`.

**Optional shell env / CI overrides (any of these still work):**

| Variable | Purpose |
|---|---|
| `CA_CERT` | Full PEM content of a corp CA — setting via env auto-flips `INJECT_CERTS=true` and writes `certs/ci-injected.crt` |
| `BUILD_DEBUG` | `true` to surface verbose `[debug]` logs from `build.sh` and `lib/load-image-env.sh` (off by default) |
| `FORCE_ALL` | `true` to bypass the path-change gate (run a build even when no image-relevant file changed) |

### Optional: SBOM ingestion

The SBOM is always generated and uploaded as a pipeline artifact.
Shipping it to a downstream platform is opt-in — `scripts/sbom-post.sh`
ships the CycloneDX JSON to whichever sinks are configured, and is a
no-op if none are set. **Four sinks** are supported out of the box;
add more by dropping a new block into `sbom-post.sh`.

The script is **vendor-agnostic** — it doesn't care if the BOM was
generated by Syft, JFrog Xray, Trivy, or anything else, as long as
it's CycloneDX. Both `scripts/scan/xray-sbom.sh` (when REGISTRY_KIND
=artifactory) and the Syft-based `sbom` job hand off to it.

**Generic webhook** — anything that accepts a POST:

| Variable | Purpose |
|---|---|
| `SBOM_WEBHOOK_URL` | Endpoint URL |
| `SBOM_WEBHOOK_AUTH_HEADER` | Optional, e.g. `Authorization: Bearer xyz` |

**OWASP Dependency-Track** — the de-facto standard enterprise SBOM
platform; correlates BOMs against its CVE database and fires
notifications on new matches:

| Variable | Purpose |
|---|---|
| `DEPENDENCY_TRACK_URL` | Base URL, e.g. `https://dtrack.example.com` |
| `DEPENDENCY_TRACK_API_KEY` | BOM-upload API key (masked) |
| `DEPENDENCY_TRACK_PROJECT` | Project name — autoCreate creates it on first upload |

**JFrog Artifactory Pro + Xray** (native SBOM Import) — Xray
auto-indexes and scans any `.cdx.json` file uploaded to an
indexed generic repository. If you're already pushing images through
Artifactory with `REGISTRY_KIND=artifactory` (below), you reuse the
same credentials — just add one variable for the destination repo:

| Variable | Purpose |
|---|---|
| `ARTIFACTORY_URL` | Same as the push backend |
| `ARTIFACTORY_USER` | Same |
| `ARTIFACTORY_TOKEN` / `ARTIFACTORY_PASSWORD` | Same |
| `ARTIFACTORY_SBOM_REPO` | Name of an Xray-indexed generic repo (e.g. `sboms-local`) |

The SBOM is uploaded to `<repo>/<image>/<version>/sbom.cdx.json` — a
predictable path you can find in the Artifactory UI under Scans →
SBOM Imports once Xray picks it up. **This needs a Pro (Xray)
licence** — JCR Free won't index the BOM.

**Splunk HEC** — generic event-collector ingestion for SecOps audit
trails. The SBOM goes inside the HEC event envelope as `event.cyclonedx`
along with `event.scanned_image`, `event.git_commit`, `event.sbom_file`
metadata. Default sourcetype is `cyclonedx:json` (vendor-neutral —
same sourcetype handles Syft-, Xray-, or Trivy-generated SBOMs).
`scripts/scan/xray-vuln.sh` uses the same shared helper to ship its
vuln scan JSON with sourcetype `jfrog:xray:scan`.

| Variable | Purpose |
|---|---|
| `SPLUNK_HEC_URL` | HEC base URL — `/services/collector` is auto-appended if missing |
| `SPLUNK_HEC_TOKEN` | HEC token (masked) — sent as `Authorization: Splunk <token>` |
| `SPLUNK_HEC_INDEX` | Target index. Default: `main` |
| `SPLUNK_SBOM_SOURCETYPE` | Override the default `cyclonedx:json` sourcetype |
| `SPLUNK_HEC_SOURCETYPE` | Override the default `jfrog:xray:scan` sourcetype (xray-vuln) |
| `SPLUNK_HEC_INSECURE` | `"true"` → `curl -k` for self-signed Splunk certs |

### Optional: push backend switch (Harbor ↔ Artifactory)

Same pattern as the monorepo. The default path does a plain
`docker push` to `PUSH_REGISTRY` (Harbor baseline, zero extra config).
Set `REGISTRY_KIND=artifactory` to delegate the push step to
`scripts/push-backends/artifactory.sh`, which handles layout template
resolution, `jf rt bp` build-info publishing, and `jf rt set-props`
metadata tagging on the manifest:

| Variable | Purpose |
|---|---|
| `REGISTRY_KIND` | Set to `artifactory` to enable |
| `ARTIFACTORY_URL` | `https://artifactory.example.com` (REST API) |
| `ARTIFACTORY_USER` | Team user with Deploy rights. **JFrog Cloud gotcha**: must match the username encoded in your access token's JWT `sub` claim (often `admin` or a service-account name), NOT the user's login email. The two are typically different on JFrog Cloud SaaS. Wrong value → docker login fails with `Wrong username was used`. Decode the token's `sub` to find the right value: `echo "$TOKEN" \| cut -d. -f2 \| base64 -d \| jq -r .sub` |
| `ARTIFACTORY_TOKEN` | Access token (preferred), or |
| `ARTIFACTORY_PASSWORD` | basic-auth password (masked) |
| `ARTIFACTORY_TEAM` | Team acronym — referenced by layout templates |
| `ARTIFACTORY_ENVIRONMENT` | `dev` \| `prod` (drives `ARTIFACTORY_REPO_SUFFIX`) |
| `ARTIFACTORY_PUSH_HOST` | Docker push hostname for subdomain layouts |
| `ARTIFACTORY_IMAGE_REF` | Template for the push URL (see monorepo's `global.env.example` for 5 named presets) |
| `ARTIFACTORY_MANIFEST_PATH` | Template for the REST storage path used by `set-props` |

The fallback layout (no templates set) is Layout A from the monorepo:
`<host>/<team>/<image>:<tag>` → `<team>-docker-<suffix>/<image>/<tag>`.
If you've already configured layouts in the monorepo, the same
template strings work here unchanged — just paste them into your
group-level CI variables.

> **⚠️ GitLab CI variable-expansion gotcha.** GitLab performs variable
> substitution on CI variable **values** before injecting them into
> the job shell. That means a literal `${IMAGE_NAME}` inside
> `ARTIFACTORY_IMAGE_REF` gets expanded to an empty string (since
> `IMAGE_NAME` isn't a CI variable — it's a runtime shell variable set
> by `build.sh`). Three ways to avoid this:
>
> 1. **Set the variable with `raw=true`** (the clean fix). When
>    creating the CI variable via the GitLab UI, check "Expand variable
>    reference" → off. Via the API, pass `"raw": true`. This tells
>    GitLab to leave the value untouched.
> 2. **Escape the dollar signs with `$$`** when triggering pipelines
>    via the `/projects/:id/pipeline` API or when the `raw` flag isn't
>    available (older GitLab versions). GitLab collapses `$$` to `$`
>    without substituting the reference. Example:
>    `$${ARTIFACTORY_PUSH_HOST}/$${ARTIFACTORY_TEAM}/$${IMAGE_NAME}:$${IMAGE_TAG}`
> 3. **Set the templates in `global.env`** (gitignored local file) or
>    directly in `scripts/push-backends/artifactory.sh` — those are
>    read by bash directly and never pass through GitLab's
>    substitution step.
>
> Bamboo doesn't have this gotcha — it relays plan variables as
> literal strings.

**Recommended homelab workflow**: don't set `REGISTRY_KIND` at all
(defaults to Harbor). **Recommended production workflow**: set
`REGISTRY_KIND=artifactory` as a group-level CI variable on the
production group, everything else stays the same. One repo, two
targets, switched by one variable.


### Closed-network / air-gap deployment

Every runtime dependency the pipeline downloads is variable-driven,
with defaults pointing at public sources (Docker Hub, GitHub releases,
dl-cdn.alpinelinux.org). In a closed network where runners have no
direct internet access, override the variables below to point at
internal Artifactory / Nexus mirrors. Nothing else in the pipeline
needs to change.

**1. Job container images** — pulled by the GitLab runner / Bamboo
agent for each stage. Must come from your Docker Hub proxy:

| Variable | Default | Example override |
|---|---|---|
| `DOCKER_CLI_IMAGE` | `docker:27-cli` | `dockerhub.artifactory.example.com/library/docker:27-cli` |
| `DOCKER_DIND_IMAGE` | `docker:27-dind` | `dockerhub.artifactory.example.com/library/docker:27-dind` |
| `ALPINE_IMAGE` | `alpine:3.20` | `dockerhub.artifactory.example.com/library/alpine:3.20` |

**2. Upstream base image** — pulled by `docker buildx` inside the
build stage. Set via the existing `UPSTREAM_REGISTRY` variable:

```
UPSTREAM_REGISTRY=dockerhub.artifactory.example.com/library
UPSTREAM_IMAGE=nginx
# Dockerfile's FROM resolves to:
#   dockerhub.artifactory.example.com/library/nginx:${UPSTREAM_TAG}
```

**3. Alpine apk packages** — both inside the Dockerfile's remediate
stage AND inside the CI job containers that need `apk add bash git
curl …`. Single variable covers both:

| Variable | Default | Example override |
|---|---|---|
| `APK_MIRROR` | (unset → dl-cdn) | `https://nexus.example.com/repository/alpine-proxy` |

When set, `sed` rewrites `/etc/apk/repositories` before any `apk`
command, preserving `v3.20/main`, `v3.20/community`, etc.

**4. Tool binaries** (crane, buildx, syft, grype, cosign, jf) — most
closed networks whitelist `github.com` releases and
`raw.githubusercontent.com`, so the defaults often work untouched. If
your network blocks those too, override each URL to point at an
Artifactory generic repo that mirrors the binary:

| Variable | Default |
|---|---|
| `BUILDX_URL` | `https://github.com/docker/buildx/releases/download/v0.17.1/buildx-v0.17.1.linux-amd64` |
| `CRANE_URL` | `https://github.com/google/go-containerregistry/releases/download/v0.20.2/go-containerregistry_Linux_x86_64.tar.gz` |
| `SYFT_INSTALLER_URL` | `https://raw.githubusercontent.com/anchore/syft/main/install.sh` |
| `GRYPE_INSTALLER_URL` | `https://raw.githubusercontent.com/anchore/grype/main/install.sh` |
| `COSIGN_URL` | `https://github.com/sigstore/cosign/releases/download/v2.4.1/cosign-linux-amd64` |
| `JF_BINARY_URL` | Direct URL to standalone `jf` binary (preferred) |
| `JF_DEB_URL` | Debian package URL — extracted with `dpkg-deb -x` (or `ar`+`tar`), no `dpkg -i` |
| `JF_RPM_URL` | RPM package URL — extracted with `rpm2cpio`+`cpio`, no `rpm -i` |
| `JF_INSTALL_DIR` | Where the binary lands (default `${HOME}/.local/bin`, no sudo) |

**5. Grype vulnerability database.** Grype fetches its CVE database
from `grype.anchore.io` by default (~100 MB). For air-gap, mirror it
to an Artifactory generic repo and point Grype at the mirror:

| Variable | Purpose |
|---|---|
| `ARTIFACTORY_GRYPE_DB_REPO` | Generic repo name (e.g. `grype-db-local`). When set, the `grype-db-sync` CI job mirrors the latest DB before every scan and the `grype` job pulls from the mirror instead of Anchore's CDN |
| `GRYPE_DB_MIRROR_SUBPATH` | Path inside the repo — default `grype-db/v6`. Preserves Anchore's relative path structure so `latest.json` resolves the tarball correctly |

Run the mirror script manually any time (e.g. from a management box
with internet access, outside the air-gap):

```bash
ARTIFACTORY_URL=https://artifactory.example.com \
  ARTIFACTORY_USER=svc-grype-mirror \
  ARTIFACTORY_TOKEN=<token> \
  ARTIFACTORY_GRYPE_DB_REPO=grype-db-local \
  ./scripts/mirror-grype-db.sh
```

The script downloads `databases/v6/latest.json` + the referenced
tarball, verifies the SHA-256 checksum against the listing, then
uploads both to `<repo>/<subpath>/`. Grype reads from the mirror
via `GRYPE_DB_UPDATE_URL` which the CI job constructs automatically
when `ARTIFACTORY_GRYPE_DB_REPO` is set.

**6. Nothing else.** The pipeline does not call any other network
endpoint at runtime. Git checkout comes from GitLab itself (already
on your internal network), `cosign sign` talks to your registry (not
Sigstore — `--tlog-upload=false` is set), and SBOM ingestion talks
only to whichever sink you configured (`ARTIFACTORY_SBOM_REPO`
reuses the push credentials).

**Suggested closed-network group CI variable block** (paste into
GitLab group settings → CI/CD → Variables; all are `raw=true` so
GitLab doesn't mangle `$` references):

```
DOCKER_CLI_IMAGE      = dockerhub.artifactory.example.com/library/docker:27-cli
DOCKER_DIND_IMAGE     = dockerhub.artifactory.example.com/library/docker:27-dind
ALPINE_IMAGE          = dockerhub.artifactory.example.com/library/alpine:3.20
UPSTREAM_REGISTRY     = dockerhub.artifactory.example.com/library
APK_MIRROR            = https://artifactory.example.com/artifactory/alpine-proxy
# Tool URLs optional if GitHub is whitelisted; override per above table if not.
```

## Pipeline flow

```
┌──────────┐  ┌─────────┐  ┌──────────┐  ┌──────────┐
│ prescan  │→ │  build  │→ │ postscan │→ │  ingest  │
└──────────┘  └─────────┘  └──────────┘  └──────────┘
xray-vuln-       buildx     xray-vuln-     sbom-ingest
  prescan        + push       postscan        (Syft SBOM
xray-sbom-     → build.env  xray-sbom-       via sbom-post)
  prescan                     postscan
                            sbom (Syft)
                            grype
```

**`prescan` (UPSTREAM_REF)** — runs BEFORE build. Scans the upstream
image we're about to rebuild. Set `XRAY_FAIL_ON_SEVERITY=critical`
(or `critical,high`) in `image.env` to gate the build on a clean
prescan; leave unset for audit-only mode. Xray vuln + Xray SBOM both
run here, scanning the upstream's tag verbatim.

**`postscan` (IMAGE_DIGEST)** — runs AFTER build. Scans what consumers
actually pull, including any remediation, cert injection, or
`scripts/extend/` customisations applied during build. Xray vuln +
Xray SBOM both default to scanning `IMAGE_DIGEST` from `build.env`
(via GitLab's dotenv artifact import / Bamboo's `. ./build.env`).
Same scripts as prescan — different target.

The scripts are vendor-symmetric: `scripts/scan/xray-vuln.sh` and
`scripts/scan/xray-sbom.sh` both honor a resolution chain (`$1` >
`XRAY_SCAN_REF` > `IMAGE_DIGEST` > `IMAGE_REF` > `UPSTREAM_REF`)
so the same script handles either stage.

**Trivy** is present as a commented-out block in both CI files. When
Trivy is unbanned for business use, uncomment the `trivy:` job in
`.gitlab-ci.yml`, uncomment the corresponding block in
`bamboo-specs/bamboo.yaml`, and re-enable the `- trivy` stage
reference. Xray + Grype cover the same ground in the meantime.

**`cosign-sign`** is present as commented-out blocks in both CI files
(dormant). Restore by uncommenting the job AND the `- sign` / `- Sign:`
stage entry, then setting `COSIGN_KEY` (file-type CI variable, ideally
backed by Vault transit / KMS).

### Promoting to production

Promotion is **not in the CI pipeline by design**. After the dev image
is validated, a human promotes it via Artifactory's native copy. Two
equivalent paths:

```bash
# Option A — Artifactory UI (most common):
#   Browse → <repo>/<image>/<dev-tag> → "Copy" or "Move"
#   Pick destination repo/path, confirm.

# Option B — CLI (scriptable, same digest):
crane auth login <prod-registry> -u <user> -p <password>
crane copy \
  <dev-registry>/<project>/<image>@sha256:<digest-from-build.env> \
  <prod-registry>/<project>/<image>:<tag>
```

Both paths preserve the digest, so any cosign attestation made in the
dev pipeline transfers to the prod tag. The dev pipeline keeps
`build.env` as a 1-month artifact — `IMAGE_DIGEST` is the value to
copy from. No automated CI promotion job exists, deliberately: the
human-in-the-loop check is the gate.

## Distro-aware remediation

`REMEDIATE=true` runs `scripts/remediate/${DISTRO}.sh` inside the
image during build. Four distros ship in the template out of the box:

| `DISTRO` | Script | What it runs |
|---|---|---|
| `alpine` | `scripts/remediate/alpine.sh` | `apk update && apk upgrade --no-cache`, honors `APK_MIRROR` |
| `debian` | `scripts/remediate/debian.sh` | `apt-get -y --only-upgrade upgrade`, rewrites `deb.debian.org` / `security.debian.org` via `APT_MIRROR` |
| `ubuntu` | `scripts/remediate/ubuntu.sh` | `apt-get -y --only-upgrade upgrade`, rewrites `archive.ubuntu.com` / `security.ubuntu.com` / `ports.ubuntu.com` via `APT_MIRROR` |
| `ubi` | `scripts/remediate/ubi.sh` | `microdnf -y update` (falls back to `dnf` / `yum` for older UBI / RHEL bases) |

**Adding a new distro family** is a two-step change:

1. Drop a new `scripts/remediate/<name>.sh` (plain POSIX shell, reads
   `APK_MIRROR` / `APT_MIRROR` from env if relevant)
2. Set `DISTRO=<name>` in `image.env`

The Dockerfile never needs an edit — it's generic: `COPY scripts/remediate/`
+ `RUN /tmp/remediate/${DISTRO}.sh`. `build.sh` validates that the
script for the selected `DISTRO` exists before invoking buildx, so
typos fail fast with a clear error instead of deep inside the build.

**For images where OS-level remediation doesn't apply** (distroless,
scratch, busybox, statically-linked bases), set `REMEDIATE=false` in
`image.env` and the stage is skipped entirely — `DISTRO` becomes
irrelevant.

**Closed-network note**: `APK_MIRROR` and `APT_MIRROR` are passed
through as `--build-arg` so a single CI variable (set at group
level) rewires all apk and apt traffic through your Artifactory /
Nexus proxies inside the build. See "Closed-network deployment"
below for the full list.

## Tagging convention

We're not the upstream — we're a **variant** of the upstream. We
pulled `nginx:1.25.3-alpine`, remediated its CVEs, optionally
injected a corp CA, and produced something that's no longer
bit-for-bit identical to what's on Docker Hub. The tagging
convention makes that delineation explicit.

```
<registry>/<project>/<image>:<UPSTREAM_TAG>-<gitShort>

# Example:
harbor.example.com/base-images/nginx:1.25.3-alpine-a1b2c3d
```

- **`UPSTREAM_TAG`** tells the consumer which upstream release this
  started from. Bumped by Renovate via the `# renovate:` hint in
  `image.env.example` when new upstream releases drop.
- **`gitShort`** is the 7-char commit SHA of the build. Every commit
  produces a uniquely-tagged image — so changes to remediation
  logic, cert rotation, label tweaks, etc. each get their own
  traceable artifact even when the upstream tag is unchanged.

Matches the container-images monorepo convention exactly. The OCI
`org.opencontainers.image.version` label on the image is **also**
set to `<UPSTREAM_TAG>-<gitShort>` (not just the bare upstream tag)
so tools inspecting the image can tell at a glance that it's a
rebuild, not an untouched upstream.

## OCI labels

The build script adds dynamic labels via `docker buildx build --label`.
Upstream labels (like `maintainer`) flow through untouched — we only
set keys we explicitly want to own:

| Label | Source |
|---|---|
| `org.opencontainers.image.version` | `${UPSTREAM_TAG}-${gitShort}` — matches the pushed tag exactly. This makes it explicit that the image is a **variant** of the upstream (remediated / cert-injected), not the untouched upstream |
| `org.opencontainers.image.revision` | `git rev-parse HEAD` |
| `org.opencontainers.image.created` | `date -u` at build time |
| `org.opencontainers.image.base.name` | `UPSTREAM_REGISTRY/UPSTREAM_IMAGE:UPSTREAM_TAG` |
| `org.opencontainers.image.base.digest` | `crane digest` on the upstream ref |
| `org.opencontainers.image.source` | `CI_PROJECT_URL` / git remote |
| `org.opencontainers.image.url` | same |
| `org.opencontainers.image.vendor` | `VENDOR` variable |
| `org.opencontainers.image.authors` | `AUTHORS` variable (default `Platform Engineering`) |
| `org.opencontainers.image.ref.name` | Same as version |
| `promoted.from` | Same as base.name — the pull origin |
| `promoted.tag` | Same as version — the promoted tag |

This matches the DevSecOps convention: upstream provenance is
preserved, our provenance is appended. The `image.version` label
reports the upstream tag, which is what OCI consumers expect.

## Repository structure

```
container-image-template/
├── image.env                  # ★ Per-fork canonical config (REQUIRED, committed)
├── image.env.example          # Template — copy to image.env, then edit. NEVER sourced
├── Dockerfile                 # Generic multi-stage: base → certs → remediate → final
├── renovate.json              # Custom manager tracks UPSTREAM_TAG in image.env
├── certs/                     # Gitignored *.crt; populated at build time
│   └── .gitkeep
├── scripts/
│   ├── build.sh               # Resolves tags + OCI labels, docker login, buildx, push
│   ├── sbom-post.sh           # 4 SBOM sinks: webhook / DT / Artifactory Xray / Splunk HEC
│   ├── mirror-grype-db.sh     # Optional: mirror Anchore Grype CVE DB to Artifactory
│   ├── lib/                   # Shared functions sourced by other scripts
│   │   ├── load-image-env.sh  # image.env loader + bamboo_* importer + _dbg helper
│   │   ├── install-jf.sh      # Sudoless jf installer (binary | .deb | .rpm)
│   │   ├── docker-login.sh    # Multi-registry login for scan jobs
│   │   ├── splunk-hec.sh      # Generic Splunk HEC envelope poster
│   │   └── build-info-merge.py  # Free-tier build-info merger (artifactory.sh, Pro skips it)
│   ├── scan/
│   │   ├── xray-vuln.sh       # `jf docker scan --format=simple-json` → xray-scan.json + Splunk
│   │   └── xray-sbom.sh       # `jf docker scan --format=cyclonedx --sbom` → sbom-post handoff
│   ├── push-backends/
│   │   └── artifactory.sh     # REGISTRY_KIND=artifactory backend (layout templates, Pro/Free)
│   ├── remediate/             # Distro-aware remediation (alpine/debian/ubuntu/ubi)
│   ├── extend/                # Fork-owned customisation (customise.sh + files/)
│   └── test/
│       └── regression.sh      # 37 local scenarios — REMEDIATE/INJECT_CERTS/CA_CERT/precedence/
│                              # backends/no-creds/argv. Run with: bash scripts/test/regression.sh
├── .gitlab-ci.yml             # GitLab pipeline — prescan → build → postscan → ingest
├── bamboo-specs/
│   └── bamboo.yaml            # Bamboo plan spec (1:1 parity with GitLab)
├── .gitignore
├── LICENSE
└── README.md
```

## Local build

```bash
# 0. First time: materialise image.env from the template
cp image.env.example image.env
$EDITOR image.env       # populate UPSTREAM_*, REMEDIATE, etc.

# 1. Sanity-check resolved config (no docker pull, no build)
./scripts/build.sh --dry-run

# 2. Build locally without pushing
./scripts/build.sh

# 3. Build + push. build.sh handles its own docker login (after sourcing
#    image.env + applying any shell overrides). Set PUSH_REGISTRY_PASSWORD
#    in the env or rely on a pre-existing daemon login.
export PUSH_REGISTRY_PASSWORD='...'   # password / token (don't commit)
./scripts/build.sh --push

# Verbose mode (logs every config decision):
BUILD_DEBUG=true ./scripts/build.sh --dry-run
```

## Local regression testing

Before pushing changes that touch `build.sh`, `scan/*`, `sbom-post.sh`,
or `lib/*`, run the local regression suite. It exercises every
behavioural permutation we've shipped (37 scenarios) — far faster than
waiting for a CI round-trip:

```bash
bash scripts/test/regression.sh                  # all 37
bash scripts/test/regression.sh remediate        # filter by name substring
```

Coverage includes: REMEDIATE on/off + supported/unsupported distros,
INJECT_CERTS variants, CA_CERT env auto-flip, APPEND_GIT_SHORT toggle,
required-field validation, argv handling, REGISTRY_KIND backend
selection, `bamboo_*` auto-import precedence, scan-target resolution
chain (`$1 > XRAY_SCAN_REF > IMAGE_DIGEST > IMAGE_REF > UPSTREAM_REF`),
and the silent-fail regression (pull/scan failure must exit non-zero).

## License

MIT — see `LICENSE`.

<!-- path-gate smoke test: this comment should NOT trigger a pipeline -->

<!-- smoke test #2: with workflow:rules, this should NOT create a pipeline at all -->
