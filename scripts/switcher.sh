#!/usr/bin/env bash
set -euo pipefail

ACTIVE_DIR="$HOME/.tmux-cc/active"
PROJECTS_DIR="$HOME/.claude/projects"
CONF_FILE="$HOME/.tmux-cc/tmux-cc.conf"
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

GREEN=$'\033[32m'
RED=$'\033[31m'
YELLOW=$'\033[33m'
MAGENTA=$'\033[35m'
LIGHT_BLUE=$'\033[38;5;117m'
DARK_GREEN=$'\033[38;5;22m'
GRAY=$'\033[90m'
CYAN=$'\033[36m'
WHITE=$'\033[97m'
RESET=$'\033[0m'

DEFAULT_ID=short
DEFAULT_DIR=complete
DEFAULT_TMUX=session+window
DEFAULT_PREVIEW=show
DEFAULT_SORT=recent
FS=$'\x1f'

# --- Config ----

read_conf() {
  local id_mode="$DEFAULT_ID" dir_mode="$DEFAULT_DIR" tmux_mode="$DEFAULT_TMUX" preview_mode="$DEFAULT_PREVIEW" sort_mode="$DEFAULT_SORT"
  if [[ -f "$CONF_FILE" ]]; then
    while IFS='=' read -r key value; do
      case "$key" in
        id) id_mode="$value" ;;
        directory) dir_mode="$value" ;;
        tmux) tmux_mode="$value" ;;
        preview) preview_mode="$value" ;;
        sort) sort_mode="$value" ;;
      esac
    done < "$CONF_FILE"
  fi
  echo "$id_mode $dir_mode $tmux_mode $preview_mode $sort_mode"
}

write_conf() {
  mkdir -p "$(dirname "$CONF_FILE")"
  printf 'id=%s\ndirectory=%s\ntmux=%s\npreview=%s\nsort=%s\n' "$1" "$2" "$3" "$4" "$5" > "$CONF_FILE"
}

cycle_setting() {
  local field="$1"
  local id_mode dir_mode tmux_mode preview_mode sort_mode
  read -r id_mode dir_mode tmux_mode preview_mode sort_mode <<< "$(read_conf)"

  case "$field" in
    id)
      case "$id_mode" in
        short) id_mode=complete ;;
        complete) id_mode=none ;;
        *) id_mode=short ;;
      esac ;;
    directory)
      case "$dir_mode" in
        complete) dir_mode=short ;;
        short) dir_mode=none ;;
        *) dir_mode=complete ;;
      esac ;;
    tmux)
      case "$tmux_mode" in
        session+window) tmux_mode=session ;;
        session) tmux_mode=window ;;
        window) tmux_mode=win.pane ;;
        win.pane) tmux_mode=session+win.pane ;;
        session+win.pane) tmux_mode=none ;;
        *) tmux_mode=session+window ;;
      esac ;;
    preview)
      case "$preview_mode" in
        show) preview_mode=hide ;;
        *) preview_mode=show ;;
      esac ;;
    sort)
      case "$sort_mode" in
        recent) sort_mode=alpha ;;
        *) sort_mode=recent ;;
      esac ;;
  esac

  write_conf "$id_mode" "$dir_mode" "$tmux_mode" "$preview_mode" "$sort_mode"
}

# --- Render ---

render_header() {
  local id_mode dir_mode tmux_mode preview_mode sort_mode
  read -r id_mode dir_mode tmux_mode preview_mode sort_mode <<< "$(read_conf)"
  echo "ctrl-s: sort($sort_mode) | ctrl-i: ID($id_mode) | ctrl-d: directory($dir_mode) | ctrl-t: tmux($tmux_mode) | ctrl-l: last message($preview_mode) | ctrl-p: preview snapshot"
}

