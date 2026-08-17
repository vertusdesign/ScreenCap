#!/bin/sh
# Allocate a monotonically increasing local CFBundleVersion for a packaged app.
# The state file is ignored by Git and is intentionally local to this checkout.
# CI/reproducible builds may pass BUILD explicitly instead of using this helper.
set -eu

STATE_FILE="${1:-.screencap-build-number}"
STATE_DIR=$(dirname "$STATE_FILE")
LOCK_DIR="${STATE_FILE}.lock"

mkdir -p "$STATE_DIR"

# mkdir is atomic on APFS and avoids relying on a non-standard `flock` command
# that is not present on a stock macOS installation.
while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    sleep 0.05
done
cleanup() {
    rmdir "$LOCK_DIR" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

last=0
if [ -f "$STATE_FILE" ]; then
    last=$(tr -d '[:space:]' < "$STATE_FILE")
    case "$last" in
        ''|*[!0-9]*) last=0 ;;
    esac
fi

now=$(date -u +%s)
if [ "$now" -le "$last" ]; then
    next=$((last + 1))
else
    next=$now
fi

temporary="${STATE_FILE}.tmp.$$"
printf '%s\n' "$next" > "$temporary"
mv -f "$temporary" "$STATE_FILE"
printf '%s\n' "$next"
