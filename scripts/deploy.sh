#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY_ENV="$PROJECT_ROOT/.deploy.env"

if [[ -f "$DEPLOY_ENV" ]]; then
  # shellcheck disable=SC1090
  source "$DEPLOY_ENV"
fi

DEPLOY_HOST="${DEPLOY_HOST:-robot@robot-host}"
REMOTE_ROOT="${REMOTE_ROOT:-/home/robot/CausalRoboQC}"
SERIAL_DEVICE="${SERIAL_DEVICE:-/dev/ttyACM0}"
SERIAL_BAUD="${SERIAL_BAUD:-115200}"

STAGE_DIR=""
SSH_OPTIONS=(-o BatchMode=yes -o ConnectTimeout=10)
RSYNC_RSH="ssh -o BatchMode=yes -o ConnectTimeout=10"

cleanup() {
  if [[ -n "$STAGE_DIR" && -d "$STAGE_DIR" ]]; then
    rm -rf -- "$STAGE_DIR"
  fi
}
trap cleanup EXIT

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  ./deploy             Sync the whitelist and start Docker Compose
  ./deploy --dry-run   Preview rsync changes only
  ./deploy status      Show remote containers, logs, health, volume, and serial
EOF
}

validate_settings() {
  [[ "$DEPLOY_HOST" =~ ^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+$ ]] ||
    die "DEPLOY_HOST must look like user@host: $DEPLOY_HOST"
  [[ "$REMOTE_ROOT" =~ ^/[A-Za-z0-9._/-]+$ && "$REMOTE_ROOT" != "/" ]] ||
    die "REMOTE_ROOT must be a safe absolute path other than /: $REMOTE_ROOT"
  [[ "$SERIAL_DEVICE" =~ ^/dev/[A-Za-z0-9._/-]+$ ]] ||
    die "SERIAL_DEVICE must be under /dev: $SERIAL_DEVICE"
  [[ "$SERIAL_BAUD" =~ ^[0-9]+$ ]] || die "SERIAL_BAUD must be numeric"
}

require_local_files() {
  command -v rsync >/dev/null || die "rsync is required"
  command -v ssh >/dev/null || die "ssh is required"
  command -v tar >/dev/null || die "tar is required"
  [[ -d "$PROJECT_ROOT/server" ]] || die "server/ is missing"
  [[ -d "$PROJECT_ROOT/app" ]] || die "app/ is missing"
  [[ -f "$PROJECT_ROOT/docker-compose.yml" ]] || die "docker-compose.yml is missing"
  [[ -f "$PROJECT_ROOT/robot_arm/poses.json" ]] || die "robot_arm/poses.json is missing"
}

print_target() {
  printf 'Deploy host: %s\n' "$DEPLOY_HOST"
  printf 'Remote root: %s\n' "$REMOTE_ROOT"
  printf 'Serial: %s @ %s\n' "$SERIAL_DEVICE" "$SERIAL_BAUD"
}

print_whitelist() {
  cat <<'EOF'
Transfer whitelist:
  server/
  app/
  docker-compose.yml
Pose input (copied as one server file; directory is never traversed):
  robot_arm/poses.json -> server/config/poses.json
EOF
}

build_stage() {
  STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/causalroboqc-deploy.XXXXXX")"
  mkdir -p "$STAGE_DIR/server/config" "$STAGE_DIR/app"

  tar \
    --exclude='./.venv' \
    --exclude='*/__pycache__' \
    --exclude='*.pyc' \
    --exclude='*.pyo' \
    --exclude='*/.pytest_cache' \
    --exclude='*/.mypy_cache' \
    --exclude='*/.ruff_cache' \
    --exclude='./data/*.db' \
    --exclude='./data/*.db-*' \
    -C "$PROJECT_ROOT/server" -cf - . | tar -C "$STAGE_DIR/server" -xf -

  tar \
    --exclude='./.dart_tool' \
    --exclude='./build' \
    --exclude='./.flutter-plugins' \
    --exclude='./.flutter-plugins-dependencies' \
    --exclude='./.packages' \
    -C "$PROJECT_ROOT/app" -cf - . | tar -C "$STAGE_DIR/app" -xf -

  install -m 0644 \
    "$PROJECT_ROOT/robot_arm/poses.json" \
    "$STAGE_DIR/server/config/poses.json"
  install -m 0644 "$PROJECT_ROOT/docker-compose.yml" "$STAGE_DIR/docker-compose.yml"
}

