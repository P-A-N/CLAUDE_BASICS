#!/usr/bin/env bash
# Auto-implement / auto-research GitHub issues via Claude Code (+ /codex-review).
#
# Usage:
#   scripts/auto_implement_issues.sh [--impl-label auto-ok] [--research-label research]
#                                    [--limit 5] [--budget 5] [--dry-run]
#
# Modes (chosen per issue from its labels / state):
#   * research label → investigate only, post findings as comment
#   * impl label     → implement, run /codex-review until APPROVED, commit on
#                      auto/issue-N branch, comment on issue (no push)
#   * both labels    → research mode wins (safer: no code changes)
#   * no label (untriaged) → also picked up in implement mode (auto-ok を必須にしない運用)
#
# Eligibility (uniform across all paths):
#   - Issues whose LAST comment is one this script posted are skipped. A new
#     comment from anyone else re-arms the issue. The script never adds or
#     removes labels — the label vocabulary stays fully user-managed.
#
# Safety:
#   - Never pushes; auto-merges APPROVED implement branches into main locally
#     (override with --no-auto-merge)
#   - --budget caps per-issue Claude spend in USD (default 0 = no cap; pass any
#     positive number to enforce a ceiling, e.g. --budget 5)

set -euo pipefail

IMPL_LABEL="auto-ok"
RESEARCH_LABEL="research"
NOT_FIXED_LABEL="not-fixed"
# Marker every auto-posted comment contains, so the next run can detect its
# own prior work via the latest-comment check without touching labels.
SCRIPT_COMMENT_MARKER="scripts/auto_implement_issues.sh"
LIMIT=5
BUDGET=0   # 0 = no per-issue budget cap; pass --budget N to enforce a ceiling.
DRY_RUN=0
TARGET_ISSUE=""
AUTO_MERGE=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --impl-label)     IMPL_LABEL="$2"; shift 2;;
    --research-label) RESEARCH_LABEL="$2"; shift 2;;
    --limit)          LIMIT="$2"; shift 2;;
    --budget)         BUDGET="$2"; shift 2;;
    --issue)          TARGET_ISSUE="$2"; shift 2;;
    --no-auto-merge)  AUTO_MERGE=0; shift;;
    --dry-run)        DRY_RUN=1; shift;;
    -h|--help)        sed -n '2,22p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

# When invoked from within a submodule (i.e. this script is itself loaded as a
# submodule and someone runs it from inside that submodule's directory),
# --show-toplevel would point at the submodule's own root, which breaks every
# 'git -C "$REPO_ROOT" ...' call. --show-superproject-working-tree returns the
# parent repo's root in that case; empty otherwise, so fall back to toplevel.
SUPER="$(git rev-parse --show-superproject-working-tree 2>/dev/null || true)"
if [[ -n "$SUPER" ]]; then
  REPO_ROOT="$SUPER"
else
  REPO_ROOT="$(git rev-parse --show-toplevel)"
fi
WT_ROOT="$REPO_ROOT/.worktrees"
LOG_DIR="$WT_ROOT/.auto_logs"
mkdir -p "$LOG_DIR"

