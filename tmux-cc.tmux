#!/usr/bin/env bash

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

default_key="C"
key="$(tmux show-option -gqv @tmux-cc-key)"
key="${key:-$default_key}"

tmux bind-key "$key" display-popup -E -w 90% -h 80% "$CURRENT_DIR/scripts/switcher.sh"
