#!/usr/bin/env bash
# scripts/lib/artifact-names.sh — canonical artifact filename contract
#
# ONE source of truth for the filenames every CI stage produces and
# consumes. Sourced by:
#
#   build.sh                  (writes the names into build.env so
#                              CI's `. ./build.env` flow propagates
#                              them to downstream stages)
#   push-backends/*.sh        (pick up the names when emitting build.env)
#   scan/syft-sbom.sh         (writes SBOM_FILE)
#   scan/xray-sbom.sh         (writes SBOM_FILE)
#   scan/xray-vuln.sh         (writes VULN_SCAN_FILE)
#   sbom-post.sh              (reads SBOM_FILE)
#
# Shell-set values WIN over the defaults below, so a CI variable or
# `export SBOM_FILE=foo.json` still overrides per-job. The point is
# that no individual script has its own default to drift — they all
# read from this one file.
#
# Why a shared lib instead of just a constant in build.sh: prescan
# stages (xray-vuln-prescan, xray-sbom-prescan) run BEFORE build.sh
# and have no build.env to source. They source this file directly to
# get the same names. This way the prescan-vs-postscan codepath stays
# symmetric — both stages produce sbom.cdx.json / vuln-scan.json,
# and downstream consumers (Grype, sbom-post) never have to know
# which producer ran.

# shellcheck disable=SC2148

# Canonical CycloneDX SBOM filename. Consumed by Grype + sbom-post.sh.
# Producers: scan/syft-sbom.sh, scan/xray-sbom.sh.
export SBOM_FILE="${SBOM_FILE:-sbom.cdx.json}"

# Canonical vulnerability scan output. Consumed by audit shippers
# (Splunk HEC, etc.). Producers: scan/xray-vuln.sh (and any future
# trivy-vuln.sh / grype-vuln.sh swap).
export VULN_SCAN_FILE="${VULN_SCAN_FILE:-vuln-scan.json}"
