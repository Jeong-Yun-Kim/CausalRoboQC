#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mode=${1:---check}
env_file=${PI_ENV_FILE:-.pi.env}
compose=(docker compose)
if [[ -f "$env_file" ]]; then
  compose+=(--env-file "$env_file")
  # Parse only the deployment keys, never execute a sourced env file.
  while IFS='=' read -r key value; do
    case "$key" in
      SERIAL_DEVICE|CAMERA_DEVICE|VISION_CONFIG_PATH|ANALYSIS_BASE_URL|VISION_ENABLED|VISION_REQUIRED|CAMERA_PREVIEW_MODE|PRESENTATION_MODE)
        if [[ ! -v "$key" ]]; then export "$key=$value"; fi ;;
    esac
  done < "$env_file"
fi
compose+=(-f docker-compose.pi.yml)
serial_device=${SERIAL_DEVICE:-/dev/ttyACM0}
camera_device=${CAMERA_DEVICE:-/dev/video0}
case "$mode" in
  --check|--dry-run)
    for device in "$serial_device" "$camera_device"; do
      if [[ -e "$device" ]]; then printf 'Device exists (not opened): %s\n' "$device";
      else printf 'Device missing: %s\n' "$device"; fi
    done
    printf 'Prepared command: '; printf '%q ' "${compose[@]}" up -d --build; printf '\n'
    printf 'No Docker startup, device opens or HTTP requests in check mode.\n'
    ;;
  --start)
    "${compose[@]}" up -d --build
    ;;
  --health)
    # Only an explicit health invocation makes local HTTP requests.
    curl --fail --max-time 3 http://127.0.0.1:8000/health
    curl --fail --max-time 3 http://127.0.0.1:8000/api/camera/health
    curl --fail --max-time 3 --output /dev/null http://127.0.0.1:8080/
    ;;
  *) printf 'Usage: %s [--check|--dry-run|--start|--health]\n' "$0" >&2; exit 2 ;;
esac
printf 'API: http://127.0.0.1:8000\nMonitor: http://127.0.0.1:8080\nTablet: http://<Pi_IP>:8080\nAI: %s\n' "${ANALYSIS_BASE_URL:-http://192.168.1.10:9000}"
