#!/usr/bin/env bash
# Mirrors ~/dev into iCloud Drive with rsync. --link-dest makes each unchanged file in the mirror a hardlink to its file
# in ~/dev, so the two share disk space.
#
# Dependency and build output (node_modules, .build, target) stays out of the mirror, and --delete-excluded removes any
# copy of it already there: it can be rebuilt from the source, and it is most of ~/dev's files, each of which iCloud
# uploads and Spotlight indexes.
#
# DEVTOSYNC_SOURCE and DEVTOSYNC_DEST override the two directories.

SOURCE_DIR="${DEVTOSYNC_SOURCE:-$HOME/dev}"
ICLOUD_DIR="${DEVTOSYNC_DEST:-$HOME/Library/Mobile Documents/com~apple~CloudDocs/dev}"

mkdir -p "$ICLOUD_DIR"

rsync -a --delete --delete-excluded \
  --exclude=node_modules/ --exclude=.build/ --exclude=target/ \
  --link-dest="$SOURCE_DIR" \
  "$SOURCE_DIR/" "$ICLOUD_DIR/"

echo "$(date): Synced $SOURCE_DIR to $ICLOUD_DIR"
