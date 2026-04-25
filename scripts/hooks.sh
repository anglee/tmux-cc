#!/usr/bin/env bash
set -euo pipefail

TMUX_CC_DIR="$HOME/.tmux-cc"
HOOKS_DIR="$TMUX_CC_DIR/hooks"
ACTIVE_DIR="$TMUX_CC_DIR/active"
SETTINGS_FILE="$HOME/.claude/settings.json"

HOOK_CMD_START="$HOOKS_DIR/session-start.sh"
HOOK_CMD_END="$HOOKS_DIR/session-end.sh"
HOOK_CMD_STATUS="$HOOKS_DIR/session-status.sh"

usage() {
  echo "Usage: $(basename "$0") <install|uninstall|status>"
  echo ""
  echo "Commands:"
  echo "  install     Install CC session hooks into ~/.claude/settings.json"
  echo "  uninstall   Remove CC session hooks and clean up ~/.tmux-cc/"
  echo "  status      Check if hooks are installed (exits 0 if enabled, 1 if not)"
  exit 1
}

ensure_settings() {
  mkdir -p "$(dirname "$SETTINGS_FILE")"
  [[ -f "$SETTINGS_FILE" ]] || echo '{}' > "$SETTINGS_FILE"
}

write_hook_scripts() {
  mkdir -p "$HOOKS_DIR" "$ACTIVE_DIR"

  cat > "$HOOKS_DIR/session-start.sh" << 'HOOKEOF'
#!/bin/bash
set -euo pipefail

ACTIVE_DIR="$HOME/.tmux-cc/active"
INPUT=$(cat)

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
MODEL=$(echo "$INPUT" | jq -r '.model // empty')
SOURCE=$(echo "$INPUT" | jq -r '.source // "cli"')

get_ppid() { ps -o ppid= -p "$1" 2>/dev/null | tr -d ' '; }
get_cmdline() { ps -o args= -p "$1" 2>/dev/null; }

INNER_PID=$(get_ppid "$PPID")
OUTER_PID=$(get_ppid "$INNER_PID")
TMUX_PANE_ID="${TMUX_PANE:-}"

# Skip subagent processes (reparented to init after parent exits).
# Empty OUTER_PID means ps couldn't find the ancestor (already gone), which
# is the same signal — and `[[ "" -le 1 ]]` would abort under set -e.
if [[ -z "$OUTER_PID" || "$OUTER_PID" -le 1 ]]; then
  exit 0
fi

# Skip --fork-session SessionStart events: CC fires SessionStart for the
# fork using the *parent's* session_id, which would clobber the parent's
# registry file. The hook is spawned directly by claude here, so the flag
# lives in $PPID's argv; walk the near chain to also handle a shell-wrapper
# variant.
if [[ "$SOURCE" != "startup" ]]; then
  for p in "$PPID" "$INNER_PID" "$OUTER_PID"; do
    if [[ -n "$p" ]] && get_cmdline "$p" | grep -q -- '--fork-session'; then
      exit 0
    fi
  done
fi

TMP_FILE="$ACTIVE_DIR/.${SESSION_ID}.tmp"
TARGET_FILE="$ACTIVE_DIR/${SESSION_ID}.json"

cat > "$TMP_FILE" <<ENTRY
{
  "pid": $INNER_PID,
  "innerPid": $INNER_PID,
  "outerPid": $OUTER_PID,
  "cwd": "$(echo "$CWD" | sed 's/"/\\"/g')",
  "model": $([ -n "$MODEL" ] && echo "\"$MODEL\"" || echo "null"),
  "source": "$SOURCE",
  "tmuxPane": $([ -n "$TMUX_PANE_ID" ] && echo "\"$TMUX_PANE_ID\"" || echo "null"),
  "startedAt": "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)",
  "status": "idle",
  "statusDetail": null,
  "statusUpdatedAt": "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
}
ENTRY

mv "$TMP_FILE" "$TARGET_FILE"
HOOKEOF
  chmod 755 "$HOOKS_DIR/session-start.sh"

  cat > "$HOOKS_DIR/session-end.sh" << 'HOOKEOF'
#!/bin/bash
set -euo pipefail

ACTIVE_DIR="$HOME/.tmux-cc/active"
INPUT=$(cat)

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id')

rm -f "$ACTIVE_DIR/${SESSION_ID}.json"
HOOKEOF
  chmod 755 "$HOOKS_DIR/session-end.sh"

  cat > "$HOOKS_DIR/session-status.sh" << 'HOOKEOF'
#!/bin/bash
set -euo pipefail

ACTIVE_DIR="$HOME/.tmux-cc/active"
INPUT=$(cat)

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id')
HOOK_EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // empty')
TARGET_FILE="$ACTIVE_DIR/${SESSION_ID}.json"
NOW=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)

