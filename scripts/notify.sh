#!/usr/bin/env bash
# Desktop notification. usage: notify.sh <title> <body>
# Config: notify = "osascript" (macOS, default) | "none". Never fails the caller.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
TITLE="${1:-dispatch}"; BODY="${2:-}"
KIND="$(cfg '.notify // "osascript"' 2>/dev/null || echo osascript)"
case "$KIND" in
  osascript)
    if command -v osascript >/dev/null 2>&1; then
      T="$(printf '%s' "$TITLE" | sed 's/"/\\"/g')"; B="$(printf '%s' "$BODY" | sed 's/"/\\"/g')"
      osascript -e "display notification \"$B\" with title \"$T\"" >/dev/null 2>&1 || true
    fi ;;
  *) : ;;
esac
echo "notified: $TITLE"
