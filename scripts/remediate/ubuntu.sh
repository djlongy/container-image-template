#!/bin/sh
# Ubuntu remediation — apt-get upgrade on top of the existing package set.
#
# Honors APT_MIRROR: if set, rewrites sources.list* entries to route
# package fetches through a proxy of archive.ubuntu.com, security.ubuntu.com,
# and ports.ubuntu.com (for non-amd64 architectures). Useful in closed
# networks.

set -eu

if [ -n "${APT_MIRROR:-}" ]; then
  echo "→ Rewriting /etc/apt/sources.list* to use APT_MIRROR=${APT_MIRROR}"
  for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [ -f "$f" ] || continue
    sed -i "s|https\?://archive.ubuntu.com/ubuntu|${APT_MIRROR}|g" "$f"
    sed -i "s|https\?://security.ubuntu.com/ubuntu|${APT_MIRROR}|g" "$f"
    sed -i "s|https\?://ports.ubuntu.com/ubuntu-ports|${APT_MIRROR}|g" "$f"
  done
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get -y --only-upgrade upgrade
apt-get clean
rm -rf /var/lib/apt/lists/*
