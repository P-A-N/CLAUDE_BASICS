#!/usr/bin/env bash
# Claude Code 用のシェルショートカットを bash / zsh の rc に登録する（冪等）。
#
#   cc ... claude --dangerously-skip-permissions（追加引数はそのまま渡す）
#
# 使い方:
#   bash claude-basics/setup/install_aliases.sh          # ログインシェルの rc に追記
#   bash claude-basics/setup/install_aliases.sh --rc ~/.zshrc
#   bash claude-basics/setup/install_aliases.sh --dry-run

set -euo pipefail

MARKER='# --- Claude Code (claude-basics) ---'
RC=''
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rc) RC="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$RC" ]]; then
  case "${SHELL##*/}" in
    zsh) RC="$HOME/.zshrc" ;;
    *)   RC="$HOME/.bashrc" ;;
  esac
fi

if [[ -f "$RC" ]] && grep -qF "$MARKER" "$RC"; then
  echo "skip (登録済み): $RC"
  exit 0
fi

if [[ -f "$RC" ]] && grep -qE '^[[:space:]]*(alias[[:space:]]+cc=|cc[[:space:]]*\(\))' "$RC"; then
  echo "skip (cc は既に定義済み): $RC" >&2
  exit 0
fi

BLOCK="
$MARKER
cc() { claude --dangerously-skip-permissions \"\$@\"; }
"

if [[ $DRY_RUN -eq 1 ]]; then
  echo "would append to $RC:"
  echo "$BLOCK"
  exit 0
fi

mkdir -p "$(dirname "$RC")"
printf '%s\n' "$BLOCK" >> "$RC"
echo "登録しました: $RC"
echo "新しいシェルを開くか 'source $RC' で cc が使えます。"
