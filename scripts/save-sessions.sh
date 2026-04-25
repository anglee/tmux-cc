#!/usr/bin/env bash
set -euo pipefail

# Snapshot the currently active CC sessions to ~/.tmux-cc/saved-sessions.json,
# keyed by stable tmux positional address (session_name:window_index.pane_index)
# so that a later restore step can replay `claude --resume <id>` into the
# matching panes after tmux-resurrect re-creates the layout.
#
# See issue #7.

ACTIVE_DIR="$HOME/.tmux-cc/active"
TARGET_FILE="$HOME/.tmux-cc/saved-sessions.json"
mkdir -p "$(dirname "$TARGET_FILE")"

TMP_ACC=$(mktemp /tmp/tmux-cc-save.XXXXXX)
PANE_MAP=$(mktemp /tmp/tmux-cc-panes.XXXXXX)
trap 'rm -f "$TMP_ACC" "$TMP_ACC.new" "$PANE_MAP" "$TARGET_FILE.tmp"' EXIT

NOW=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)

# Build a lookup from "%pane_id" -> "session:window.pane" for every pane on
# this tmux server. -a covers all sessions, including detached. Tab-separated
# so session names containing spaces don't break the awk lookup below.
tmux list-panes -aF $'#{pane_id}\t#{session_name}:#{window_index}.#{pane_index}' \
  > "$PANE_MAP" 2>/dev/null || true

if [[ ! -s "$PANE_MAP" ]]; then
  echo "Warning: no tmux panes found (is the tmux server running?)." >&2
fi

echo '{}' > "$TMP_ACC"
count=0
skipped_non_tmux=0

shopt -s nullglob
for f in "$ACTIVE_DIR"/*.json; do
  inner_pid=$(jq -r '.innerPid // .pid // 0' "$f")
  [[ "$inner_pid" -gt 0 ]] || continue
  kill -0 "$inner_pid" 2>/dev/null || continue

  pane_id=$(jq -r '.tmuxPane // ""' "$f")
  if [[ -z "$pane_id" ]]; then
    skipped_non_tmux=$((skipped_non_tmux + 1))
    continue
  fi

  addr=$(awk -F'\t' -v p="$pane_id" '$1 == p { print $2; exit }' "$PANE_MAP")
  [[ -n "$addr" ]] || continue

  sid=$(basename "$f" .json)

  # Collision tiebreak: if two alive registries resolve to the same addr
  # (e.g. parent + fork briefly overlapping in the same pane), last write
  # wins in glob order (alphabetical by session_id). Acceptable for phase 1;
  # follow-up may sort by statusUpdatedAt for determinism.
  jq --arg addr "$addr" \
     --arg sid "$sid" \
     --slurpfile reg "$f" \
     '. + { ($addr): { sessionId: $sid, cwd: $reg[0].cwd, model: $reg[0].model } }' \
     "$TMP_ACC" > "$TMP_ACC.new"
  mv "$TMP_ACC.new" "$TMP_ACC"

  count=$((count + 1))
done
shopt -u nullglob

jq --arg now "$NOW" '{ savedAt: $now, panes: . }' "$TMP_ACC" > "$TARGET_FILE.tmp"
# Defensive re-parse: the prior jq already produced valid JSON by construction,
# so this catches only post-write corruption (disk hiccup, etc.) before we
# overwrite the durable target. Intentional belt-and-suspenders — keep.
jq -e . "$TARGET_FILE.tmp" >/dev/null
mv "$TARGET_FILE.tmp" "$TARGET_FILE"

if [[ "$skipped_non_tmux" -gt 0 ]]; then
  echo "Saved $count CC session(s) (skipped $skipped_non_tmux non-tmux) to $TARGET_FILE"
else
  echo "Saved $count CC session(s) to $TARGET_FILE"
fi