# Fallback registration for forked sessions. CC's fork SessionStart fires
# with the parent's session_id (skipped in session-start.sh to avoid
# clobbering the parent), so the fork never gets its own registry file.
# UserPromptSubmit is the first event to carry the fork's real session_id
# — register on first sight here so the fork shows up in the switcher.
if [[ ! -f "$TARGET_FILE" ]]; then
  if [[ "$HOOK_EVENT" != "UserPromptSubmit" ]]; then
    exit 0
  fi
  CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
  get_ppid() { ps -o ppid= -p "$1" 2>/dev/null | tr -d ' '; }
  INNER_PID=$(get_ppid "$PPID")
  OUTER_PID=$(get_ppid "$INNER_PID")
  TMUX_PANE_ID="${TMUX_PANE:-}"
  # Same subagent guard as session-start.sh
  if [[ -z "$OUTER_PID" || "$OUTER_PID" -le 1 ]]; then
    exit 0
  fi
  TMP_FILE="$ACTIVE_DIR/.${SESSION_ID}.tmp"
  cat > "$TMP_FILE" <<ENTRY
{
  "pid": $INNER_PID,
  "innerPid": $INNER_PID,
  "outerPid": $OUTER_PID,
  "cwd": "$(echo "$CWD" | sed 's/"/\\"/g')",
  "model": null,
  "source": "fork",
  "tmuxPane": $([ -n "$TMUX_PANE_ID" ] && echo "\"$TMUX_PANE_ID\"" || echo "null"),
  "startedAt": "$NOW",
  "status": "idle",
  "statusDetail": null,
  "statusUpdatedAt": "$NOW"
}
ENTRY
  mv "$TMP_FILE" "$TARGET_FILE"
fi

case "$HOOK_EVENT" in
  Stop)
    STATUS="idle"; DETAIL="null"
    ;;
  UserPromptSubmit|PostToolUse)
    STATUS="working"; DETAIL="null"
    ;;
  Notification)
    NOTIF_TYPE=$(echo "$INPUT" | jq -r '.notification_type // empty')
    case "$NOTIF_TYPE" in
      idle_prompt) STATUS="idle"; DETAIL="null" ;;
      *) STATUS="waiting"; DETAIL="\"$NOTIF_TYPE\"" ;;
    esac
    ;;
  *)
    exit 0
    ;;
esac

TMP=$(mktemp "$TARGET_FILE.XXXXXX")
jq --arg s "$STATUS" --arg now "$NOW" --argjson d "$DETAIL" \
  '.status = $s | .statusDetail = $d | .statusUpdatedAt = $now' \
  "$TARGET_FILE" > "$TMP" && mv "$TMP" "$TARGET_FILE" || rm -f "$TMP"
HOOKEOF
  chmod 755 "$HOOKS_DIR/session-status.sh"
}

install_settings() {
  ensure_settings
  local tmp
  tmp=$(mktemp)
  jq --arg start "$HOOK_CMD_START" \
    --arg endhook "$HOOK_CMD_END" \
    --arg status "$HOOK_CMD_STATUS" \
  '
    def has_cmd($type; $cmd):
      [.hooks[$type][]?.hooks[]?.command] | any(. == $cmd);

    def add_if_missing($type; $cmd; $matcher):
      if has_cmd($type; $cmd) then .
      else .hooks[$type] = (.hooks[$type] // []) +
        [{"matcher": $matcher, "hooks": [{"type": "command", "command": $cmd}]}]
      end;

    .hooks = (.hooks // {}) |
    add_if_missing("SessionStart"; $start; "") |
    add_if_missing("SessionEnd"; $endhook; "") |
    add_if_missing("Stop"; $status; "") |
    add_if_missing("UserPromptSubmit"; $status; "") |
    add_if_missing("PostToolUse"; $status; "") |
    add_if_missing("Notification"; $status; "")
  ' "$SETTINGS_FILE" > "$tmp" && mv "$tmp" "$SETTINGS_FILE"
}

uninstall_settings() {
  [[ -f "$SETTINGS_FILE" ]] || return 0
  local tmp
  tmp=$(mktemp)
  jq --arg start "$HOOK_CMD_START" \
    --arg endhook "$HOOK_CMD_END" \
    --arg status "$HOOK_CMD_STATUS" \
  '
    def remove_cmd($type; $cmd):
      [.hooks[$type][]? |
        .hooks = [.hooks[]? | select(.command != $cmd)] |
        select(.hooks | length > 0)];

    def clean($type; $cmd):
      .hooks[$type] = remove_cmd($type; $cmd) |
      if (.hooks[$type] | length) == 0 then del(.hooks[$type]) else . end;

    if .hooks then
      clean("SessionStart"; $start) |
      clean("SessionEnd"; $endhook) |
      clean("Stop"; $status) |
      clean("UserPromptSubmit"; $status) |
      clean("PostToolUse"; $status) |
      clean("Notification"; $status) |
      if (.hooks | length) == 0 then del(.hooks) else . end
    else . end
  ' "$SETTINGS_FILE" > "$tmp" && mv "$tmp" "$SETTINGS_FILE"
}

check_status() {
  [[ -f "$SETTINGS_FILE" ]] || return 1
  jq -e --arg start "$HOOK_CMD_START" \
    --arg end "$HOOK_CMD_END" \
    --arg status "$HOOK_CMD_STATUS" \
  '
    def has_cmd($type; $cmd):
      [.hooks[$type][]?.hooks[]?.command] | any(. == $cmd);

    has_cmd("SessionStart"; $start) and
    has_cmd("SessionEnd"; $end) and
    has_cmd("Stop"; $status) and
    has_cmd("UserPromptSubmit"; $status) and
    has_cmd("PostToolUse"; $status) and
    has_cmd("Notification"; $status)
  ' "$SETTINGS_FILE" >/dev/null 2>&1
}

cmd_install() {
  write_hook_scripts
  install_settings
  echo "Hooks installed. Restart existing CC sessions for changes to take effect."
}

cmd_uninstall() {
  uninstall_settings
  rm -rf "$ACTIVE_DIR" "$HOOKS_DIR"
  echo "Hooks removed."
}

cmd_status() {
  if check_status; then
    echo "enabled"
  else
    echo "disabled"
  fi
}

case "${1:-}" in
  install)  cmd_install ;;
  uninstall) cmd_uninstall ;;
  status)   cmd_status ;;
  *)        usage ;;
esac
