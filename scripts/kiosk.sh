#!/usr/bin/env bash
set -euo pipefail
browser=${CHROMIUM_BIN:-chromium}
url=http://127.0.0.1:8080
case "${1:---dry-run}" in
  --dry-run|--check)
    printf 'Prepared: wait for %s then %s --kiosk --no-first-run %s\n' "$url" "$browser" "$url"
    exit 0 ;;
  --start) ;;
  *) printf 'Usage: %s [--dry-run|--start]\n' "$0" >&2; exit 2 ;;
esac
for attempt in {1..60}; do
  if curl --fail --silent --max-time 2 --output /dev/null "$url"; then
    exec "$browser" --kiosk --no-first-run "$url"
  fi
  sleep 2
done
printf 'App did not become ready: %s\n' "$url" >&2
exit 1
