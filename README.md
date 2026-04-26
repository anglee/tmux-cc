# tmux-cc

A tmux plugin for managing multiple [Claude Code](https://docs.anthropic.com/en/docs/claude-code) sessions. Quickly see which sessions are active, what they're doing, and jump between them.

<img width="1351" height="859" alt="image" src="https://github.com/user-attachments/assets/346b3e13-3936-4c5c-bc2d-1186f70c012c" />


## Features

- **Session switcher** -- fuzzy-find across all active Claude Code sessions with `prefix + C`
- **Live status** -- see at a glance which sessions are working, waiting for input, or idle
- **Pane preview** -- the fzf preview pane shows a live snapshot of each session's tmux pane
- **Session names** -- shows the custom session name (from `/rename`) alongside the last message
- **Last message preview** -- optionally show a snippet of Claude's most recent response
- **Sortable** -- toggle between recent-activity and alphabetical sort with `ctrl-s`
- **Configurable columns** -- toggle display of session ID, directory, tmux location, and message preview with keyboard shortcuts
- **Environment-aware** -- non-tmux sessions (VS Code, plain iTerm2 / Terminal) show their environment label (`vscode`, `iTerm.app`, etc.) instead of a generic "(no pane)"

## Prerequisites

- tmux 3.2+ (for `display-popup`)
- [fzf](https://github.com/junegunn/fzf)
- [jq](https://jqlang.github.io/jq/)

Works on both macOS and Linux.

## Installation

### 1. Clone the repo

```sh
git clone https://github.com/anglee/tmux-cc.git ~/.tmux/plugins/tmux-cc
```

### 2. Add to tmux.conf

```tmux
run '~/.tmux/plugins/tmux-cc/tmux-cc.tmux'
```

Then reload your config:

```sh
tmux source-file ~/.tmux.conf
```

### 3. Install the Claude Code hooks

```sh
~/.tmux/plugins/tmux-cc/scripts/hooks.sh install
```

This registers lifecycle hooks in `~/.claude/settings.json` that track session state. You need to **restart any running Claude Code sessions** for the hooks to take effect.

To check if hooks are installed:

```sh
~/.tmux/plugins/tmux-cc/scripts/hooks.sh status
```

To remove the hooks:

```sh
~/.tmux/plugins/tmux-cc/scripts/hooks.sh uninstall
```

## Usage

Press `prefix + C` to open the session switcher in a tmux popup.

### Switcher controls

| Key | Action |
|---|---|
| `Enter` | Jump to the selected session's tmux pane |
| `Esc` | Close the switcher |
| `ctrl-s` | Toggle sort order: recent (most recently active first) / alpha (by directory name) |
| `ctrl-i` | Cycle session ID display: short / complete / hidden |
| `ctrl-d` | Cycle directory display: full path / basename / hidden |
| `ctrl-t` | Cycle tmux location display: session+window / session / window / win.pane / session+win.pane / hidden |
| `ctrl-l` | Toggle last assistant message preview |
| `ctrl-p` | Toggle the pane snapshot preview panel |

### Session statuses

| Status | Meaning |
|---|---|
| ● **working** (blue) | Claude is actively responding or using tools |
| ◐ **waiting** (red) | Claude needs input (e.g. permission prompt) |
| ○ **idle** (green) | Session is idle, waiting for your next prompt |

## Configuration

### Custom keybinding

By default the switcher is bound to `prefix + C`. To change it, set the `@tmux-cc-key` option in your `tmux.conf` before loading the plugin:

```tmux
set -g @tmux-cc-key S
run '~/.tmux/plugins/tmux-cc/tmux-cc.tmux'
```

### Display preferences

Column visibility preferences are persisted in `~/.tmux-cc/tmux-cc.conf` and can be changed live using the keyboard shortcuts listed above.

## Save/Restore Sessions Across Reboots

[tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect) saves and restores tmux sessions/windows/panes across reboots. It doesn't know about Claude Code, so tmux-cc ships companion scripts that pair with it.

**Before reboot:**

1. `prefix + Ctrl-s` — tmux-resurrect saves the tmux layout.
2. `~/.tmux/plugins/tmux-cc/scripts/save-sessions.sh` — snapshots active CC sessions.

**After reboot:**

1. `prefix + Ctrl-r` — tmux-resurrect restores the tmux layout.
2. `~/.tmux/plugins/tmux-cc/scripts/restore-sessions.sh` — replays `claude --resume <sessionId>` into each matching pane.

`save-sessions.sh` writes `~/.tmux-cc/saved-sessions.json` mapping each live CC session to its tmux pane coordinates (`session:window.pane`) — coordinates that are stable across restore even though pane ids change. `restore-sessions.sh` reads the file back and runs `claude --resume <sessionId>` in the pane at each saved address.

Use `restore-sessions.sh --dry-run` to preview what would be restored without sending any keystrokes.

> Auto-wiring these scripts into resurrect's pre-save and post-restore hooks (so you don't have to remember the second step in each list) is tracked in [#7](https://github.com/anglee/tmux-cc/issues/7).

## How it works

1. `hooks.sh install` writes three small hook scripts to `~/.tmux-cc/hooks/` and registers them in `~/.claude/settings.json`.
2. When a Claude Code session starts, the **session-start** hook writes a JSON file to `~/.tmux-cc/active/` containing the session's PID, working directory, model, tmux pane, and status.
3. As you interact with a session, the **session-status** hook updates the status field (working/waiting/idle).
4. When a session ends, the **session-end** hook removes the JSON file.
5. The switcher reads these JSON files, cross-references them with tmux pane info, and presents everything in an fzf interface.

## Uninstalling

```sh
# Remove the hooks from Claude Code settings
~/.tmux/plugins/tmux-cc/scripts/hooks.sh uninstall

# Remove the plugin line from ~/.tmux.conf, then reload
tmux source-file ~/.tmux.conf
```

## License

MIT
