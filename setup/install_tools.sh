#!/usr/bin/env bash
# Claude Code 開発環境に必要なツールを一括インストールする（macOS / Linux）。
#
#   パッケージマネージャ: git / python3 / node / gh / jq   (brew もしくは apt)
#   curl:                 uv (astral.sh)
#   npm -g:               @anthropic-ai/claude-code, @openai/codex
#
# 既に PATH にあるものはスキップする。
#
# 使い方:
#   bash claude-basics/setup/install_tools.sh --dry-run
#   bash claude-basics/setup/install_tools.sh
#   bash claude-basics/setup/install_tools.sh --only codex
#   bash claude-basics/setup/install_tools.sh --skip python3,node

set -uo pipefail

DRY_RUN=0
ONLY=''
SKIP=''

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --only) ONLY=",$2,"; shift 2 ;;
    --skip) SKIP=",$2,"; shift 2 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

# パッケージマネージャの判定
if command -v brew >/dev/null 2>&1; then
  PM='brew'
elif command -v apt-get >/dev/null 2>&1; then
  PM='apt'
else
  PM=''
  echo "warning: brew / apt-get が見つからない。npm と uv だけ処理する。" >&2
fi

run() {
  echo "  $*"
  if [[ $DRY_RUN -eq 0 ]]; then "$@"; fi
}

# dry-run 中は「入れた」扱いにしない
mark_installed() {
  if [[ $DRY_RUN -eq 0 ]]; then INSTALLED+=("$1"); fi
}

wanted() {
  local key="$1"
  [[ -n "$ONLY" && "$ONLY" != *",$key,"* ]] && return 1
  [[ -n "$SKIP" && "$SKIP" == *",$key,"* ]] && return 1
  return 0
}

INSTALLED=()
SKIPPED=()
FAILED=()

# key / 表示名 / brew パッケージ / apt パッケージ
PKGS=(
  "git:Git:git:git"
  "python3:Python 3:python@3.13:python3"
  "node:Node.js:node:nodejs"
  "gh:GitHub CLI:gh:gh"
  "jq:jq:jq:jq"
)

for entry in "${PKGS[@]}"; do
  IFS=':' read -r key name brewpkg aptpkg <<<"$entry"
  wanted "$key" || { SKIPPED+=("$name (指定外)"); continue; }
  if command -v "$key" >/dev/null 2>&1; then
    echo "OK   $name -> $(command -v "$key")"
    SKIPPED+=("$name (導入済み)")
    continue
  fi
  echo "INST $name"
  case "$PM" in
    brew) run brew install "$brewpkg" && mark_installed "$name" || FAILED+=("$name") ;;
    apt)  run sudo apt-get install -y "$aptpkg" && mark_installed "$name" || FAILED+=("$name") ;;
    *)    echo "  skip: パッケージマネージャなし"; FAILED+=("$name (pm なし)") ;;
  esac
done

# uv は公式インストーラで入れる（brew 版より更新が速い）
if wanted uv; then
  if command -v uv >/dev/null 2>&1; then
    echo "OK   uv -> $(command -v uv)"
    SKIPPED+=("uv (導入済み)")
  else
    echo "INST uv"
    if [[ $DRY_RUN -eq 1 ]]; then
      echo '  curl -LsSf https://astral.sh/uv/install.sh | sh'
    elif curl -LsSf https://astral.sh/uv/install.sh | sh; then
      mark_installed uv
    else
      FAILED+=("uv")
    fi
  fi
fi

# npm グローバル
NPM_PKGS=(
  "claude:Claude Code:@anthropic-ai/claude-code"
  "codex:Codex CLI:@openai/codex"
)

for entry in "${NPM_PKGS[@]}"; do
  IFS=':' read -r key name pkg <<<"$entry"
  wanted "$key" || { SKIPPED+=("$name (指定外)"); continue; }
  if command -v "$key" >/dev/null 2>&1; then
    echo "OK   $name -> $(command -v "$key")"
    SKIPPED+=("$name (導入済み)")
    continue
  fi
  if ! command -v npm >/dev/null 2>&1; then
    echo "warning: npm が無いので $name をスキップ。Node.js 導入後にシェルを開き直して再実行すること。" >&2
    FAILED+=("$name (npm なし)")
    continue
  fi
  echo "INST $name"
  run npm install -g "$pkg" && mark_installed "$name" || FAILED+=("$name")
done

echo
echo '--- まとめ ---'
[[ $DRY_RUN -eq 1 ]]        && echo '(dry-run: 実際のインストールはしていない)'
[[ ${#INSTALLED[@]} -gt 0 ]] && echo "installed: ${INSTALLED[*]}"
[[ ${#SKIPPED[@]} -gt 0 ]]   && echo "skipped  : ${SKIPPED[*]}"
[[ ${#FAILED[@]} -gt 0 ]]    && echo "failed   : ${FAILED[*]}"

echo
echo '次にやること:'
echo '  1. 新しいシェルを開く（PATH 反映のため）'
echo '  2. gh auth login   … GitHub 認証'
echo '  3. codex login     … ChatGPT アカウントで Codex CLI 認証'
echo '  4. bash setup/install_aliases.sh … cc ショートカット登録'
exit 0
