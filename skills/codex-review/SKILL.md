---
name: codex-review
description: Send the current plan, uncommitted changes, committed branch diff, or a specific commit to OpenAI Codex for iterative review. Claude and Codex go back-and-forth until Codex approves. Max 5 rounds. In code-review mode, after approval auto-commits any reviewed fixes and merges the feature branch into main (no push).
---

# Codex Iterative Review (Plan + Working Tree + Commits) with Auto-Commit/Merge

Send the current implementation plan or a Claude-selected Git change target to OpenAI Codex for review. Code targets may be uncommitted changes, all branch changes relative to a base branch (including committed changes), or a specific commit. Claude revises based on Codex's feedback and re-submits until Codex approves. Max 5 rounds.

On code-review approval, automatically stage+commit the reviewed changes and merge the feature branch back into main (local only — never pushes).

> **Runtime selection**: Use the Codex CLI's native `codex review` command for code
> review. It understands working-tree, base-branch, and commit targets and works
> with ChatGPT login. Use the companion runtime only for plan review, which has no
> native Git review target. Do not pin a legacy `gpt-5.x-codex` model name. For this
> account, prefer `gpt-5.6-sol` with high reasoning for merge-gate reviews; if that
> model is unavailable, retry once with the account default model and high reasoning.

---

## When to Invoke

- When the user runs `/codex-review` during or after plan mode (plan review)
- When the user runs `/codex-review` after implementing code changes, including
  changes that have already been committed (code review)
- When the user wants a second opinion from a different model

## Agent Instructions

When invoked, perform the following iterative review loop.

### Step 0: Check Codex and resolve the companion runtime when needed

Check that the current Codex CLI and authentication are ready:

```bash
codex --version
codex login status
```

For plan review only, resolve the companion path once (picks the newest installed
plugin version) and reuse it for every round:

```bash
COMPANION=$(ls -t "$HOME/.claude/plugins/cache/openai-codex/codex/"*/scripts/codex-companion.mjs 2>/dev/null | head -1)
[ -z "$COMPANION" ] && echo "Codex companion not found — is the openai-codex plugin installed?" && exit 1
# Sanity check the runtime + auth are ready:
node "$COMPANION" setup --json | head -40
```

If `setup --json` reports `"ready": false`, stop and surface its `nextSteps`
(usually `!codex login` or `npm install -g @openai/codex`).

### Step 0b: Stale-runtime recovery (plan review only)

**Symptom**: every `task` call — even with **no `-m`** — fails with
`400 ... The '<model>' model is not supported when using Codex with a ChatGPT
account`, or returns `status != 0` with an empty `rawOutput`. This persists across
`codex login`, `npm install` version changes, and workspace re-login.

**Root cause (observed)**: the companion broker (`app-server-broker.mjs`) keeps a
long-lived `codex app-server` process alive and **reuses it**. If that server was
first started under an older/newer codex whose default model (e.g. `gpt-5.3-codex`)
is not entitled for the account's plan/workspace, the bad default is pinned for the
life of the process — upgrading/downgrading the `codex` CLI does **not** restart it,
so the gating error keeps coming back even though the CLI on disk is fine.

**Fix**: kill the stale runtime so the next `task` spawns a fresh app-server:

```bash
# Show what's running (optional):
ps aux | grep -E 'codex.*app-server|app-server-broker' | grep -v grep
# Kill the broker + app-server (portable; ignore "no process" errors):
pkill -f 'app-server-broker\.mjs' 2>/dev/null
pkill -f 'codex app-server'      2>/dev/null
# On Windows/MSYS where pkill is absent, kill by PID from the ps line above:
#   ps aux | grep -E 'codex.*app-server|app-server-broker' | grep -v grep | awk '{print $2}' | xargs -r kill
```

Then re-run the failing `task` command once. The companion prints
`No shared Codex runtime is active yet ... will start one on demand` and the fresh
server picks up the on-disk codex default, which works. Do **not** downgrade the CLI
or switch workspaces to chase this — it is a stale-process issue, not an account or
version issue. (Only if a *fresh* runtime still gates every model is it a real
account/plan/workspace entitlement problem; then fall back to `!codex login`,
default-workspace change, or `!codex login --with-api-key`.)

