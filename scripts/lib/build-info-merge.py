#!/usr/bin/env python3
"""Merge module linkage + filtered env vars into Artifactory build info.

Called by scripts/push-backends/artifactory.sh (Free-tier path) after
`jf rt bp --collect-env` publishes a baseline build record. This script:

  1. Reads the published build info JSON (if available) and merges its
     env vars + VCS context in, filtered through our include/exclude
     prefix lists.
  2. Classifies each stored file by digest using side-loaded final and
     upstream manifests (config blob, upstream-inherited layer, ours).
     See `_compute_inherited_blob_digests` for the details.
  3. Enriches with CI context (build URL, principal, duration, etc.)
     auto-detected from common CI env vars.
  4. Writes the final build-info JSON for PUT to /api/build.

Usage:
  python3 build-info-merge.py <tmpdir> <file_count> <tag_subpath> \
    <build_name> <build_number> <target> <image_name> <image_tag> \
    <git_rev> <git_url> <started> [<repo> [<started_ms> \
    [<docker_image_id>]]]

11 required positional args + 3 optional tail. The tail controls
parity-with-Pro fields (`modules[].repository`, `durationMillis`,
`modules[].properties.docker.image.id`); unsupplied values just emit
empty strings.
"""

import json
import sys
import os
import time


INCLUDE_PREFIXES = [
    "REGISTRY_KIND", "PUSH_REGISTRY", "PUSH_PROJECT",
    "ARTIFACTORY_", "IMAGE_", "UPSTREAM_", "DISTRO", "REMEDIATE",
    "INJECT_CERTS", "ORIGINAL_USER", "VENDOR", "PLATFORM",
    "APK_MIRROR", "APT_MIRROR", "BASE_DIGEST", "GIT_SHA", "CREATED",
    "CI_", "GITLAB_", "GITHUB_", "BAMBOO_", "BUILD_",
    "RUNNER_", "JOB_", "PIPELINE_",
    "USER", "HOME", "SHELL", "PWD", "PATH", "LANG",
    "HOSTNAME", "LOGNAME",
    "DOCKER_", "BUILDKIT",
    "SOURCE", "TAG", "VCS_REF",
]
# EXCLUDE wins over INCLUDE. Keep VAULT_* out of build-info: token + CA +
# namespace shouldn't be audit-visible, and VAULT_ADDR leaks internal
# infra topology even if non-secret.
EXCLUDE_PREFIXES = ["CLAUDE", "CLAUDECODE", "VAULT"]


def _keep_env_var(varname):
    """Return True if the env var should be kept in build info properties."""
    vname = varname.upper()
    if any(vname.startswith(p.upper()) for p in EXCLUDE_PREFIXES):
        return False
    return any(vname.startswith(p.upper()) for p in INCLUDE_PREFIXES)


def _filter_env_props(props):
    """Filter buildInfo.env.* properties through the include/exclude prefix lists."""
    filtered = {}
    kept = stripped = 0
    for k, v in props.items():
        if k.startswith("buildInfo.env."):
            varname = k[len("buildInfo.env."):]
            if _keep_env_var(varname):
                kept += 1
            else:
                stripped += 1
                continue
        filtered[k] = v
    return filtered, kept, stripped


def load_published_build_info(published_path):
    """Return the baseline build info from jf rt bp, or {} if unavailable."""
    if not os.path.exists(published_path):
        return {}
    try:
        with open(published_path) as f:
            resp = json.load(f)
        base_bi = resp.get("buildInfo", {})
        props = base_bi.get("properties", {})
        filtered, kept, stripped = _filter_env_props(props)
        base_bi["properties"] = filtered
        print(f"  merged from jf rt bp: {kept} env vars kept, "
              f"{stripped} stripped, {len(base_bi.get('vcs', []))} vcs entries")
        return base_bi
    except (OSError, json.JSONDecodeError) as e:
        print(f"  WARN: could not parse published build info: {e}",
              file=sys.stderr)
        return {}


def _load_file_entry(tmpdir, idx):
    """Read name_<idx>.txt + file_<idx>.json. Return (fname, info) or None."""
    name_file = os.path.join(tmpdir, f"name_{idx}.txt")
    info_file = os.path.join(tmpdir, f"file_{idx}.json")
    if not os.path.exists(name_file) or not os.path.exists(info_file):
        return None
    try:
        with open(name_file) as f:
            fname = f.read().strip()
        with open(info_file) as f:
            info = json.load(f)
    except (OSError, json.JSONDecodeError):
        return None
    if not info.get("checksums", {}).get("sha256"):
        return None
    return fname, info


def _filename_to_digest(fname):
    """Convert storage filename 'sha256__<hex>' to OCI digest 'sha256:<hex>'."""
    if "__" not in fname:
        return ""
    algo, hex_val = fname.split("__", 1)
    return f"{algo}:{hex_val}"


