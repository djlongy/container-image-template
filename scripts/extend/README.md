# scripts/extend/ — the fork's customisation point

This directory is where a **fork of the template owns its differences**.
Everything above the `RESERVED EXTENSION POINT` banner in `Dockerfile`
is template-owned and flows down when you pull updates. Everything
inside `scripts/extend/` is yours.

## The contract

The template's `Dockerfile`, after remediation and before the final
`USER` flip, does exactly this:

```dockerfile
COPY scripts/extend/ /tmp/extend/
RUN set -eu; \
    if [ -d /tmp/extend/files ] && [ "$(ls -A /tmp/extend/files)" ]; then \
      mkdir -p /opt/app; \
      cp -a /tmp/extend/files/. /opt/app/; \
    fi; \
    if [ -x /tmp/extend/customise.sh ]; then \
      /tmp/extend/customise.sh; \
    fi; \
    rm -rf /tmp/extend
```

Two optional surfaces:

| What | Where | When |
|---|---|---|
| Static content | `scripts/extend/files/` | copied verbatim into `/opt/app/` in the image |
| Dynamic setup | `scripts/extend/customise.sh` | executed as root after `files/` is copied |

**Both are optional.** An empty `scripts/extend/` (just this README) is
a valid fork — you'll get the base image plus template hardening and
nothing else.

## When to use which

- **`files/` only** — pure static drops. Config files, systemd units,
  entrypoint shims, prebuilt binaries, HTML/TLS assets, helm templates.
  No commands need to run to put them in place.

- **`customise.sh` only** — anything that needs a command at build
  time: `apk add`, `apt-get install`, `chown`, `useradd`, writing
  files generated from env vars, compiling something tiny, etc.

- **Both** — drop the static content in `files/`, then have
  `customise.sh` run permissions/ownership/installation commands over
  `/opt/app/`. The copy happens BEFORE the hook runs, so
  `customise.sh` can reference `/opt/app/` freely.

## Writing `customise.sh`

- It runs as `root` (before the final `USER ${ORIGINAL_USER}` flip).
  If you need to end up non-root, do your privileged work here, then
  let the template's `USER` line drop privs.
- The Dockerfile invokes it with `set -eu` — **failures fail the build
  loudly**. No silent-skip. Put your own `set -e` at the top of the
  script too, for clarity to the reader.
- You're inside `/tmp/extend/` at invocation. `/opt/app/` exists if
  `files/` was populated; otherwise you'll have to `mkdir -p /opt/app`
  yourself if you want it.
- Keep it fast and deterministic. Every line becomes part of the
  image history; every build re-runs it. Anything that hits the
  network at build time should be mirrored/pinned the same way the
  template's other install URLs are (e.g. via an image.env-supplied
  artifactory mirror).

Example:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Install a runtime dependency
apk add --no-cache tini

# Drop an entrypoint that execs tini then the upstream binary
install -m 0755 /opt/app/entrypoint.sh /usr/local/bin/entrypoint.sh
```

(The `entrypoint.sh` template would live in `scripts/extend/files/`.)

## What NOT to do here

- **Don't edit the template `Dockerfile`** unless you genuinely need a
  multi-stage `COPY --from=<other-image>` (~5% of cases). That's the
  escape hatch — it costs you clean template upgrades. Everything else
  belongs in `customise.sh`.
- **Don't commit secrets.** The contents of `files/` are baked into
  the image layers and visible to anyone who can pull the image. Use
  `CA_CERT` / Vault-based secret injection (see `image.env.example`)
  for anything sensitive.
- **Don't rely on cache-busting tricks.** The entire
  `scripts/extend/` tree is one layer in the image; changing any
  file in it invalidates that layer. Don't try to split
  customisation across multiple `RUN` statements by editing the
  Dockerfile — if you need that granularity, accept the Dockerfile
  fork cost.

## Renovate coverage

Renovate picks up the `# renovate:` hint on `UPSTREAM_TAG` in
`image.env` automatically. If your `customise.sh` pins versions
(package versions, binary URLs), drop a `# renovate:` comment above
each pin the same way the template does — `renovate.json` scans
shell scripts the same as `image.env`.
