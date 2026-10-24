#!/usr/bin/env bash
set -Eeuo pipefail

# Refresh Debian packages only while building the image. Never patch a running
# container: doing so makes deployments non-reproducible and may mutate volumes.
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get -y --no-install-recommends upgrade --with-new-pkgs
apt-get clean
rm -rf /var/lib/apt/lists/*
