#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_DIR="$ROOT_DIR/.venv"
PYTHON_BIN="${PYTHON_BIN:-python3.11}"

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "错误: 未检测到 ffmpeg，请先安装 ffmpeg。"
  exit 1
fi

if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  echo "错误: 未检测到 $PYTHON_BIN，请安装 Python 3.11 或设置 PYTHON_BIN 环境变量。"
  exit 1
fi

if [ ! -d "$VENV_DIR" ]; then
  "$PYTHON_BIN" -m venv "$VENV_DIR"
fi

# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"

python -m pip install --upgrade pip
python -m pip install -r "$ROOT_DIR/requirements.txt"

exec uvicorn app:app --host 0.0.0.0 --port 8765 --app-dir "$ROOT_DIR"