sync_whitelist() {
  local dry_run="$1"
  local -a rsync_args=(-az --delete --itemize-changes -e "$RSYNC_RSH")
  local -a server_args
  local -a app_args

  if [[ "$dry_run" == "true" ]]; then
    rsync_args+=(--dry-run --mkpath)
  fi

  server_args=(
    "${rsync_args[@]}"
    --exclude='.venv/'
    --exclude='__pycache__/'
    --exclude='*.pyc'
    --exclude='*.pyo'
    --exclude='data/*.db'
    --exclude='data/*.db-*'
  )
  app_args=(
    "${rsync_args[@]}"
    --exclude='.dart_tool/'
    --exclude='build/'
    --exclude='.flutter-plugins'
    --exclude='.flutter-plugins-dependencies'
  )

  # Keep these as separate, explicit calls. Never replace them with PROJECT_ROOT/.
  rsync "${server_args[@]}" "$STAGE_DIR/server/" \
    "$DEPLOY_HOST:$REMOTE_ROOT/server/"
  rsync "${app_args[@]}" "$STAGE_DIR/app/" \
    "$DEPLOY_HOST:$REMOTE_ROOT/app/"
  rsync "${rsync_args[@]}" "$STAGE_DIR/docker-compose.yml" \
    "$DEPLOY_HOST:$REMOTE_ROOT/docker-compose.yml"
}

check_remote_environment() {
  local dry_run="$1"
  ssh "${SSH_OPTIONS[@]}" -- "$DEPLOY_HOST" bash -s -- \
    "$REMOTE_ROOT" "$SERIAL_DEVICE" "$dry_run" <<'REMOTE'
set -Eeuo pipefail
remote_root="$1"
serial_device="$2"
dry_run="$3"
remote_parent="${remote_root%/*}"
[[ -n "$remote_parent" ]] || remote_parent="/"

printf 'Architecture: '
uname -m
command -v docker >/dev/null || {
  echo 'Docker is not installed.' >&2
  exit 1
}
docker --version
docker compose version
docker info >/dev/null 2>&1 || {
  echo 'The deploy user cannot access the Docker daemon.' >&2
  echo 'Add the user to the docker group, then log out and back in.' >&2
  exit 1
}

printf 'Groups: '
id -nG
if id -nG | tr ' ' '\n' | grep -Fx dialout >/dev/null; then
  echo 'dialout: OK'
else
  echo 'dialout: missing (Docker runs as root, but adding it is recommended)'
fi

if [[ -e "$serial_device" ]]; then
  printf 'Serial: '
  ls -l -- "$serial_device"
else
  echo "Serial: disconnected ($serial_device is not present)"
fi

command -v rsync >/dev/null || {
  echo 'Remote rsync is required for deployment.' >&2
  exit 1
}

if [[ -e "$remote_root" && ! -d "$remote_root" ]]; then
  echo "REMOTE_ROOT exists but is not a directory: $remote_root" >&2
  exit 1
fi
if [[ -d "$remote_root" ]]; then
  echo "REMOTE_ROOT: exists ($remote_root)"
elif [[ "$dry_run" == "true" ]]; then
  rsync --help | grep -- '--mkpath' >/dev/null || {
    echo 'Remote rsync does not support the read-only --mkpath preview.' >&2
    exit 1
  }
  if [[ ! -d "$remote_parent" ]]; then
    echo "REMOTE_ROOT parent is missing; dry-run made no changes: $remote_parent" >&2
    exit 1
  fi
  echo "REMOTE_ROOT is absent; rsync will preview it without creating it: $remote_root"
else
  echo "REMOTE_ROOT: will create ($remote_root)"
fi
REMOTE
}

prepare_remote() {
  ssh "${SSH_OPTIONS[@]}" -- "$DEPLOY_HOST" bash -s -- "$REMOTE_ROOT" <<'REMOTE'
set -Eeuo pipefail
remote_root="$1"
mkdir -p -- "$remote_root"
REMOTE
}

