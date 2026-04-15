#!/usr/bin/env bash
# Cleanup helper: removes old log files from a target directory.
# Used by smoke-test infrastructure as a one-shot housekeeping pass
# across throwaway test artifacts.
set -euo pipefail

TARGET=${1:?usage: cleanup.sh <target-dir> <days>}
DAYS=${2:?usage: cleanup.sh <target-dir> <days>}

if [ ! -d "$TARGET" ]; then
  echo "cleanup: target directory '$TARGET' does not exist" >&2
  exit 1
fi

cd "$TARGET"
find . -name '*.log' -mtime "+${DAYS}" -delete
echo "Cleaned up logs in $TARGET"
