#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
python_bin=${AI_PYTHON:-.venv/bin/python}
export OLLAMA_BASE_URL=${OLLAMA_BASE_URL:-http://127.0.0.1:11434}
export OLLAMA_MODEL=${OLLAMA_MODEL:-qwen3:4b-instruct}
case "${1:---start}" in
  --dry-run|--check)
    printf 'Prepared: check Ollama /api/tags for %s, then %s -m uvicorn ai.app.main:app --host 0.0.0.0 --port 9000\n' "$OLLAMA_MODEL" "$python_bin"
    exit 0 ;;
  --start) ;;
  *) printf 'Usage: %s [--start|--dry-run|--check]\n' "$0" >&2; exit 2 ;;
esac
"$python_bin" - <<'PY'
import json, os, urllib.request
url = os.environ['OLLAMA_BASE_URL'].rstrip('/') + '/api/tags'
try:
    with urllib.request.urlopen(url, timeout=3) as response:
        models = json.load(response).get('models', [])
    if os.environ['OLLAMA_MODEL'] not in {m.get('name') for m in models}:
        raise SystemExit('Required model missing: run ollama pull ' + os.environ['OLLAMA_MODEL'])
except OSError as exc:
    raise SystemExit('Start Ollama before running this script: ' + str(exc))
PY
exec "$python_bin" -m uvicorn ai.app.main:app --host 0.0.0.0 --port 9000
