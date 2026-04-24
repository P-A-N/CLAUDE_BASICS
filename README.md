# CLAUDE_BASICS

Claude Code を使った開発でプロジェクト横断的に再利用したい資産を集めたリポジトリ。
親リポジトリに **submodule として取り込んで使う** 想定。

## 構成

| ファイル | 内容 |
|---|---|
| [`claude_basics.md`](./claude_basics.md) | プロジェクト非依存の Claude 作業ルール（基本姿勢）。親 `CLAUDE.md` から参照 / コピーして使う |
| [`auto_implement_issues.sh`](./auto_implement_issues.sh) | GitHub issue を Claude Code + `/codex-review` で自動実装 / 自動調査するスクリプト |

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

## サブモジュール更新

```bash
git submodule update --remote claude-basics
git add claude-basics
git commit -m "Bump CLAUDE_BASICS"
```

## ライセンス

MIT
