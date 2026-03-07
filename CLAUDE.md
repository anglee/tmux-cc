# tmux-cc

A tmux plugin for switching between active Claude Code sessions via an fzf popup.

## Repo structure

```
tmux-cc.tmux          # Plugin entry point. Sourced by tmux on load. Binds prefix+C to the switcher popup.
scripts/
  hooks.sh            # CLI tool (install|uninstall|status) that manages Claude Code lifecycle hooks.
  switcher.sh         # The fzf-based session switcher UI. Also serves fzf callbacks (--render, --cycle, etc).
```

## Runtime data (not in repo)

```
~/.tmux-cc/
  hooks/
    session-start.sh  # Hook: writes session JSON on start
    session-end.sh    # Hook: removes session JSON on end
    session-status.sh # Hook: updates status field (working/waiting/idle)
  active/
    {session-id}.json # One file per active session, written/updated by hooks
  tmux-cc.conf        # Display preferences (id/directory/tmux/preview/sort modes)
```

The hook scripts under `~/.tmux-cc/hooks/` are **generated** by `hooks.sh install` (written via heredocs in `write_hook_scripts()`). They are not checked into the repo. If you change the hook logic, edit the heredocs in `hooks.sh` and re-run `install`.

## How the pieces connect

1. **hooks.sh install** does two things:
   - Writes the three hook shell scripts to `~/.tmux-cc/hooks/`
   - Adds entries to `~/.claude/settings.json` under `.hooks` for events: `SessionStart`, `SessionEnd`, `Stop`, `UserPromptSubmit`, `PostToolUse`, `Notification`

2. **Claude Code** calls these hooks during its lifecycle. Each hook receives JSON on stdin with fields like `session_id`, `cwd`, `model`, `hook_event_name`, etc.

3. **session-start.sh** walks up the process tree via `ps -o ppid=` to find the Claude Code PID. It writes a JSON file to `~/.tmux-cc/active/{session_id}.json` containing pid, cwd, model, tmux pane ID, status, and timestamps. It skips forked sessions (detected via `--fork-session` in the parent cmdline).

4. **session-status.sh** maps hook events to statuses:
   - `Stop` -> idle
   - `UserPromptSubmit`, `PostToolUse` -> working
   - `Notification` -> idle (if idle_prompt) or waiting (otherwise)

   It updates the JSON file in-place using jq.

5. **switcher.sh** is the UI. It:
   - Reads all `~/.tmux-cc/active/*.json` files
   - Validates each session is still alive (`kill -0`)
   - Deduplicates by PID (prefers non-startup source, merges model info from startup entries)
   - Sorts by status priority (waiting > working > idle), then by recent activity (default) or alphabetically by cwd
   - Cross-references tmux pane IDs with `tmux list-panes` to get session/window names
   - Optionally fetches session title and last assistant message from `~/.claude/projects/` JSONL logs in parallel background jobs via `fetch_snippet()`, which calls `get_title()` (extracts `customTitle` from `"type":"custom-title"` JSONL entries written by `/rename`) and `get_last_message()` (extracts last assistant text). Results are stored as `{sid}.title` and `{sid}.msg` files in the preview temp dir, then merged into the tmpfile by `merge_previews()`
   - Renders everything into fzf with live pane preview

6. **switcher.sh** also handles fzf callbacks. fzf's `--bind` options invoke the same script with flags like `--cycle id`, `--cycle sort`, `--resort <tmpfile>`, `--render <tmpfile>`, `--render-header`, and `--toggle-preview`. This lets the user change display settings and sort order without leaving fzf.

## Key design decisions

- **Bash 3 compatible**: no associative arrays (`declare -A`). macOS ships bash 3.2. Lookups use temp files + awk/grep instead.
- **Cross-platform**: uses `ps -o ppid=` instead of `/proc`. Uses a `reverse_lines` helper that picks `tac` (Linux) or `tail -r` (macOS). Avoids gawk-only features (no `asorti`); sorting uses `awk | sort | cut` pipeline.
- **Unit separator delimited**: internal data uses `\x1f` (ASCII unit separator) as field delimiter to avoid conflicts with filenames/paths that contain spaces, tabs, or other common delimiters.
- **Atomic writes**: session JSON files are written to a temp file then `mv`'d to avoid partial reads.
- **fzf `|| true`**: fzf returns non-zero on Esc/no-selection. With `set -e`, the `selected=$(...)` assignment would abort the script, so the fzf call uses `|| true` and checks `$selected` emptiness afterward.

## Common modifications

- **Add a new status mapping**: edit the `case "$HOOK_EVENT"` block in the `session-status.sh` heredoc in `hooks.sh`, then re-run `hooks.sh install`.
- **Add a new display column**: add a field to the `printf` in `main()`, update `render_lines()` to read and display it, and update `merge_previews()` to preserve it.
- **Change the keybinding**: users set `@tmux-cc-key` in tmux.conf. The default is `C` (defined in `tmux-cc.tmux`).
- **Change sort order**: there are two sort modes (`recent` and `alpha`) implemented in both `main()` (initial sort from deduped_file) and `resort_tmpfile()` (re-sort from tmpfile via ctrl-s). Both must be kept in sync. Sort keys: status priority (1=waiting, 2=working, 3=idle), then either statusUpdatedAt descending (recent) or cwd alphabetical + pane presence (alpha).

## Dependencies

- bash (3.2+), awk, sort, cut, jq, fzf, tmux (3.2+)