render_lines() {
  local tmpfile="$1"
  local id_mode dir_mode tmux_mode preview_mode _sort
  read -r id_mode dir_mode tmux_mode preview_mode _sort <<< "$(read_conf)"

  while IFS="$FS" read -r sid cwd status model tmux_session tmux_winname tmux_winidx tmux_paneidx tmux_target updated title msg; do
    local line=""

    case "$status" in
      working) line+="${LIGHT_BLUE}●${RESET} working" ;;
      waiting) line+="${RED}◐${RESET} waiting" ;;
      idle)    line+="${GREEN}○${RESET} idle   " ;;
      *)       line+="${GRAY}○${RESET} -------" ;;
    esac

    case "$id_mode" in
      short)    line+="  ${MAGENTA}${sid:0:8}${RESET}" ;;
      complete) line+="  ${MAGENTA}${sid}${RESET}" ;;
    esac

    case "$dir_mode" in
      complete) line+="  ${YELLOW}${cwd//#$HOME/\~}${RESET}" ;;
      short)    line+="  ${YELLOW}$(basename "$cwd")${RESET}" ;;
    esac

    if [[ "$tmux_mode" != "none" ]]; then
      if [[ -n "$tmux_target" ]]; then
        case "$tmux_mode" in
          session+window)    line+="  ${GREEN}${tmux_session}${RESET}:${LIGHT_BLUE}${tmux_winname}${RESET}" ;;
          session)           line+="  ${GREEN}${tmux_session}${RESET}" ;;
          window)            line+="  ${LIGHT_BLUE}${tmux_winname}${RESET}" ;;
          win.pane)          line+="  ${GREEN}${tmux_winidx}.${tmux_paneidx}${RESET}" ;;
          session+win.pane)  line+="  ${GREEN}${tmux_session}${RESET}:${LIGHT_BLUE}${tmux_winidx}.${tmux_paneidx}${RESET}" ;;
          *)                 line+="  ${GREEN}${tmux_session}${RESET}:${LIGHT_BLUE}${tmux_winname}${RESET}" ;;
        esac
      else
        local label="(no pane)"
        if [[ -f "$ACTIVE_DIR/${sid}.json" ]]; then
          local derived
          derived=$(jq -r '
            if (.entrypoint // "") == "claude-vscode" then "vscode"
            elif (.termProgram // "") != "" then .termProgram
            else ""
            end
          ' "$ACTIVE_DIR/${sid}.json" 2>/dev/null)
          [[ -n "$derived" ]] && label="$derived"
        fi
        line+="  ${DARK_GREEN}${label}${RESET}"
      fi
    fi

    if [[ "$preview_mode" == "show" ]]; then
      [[ -n "$title" ]] && line+="  ${WHITE}[${title}]${RESET}"
      if [[ -n "$msg" ]]; then
        [[ -n "$title" ]] && line+=" ${GRAY}${msg}${RESET}" || line+="  ${GRAY}${msg}${RESET}"
      fi
    fi

    local model_display="${model#claude-}"
    line+="  ${CYAN}${model_display}${RESET}"

    [[ -n "$tmux_target" ]] && line+=$'\t'"$tmux_target"

    echo "$line"
  done < "$tmpfile"
}

# --- Helpers ---

reverse_lines() {
  if command -v tac >/dev/null 2>&1; then
    tac "$1"
  else
    tail -r "$1"
  fi
}

encode_cwd() {
  echo "$1" | sed 's|[/.]|-|g'
}

get_title() {
  local jsonl_file="$1"
  grep '"type":"custom-title"\|"type": "custom-title"' "$jsonl_file" \
    | tail -1 \
    | jq -r '.customTitle // empty' 2>/dev/null
}

get_last_message() {
  local jsonl_file="$1"
  reverse_lines "$jsonl_file" \
    | grep '"type":"assistant"\|"type": "assistant"' \
    | head -20 \
    | jq -r '
      .message.content
      | if type == "string" then .
        elif type == "array" then
          [.[] | select(.type == "text") | .text] | join("")
        else ""
        end
      | select(length > 0)
      | gsub("\n"; " ")
      | gsub("\t"; " ")
      | if length > 100 then .[:100] + "..." else . end
    ' 2>/dev/null \
    | head -1
}

fetch_snippet() {
  local session_id="$1" cwd="$2" preview_dir="$3"
  local encoded
  encoded=$(encode_cwd "$cwd")
  local jsonl_file="$PROJECTS_DIR/$encoded/${session_id}.jsonl"

  [[ -f "$jsonl_file" ]] || return 1

  get_title "$jsonl_file" > "$preview_dir/${session_id}.title"
  get_last_message "$jsonl_file" > "$preview_dir/${session_id}.msg"
}

merge_previews() {
  local tmpfile="$1" preview_dir="$2"
  local merged
  merged=$(mktemp /tmp/tmux-cc-merged.XXXXXX)
  while IFS="$FS" read -r sid cwd status model tmux_session tmux_winname tmux_winidx tmux_paneidx tmux_target updated _ _; do
    local title="" msg=""
    [[ -s "$preview_dir/${sid}.title" ]] && title=$(< "$preview_dir/${sid}.title")
    [[ -s "$preview_dir/${sid}.msg" ]] && msg=$(< "$preview_dir/${sid}.msg")
    printf "%s${FS}%s${FS}%s${FS}%s${FS}%s${FS}%s${FS}%s${FS}%s${FS}%s${FS}%s${FS}%s${FS}%s\n" \
      "$sid" "$cwd" "$status" "$model" "$tmux_session" "$tmux_winname" "$tmux_winidx" "$tmux_paneidx" "$tmux_target" "$updated" "$title" "$msg"
  done < "$tmpfile" > "$merged"
  mv "$merged" "$tmpfile"
}

resort_tmpfile() {
  local tmpfile="$1"
  local _id _dir _tmux _preview sort_mode
  read -r _id _dir _tmux _preview sort_mode <<< "$(read_conf)"

  local sorted
  sorted=$(mktemp /tmp/tmux-cc-sorted.XXXXXX)
  local fs=$'\x1f'
  if [[ "$sort_mode" == "alpha" ]]; then
    awk -F"$fs" 'BEGIN{OFS=FS}
      { s=$3; t=$9
        printf "%d\t%s\t%d\t%s\t%s\n", \
          (s=="waiting"?1:s=="working"?2:3), $2, (t==""?1:0), t, $0}' "$tmpfile" \
    | sort -t$'\t' -k1,1n -k2,2 -k3,3n -k4,4 \
    | cut -d$'\t' -f5-
  else
    awk -F"$fs" 'BEGIN{OFS=FS}
      { s=$3; u=$10
        printf "%d\t%s\t%s\n", \
          (s=="waiting"?1:s=="working"?2:3), u, $0}' "$tmpfile" \
    | sort -t$'\t' -k1,1n -k2,2r \
    | cut -d$'\t' -f3-
  fi > "$sorted"
  mv "$sorted" "$tmpfile"
}

toggle_preview() {
  local tmpfile="$1" preview_dir="$2"
  cycle_setting preview

  local _id _dir _tmux preview_mode _sort
  read -r _id _dir _tmux preview_mode _sort <<< "$(read_conf)"

  if [[ "$preview_mode" == "show" ]] && [[ -z "$(ls -A "$preview_dir" 2>/dev/null)" ]]; then
    while IFS="$FS" read -r sid cwd _; do
      (fetch_snippet "$sid" "$cwd" "$preview_dir" 2>/dev/null || true) &
    done < "$tmpfile"
    wait
    merge_previews "$tmpfile" "$preview_dir"
  fi
}

# --- Main ----

main() {
  local pane_map_file
  pane_map_file=$(mktemp /tmp/tmux-cc-panes.XXXXXX)

  tmux list-panes -a -F "#{pane_id}	#{session_name}	#{window_name}	#{window_index}	#{pane_index}	#{session_name}:#{window_index}.#{pane_index}" 2>/dev/null > "$pane_map_file"

  [[ -d "$ACTIVE_DIR" ]] || { echo "No active sessions directory found."; rm -f "$pane_map_file"; read -r -n1; exit 0; }

  local entries_file
  entries_file=$(mktemp /tmp/tmux-cc-entries.XXXXXX)
  local json_files=("$ACTIVE_DIR"/*.json)
  if [[ -f "${json_files[0]:-}" ]]; then
    while IFS=$'\t' read -r sid inner_pid source cwd status model tmux_pane updated; do
      if [[ "$inner_pid" -gt 0 ]] && kill -0 "$inner_pid" 2>/dev/null; then
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
          "$sid" "$inner_pid" "$source" "$cwd" "$status" "$model" "$tmux_pane" "$updated" >> "$entries_file"
      else
        rm -f "$ACTIVE_DIR/${sid}.json"
      fi
    done < <(jq -r '[
      (input_filename | split("/") | last | rtrimstr(".json")),
      (.innerPid // .pid // 0 | tostring),
      (.source // "cli"),
      (.cwd // ""),
      (.status // "unknown"),
      (.model // "unknown"),
      (.tmuxPane // ""),
      (.statusUpdatedAt // "")
    ] | join("\t")' "${json_files[@]}" 2>/dev/null)
  fi

  if [[ ! -s "$entries_file" ]]; then
    echo "No active Claude Code sessions found."
    rm -f "$pane_map_file" "$entries_file"
    read -r -n1
    exit 0
  fi

  # Dedup by PID: prefer non-startup source, merge model from startup if needed
  local deduped_file
  deduped_file=$(mktemp /tmp/tmux-cc-deduped.XXXXXX)
  awk -F'\t' 'BEGIN{OFS=FS}
    {
      pid=$2; src=$3; model=$6
      if (!(pid in best)) {
        best[pid] = $0; bsrc[pid] = src; bmodel[pid] = model
      } else {
        if (src != "startup" && bsrc[pid] == "startup") {
          if (model == "unknown" || model == "null" || model == "") {
            split($0, f, FS); f[6] = bmodel[pid]
            s = f[1]; for (i=2; i<=8; i++) s = s FS f[i]
            best[pid] = s
          } else {
            best[pid] = $0
          }
          bsrc[pid] = src; bmodel[pid] = (model != "unknown" && model != "null" && model != "") ? model : bmodel[pid]
        } else if (bsrc[pid] != "startup" && src == "startup") {
          if (bmodel[pid] == "unknown" || bmodel[pid] == "null" || bmodel[pid] == "") {
            split(best[pid], f, FS); f[6] = model
            s = f[1]; for (i=2; i<=8; i++) s = s FS f[i]
            best[pid] = s; bmodel[pid] = model
          }
        }
      }
    }
    END { for (pid in best) print best[pid] }
  ' "$entries_file" > "$deduped_file"

  local tmpfile preview_dir
  tmpfile=$(mktemp /tmp/tmux-cc-sessions.XXXXXX)
  preview_dir=$(mktemp -d /tmp/tmux-cc-previews.XXXXXX)
  trap "rm -f '$pane_map_file' '$entries_file' '$deduped_file' '$tmpfile'; rm -rf '$preview_dir'" EXIT

  local _id _dir _tmux preview_mode sort_mode
  read -r _id _dir _tmux preview_mode sort_mode <<< "$(read_conf)"

  while IFS=$'\t' read -r sid inner_pid source cwd status model tmux_pane updated; do
    local tmux_session="" tmux_winname="" tmux_winidx="" tmux_paneidx="" tmux_target=""

    if [[ -n "$tmux_pane" ]]; then
      local pane_info
      pane_info=$(awk -F'\t' -v pane="$tmux_pane" '$1 == pane {print $2 FS $3 FS $4 FS $5 FS $6; exit}' "$pane_map_file")
      if [[ -n "$pane_info" ]]; then
        IFS=$'\t' read -r tmux_session tmux_winname tmux_winidx tmux_paneidx tmux_target <<< "$pane_info"
      fi
    fi

    printf "%s${FS}%s${FS}%s${FS}%s${FS}%s${FS}%s${FS}%s${FS}%s${FS}%s${FS}%s\n" \
      "$sid" "$cwd" "$status" "$model" "$tmux_session" "$tmux_winname" "$tmux_winidx" "$tmux_paneidx" "$tmux_target" "$updated"

    if [[ "$preview_mode" == "show" ]]; then
      (fetch_snippet "$sid" "$cwd" "$preview_dir" 2>/dev/null || true) &
    fi
  done < <(
    if [[ "$sort_mode" == "alpha" ]]; then
      awk -F'\t' 'BEGIN{OFS=FS}
        { s=$5; p=$7
          printf "%d\t%s\t%d\t%s\t%s\n", \
            (s=="waiting"?1:s=="working"?2:3), $4, (p==""?1:0), p, $0}' "$deduped_file" \
      | sort -t$'\t' -k1,1n -k2,2 -k3,3n -k4,4 \
      | cut -d$'\t' -f5-
    else
      awk -F'\t' 'BEGIN{OFS=FS}
        { s=$5; u=$8
          printf "%d\t%s\t%s\n", \
            (s=="waiting"?1:s=="working"?2:3), u, $0}' "$deduped_file" \
      | sort -t$'\t' -k1,1n -k2,2r \
      | cut -d$'\t' -f3-
    fi
  ) > "$tmpfile"

  wait

  merge_previews "$tmpfile" "$preview_dir"

  local selected
  selected=$(render_lines "$tmpfile" | fzf --ansi --reverse --tiebreak=index \
    --prompt="Search CC sessions > " \
    --header="$(${SCRIPT} --render-header)" \
    --delimiter=$'\t' --with-nth=1 \
    --preview='[[ -n {2} ]] && tmux capture-pane -t {2} -p -e 2>/dev/null | awk '"'"'{a[NR]=$0} /\S/{p=NR} END{for(i=1;i<=p;i++)print a[i]}'"'"' || echo "No pane"' \
    --preview-window=down:50%:follow \
    --expect=enter \
    --bind "ctrl-i:execute-silent(${SCRIPT} --cycle id)+reload(${SCRIPT} --render $tmpfile)+transform-header(${SCRIPT} --render-header)" \
    --bind "ctrl-d:execute-silent(${SCRIPT} --cycle directory)+reload(${SCRIPT} --render $tmpfile)+transform-header(${SCRIPT} --render-header)" \
    --bind "ctrl-t:execute-silent(${SCRIPT} --cycle tmux)+reload(${SCRIPT} --render $tmpfile)+transform-header(${SCRIPT} --render-header)" \
    --bind "ctrl-s:execute-silent(${SCRIPT} --cycle sort)+execute-silent(${SCRIPT} --resort $tmpfile)+reload(${SCRIPT} --render $tmpfile)+transform-header(${SCRIPT} --render-header)" \
    --bind "ctrl-l:execute-silent(${SCRIPT} --toggle-preview $tmpfile $preview_dir)+reload(${SCRIPT} --render $tmpfile)+transform-header(${SCRIPT} --render-header)" \
    --bind "ctrl-p:toggle-preview") || true

  [[ -z "$selected" ]] && exit 0

  local action target_line
  action=$(echo "$selected" | head -1)
  target_line=$(echo "$selected" | tail -1)

  [[ "$action" == "enter" ]] || exit 0

  local target
  target=$(echo "$target_line" | awk -F'\t' '{print $2}')

  if [[ -z "$target" ]]; then
    tmux display-message "This session is not in a tmux pane"
    exit 0
  fi

  local target_session="${target%%:*}"
  tmux switch-client -t "$target_session"
  tmux select-window -t "$target"
  tmux select-pane -t "$target"
}

case "${1:-}" in
  --cycle)           cycle_setting "${2:?missing field}" ;;
  --render)          render_lines "${2:?missing tmpfile}" ;;
  --render-header)   render_header ;;
  --toggle-preview)  toggle_preview "${2:?missing tmpfile}" "${3:?missing preview_dir}" ;;
  --resort)          resort_tmpfile "${2:?missing tmpfile}" ;;
  *)                 main ;;
esac
