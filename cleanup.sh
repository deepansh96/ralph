#!/bin/bash

# cleanup.sh - Archive a ralph workspace and reset for next feature
# Usage: ./cleanup.sh <name>
#
# Arguments:
#   name    The workspace name (same as --prd name used with ralph.sh)
#           Moves ralph/workspaces/<name>/ to ralph/archive/<date>-<name>/

set -e

RALPH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCHIVE_DIR="$RALPH_DIR/archive"

# Validate argument
if [[ -z "$1" ]]; then
    echo "Error: workspace name is required"
    echo "Usage: ./cleanup.sh <name>"
    echo ""
    echo "Active workspaces:"
    if [[ -d "$RALPH_DIR/workspaces" ]]; then
        ls -1 "$RALPH_DIR/workspaces" 2>/dev/null || echo "  (none)"
    else
        echo "  (none)"
    fi
    exit 1
fi

WORKSPACE_NAME="$1"
WORKSPACE_DIR="$RALPH_DIR/workspaces/$WORKSPACE_NAME"

# Check workspace exists
if [[ ! -d "$WORKSPACE_DIR" ]]; then
    echo "Error: Workspace not found: $WORKSPACE_DIR"
    echo ""
    echo "Active workspaces:"
    ls -1 "$RALPH_DIR/workspaces" 2>/dev/null || echo "  (none)"
    exit 1
fi

# Create archive folder name with today's date
DATE=$(date +%Y-%m-%d)
ARCHIVE_FOLDER="$ARCHIVE_DIR/$DATE-$WORKSPACE_NAME"

# Check if archive folder already exists
if [[ -d "$ARCHIVE_FOLDER" ]]; then
    echo "Error: Archive folder already exists: $ARCHIVE_FOLDER"
    exit 1
fi

# Move the entire workspace to archive
mkdir -p "$ARCHIVE_DIR"
mv "$WORKSPACE_DIR" "$ARCHIVE_FOLDER"

echo "Archived workspace: $WORKSPACE_NAME"
echo "  From: $WORKSPACE_DIR"
echo "  To:   $ARCHIVE_FOLDER"

# Clean up empty workspaces dir
rmdir "$RALPH_DIR/workspaces" 2>/dev/null || true

echo ""
echo "Done! Run './ralph/ralph.sh --prd <new-name> ...' to start a new feature."
