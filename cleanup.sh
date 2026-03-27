#!/bin/bash

# cleanup.sh - Archive ralph session files and reset for next session
# Usage: ./cleanup.sh

set -e

RALPH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCHIVE_DIR="$RALPH_DIR/archive"

# Check required files exist
if [[ ! -f "$RALPH_DIR/.last-branch" ]]; then
    echo "Error: .last-branch file not found"
    exit 1
fi

if [[ ! -f "$RALPH_DIR/prd.json" ]]; then
    echo "Error: prd.json file not found"
    exit 1
fi

BRANCH_NAME=$(cat "$RALPH_DIR/.last-branch" | tr -d '\n')

# Extract the suffix after "ralph/" (e.g., "ralph/cache-consolidation" -> "cache-consolidation")
if [[ "$BRANCH_NAME" == ralph/* ]]; then
    SUFFIX="${BRANCH_NAME#ralph/}"
else
    SUFFIX="$BRANCH_NAME"
fi

# Create archive folder name with today's date
DATE=$(date +%Y-%m-%d)
ARCHIVE_FOLDER="$ARCHIVE_DIR/$DATE-$SUFFIX"

# Check if archive folder already exists
if [[ -d "$ARCHIVE_FOLDER" ]]; then
    echo "Error: Archive folder already exists: $ARCHIVE_FOLDER"
    exit 1
fi

# Create archive folder
mkdir -p "$ARCHIVE_FOLDER"
echo "Created archive folder: $ARCHIVE_FOLDER"

# Move files to archive
FILES_MOVED=0

# Move .last-branch
if [[ -f "$RALPH_DIR/.last-branch" ]]; then
    mv "$RALPH_DIR/.last-branch" "$ARCHIVE_FOLDER/"
    echo "  Moved: .last-branch"
    ((FILES_MOVED++))
fi

# Move prd-*.md files
for f in "$RALPH_DIR"/prd-*.md; do
    if [[ -f "$f" ]]; then
        mv "$f" "$ARCHIVE_FOLDER/"
        echo "  Moved: $(basename "$f")"
        ((FILES_MOVED++))
    fi
done

# Move *-plan.md files
for f in "$RALPH_DIR"/*-plan.md; do
    if [[ -f "$f" ]]; then
        mv "$f" "$ARCHIVE_FOLDER/"
        echo "  Moved: $(basename "$f")"
        ((FILES_MOVED++))
    fi
done

# Move *review.txt files
for f in "$RALPH_DIR"/*review.txt; do
    if [[ -f "$f" ]]; then
        mv "$f" "$ARCHIVE_FOLDER/"
        echo "  Moved: $(basename "$f")"
        ((FILES_MOVED++))
    fi
done

# Move prd.json
if [[ -f "$RALPH_DIR/prd.json" ]]; then
    mv "$RALPH_DIR/prd.json" "$ARCHIVE_FOLDER/"
    echo "  Moved: prd.json"
    ((FILES_MOVED++))
fi

# Extract Codebase Patterns from existing progress.txt before moving
CODEBASE_PATTERNS=""
if [[ -f "$RALPH_DIR/progress.txt" ]]; then
    # Extract everything between "## Codebase Patterns" and "---" (exclude the ---)
    CODEBASE_PATTERNS=$(sed -n '/^## Codebase Patterns$/,/^---$/p' "$RALPH_DIR/progress.txt" | sed '$d')
fi

# Move progress.txt
if [[ -f "$RALPH_DIR/progress.txt" ]]; then
    mv "$RALPH_DIR/progress.txt" "$ARCHIVE_FOLDER/"
    echo "  Moved: progress.txt"
    ((FILES_MOVED++))
fi

# Move runs/ folder (metrics from ralph.sh)
if [[ -d "$RALPH_DIR/runs" ]]; then
    mv "$RALPH_DIR/runs" "$ARCHIVE_FOLDER/"
    echo "  Moved: runs/"
    ((FILES_MOVED++))

    # Move ralph_runs_cumulative.json into runs/ folder
    if [[ -f "$RALPH_DIR/ralph_runs_cumulative.json" ]]; then
        mv "$RALPH_DIR/ralph_runs_cumulative.json" "$ARCHIVE_FOLDER/runs/"
        echo "  Moved: ralph_runs_cumulative.json -> runs/"
        ((FILES_MOVED++))
    fi
fi

# Move *-plan-docs/ folders
for d in "$RALPH_DIR"/*-plan-docs; do
    if [[ -d "$d" ]]; then
        mv "$d" "$ARCHIVE_FOLDER/"
        echo "  Moved: $(basename "$d")/"
        ((FILES_MOVED++))
    fi
done

# Create fresh progress.txt with header and preserved Codebase Patterns
cat > "$RALPH_DIR/progress.txt" << EOF
# Ralph Progress Log
Started: $(date "+%a %b %d %Y")

$CODEBASE_PATTERNS

---

EOF

echo "Created fresh progress.txt"
echo ""
echo "Cleanup complete! Archived $FILES_MOVED files to: $ARCHIVE_FOLDER"
