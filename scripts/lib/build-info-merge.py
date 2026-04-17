#!/usr/bin/env python3
"""Merge module linkage + filtered env vars into Artifactory build info.

Called by scripts/push-backends/artifactory.sh (Free-tier path) after
`jf rt bp --collect-env` publishes a baseline build record. This script:

  1. Reads the published build info JSON (if available)
  2. Post-filters environment variables via include-first allowlist
  3. Builds the modules array from storage API checksums
  4. Splits artifacts vs dependencies using upstream layer count
  5. Writes the enriched build info JSON for PUT back to /api/build

Usage:
  python3 build-info-merge.py <tmpdir> <file_count> <tag_subpath> \
    <build_name> <build_number> <target> <image_name> <image_tag> \
    <git_rev> <git_url> <started> <upstream_layer_count>

All 12 positional args are required. The script reads per-file JSON
from <tmpdir>/file_0.json..file_N.json (with matching name_N.txt)
and writes the merged result to <tmpdir>/build-info.json.
"""

import json
import sys
import os


INCLUDE_PREFIXES = [
    "REGISTRY_KIND", "PUSH_REGISTRY", "PUSH_PROJECT",
    "ARTIFACTORY_", "IMAGE_", "UPSTREAM_", "DISTRO", "REMEDIATE",
    "INJECT_CERTS", "ORIGINAL_USER", "VENDOR", "PLATFORM",
    "APK_MIRROR", "APT_MIRROR", "BASE_DIGEST", "GIT_SHA", "CREATED",
    "CI_", "GITLAB_", "GITHUB_", "BAMBOO_", "BUILD_",
    "RUNNER_", "JOB_", "PIPELINE_",
    "USER", "HOME", "SHELL", "PWD", "PATH", "LANG",
    "HOSTNAME", "LOGNAME",
    "DOCKER_", "BUILDKIT", "VAULT_ADDR",
    "SOURCE", "TAG", "VCS_REF",
]
EXCLUDE_PREFIXES = ["CLAUDE", "CLAUDECODE"]


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


def _build_artifact(fname, info, tag_subpath):
    """Build one artifacts[] entry from a storage API file record."""
    cs = info["checksums"]
    ftype = "json" if fname == "manifest.json" else "gz"
    return {
        "type": ftype,
        "sha1": cs.get("sha1", ""),
        "sha256": cs["sha256"],
        "md5": cs.get("md5", ""),
        "name": fname,
        "path": f"{tag_subpath}/{fname}",
    }


def _build_blob(fname, info):
    """Build one dependencies[] entry, or None if fname isn't a layer blob."""
    if fname == "manifest.json" or not fname.startswith("sha256__"):
        return None
    cs = info["checksums"]
    return {
        "id": fname,
        "sha1": cs.get("sha1", ""),
        "sha256": cs["sha256"],
        "md5": cs.get("md5", ""),
    }


def collect_artifacts_and_blobs(tmpdir, file_count, tag_subpath):
    """Walk the tmpdir file_N.json entries and return (artifacts, all_blobs)."""
    artifacts = []
    all_blobs = []
    for i in range(file_count):
        entry = _load_file_entry(tmpdir, i)
        if entry is None:
            continue
        fname, info = entry
        artifacts.append(_build_artifact(fname, info, tag_subpath))
        blob = _build_blob(fname, info)
        if blob is not None:
            all_blobs.append(blob)
    return artifacts, all_blobs


def split_dependencies(all_blobs, upstream_layer_count):
    """First N blobs are upstream base layers (dependencies); rest are ours."""
    if 0 < upstream_layer_count <= len(all_blobs):
        return all_blobs[:upstream_layer_count]
    return all_blobs


def assemble_build_info(base_bi, *, build_name, build_number, target,
                        image_name, image_tag, git_rev, git_url, started,
                        artifacts, dependencies):
    """Merge modules into the base build info and return the final dict."""
    build_info = base_bi.copy() if base_bi else {}
    vcs_default = [{"revision": git_rev, "url": git_url}] if git_rev else []
    build_info.update({
        "version": "1.0.1",
        "name": build_name,
        "number": build_number,
        "type": "DOCKER",
        "started": base_bi.get("started", started),
        "buildAgent": base_bi.get(
            "buildAgent", {"name": "container-images", "version": "1.0"}),
        "agent": base_bi.get(
            "agent", {"name": "build.sh", "version": "free-lcd"}),
        "properties": base_bi.get("properties", {}),
        "vcs": base_bi.get("vcs", vcs_default),
        "modules": [{
            "properties": {"docker.image.tag": target, "docker.image.id": ""},
            "type": "docker",
            "id": f"{image_name}:{image_tag}",
            "artifacts": artifacts,
            "dependencies": dependencies,
        }],
    })
    return build_info


def main():
    tmpdir = sys.argv[1]
    file_count = int(sys.argv[2])
    tag_subpath = sys.argv[3]
    build_name, build_number, target = sys.argv[4], sys.argv[5], sys.argv[6]
    image_name, image_tag = sys.argv[7], sys.argv[8]
    git_rev, git_url, started = sys.argv[9], sys.argv[10], sys.argv[11]
    upstream_layer_count = int(sys.argv[12]) if len(sys.argv) > 12 else 0

    base_bi = load_published_build_info(os.path.join(tmpdir, "published-bi.json"))
    artifacts, all_blobs = collect_artifacts_and_blobs(tmpdir, file_count, tag_subpath)
    dependencies = split_dependencies(all_blobs, upstream_layer_count)
    build_info = assemble_build_info(
        base_bi,
        build_name=build_name, build_number=build_number, target=target,
        image_name=image_name, image_tag=image_tag,
        git_rev=git_rev, git_url=git_url, started=started,
        artifacts=artifacts, dependencies=dependencies,
    )

    outfile = os.path.join(tmpdir, "build-info.json")
    with open(outfile, "w") as f:
        json.dump(build_info, f)

    print(f"  artifacts: {len(artifacts)}, dependencies: {len(dependencies)}")


if __name__ == "__main__":
    main()