### Step 1: Generate Session ID

Generate a unique ID to avoid conflicts with concurrent Claude Code sessions:

```bash
if command -v uuidgen >/dev/null 2>&1; then
  REVIEW_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')
else
  REVIEW_ID="$(date +%s)-$$-${RANDOM:-0}"
fi
```

Use this for the temp file paths: `/tmp/claude-review-${REVIEW_ID}.md` (the content
sent to Codex) and `/tmp/codex-review-${REVIEW_ID}.json` (Codex's JSON response).

### Step 2: Select review mode and code target

Claude selects the target from user intent and repository state. An explicit user
target always wins.

**Mode A — Plan Review** (if a plan exists in the current conversation context):
1. Write the full plan content to `/tmp/claude-review-${REVIEW_ID}.md`
2. Set `REVIEW_MODE=plan`

**Mode B — Uncommitted Code Review**:
Use when staged, unstaged, or untracked changes are the intended target.

```bash
REVIEW_MODE=code
REVIEW_TARGET=uncommitted
```

Native `codex review --uncommitted` includes staged, unstaged, and untracked
changes. Before every round, also run `git status --short` and preserve the listed
paths as `REVIEWED_PATHS` for safe staging after approval.

**Mode C — Branch/Base Code Review**:
Use when the feature branch already contains commits, or when the user asks to
review everything relative to a base branch. Determine the base from the user's
request, then `origin/HEAD`, then fall back to `main`.

```bash
REVIEW_MODE=code
REVIEW_TARGET=base
REVIEW_BASE=<base-branch>
git diff --name-only "$REVIEW_BASE"...HEAD
git diff --name-only
git diff --cached --name-only
```

This mode intentionally reviews committed branch changes. Any uncommitted fixes
made during the loop are also part of the effective branch review and must be
included in `REVIEWED_PATHS`.

**Mode D — Single Commit Review**:
Use when the user names a commit or explicitly asks for only the latest commit.

```bash
REVIEW_MODE=code
REVIEW_TARGET=commit
REVIEW_COMMIT=<sha-or-ref>
git diff-tree --no-commit-id --name-only -r "$REVIEW_COMMIT"
```

If fixes are required for an existing commit, do not rewrite or amend it
automatically. Make a new working-tree fix, and switch subsequent rounds to
`REVIEW_TARGET=base` so Codex reviews the original commit plus the fix together.

**Default detection order**:
1. Explicit plan, commit, or base target from the user
2. Uncommitted changes, including untracked files
3. Current branch changes relative to the detected base branch
4. Otherwise ask what should be reviewed

Tell the user the selected mode and exact target, for example:
`Detected code review — reviewing all changes relative to main (committed changes included).`

### Step 3: Initial Review (Round 1)

Run Codex in the **foreground**. Plan review uses the companion runtime. Code
review uses native `codex review` with the selected Git target.

**For Plan Review (`REVIEW_MODE=plan`):**

```bash
node "$COMPANION" task --fresh --json --model gpt-5.6-sol --effort high \
  "Review the implementation plan in /tmp/claude-review-${REVIEW_ID}.md. Read it, then focus on:
1. Correctness - Will this plan achieve the stated goals?
2. Risks - What could go wrong? Edge cases? Data loss?
3. Missing steps - Is anything forgotten?
4. Alternatives - Is there a simpler or better approach?
5. Security - Any security concerns?

Be specific and actionable. If the plan is solid and ready to implement, end your review with exactly: VERDICT: APPROVED
If changes are needed, end with exactly: VERDICT: REVISE" \
  > /tmp/codex-review-${REVIEW_ID}.json 2>/tmp/codex-review-${REVIEW_ID}.err
```

If `gpt-5.6-sol` is unavailable for the account/workspace, retry once without
`--model` while keeping `--effort high`.

**For Code Review (`REVIEW_MODE=code`):**

```bash
CODEX_REVIEW_PROMPT="Review the selected code changes. Read the relevant source files and project instructions for full context. Focus on:
1. Correctness / bug risk - Will this code work as intended?
2. Regression risk - Could this break existing functionality?
3. Edge cases - Are boundary conditions handled?
4. Security - Any security vulnerabilities introduced?

Classify each issue as:
- BLOCKING: Must fix before merge (bugs, security, data loss risk)
- NON_BLOCKING: Improvement suggestions (can be addressed later)

Report only real problems. Skip style nitpicks unless they could cause bugs.

If the code is solid and ready to merge, end your review with exactly: VERDICT: APPROVED
If changes are needed, end with exactly: VERDICT: REVISE"

case "$REVIEW_TARGET" in
  uncommitted)
    codex -m gpt-5.6-sol -c model_reasoning_effort='"high"' \
      review --uncommitted "$CODEX_REVIEW_PROMPT"
    ;;
  base)
    codex -m gpt-5.6-sol -c model_reasoning_effort='"high"' \
      review --base "$REVIEW_BASE" "$CODEX_REVIEW_PROMPT"
    ;;
  commit)
    codex -m gpt-5.6-sol -c model_reasoning_effort='"high"' \
      review --commit "$REVIEW_COMMIT" "$CODEX_REVIEW_PROMPT"
    ;;
esac > /tmp/codex-review-${REVIEW_ID}.txt 2>/tmp/codex-review-${REVIEW_ID}.err
```

If `gpt-5.6-sol` is unavailable, retry once without `-m gpt-5.6-sol`; keep the
high reasoning override. Do not fall back to a legacy hard-coded model.

**Notes:**
- Both native `codex review` and companion plan tasks are read-only. Do not add
  write access.
- If the user explicitly requests another available model or reasoning effort,
  honor it instead of the defaults above.
- Do not use `--resume-last`; it is repository-global and can resume another
  concurrent review. Every round is fresh and includes the previous feedback and
  revision summary in its prompt.

### Step 4: Read Review & Check Verdict

1. For plan mode, read `/tmp/codex-review-${REVIEW_ID}.json`; the review text is
   the `rawOutput` field. Extract it with the Read tool, or in the same shell with
   `python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['rawOutput'])" /tmp/codex-review-${REVIEW_ID}.json`
   or `jq -r .rawOutput /tmp/codex-review-${REVIEW_ID}.json`.
   (Do NOT use `node -e "...'/tmp/...'"` on Windows: bash redirects to the MSYS `/tmp`
   but Node resolves `/tmp` to `C:\tmp`, so they disagree. `python3`/`jq`/cat read the
   same MSYS `/tmp` as the redirect.)
   For code mode, read `/tmp/codex-review-${REVIEW_ID}.txt` directly.
   - If the command status is non-zero or output is empty, the run failed — show the
     `.err` file. If a pinned model is unavailable, retry once with the account
     default. For companion-based plan review only, if the default still
     model-gates, apply Step 0b before concluding it is an account problem.
2. Present Codex's review to the user:

```
## Codex Review — Round N [Plan|Code]

[Codex's rawOutput here]
```

3. Check the verdict (search `rawOutput` for the marker):
   - If **VERDICT: APPROVED** → go to Step 7 (Done)
   - If **VERDICT: REVISE** → go to Step 5 (Revise & Re-submit)
   - If no clear verdict but feedback is all positive / no actionable items → treat as approved
   - If max rounds (5) reached → go to Step 7 with a note that max rounds hit

### Step 5: Revise

Based on Codex's feedback, the revision approach differs by mode:

**Plan Review**: Revise the plan — address each issue Codex raised. Update the plan in conversation context and rewrite `/tmp/claude-review-${REVIEW_ID}.md`.

**Code Review**: Fix the code — apply changes to the actual source files using Edit tool to address BLOCKING issues. Then regenerate the diff and rewrite `/tmp/claude-review-${REVIEW_ID}.md` with the updated diff.

In both modes, briefly summarize what was changed:

```
### Revisions (Round N)
- [What was changed and why, one bullet per Codex issue addressed]
```

Inform the user: "Sending revised [plan|code] back to Codex for re-review..."

### Step 6: Re-submit to Codex (Rounds 2-5)

Start a fresh review each round to avoid cross-session collisions. Include the
previous review and the exact revisions in the next prompt.

```bash
node "$COMPANION" task --fresh --json --model gpt-5.6-sol --effort high \
  "I've revised the [plan|code] based on your feedback. The updated content is in /tmp/claude-review-${REVIEW_ID}.md.

Previous review:
[Previous Codex review]

Here's what I changed:
[List the specific changes made]

Please re-review. If it's now solid, end with: VERDICT: APPROVED
If more changes are needed, end with: VERDICT: REVISE" \
  > /tmp/codex-review-${REVIEW_ID}.json 2>/tmp/codex-review-${REVIEW_ID}.err
```

For code mode, rerun the matching native `codex review` command from Step 3 with
the previous review and revision list appended to `CODEX_REVIEW_PROMPT`. Recompute
`REVIEWED_PATHS` before every round. If a commit-only review required fixes, switch
to base mode as described in Step 2.

Then go back to **Step 4** (Read Review & Check Verdict).

### Step 7: Present Final Result

Once approved (or max rounds reached):

```
## Codex Review — Final [Plan|Code]

**Status:** Approved after N round(s)

[Final Codex feedback / approval message]

---
**[Plan|Code] has been reviewed and approved by Codex.**
```

If max rounds were reached without approval:

```
## Codex Review — Final [Plan|Code]

**Status:** Max rounds (5) reached — not fully approved

**Remaining concerns:**
[List unresolved issues from last review]

---
**Codex still has concerns. Review the remaining items and decide whether to proceed.**
```

### Step 8: Auto-commit reviewed fixes & Auto-merge (code mode only, on APPROVED)

This step runs **only** when all of the following are true:
- `REVIEW_MODE=code`
- Codex verdict is **APPROVED** (or max-rounds reached with code already fixed — treat max-rounds as NOT approved, skip auto-merge)
- The user has NOT said "review only" / "don't commit" / "don't merge" in the current invocation

Skip this step silently for plan-review mode.

If the reviewed target was already fully committed and no fixes produced working
tree changes, skip commit creation and proceed to merge-target detection.

**Substep 8a — Generate commit message for working-tree changes**

Claude writes a 1–2 line imperative commit message from the diff it already reviewed. Format:

```
<short imperative subject, under 70 chars>

Co-Authored-By: Claude <noreply@anthropic.com>
```

Do not mention the review process in the subject — describe the code change itself.

**Substep 8b — Stage and commit in the current worktree**

Stage only paths in `REVIEWED_PATHS` that still have working-tree changes (do NOT
`git add -A` or `.`). This may include untracked files because native
`--uncommitted` review included them. Commit with the message from 8a.

```bash
# From the current worktree (where the changes are)
git add <files-from-diff>
git commit -m "$(cat <<'EOF'
<subject>

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

If the pre-commit hook fails: report the failure to the user and stop. Do NOT use `--no-verify`. Do NOT amend. The user fixes the hook issue and re-invokes.

**Substep 8c — Determine merge target**

1. Get the current branch: `git rev-parse --abbrev-ref HEAD`
2. Determine the main branch name: `git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@'` — fallback to `main` if not set.
3. If current branch == main branch → already on main, skip merge (commit alone is the result). Go to Step 9.
4. Otherwise, the current branch is a feature branch. Proceed to merge.

**Substep 8d — Locate the main worktree**

`git worktree list --porcelain` lists all worktrees. Find the one whose `branch` is `refs/heads/<main-branch>`. That's the main worktree path.

If no worktree is checked out on main (e.g., main was detached or main branch has no worktree), stop and tell the user: they need to check out main somewhere before auto-merge can run.

**Substep 8e — Merge feature branch into main**

```bash
# From the main worktree directory
cd <main-worktree-path>
git merge --no-ff -m "Merge branch '<feature-branch>'" <feature-branch>
```

Handle outcomes:

- **Clean merge**: report success with the new main HEAD hash. Done.
- **Conflict**: stop immediately. Report which files conflict. Do NOT try to auto-resolve — tell the user to resolve and commit manually, or to abort with `git merge --abort`.
- **Other failure**: report the exact error; do not retry.

**Substep 8f — Safety constraints (must not violate)**

- NEVER run `git push` (push is a separate, explicit user action)
- NEVER use `--force`, `--force-with-lease`, or `--no-verify`
- NEVER delete the worktree or the feature branch (per project memory: worktree deletion crashes running servers)
- NEVER touch the remote in any way

After a successful merge, tell the user:
> Merged `<feature-branch>` into `<main-branch>` (commit `<hash>`). Worktree and feature branch left in place — delete manually when ready (stop any server running from the worktree first).

### Step 9: Cleanup

Remove the session-scoped temporary files:
```bash
rm -f /tmp/claude-review-${REVIEW_ID}.md /tmp/codex-review-${REVIEW_ID}.json /tmp/codex-review-${REVIEW_ID}.txt /tmp/codex-review-${REVIEW_ID}.err
```

## Loop Summary

```
Round 1: Claude selects [plan|uncommitted|base|commit] → Codex reviews → REVISE?
Round 2: Claude revises → fresh review with prior feedback included → REVISE?
Round 3: Claude revises → fresh review with prior feedback included → APPROVED
  ↓ (code mode only)
Auto-commit in current worktree → Auto-merge feature branch into main (local, no push)
```

Max 5 rounds. Each fresh round receives the prior review and revision summary
explicitly, avoiding repository-global resume collisions.

## Rules

- Code review uses native `codex review`; plan review uses the companion runtime.
- Default merge-gate model is `gpt-5.6-sol` with high reasoning. If unavailable,
  retry once with the account default. Honor an explicit user model/effort request.
- Claude **actively revises** based on Codex feedback between rounds — this is NOT just passing messages, Claude should make real improvements
- In code review mode, Claude fixes BLOCKING issues only. NON_BLOCKING items are reported but not auto-fixed
- In code review mode, if a fix contradicts the user's explicit requirements or the project's CLAUDE.md rules, skip that fix and note it for the user
- Codex review runs read-only — Codex never modifies files
- Max 5 review rounds to prevent infinite loops
- Show the user each round's feedback and revisions so they can follow along
- If the companion is missing or `setup --json` is not ready, inform the user and suggest `npm install -g @openai/codex` then `!codex login`

### Auto-commit & auto-merge rules (Step 8, code mode only)

- Runs only on **VERDICT: APPROVED** in code-review mode. Never for plan review. Never on max-rounds-reached-without-approval.
- Skip if the user has said "review only", "don't commit", or "don't merge" in the current invocation.
- Stage only working-tree paths recorded in `REVIEWED_PATHS` — never `git add -A`
  or `.`. Reviewed untracked files are allowed; unrelated untracked files are not.
- If the branch/base or commit target is already committed and there are no
  reviewed working-tree fixes, do not create an empty or duplicate commit.
- Commit message: Claude writes a 1–2 line imperative subject from the reviewed
  working-tree changes and uses `Co-Authored-By: Claude <noreply@anthropic.com>`.
- On pre-commit hook failure: stop and report. Do NOT `--no-verify`. Do NOT amend.
- Merge target: the branch pointed to by `origin/HEAD` (default `main`), merged with `--no-ff`. If already on main, skip the merge step.
- On merge conflict: stop immediately. Do not attempt to auto-resolve. Tell the user which files conflicted and let them resolve manually.
- NEVER `git push`, `--force`, `--force-with-lease`, or `--no-verify`.
- NEVER delete the worktree or feature branch (worktree deletion can crash a server running from its cwd).
- After a successful merge, explicitly remind the user to stop any server running from the worktree before they delete it.