# Returns "true" when issue $1's latest comment was posted by this script.
# Used uniformly across all search arms to skip already-processed issues
# without touching labels. Returns "true" when the latest comment on the
# issue looks like one this script (or an interactive supplement Claude
# posts on the same workflow) authored.
#
# Detection uses ASCII-only substring matches because Git Bash's grep on
# Windows mis-handles multi-byte UTF-8 in the pattern even with -F. Each
# matched phrase only ever appears in bot-style headers — false positives
# on organic user comments are very unlikely:
#  - "scripts/auto_implement_issues.sh"  → script's standard post
#  - "Auto-implemented by"               → standard implement comment
#  - "Auto-researched by"                → standard research comment
#  - "Auto re-implemented by"            → not-fixed re-run implement
#  - "Auto re-researched by"             → not-fixed re-run research
#  - "(autoimplement "                   → Claude's manual supplements
_last_comment_is_script() {
  local num="$1"
  local body
  body=$(gh issue view "$num" --json comments \
    --jq '.comments | (last | .body // "")' 2>/dev/null || echo "")
  if [[ -z "$body" ]]; then echo "false"; return 0; fi
  # Restrict to the first few hundred bytes so a long user comment that
  # happens to quote an old bot post deeper down doesn't trigger.
  local head_body
  head_body=$(head -c 400 <<<"$body")
  if grep -qE \
       "(scripts/auto_implement_issues\.sh|Auto-implemented by|Auto-researched by|Auto re-implemented by|Auto re-researched by|\(autoimplement )" \
       <<<"$head_body"; then
    echo "true"; return 0
  fi
  echo "false"
}

if [[ -n "$TARGET_ISSUE" ]]; then
  # Single-issue mode: bypass the latest-comment filter — the caller explicitly
  # asked for this one, so honor it without requiring a fresh user comment.
  echo "Fetching single issue #$TARGET_ISSUE..."
  RAW=$(gh issue view "$TARGET_ISSUE" --json number,title,url,body,labels)
  HAS_RESEARCH=$(jq --arg L "$RESEARCH_LABEL" '[.labels[].name] | index($L) != null' <<<"$RAW")
  HAS_NOT_FIXED=$(jq --arg L "$NOT_FIXED_LABEL" '[.labels[].name] | index($L) != null' <<<"$RAW")
  if [[ "$HAS_RESEARCH" == "true" ]]; then
    MODE_FORCED="research"
  else
    MODE_FORCED="implement"
  fi
  ISSUES=$(jq --arg m "$MODE_FORCED" --argjson nf "$HAS_NOT_FIXED" \
    '[{number, title, url, body, mode:$m, not_fixed:$nf}]' <<<"$RAW")
else
  # Fetch by input label + an untriaged sweep. Tag each with its mode and
  # whether the not-fixed label is also present (purely informational — the
  # script does not transition labels). The latest-comment filter below
  # decides eligibility uniformly, so we no longer need the old NF_* re-run
  # arms or done-label exclusions.
  echo "Fetching issues: impl=$IMPL_LABEL, research=$RESEARCH_LABEL, untriaged=any (limit=$LIMIT each)..."
  NF_JQ='[.[] | . + {not_fixed: ([.labels[].name] | index("'"$NOT_FIXED_LABEL"'") != null)}]'
  RESEARCH_ISSUES=$(gh issue list --state open --limit "$LIMIT" \
    --search "label:$RESEARCH_LABEL" \
    --json number,title,url,body,labels \
    | jq "$NF_JQ"' | [.[] | . + {mode:"research"}]')
  IMPL_ISSUES=$(gh issue list --state open --limit "$LIMIT" \
    --search "label:$IMPL_LABEL" \
    --json number,title,url,body,labels \
    | jq "$NF_JQ"' | [.[] | . + {mode:"implement"}]')
  UNTRIAGED_ISSUES=$(gh issue list --state open --limit "$LIMIT" \
    --search "-label:$IMPL_LABEL -label:$RESEARCH_LABEL" \
    --json number,title,url,body,labels \
    | jq "$NF_JQ"' | [.[] | . + {mode:"implement"}]')
  # Priority: research → impl → untriaged. Research wins when both labels are
  # set; explicit-label intents beat the catch-all untriaged sweep.
  ALL_ISSUES=$(jq -s '(.[0] + .[1] + .[2]) | unique_by(.number)' \
    <(echo "$RESEARCH_ISSUES") <(echo "$IMPL_ISSUES") <(echo "$UNTRIAGED_ISSUES"))
  # Apply the uniform last-comment filter across every path.
  PRE_COUNT=$(jq 'length' <<<"$ALL_ISSUES")
  KEPT="[]"
  for k in $(seq 0 $((PRE_COUNT-1))); do
    [[ "$PRE_COUNT" -eq 0 ]] && break
    CUR=$(jq ".[$k]" <<<"$ALL_ISSUES")
    CUR_NUM=$(jq -r '.number' <<<"$CUR")
    if [[ "$(_last_comment_is_script "$CUR_NUM")" == "true" ]]; then
      echo "  skipping #$CUR_NUM: last comment is from this script (add a new comment to re-trigger)"
      continue
    fi
    KEPT=$(jq --argjson c "$CUR" '. + [$c]' <<<"$KEPT")
  done
  ISSUES=$(jq --argjson lim "$LIMIT" '.[:$lim]' <<<"$KEPT")