start_remote() {
  ssh "${SSH_OPTIONS[@]}" -- "$DEPLOY_HOST" bash -s -- \
    "$REMOTE_ROOT" "$SERIAL_DEVICE" "$SERIAL_BAUD" <<'REMOTE'
set -Eeuo pipefail
remote_root="$1"
export SERIAL_DEVICE="$2"
export SERIAL_BAUD="$3"

cd -- "$remote_root"
docker compose config >/dev/null
docker compose up -d --build
docker compose ps

api_ok=false
app_ok=false
for _ in $(seq 1 20); do
  if curl -fsS http://127.0.0.1:8000/health >/dev/null 2>&1 ||
     curl -fsS http://127.0.0.1:8000/api/status >/dev/null 2>&1; then
    api_ok=true
  fi
  if curl -fsS http://127.0.0.1:8080/ >/dev/null 2>&1; then
    app_ok=true
  fi
  if [[ "$api_ok" == "true" && "$app_ok" == "true" ]]; then
    break
  fi
  sleep 2
done

[[ "$api_ok" == "true" ]] && echo 'FastAPI health: OK' || echo 'FastAPI health: not ready'
[[ "$app_ok" == "true" ]] && echo 'Flutter/nginx health: OK' || echo 'Flutter/nginx health: not ready'

if [[ -e "$SERIAL_DEVICE" ]]; then
  ls -l -- "$SERIAL_DEVICE"
else
  echo "Serial: disconnected ($SERIAL_DEVICE is not present; deployment remains active)"
fi

if [[ "$api_ok" != "true" || "$app_ok" != "true" ]]; then
  echo 'Deployment health check failed. Recent logs:' >&2
  docker compose logs --tail=50 >&2
  exit 1
fi
REMOTE
}

show_status() {
  print_target
  ssh "${SSH_OPTIONS[@]}" -- "$DEPLOY_HOST" bash -s -- \
    "$REMOTE_ROOT" "$SERIAL_DEVICE" "$SERIAL_BAUD" <<'REMOTE'
set -u
remote_root="$1"
export SERIAL_DEVICE="$2"
export SERIAL_BAUD="$3"

if [[ ! -d "$remote_root" ]]; then
  echo "Remote root is missing: $remote_root" >&2
  exit 1
fi

cd -- "$remote_root"
echo '--- docker compose ps ---'
docker compose ps
echo '--- docker compose logs (last 50 lines) ---'
docker compose logs --tail=50
echo '--- restart policies and named volume mounts ---'
mapfile -t container_ids < <(docker compose ps --all --quiet 2>/dev/null)
if (( ${#container_ids[@]} == 0 )); then
  echo 'No Compose containers found.'
else
  for container_id in "${container_ids[@]}"; do
    docker inspect --format \
      '{{.Name}} restart={{.HostConfig.RestartPolicy.Name}}{{range .Mounts}}{{if eq .Type "volume"}} volume={{.Name}}:{{.Destination}}{{end}}{{end}}' \
      "$container_id"
  done
fi
echo '--- FastAPI health ---'
curl -fsS http://127.0.0.1:8000/health 2>/dev/null ||
  curl -fsS http://127.0.0.1:8000/api/status 2>/dev/null ||
  echo 'FastAPI health endpoint is unavailable'
echo
echo '--- Flutter/nginx ---'
curl -fsS -o /dev/null -w 'HTTP %{http_code}\n' http://127.0.0.1:8080/ ||
  echo 'Flutter/nginx is unavailable'
echo '--- SQLite volumes ---'
docker compose config --volumes 2>/dev/null || true
docker volume ls --filter label=com.docker.compose.project
echo '--- Arduino serial ---'
echo "Configured: $SERIAL_DEVICE @ $SERIAL_BAUD"
if [[ -e "$SERIAL_DEVICE" ]]; then
  ls -l -- "$SERIAL_DEVICE"
else
  echo 'disconnected (device is not present; containers may still be healthy)'
fi
echo '--- user groups ---'
id
REMOTE
}

main() {
  local command="${1:-deploy}"
  validate_settings

  case "$command" in
    deploy)
      [[ $# -eq 0 ]] || { usage >&2; exit 2; }
      require_local_files
      print_target
      print_whitelist
      build_stage
      check_remote_environment false
      prepare_remote
      sync_whitelist false
      start_remote
      ;;
    --dry-run)
      [[ $# -eq 1 ]] || { usage >&2; exit 2; }
      require_local_files
      print_target
      print_whitelist
      build_stage
      echo 'Dry run: no remote directory or Docker state will be changed.'
      check_remote_environment true
      sync_whitelist true
      ;;
    status)
      [[ $# -eq 1 ]] || { usage >&2; exit 2; }
      show_status
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
