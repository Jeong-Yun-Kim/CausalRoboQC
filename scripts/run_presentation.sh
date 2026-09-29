#!/usr/bin/env bash
set -Eeuo pipefail
PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"
exec "${PRESENTATION_PYTHON:-$PROJECT_ROOT/.venv/bin/python}" "$PROJECT_ROOT/scripts/presentation_runner.py"
