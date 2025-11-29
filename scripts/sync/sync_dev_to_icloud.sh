#!/bin/bash
# Purpose: Sync ~/dev to iCloud Drive using rsync with hardlinks
# This script creates hardlinks in iCloud Drive that point to files in ~/dev,
# allowing files to exist in both locations while sharing disk space.

SOURCE_DIR="$HOME/dev"
ICLOUD_DIR="$HOME/Library/Mobile Documents/com~apple~CloudDocs/dev"

# Create destination directory if it doesn't exist
mkdir -p "$ICLOUD_DIR"

# Sync with hardlinks
# -a: archive mode (preserves permissions, timestamps, etc.)
# -v: verbose output
# --delete: remove files in destination that don't exist in source
# --link-dest: create hardlinks when possible, saving disk space
rsync -av --delete \
    --link-dest="$SOURCE_DIR" \
    "$SOURCE_DIR/" "$ICLOUD_DIR/"

echo "$(date): Synced $SOURCE_DIR to $ICLOUD_DIR"

