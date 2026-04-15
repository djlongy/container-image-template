#!/bin/sh
# Alpine remediation — apk upgrade on top of the existing package set.
#
# Honors APK_MIRROR: if set, rewrites /etc/apk/repositories to route
# package fetches through a raw-proxy of dl-cdn.alpinelinux.org/alpine
# before running apk update. Useful in closed networks.

set -eu

if [ -n "${APK_MIRROR:-}" ]; then
  echo "→ Rewriting /etc/apk/repositories to use APK_MIRROR=${APK_MIRROR}"
  sed -i "s|https\?://dl-cdn.alpinelinux.org/alpine|${APK_MIRROR}|g" /etc/apk/repositories
fi

apk update
apk upgrade --no-cache
rm -rf /var/cache/apk/*
