#!/bin/sh
# Red Hat UBI / RHEL / CentOS-family remediation.
#
# Picks microdnf / dnf / yum in that order (microdnf on minimal UBI,
# dnf on standard UBI, yum on older RHEL / CentOS 7). Red Hat's
# Subscription Manager + CDN is assumed already configured inside the
# base image — closed-network setups typically use Red Hat Satellite
# or a Pulp mirror, which Red Hat handles via /etc/yum.repos.d/*.repo
# rewrites rather than a single environment variable. If you're on
# RHEL air-gapped, edit the repo files inside this script OR bake the
# mirror config into your base image before building.

set -eu

if command -v microdnf >/dev/null 2>&1; then
  microdnf -y update
  microdnf clean all
elif command -v dnf >/dev/null 2>&1; then
  dnf -y update
  dnf clean all
elif command -v yum >/dev/null 2>&1; then
  yum -y update
  yum clean all
else
  echo "ERROR: no dnf/microdnf/yum found in image — is DISTRO=ubi correct?" >&2
  exit 1
fi

rm -rf /var/cache/yum /var/cache/dnf
