#!/usr/bin/env bash
# Cleanup helper: removes old log files from a target directory.
# Used by smoke-test infrastructure as a one-shot housekeeping pass
# across throwaway test artifacts.
set -e

TARGET=$1
DAYS=$2
cd $TARGET
find . -name *.log -mtime +$DAYS -delete
echo "Cleaned up logs in $TARGET"