def _load_json_file(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return None


def _compute_inherited_blob_digests(tmpdir):
    """Determine which final-manifest layer blobs are inherited from the
    upstream base image. Matches what Pro's `jf docker push` writes —
    the first N entries of the final manifest's layers[] (where N is
    the upstream's layer count) are marked as dependencies.

    Reads side-loaded files written by the push backend:
      - final-manifest.json     distribution manifest we just pushed
      - upstream-diffids.json   upstream rootfs.diff_ids (just used
                                for its length = upstream layer count)

    Returns (config_digest, inherited_blob_digests_set). Empty set if
    inputs are missing — Python falls back to "all non-config blobs
    are dependencies".
    """
    final = _load_json_file(os.path.join(tmpdir, "final-manifest.json")) or {}
    config_digest = final.get("config", {}).get("digest", "")
    final_layers = final.get("layers", [])

    upstream_diffs = _load_json_file(
        os.path.join(tmpdir, "upstream-diffids.json")) or []
    if not upstream_diffs or not final_layers:
        return config_digest, set()

    inherited_count = min(len(upstream_diffs), len(final_layers))
    inherited = set()
    for i in range(inherited_count):
        d = final_layers[i].get("digest", "")
        if d:
            inherited.add(d)
    return config_digest, inherited


def _artifact_type(fname, config_digest):
    """Return the Pro-equivalent artifact type tag for a stored file."""
    if fname == "manifest.json":
        return "json"
    if _filename_to_digest(fname) == config_digest:
        return "json"  # image config is JSON, same as Pro labels it
    if fname.startswith("sha256__"):
        return "sha256"
    return "generic"


def _build_artifact(fname, info, tag_subpath, repo, config_digest):
    """Build one artifacts[] entry from a storage API file record."""
    cs = info["checksums"]
    entry = {
        "type": _artifact_type(fname, config_digest),
        "sha1": cs.get("sha1", ""),
        "sha256": cs["sha256"],
        "md5": cs.get("md5", ""),
        "name": fname,
        "path": f"{tag_subpath}/{fname}",
    }
    if repo:
        entry["originalDeploymentRepo"] = repo
    return entry


def _build_blob(fname, info, config_digest, upstream_digests):
    """Return one dependencies[] entry if fname is an upstream-inherited
    layer blob, else None. Always excludes manifest.json and the config
    blob. When upstream_digests is populated, further restricts to layers
    the upstream manifest declares (matching Pro's semantics). When empty
    (the upstream fetch failed), keeps every non-config sha256__ blob —
    conservative but avoids dropping data.
    """
    if fname == "manifest.json" or not fname.startswith("sha256__"):
        return None
    digest = _filename_to_digest(fname)
    if digest == config_digest:
        return None
    if upstream_digests and digest not in upstream_digests:
        return None
    cs = info["checksums"]
    return {
        "id": fname,
        "type": "sha256",
        "sha1": cs.get("sha1", ""),
        "sha256": cs["sha256"],
        "md5": cs.get("md5", ""),
    }


def collect_artifacts_and_dependencies(tmpdir, file_count, tag_subpath, repo,
                                       config_digest, upstream_digests):
    """Walk stored files and return (artifacts, dependencies).

    Artifacts: every stored file, tagged with Pro-equivalent type.
    Dependencies: only layer blobs inherited from the upstream base image
    (matched by digest). Config blob is never a dependency.
    """
    artifacts = []
    dependencies = []
    for i in range(file_count):
        entry = _load_file_entry(tmpdir, i)
        if entry is None:
            continue
        fname, info = entry
        artifacts.append(_build_artifact(
            fname, info, tag_subpath, repo, config_digest))
        blob = _build_blob(fname, info, config_digest, upstream_digests)
        if blob is not None:
            dependencies.append(blob)
    return artifacts, dependencies


def _detect_ci_agent():
    """Best-guess {name, version} for the CI system driving this build."""
    if os.environ.get("GITLAB_CI"):
        return {"name": "gitlab-ci",
                "version": os.environ.get("CI_SERVER_VERSION", "")}
    if os.environ.get("GITHUB_ACTIONS"):
        return {"name": "github-actions",
                "version": os.environ.get("GITHUB_RUN_ID", "")}
    if os.environ.get("bamboo_buildNumber"):
        return {"name": "bamboo",
                "version": os.environ.get("bamboo_buildNumber", "")}
    if os.environ.get("JENKINS_URL"):
        return {"name": "jenkins",
                "version": os.environ.get("BUILD_NUMBER", "")}
    return {"name": "generic", "version": ""}


def _detect_build_url():
    """Resolve the CI run URL from the first env var that's set."""
    for var in ("CI_PIPELINE_URL", "CI_JOB_URL", "BUILDKITE_BUILD_URL",
                "BUILD_URL", "bamboo_buildResultsUrl"):
        val = os.environ.get(var)
        if val:
            return val
    gh_server = os.environ.get("GITHUB_SERVER_URL")
    gh_repo = os.environ.get("GITHUB_REPOSITORY")
    gh_run = os.environ.get("GITHUB_RUN_ID")
    if gh_server and gh_repo and gh_run:
        return f"{gh_server}/{gh_repo}/actions/runs/{gh_run}"
    return ""


def _detect_principal():
    """Who triggered the build — CI user, GitHub actor, or git committer."""
    for var in ("GITLAB_USER_LOGIN", "GITHUB_ACTOR",
                "BUILDKITE_BUILD_CREATOR", "bamboo_ManualBuildTriggerReason_userName",
                "USER"):
        val = os.environ.get(var)
        if val:
            return val
    return ""


def assemble_build_info(base_bi, *, build_name, build_number, target,
                        image_name, image_tag, git_rev, git_url, started,
                        started_ms, repo, docker_image_id,
                        artifacts, dependencies):
    """Merge modules into the base build info and return the final dict."""
    build_info = base_bi.copy() if base_bi else {}
    vcs_default = [{"revision": git_rev, "url": git_url}] if git_rev else []

    # Top-level enrichments — parity with what Pro's jf rt bp + jf docker push
    # write. Each field is safe to leave empty; Artifactory just omits the UI
    # element when the value is blank.
    build_url = _detect_build_url()
    principal = _detect_principal()
    art_principal = os.environ.get("ARTIFACTORY_USER", "")
    agent = base_bi.get("agent") or _detect_ci_agent()

    duration_ms = 0
    if started_ms:
        try:
            duration_ms = max(0, int(time.time() * 1000) - int(started_ms))
        except ValueError:
            duration_ms = 0

    # Module-level repository — JCR Free strips artifact-level
    # originalDeploymentRepo at ingestion; module.repository survives.
    # Still doesn't restore Packages → Produced By (that UI path calls
    # /api/search/buildArtifacts which is Pro-licensed), but keeps the
    # repo linkage present for any integration that walks modules[].
    module = {
        "properties": {
            "docker.image.tag": target,
            "docker.image.id": docker_image_id or "",
        },
        "type": "docker",
        "id": f"{image_name}:{image_tag}",
        "artifacts": artifacts,
        "dependencies": dependencies,
    }
    if repo:
        module["repository"] = repo

    build_info.update({
        "version": "1.0.1",
        "name": build_name,
        "number": build_number,
        "type": "DOCKER",
        "started": base_bi.get("started", started),
        "durationMillis": duration_ms,
        "buildAgent": base_bi.get(
            "buildAgent", {"name": "container-images", "version": "1.0"}),
        "agent": agent,
        "url": build_url,
        "principal": principal,
        "artifactoryPrincipal": art_principal,
        "properties": base_bi.get("properties", {}),
        "vcs": base_bi.get("vcs", vcs_default),
        "modules": [module],
    })
    return build_info


def main():
    tmpdir = sys.argv[1]
    file_count = int(sys.argv[2])
    tag_subpath = sys.argv[3]
    build_name, build_number, target = sys.argv[4], sys.argv[5], sys.argv[6]
    image_name, image_tag = sys.argv[7], sys.argv[8]
    git_rev, git_url, started = sys.argv[9], sys.argv[10], sys.argv[11]
    repo = sys.argv[12] if len(sys.argv) > 12 else ""
    started_ms = sys.argv[13] if len(sys.argv) > 13 else ""
    docker_image_id = sys.argv[14] if len(sys.argv) > 14 else ""

    config_digest, upstream_digests = _compute_inherited_blob_digests(tmpdir)
    base_bi = load_published_build_info(os.path.join(tmpdir, "published-bi.json"))
    artifacts, dependencies = collect_artifacts_and_dependencies(
        tmpdir, file_count, tag_subpath, repo, config_digest, upstream_digests)

    build_info = assemble_build_info(
        base_bi,
        build_name=build_name, build_number=build_number, target=target,
        image_name=image_name, image_tag=image_tag,
        git_rev=git_rev, git_url=git_url, started=started,
        started_ms=started_ms, repo=repo,
        docker_image_id=docker_image_id,
        artifacts=artifacts, dependencies=dependencies,
    )

    outfile = os.path.join(tmpdir, "build-info.json")
    with open(outfile, "w") as f:
        json.dump(build_info, f)

    mode = "per-digest" if upstream_digests else "fallback"
    print(f"  artifacts: {len(artifacts)}, dependencies: {len(dependencies)} ({mode})")


if __name__ == "__main__":
    main()
