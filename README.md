# CLAUDE_BASICS

Claude Code を使った開発でプロジェクト横断的に再利用したい資産を集めたリポジトリ。
親リポジトリに **submodule として取り込んで使う** 想定。

## 構成

| ファイル | 内容 |
|---|---|
| [`claude_basics.md`](./claude_basics.md) | プロジェクト非依存の Claude 作業ルール（基本姿勢）。親 `CLAUDE.md` から参照 / コピーして使う |
| [`auto_implement_issues.sh`](./auto_implement_issues.sh) | GitHub issue を Claude Code + `/codex-review` で自動実装 / 自動調査するスクリプト |
| [`skills/autoimplement/SKILL.md`](./skills/autoimplement/) | `auto_implement_issues.sh` を呼び出す Claude Code スキル (`/autoimplement`) |
| [`setup/install_tools.ps1`](./setup/install_tools.ps1) / [`.sh`](./setup/install_tools.sh) | Python / Node / uv / gh / jq / Claude Code / Codex CLI を一括インストールする |
| [`setup/install_aliases.ps1`](./setup/install_aliases.ps1) / [`.sh`](./setup/install_aliases.sh) | `cc` シェルショートカット（`claude --dangerously-skip-permissions`）をシェルのプロファイルに登録する |

## 目的

- Claude を使った開発で毎回同じ規約 (`CLAUDE.md`) を書き直すのを避ける
- `/codex-review` 経由の安全な auto-merge ワークフローを共通化する
- プロジェクトごとの `CLAUDE.md` は「汎用 = ここを参照」「固有 = プロジェクトに残す」と明確に分離する

## submodule として取り込む

```bash
git submodule add https://github.com/P-A-N/CLAUDE_BASICS.git claude-basics
git commit -m "Add CLAUDE_BASICS as submodule"
```

親 `CLAUDE.md` の冒頭で `claude_basics.md` を参照する例:

```markdown
# プロジェクト Claude 作業ルール

## 共通ルール

[claude-basics/claude_basics.md](./claude-basics/claude_basics.md) を参照。

## プロジェクト固有ルール

- （ここに固有ルール）
```

## 新しいマシンのセットアップ

新環境で最初にやること。`setup/` の 2 本を順に流せば、ツール導入と `cc` ショートカット登録が終わる。

### 1. ツールの一括インストール

`git` / `python3` / `node` / `gh` / `jq` / `uv` / `claude` / `codex` を、
**PATH に無いものだけ** 入れる（Windows は winget、mac/Linux は brew もしくは apt + npm）。

```powershell
# Windows
powershell -ExecutionPolicy Bypass -File claude-basics\setup\install_tools.ps1 -DryRun   # 確認
powershell -ExecutionPolicy Bypass -File claude-basics\setup\install_tools.ps1
```

```bash
# macOS / Linux
bash claude-basics/setup/install_tools.sh --dry-run
bash claude-basics/setup/install_tools.sh
```

| フラグ | 説明 |
|---|---|
| `-DryRun` / `--dry-run` | 何を入れるか表示するだけ |
| `-Only <key>` / `--only <key>` | 指定ツールだけ処理（例: `codex`） |
| `-Skip <key,...>` / `--skip <key,...>` | 指定ツールを除外 |
| `-IncludeOptional` (ps1) | 任意扱いの PowerShell 7 も入れる |
| `-Force` (ps1) | 導入済みでも再インストール |

インストール後は **シェルを開き直してから**（PATH 反映のため）認証する:

```bash
gh auth login     # GitHub
codex login       # ChatGPT アカウント（/codex-review が使う）
claude            # 初回起動で Anthropic 認証
```

Windows で winget が無い場合は Microsoft Store の「アプリ インストーラー」を先に入れる。

### 2. `cc` エイリアスの登録

`cc` = `claude --dangerously-skip-permissions`（引数はそのまま渡る）をシェルのプロファイルに追記する。
冪等 — 既に `cc` が定義済みならスキップする。

```powershell
# Windows（5.1 / 7 の両プロファイルに書く）
powershell -ExecutionPolicy Bypass -File claude-basics\setup\install_aliases.ps1
powershell -ExecutionPolicy Bypass -File claude-basics\setup\install_aliases.ps1 -WhatIf          # 確認だけ
powershell -ExecutionPolicy Bypass -File claude-basics\setup\install_aliases.ps1 -Scope PowerShell # 7 だけ
```

