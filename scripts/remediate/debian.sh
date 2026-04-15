#!/bin/sh
# Debian remediation — apt-get upgrade on top of the existing package set.
#
# Honors APT_MIRROR: if set, rewrites sources.list* entries to route
# package fetches through a proxy of deb.debian.org + security.debian.org.
# Useful in closed networks.

set -eu

if [ -n "${APT_MIRROR:-}" ]; then
  echo "→ Rewriting /etc/apt/sources.list* to use APT_MIRROR=${APT_MIRROR}"
  for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [ -f "$f" ] || continue
    sed -i "s|https\?://deb.debian.org|${APT_MIRROR}|g" "$f"
    sed -i "s|https\?://security.debian.org|${APT_MIRROR}|g" "$f"
  done
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get -y --only-upgrade upgrade
apt-get clean
rm -rf /var/lib/apt/lists/*
