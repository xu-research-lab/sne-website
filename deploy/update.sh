#!/usr/bin/env bash
# Bring the live site up to date with this repository.
#
# Run it on the server, from the repository clone:
#
#     cd ~/sne-website && bash deploy/update.sh
#
# It pulls, checks the WebAssembly files that git does not carry, and copies
# each part of the repository to where nginx and Docker expect it. Running it
# twice does nothing the second time. It does not restart the /map service;
# do that by hand when server/ has changed (the script tells you how).

set -euo pipefail

DEST="${DEST:-/srv/microbial}"     # where the live site lives

cd "$(dirname "$0")/.."

git pull --ff-only
bash script/check_vendor.sh        # stops here if a .wasm file is missing or stale

sudo mkdir -p "$DEST/site"
# One rsync per folder: a trailing slash copies a folder's contents, and
# --delete removes files that are gone from the repository.
sudo rsync -a --delete --exclude=/data web/  "$DEST/site/"
sudo rsync -a --delete data/web/             "$DEST/site/data/"
sudo rsync -a --delete data/server/          "$DEST/data/"
sudo rsync -a --delete server/               "$DEST/server/"
sudo rsync -a --delete deploy/               "$DEST/deploy/"

echo
echo "Site updated in $DEST."
echo "If you changed server/, restart the /map service:"
echo "  cd $DEST && sudo docker compose -f deploy/docker-compose.yml up -d --build"
