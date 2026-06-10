#!/bin/zsh
set -euo pipefail

SESSION_NAME="${1:-howmuch-dev}"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
API_PORT="${HOWMUCH_PORT:-${PORT:-8787}}"

if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
  echo "tmux session '$SESSION_NAME' already exists"
  echo "Attach with: tmux attach -t $SESSION_NAME"
  exit 0
fi

if lsof -nP -iTCP:"$API_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "Cannot start '$SESSION_NAME': API port $API_PORT is already in use."
  echo "Listening process:"
  lsof -nP -iTCP:"$API_PORT" -sTCP:LISTEN || true
  echo "Stop the existing process or set HOWMUCH_PORT to a different port before rerunning."
  exit 1
fi

tmux new-session -d -s "$SESSION_NAME" -c "$ROOT_DIR" "bun run api:dev"
tmux rename-window -t "$SESSION_NAME" api
tmux set-option -t "$SESSION_NAME" -g remain-on-exit on >/dev/null

if [ -f "$ROOT_DIR/apps/web/package.json" ]; then
  tmux new-window -t "$SESSION_NAME" -n web -c "$ROOT_DIR/apps/web" "bun run dev"
else
  tmux new-window -t "$SESSION_NAME" -n web-status -c "$ROOT_DIR" "zsh -lc 'printf \"apps/web is not present in this checkout yet.\nMerge the web track, then rerun bun run dev:stack in a fresh session if needed.\n\"; exec zsh'"
fi

echo "Started tmux session '$SESSION_NAME'"
echo "Attach with: tmux attach -t $SESSION_NAME"
