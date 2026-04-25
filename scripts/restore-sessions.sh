#!/usr/bin/env bash
set -euo pipefail

# Read ~/.tmux-cc/saved-sessions.json and replay `claude --resume <sessionId>`
# into each matching tmux pane. Companion to save-sessions.sh and
# tmux-resurrect: invoke after `prefix + Ctrl-r` has restored the tmux layout.
#
# Use --dry-run to preview without sending any keystrokes.
#
# Idempotency: panes are skipped if their foreground process isn't a known
# shell (bash/zsh/fish/sh/dash). This prevents typing into an already-running
# claude on accidental re-runs, but means non-allowlisted shells (nu, xonsh,
# etc.) won't restore — extend SHELL_ALLOWLIST if needed.
#
# `claude --resume` runs in whatever cwd the pane has (tmux-resurrect already
# restores pane cwd). The saved cwd is printed for visibility only.
#
# See issue #7.

DRY_RUN=false
case "${1:-}" in
  --dry-run) DRY_RUN=true ;;
  "") ;;
  -h|--help) echo "Usage: $(basename "$0") [--dry-run]"; exit 0 ;;
  *) echo "Usage: $(basename "$0") [--dry-run]" >&2; exit 1 ;;
esac

SAVED_FILE="$HOME/.tmux-cc/saved-sessions.json"

if [[ ! -f "$SAVED_FILE" ]]; then
  echo "No saved sessions file at $SAVED_FILE. Run save-sessions.sh first." >&2
  exit 1
fi

if ! jq -e . "$SAVED_FILE" >/dev/null 2>&1; then
  echo "Saved file is malformed JSON: $SAVED_FILE" >&2
  exit 1
fi

PANE_LIST=$(mktemp /tmp/tmux-cc-restore-panes.XXXXXX)
trap 'rm -f "$PANE_LIST"' EXIT
tmux list-panes -aF $'#{session_name}:#{window_index}.#{pane_index}\t#{pane_current_command}' \
  > "$PANE_LIST" 2>/dev/null || true

if [[ ! -s "$PANE_LIST" ]]; then
  echo "Warning: no tmux panes found (is the tmux server running?)." >&2
fi

prefix=""
if $DRY_RUN; then prefix="[dry-run] "; fi

# Foreground processes that indicate "pane is at a shell prompt, safe to type".
SHELL_ALLOWLIST_RE='^(bash|zsh|fish|sh|dash)$'

total=0
restored=0
skipped=0

while IFS=$'\t' read -r addr sid cwd; do
  [[ -n "$addr" ]] || continue
  total=$((total + 1))

  pane_cmd=$(awk -F'\t' -v a="$addr" '$1 == a { print $2; exit }' "$PANE_LIST")

  if [[ -z "$pane_cmd" ]]; then
    echo "${prefix}${addr} -> SKIP (no such pane)"
    skipped=$((skipped + 1))
    continue
  fi

  if ! [[ "$pane_cmd" =~ $SHELL_ALLOWLIST_RE ]]; then
    echo "${prefix}${addr} -> SKIP (not at shell prompt: $pane_cmd)"
    skipped=$((skipped + 1))
    continue
  fi

  cmd="claude --resume $sid"
  echo "${prefix}${addr} -> ${cmd}    (cwd: ${cwd})"

  if ! $DRY_RUN; then
    # C-u first to clear any partial input at the prompt. Any send-keys
    # failure (e.g. pane vanished between list-panes and now) is per-pane,
    # so we log and continue rather than abort the whole restore.
    if ! tmux send-keys -t "$addr" C-u 2>/dev/null \
       || ! tmux send-keys -t "$addr" "$cmd" Enter 2>/dev/null; then
      echo "${prefix}${addr} -> SKIP (send-keys failed)"
      skipped=$((skipped + 1))
      continue
    fi
  fi

  restored=$((restored + 1))
done < <(jq -r '(.panes // {}) | to_entries[] | [.key, .value.sessionId, (.value.cwd // "<unknown>")] | @tsv' "$SAVED_FILE")

verb="Restored"
if $DRY_RUN; then verb="Would restore"; fi

echo "${prefix}${verb} ${restored} of ${total} session(s); ${skipped} skipped."