fi
COUNT=$(jq 'length' <<<"$ISSUES")
echo "Found $COUNT issue(s)"
[[ "$COUNT" -eq 0 ]] && exit 0

if [[ "$DRY_RUN" == "1" ]]; then
  jq -r '.[] | "[\(.mode)] #\(.number) \(.title)  \(.url)"' <<<"$ISSUES"
  exit 0
fi

SUCCEEDED=()
FAILED=()
SKIPPED=()

for i in $(seq 0 $((COUNT-1))); do
  NUM=$(jq -r ".[$i].number" <<<"$ISSUES")
  TITLE=$(jq -r ".[$i].title" <<<"$ISSUES")
  URL=$(jq -r ".[$i].url" <<<"$ISSUES")
  BODY=$(jq -r ".[$i].body" <<<"$ISSUES")
  MODE=$(jq -r ".[$i].mode" <<<"$ISSUES")
  NOT_FIXED=$(jq -r ".[$i].not_fixed // false" <<<"$ISSUES")

  # Pull comments so impl mode sees prior research findings / user decisions.
  COMMENTS=$(gh issue view "$NUM" --json comments \
    --jq '.comments[] | "--- @\(.author.login) (\(.createdAt)) ---\n\(.body)\n"' 2>/dev/null || true)

  BRANCH="auto/issue-$NUM"
  WT="$WT_ROOT/issue-$NUM"
  LOG="$LOG_DIR/issue-$NUM.log"

  echo ""
  if [[ "$NOT_FIXED" == "true" ]]; then
    echo "=== [$MODE / re-run: $NOT_FIXED_LABEL] Issue #$NUM: $TITLE ==="
  else
    echo "=== [$MODE] Issue #$NUM: $TITLE ==="
  fi

  # Handle leftover branch/worktree from a prior run. If the user removed the
  # done-label (auto-implemented / auto-researched) and added feedback comments
  # asking for revision, we need to re-run — but the branch/worktree from the
  # prior pass are stale. Clean up only when it's safe (no local work at risk):
  #   - unmerged commits on branch            → skip (may be in-progress work)
  #   - dirty/untracked files in worktree     → skip (user may have WIP edits)
  #   - clean + fully merged                  → delete and start fresh
  # Never fall back to `rm -rf` on the worktree: let git enforce its safety.
  _wt_is_dirty() {
    local _wt="$1"
    [[ -d "$_wt" ]] || { echo ""; return 0; }
    local _out
    _out=$(git -C "$_wt" status --porcelain 2>&1)
    local _rc=$?
    if [[ "$_rc" -ne 0 ]]; then
      # unreadable / corrupt worktree — treat as dirty (skip, don't auto-wipe)
      echo "UNREADABLE"
    else
      echo "$_out"
    fi
  }
  if git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$BRANCH"; then
    # Distinguish "0 unmerged commits" from "rev-list failed" — silently
    # treating failure as 0 would let us branch -D a branch with real work.
    if ! UNMERGED=$(git -C "$REPO_ROOT" rev-list --count "main..$BRANCH" 2>/dev/null); then
      echo "  rev-list main..$BRANCH failed — skipping (resolve manually)"
      SKIPPED+=("#$NUM (rev-list failed)")
      continue
    fi
    if [[ "$UNMERGED" -gt 0 ]]; then
      echo "  branch $BRANCH has $UNMERGED unmerged commit(s) — skipping (resolve manually)"
      SKIPPED+=("#$NUM (branch has unmerged commits)")
      continue
    fi
    WT_DIRTY=$(_wt_is_dirty "$WT")
    if [[ -n "$WT_DIRTY" ]]; then
      echo "  worktree $WT has local changes — skipping (commit/stash first)"
      SKIPPED+=("#$NUM (worktree has local changes)")
      continue
    fi
    echo "  stale branch/worktree from prior pass — cleaning up for re-run"
    if [[ -d "$WT" ]]; then
      if ! git -C "$REPO_ROOT" worktree remove "$WT" >/dev/null 2>&1; then
        echo "  WARN: git worktree remove $WT failed — skipping (resolve manually)"
        SKIPPED+=("#$NUM (worktree remove failed)")
        continue
      fi
    fi
    git -C "$REPO_ROOT" branch -D "$BRANCH" >/dev/null 2>&1 || true
  elif [[ -d "$WT" ]]; then
    # Worktree dir without a matching branch ref — orphaned. Still check for
    # local changes before removing; respect anything the user left behind.
    WT_DIRTY=$(_wt_is_dirty "$WT")
    if [[ -n "$WT_DIRTY" ]]; then
      echo "  orphaned worktree $WT has local changes — skipping (resolve manually)"
      SKIPPED+=("#$NUM (orphaned worktree has local changes)")
      continue
    fi
    echo "  orphaned worktree dir at $WT (no branch, clean) — removing"
    if ! git -C "$REPO_ROOT" worktree remove "$WT" >/dev/null 2>&1; then
      echo "  WARN: git worktree remove $WT failed — skipping (resolve manually)"
      SKIPPED+=("#$NUM (orphaned worktree remove failed)")
      continue
    fi
  fi

  echo "  creating worktree: $WT (branch $BRANCH from main)"
  git -C "$REPO_ROOT" worktree add -b "$BRANCH" "$WT" main >/dev/null

  RERUN_NOTE=""
  if [[ "$NOT_FIXED" == "true" ]]; then
    RERUN_NOTE=$(cat <<EOF
⚠ これは **再対応** のリクエストです（\`$NOT_FIXED_LABEL\` ラベルが付いている）。
前回の対応で問題が解決しなかったというユーザーの判断。直近のユーザー FB を**最優先**で読み、前回と同じ変更を繰り返すのではなく、足りなかった点・誤っていた点にフォーカスすること。

EOF
)
  fi

  if [[ "$MODE" == "research" ]]; then
    FINDINGS_PATH="$WT/RESEARCH_FINDINGS.md"
    PROMPT=$(cat <<EOF
GitHub Issue #$NUM の**調査のみ**をお願いします。コード変更は禁止です。

${RERUN_NOTE}URL: $URL
Title: $TITLE

Body:
$BODY

Comments (過去の調査結果・自動実装履歴・ユーザー FB 含む):
${COMMENTS:-(コメントなし)}

手順:
1. issueの質問・調査依頼の意図を把握する。
2. 関連コード・ログ・DBスキーマ等を読んで原因や論点を特定する。
3. **コードは変更しない**（git status がクリーンのまま終了すること）。
4. 調査結果を \`RESEARCH_FINDINGS.md\` に以下の構成で書き出す:
   - ## TL;DR (3行以内)
   - ## 調査範囲 (ファイル/関数を**テーブル**で列挙: | ファイル:行 | 役割 |)
   - ## 所見 (**箇条書き**中心。根拠の行番号を括弧で付ける)
   - ## 対応案 (選択肢を**テーブル**で比較: | 案 | 変更点 | メリット | デメリット |。末尾に「推奨: ...」1行)
   - ## 未解決 (**箇条書き**、1項目1-2行)
5. 完了したら最後に一行 "AUTO_RESULT: RESEARCHED" と出力する。調査不能なら "AUTO_RESULT: SKIP <理由>" で終了。

スタイル制約（厳守）:
- 散文は連続3行以内。3行超えそうなら箇条書きかテーブルに分解する。
- コードブロックは最小限、diff/該当行のみ引用。長い貼り付けは禁止。
- 書きすぎない。読み手はタイトルと TL;DR → テーブル → 推奨の順に見る。

作業ディレクトリは既に worktree ($WT) に入った状態で起動されている。
EOF
)
  else
    PROMPT=$(cat <<EOF
GitHub Issue #$NUM の実装をお願いします。

${RERUN_NOTE}URL: $URL
Title: $TITLE

Body:
$BODY

Comments (過去の調査結果、自動実装履歴、ユーザーからの FB が含まれる — 必ず目を通すこと。
直近のユーザーコメント（特に前回の auto-implemented 以降に追加されたもの）を**最優先**で反映すること):
${COMMENTS:-(コメントなし)}

重要な制約（違反は破壊的回帰を招くので厳守すること）:
- 変更範囲は issue と直接関係するコード・ロジックのみに限定する。
- issue に関係しない既存機能・カラム・関数・テスト・migration・UIフィールドを**削除・改名・後退させない**。
- 変更前後で「git diff main..HEAD -- 該当領域外のファイル」に意味のある変更が出るならそれは禁止。
- issue 文面とコメントで言及されていない挙動は一切触らない。疑わしければ触らない。
- 制約を満たせず実装が広がりそうなら、実装せず "AUTO_RESULT: SKIP 範囲を限定できないため" で終了する。

手順:
1. issue内容と過去コメントを読んで変更範囲を特定する。関係ないファイルの変更は一切しない。
2. 要求が曖昧、または制約を満たせない場合は、コード変更せず最後に一行 "AUTO_RESULT: SKIP <理由>" とだけ出力して終了する。
3. 実装したらまず \`IMPLEMENTATION_NOTES.md\` を worktree root に作成する（テンプレは下記）。codex-review で軽微な diff が増えても上書きすれば良い。
4. /codex-review skill を**必ず**呼ぶ。APPROVED が出るまで修正をループする（最大5ラウンド）。
5. /codex-review の各ラウンド終了時に、Codex の verdict 要約を一行 "CODEX_ROUND <n>: <APPROVED|CHANGES_REQUESTED|...> - <要約>" で出力する。
6. **APPROVED が返ったら、即座に commit する**（プロジェクトの規約 CLAUDE.md / AGENTS.md / CONTRIBUTING.md 等に従い、現在のブランチ \`$BRANCH\` 上で）。
   - **重要**: APPROVED と commit の間に追加の確認 / 再 review / 再読 / 詳細説明・要約のドラフト等は一切しない。commit を**最優先のアクション**として実行する。説明や IMPLEMENTATION_NOTES.md の補強が必要なら commit 後に行う。
   - 過去に APPROVED 後ハングして commit せず claude プロセスが kill された事故があった (issue #19)。commit していれば最悪 main にマージできるので、まず commit。
   - approval文の最初の一行をそのまま "CODEX_APPROVED: <Codexの一言>" として最終メッセージに出力する。
   - APPROVED に到達できなかったら "AUTO_RESULT: NO_APPROVAL <理由>" を出して終了（コミットしない）。

\`IMPLEMENTATION_NOTES.md\` テンプレ:

   \`\`\`markdown
   ## 実装概要
   <1-3行で何をどう変えたかの要約>

   ## 追加ファイル
   - \`path/to/new.cs\`: 何のためのファイルか
   - (なし の場合は「なし」と書く)

   ## 修正ファイル
   - \`path/to/existing.cs\`: 何をどう変えたか
   - …

   ## 追加 GameObject (Hierarchy)
   - \`/Foo/Bar\`: 何のため、どこに置いたか
   - (なし の場合は「なし」)

   ## 修正 GameObject (Hierarchy)
   - \`/Existing/Thing\`: どの Inspector 値 / コンポーネント / 子を変えたか
   - (なし の場合は「なし」)

   ## 動作確認方法
   1. (Editor で何を Play / Inspector でどう操作する)
   2. (何が起きれば成功か。期待値を具体的に)
   3. (失敗時の典型症状)
   \`\`\`

   この MD は autoimplement が issue へのコメントに**そのまま貼り付ける**ので、レビュワー視点で必要十分・嘘なしで書くこと（推測ではなく実際に diff/コミットに入った変更だけ書く）。
   **このファイルは commit には絶対に含めないこと** — 各実装ごとに上書きされる一時ファイル扱い。プロジェクトの \`.gitignore\` に \`IMPLEMENTATION_NOTES.md\` を入れておくと安心 (まだ無ければ追加して別 commit にしておく)。script は worktree のファイルをそのまま読む。

7. main へのマージや push は絶対にしない。ユーザーが後で手動で行う。
8. 完了したら**最終 assistant メッセージに必ず**以下を含めて終了する（-p モードは途中出力を捨てるため、途中で書いても意味がない。必ず最後のメッセージに書く）:
   - "CODEX_ROUND <n>: ..." 行（ラウンド数分）
   - "CODEX_APPROVED: ..." 行
   - "AUTO_RESULT: DONE <commit-sha>" 行

重要:
- /codex-review を実行せずに commit するのは禁止。最終メッセージに CODEX_APPROVED 行が無い＝失敗扱いでマージされない。
- 逆に **/codex-review が APPROVED を返したのに commit していない**状態でメッセージを終わらせるのも禁止。APPROVED 直後に **commit を最優先**で実行すること。途中で claude プロセスが kill されても commit してあれば実装はロストしない。

作業ディレクトリは既に worktree ($WT / branch $BRANCH) に入った状態で起動されている。
EOF
)
  fi

  if [[ "$BUDGET" == "0" ]]; then
    echo "  launching Claude (mode=$MODE, budget=unlimited, log=$LOG)"
  else
    echo "  launching Claude (mode=$MODE, budget=\$$BUDGET, log=$LOG)"
  fi
  # Feed the prompt via stdin instead of argv. On Windows/MSYS, argv has a hard
  # ~32 KiB cap (CreateProcess) and long prompts trip `execve: E2BIG` before the
  # CLI even starts (rc=126). Bash's `<<<` materializes the here-string through
  # a temp file, so stdin avoids the limit entirely.
  set +e
  if [[ "$BUDGET" == "0" ]]; then
    # Omit --max-budget-usd so the claude CLI runs without a spend ceiling.
    ( cd "$WT" && claude -p \
        --dangerously-skip-permissions \
        <<<"$PROMPT"
    ) >"$LOG" 2>&1
  else
    ( cd "$WT" && claude -p \
        --dangerously-skip-permissions \
        --max-budget-usd "$BUDGET" \
        <<<"$PROMPT"
    ) >"$LOG" 2>&1
  fi
  RC=$?
  set -e

  RESULT_LINE=$(grep -E '^AUTO_RESULT:' "$LOG" | tail -1 || true)
  echo "  rc=$RC  result=${RESULT_LINE:-<none>}"

  if [[ "$RC" -ne 0 ]]; then
    FAILED+=("#$NUM [$MODE] (rc=$RC)")
    continue
  fi

  if [[ "$MODE" == "research" ]]; then
    if [[ "$RESULT_LINE" == AUTO_RESULT:\ RESEARCHED* && -s "$FINDINGS_PATH" ]]; then
      if [[ "$NOT_FIXED" == "true" ]]; then
        HEADER="🔁 Auto re-researched by \`scripts/auto_implement_issues.sh\` (\`$NOT_FIXED_LABEL\` was set; label left untouched)."
      else
        HEADER="🔍 Auto-researched by \`scripts/auto_implement_issues.sh\`."
      fi
      COMMENT=$(printf '%s\n\n---\n\n%s\n' "$HEADER" "$(cat "$FINDINGS_PATH")")
      # The header contains SCRIPT_COMMENT_MARKER, so the next run's
      # _last_comment_is_script filter skips this issue until the user posts a
      # fresh comment. The script never adds or removes labels.
      if gh issue comment "$NUM" --body "$COMMENT" >/dev/null 2>&1; then
        echo "  posted findings to issue #$NUM"
      else
        echo "  WARN: failed to post findings to issue #$NUM"
      fi
      SUCCEEDED+=("#$NUM [research] findings posted")
      # Research mode should leave no commits and no local edits. Respect that:
      # only drop the throwaway worktree+branch when truly clean, so any
      # unexpected manual changes Claude (or the user) left behind survive.
      WT_DIRTY=$(_wt_is_dirty "$WT")
      if [[ -n "$WT_DIRTY" ]]; then
        echo "  research worktree $WT has local changes — leaving in place (resolve manually)"
      else
        git -C "$REPO_ROOT" worktree remove "$WT" >/dev/null 2>&1 \
          || echo "  WARN: git worktree remove $WT failed — leaving in place"
        git -C "$REPO_ROOT" branch -D "$BRANCH" >/dev/null 2>&1 || true
      fi
    elif [[ "$RESULT_LINE" == AUTO_RESULT:\ SKIP* ]]; then
      SKIPPED+=("#$NUM [research] $RESULT_LINE")
    else
      FAILED+=("#$NUM [research] (no findings file or bad marker)")
    fi
    continue
  fi

  # implement mode
  APPROVED_LINE=$(grep -E '^CODEX_APPROVED:' "$LOG" | tail -1 || true)
  echo "  codex: ${APPROVED_LINE:-<no approval line>}"

  if [[ "$RESULT_LINE" == AUTO_RESULT:\ DONE* ]]; then
    if [[ -z "$APPROVED_LINE" ]]; then
      FAILED+=("#$NUM [impl] (commit without CODEX_APPROVED — review not verified)")
    else
      SHA=$(awk '/^AUTO_RESULT: DONE/ {print $3; exit}' "$LOG")
      CODEX_MSG=${APPROVED_LINE#CODEX_APPROVED: }
      SUBJECT=$(git -C "$WT" log -1 --pretty=%s "$SHA" 2>/dev/null || echo "$TITLE")

      # Capture IMPLEMENTATION_NOTES.md NOW — a successful auto-merge below
      # removes the worktree, so reading later would race with cleanup. If the
      # implementer wrote one (it should, per the prompt) the contents go
      # straight into the issue comment. Falls back to nothing if missing.
      IMPL_NOTES_PATH="$WT/IMPLEMENTATION_NOTES.md"
      IMPL_NOTES_BODY=""
      if [[ -s "$IMPL_NOTES_PATH" ]]; then
        IMPL_NOTES_BODY=$(cat "$IMPL_NOTES_PATH")
      fi

      MERGE_STATUS="skipped (--no-auto-merge)"
      if [[ "$AUTO_MERGE" == "1" ]]; then
        CUR=$(git -C "$REPO_ROOT" symbolic-ref --short HEAD 2>/dev/null || echo "")
        DIRTY=$(git -C "$REPO_ROOT" status --porcelain -uno)
        if [[ "$CUR" != "main" ]]; then
          MERGE_STATUS="⚠ skipped (REPO_ROOT HEAD=$CUR, expected main)"
        elif [[ -n "$DIRTY" ]]; then
          MERGE_STATUS="⚠ skipped (uncommitted tracked changes in main worktree)"
        elif git -C "$REPO_ROOT" merge --no-ff "$BRANCH" \
               -m "Merge branch '$BRANCH' (auto issue #$NUM)" >/dev/null 2>&1; then
          MERGE_STATUS="✅ merged to main (no push)"
          echo "  merged $BRANCH into main"
          git -C "$REPO_ROOT" worktree remove "$WT" >/dev/null 2>&1 || true
        else
          git -C "$REPO_ROOT" merge --abort >/dev/null 2>&1 || true
          MERGE_STATUS="⚠ merge failed (conflicts?) — branch left for manual merge"
          echo "  WARN: merge failed for $BRANCH; aborted and left branch"
        fi
      fi

      if [[ "$NOT_FIXED" == "true" ]]; then
        COMMENT_HEADER="🔁 Auto re-implemented by \`scripts/auto_implement_issues.sh\` (\`$NOT_FIXED_LABEL\` was set; label left untouched)."
      else
        COMMENT_HEADER="🤖 Auto-implemented by \`scripts/auto_implement_issues.sh\`."
      fi
      if [[ -n "$IMPL_NOTES_BODY" ]]; then
        IMPL_SECTION=$(printf '\n---\n\n%s\n' "$IMPL_NOTES_BODY")
      else
        IMPL_SECTION=$'\n---\n\n⚠ IMPLEMENTATION_NOTES.md が見つかりませんでした — 実装者は次回からこのファイルを worktree root に作成すること (テンプレは auto_implement_issues.sh のプロンプト参照)。\n'
      fi
      COMMENT=$(cat <<COMMENT_EOF
$COMMENT_HEADER

- branch: \`$BRANCH\`
- commit: \`${SHA:0:7}\` — $SUBJECT
- codex review: ✅ APPROVED — $CODEX_MSG
- merge: $MERGE_STATUS

Push は手動で。次回 \`auto_implement_issues.sh\` が走ったときにこの issue を再処理させたい場合は、新しいコメントを追加してください（自動コメントが「最後のコメント」のままだと skip されます）。
$IMPL_SECTION
COMMENT_EOF
)
      # Header contains SCRIPT_COMMENT_MARKER → next run skips this issue
      # until the user posts a fresh comment. No label mutation.
      if gh issue comment "$NUM" --body "$COMMENT" >/dev/null 2>&1; then
        echo "  posted comment to issue #$NUM"
      else
        echo "  WARN: failed to post comment to issue #$NUM"
      fi
      SUCCEEDED+=("#$NUM [impl] $RESULT_LINE")
    fi
  elif [[ "$RESULT_LINE" == AUTO_RESULT:\ SKIP* ]]; then
    SKIPPED+=("#$NUM [impl] $RESULT_LINE")
  elif [[ "$RESULT_LINE" == AUTO_RESULT:\ NO_APPROVAL* ]]; then
    FAILED+=("#$NUM [impl] $RESULT_LINE")
  else
    FAILED+=("#$NUM [impl] (no AUTO_RESULT line)")
  fi
done

echo ""
echo "===== Summary ====="
printf 'DONE:    %d\n' "${#SUCCEEDED[@]}"
for s in "${SUCCEEDED[@]:-}"; do [[ -n "$s" ]] && echo "  $s"; done
printf 'SKIPPED: %d\n' "${#SKIPPED[@]}"
for s in "${SKIPPED[@]:-}"; do [[ -n "$s" ]] && echo "  $s"; done
printf 'FAILED:  %d\n' "${#FAILED[@]}"
for s in "${FAILED[@]:-}"; do [[ -n "$s" ]] && echo "  $s"; done

echo ""
echo "remaining branches (un-merged):"
git -C "$REPO_ROOT" branch --list 'auto/issue-*' || true
echo ""
echo "next step (manual): git push  (merge はAPPROVED分自動実行済み)"