```bash
# macOS / Linux（$SHELL から .bashrc / .zshrc を判定）
bash claude-basics/setup/install_aliases.sh
bash claude-basics/setup/install_aliases.sh --rc ~/.zshrc
bash claude-basics/setup/install_aliases.sh --dry-run
```

反映は新しいシェルを開くか、`. $PROFILE` / `source ~/.bashrc`。

## auto_implement_issues.sh

GitHub issue を自動実装 / 調査するスクリプト。詳細は [`auto_implement_issues.sh`](./auto_implement_issues.sh) のヘッダーコメントを参照。

### 動作

ラベルでモードを切り替える:

| ラベル | モード | 動作 |
|---|---|---|
| `research` | 調査のみ | コード変更せず `RESEARCH_FINDINGS.md` を生成し、issue にコメント投稿 |
| `auto-ok` | 自動実装 | `auto/issue-<N>` ブランチを作り実装 → `/codex-review` APPROVED まで最大 5 ラウンド → `main` に `--no-ff` マージ（push はしない） |
| 両方 | 調査優先 | 安全側: code 変更なし |

done-label (`auto-researched` / `auto-implemented`) で再処理を skip。
ユーザーが done-label を外して FB コメントを追記すれば、次回実行で再実装（安全条件を満たす場合のみ自動 cleanup → re-run）。

### 安全ガード

- main 未マージの commit が branch に残っていれば skip
- worktree に uncommitted / untracked あれば skip
- push は一切しない
- `rm -rf` / `--force` 破壊的オペは使わない（git のセーフティを信頼）

### 依存

- `gh` CLI (authenticated)
- `jq`
- `claude` CLI (with Claude Code, `/codex-review` skill installed)
- Bash 4+

### 実行

親リポジトリのルートから:

```bash
# 全 eligible issue を処理
bash claude-basics/auto_implement_issues.sh

# 単一 issue
bash claude-basics/auto_implement_issues.sh --issue 42

# dry-run（対象 issue の列挙のみ）
bash claude-basics/auto_implement_issues.sh --dry-run
```

### 主なオプション

| フラグ | デフォルト | 説明 |
|---|---|---|
| `--issue <N>` | - | 単一 issue 指定 |
| `--impl-label <L>` | `auto-ok` | 自動実装対象のラベル |
| `--research-label <L>` | `research` | 調査対象のラベル |
| `--limit <N>` | 5 | 1 回で処理する issue 数上限 |
| `--budget <N>` | 5 | issue あたりの Claude 予算 (USD) |
| `--no-auto-merge` | off | 実装 APPROVED 後 `main` への自動マージを抑止 |
| `--dry-run` | off | 対象列挙のみ |

### 親リポジトリ側に用意するもの

- プロジェクトの規約ファイル（`CLAUDE.md` / `AGENTS.md` / `CONTRIBUTING.md` のいずれか）— Claude が commit 規約を読むために参照する
- `gh auth status` が通る GitHub 認証
- `main` ブランチ（`main..$BRANCH` を unmerged commit カウントに使用）

## `/autoimplement` スキル

`auto_implement_issues.sh` を Claude Code のスラッシュコマンド `/autoimplement` で呼び出せる。

- `/autoimplement` — eligible な issue をすべて処理
- `/autoimplement <N>` — 単一 issue

submodule の `skills/autoimplement/` を親リポジトリの `.claude/skills/autoimplement/` にコピー or symlink すると Claude Code がスキルを認識する:

```bash
# コピー（シンプル、ただし submodule bump 時に追従しない）
cp -r claude-basics/skills/autoimplement .claude/skills/

# もしくは symlink（submodule の更新が自動で反映される）
ln -s ../../claude-basics/skills/autoimplement .claude/skills/autoimplement
```

スキル内部では **常に `--issue N` で per-issue 実行** する。これは Windows Git Bash の
process substitution (`<(...)`) が `jq: Could not open /proc/<pid>/fd/<n>` で壊れるのを回避するため（他 OS では無害）。

## サブモジュール更新

```bash
git submodule update --remote claude-basics
git add claude-basics
git commit -m "Bump CLAUDE_BASICS"
```

## ライセンス

MIT
