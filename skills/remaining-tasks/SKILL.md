---
name: remaining-tasks
description: Show the remaining tasks for the current project as a grouped, actionable list — pulled from the conversation, git state, project docs, open issues, and running background work. Use when the user types /remaining-tasks or asks for 残タスク / what's left / remaining work / TODO list.
user_invocable: true
---

# remaining-tasks

Produce an up-to-date list of what is left to do. **Read-only: list the tasks, do not start doing them.**

## Sources (check all, in this order)

1. **Conversation.** Things promised but not done, questions asked but not answered, results not yet verified
   ("compiled but not run", "checked in Editor, not on hardware"), decisions the user deferred, assets or
   information the user said would come later. This is usually the richest source — scan the whole session,
   not just the last few turns.
2. **Git.**
   ```bash
   git status --short
   git log --oneline @{u}..HEAD 2>/dev/null   # committed but not pushed
   git submodule status                        # submodules with local changes / detached
   ```
   Uncommitted changes and unpushed commits are tasks. Note what they contain, not just file names.
3. **Running work.** Background shells, reviews, builds, agents still in progress. Say they are running;
   never guess their result.
4. **Project docs.** `CLAUDE.md` (and files it points to): sections like 未確定事項 / 未実装 / TODO / ⚠ open
   questions / milestones. Only list items that are still open — check against the conversation and code
   before listing (a doc can lag behind work done this session).
5. **Issues (optional).** If the repo has a GitHub remote and `gh` is authenticated:
   `gh issue list --state open --limit 30`. Summarize only those relevant to the current work; mention the count
   of the rest.

## Grouping

Use these groups, in this order. Omit a group that is empty.

| Group | What goes in it |
|---|---|
| 今の作業の続き (in progress) | Uncommitted / unpushed work, running reviews or builds, cleanup left from this session |
| 素材・機材待ち (waiting on others) | Assets, hardware, information someone else must provide. Say who, if known |
| 実機・手動で確かめること (verify) | Things only testable on real hardware / by a human, or not yet verified. Say what "done" looks like |
| 決まっていないこと (decisions) | Open questions for the user or a third party. Phrase each as the actual question |
| 運用・本番前 (before release / ops) | Deployment steps, settings to flip before production, one-time setup |

## Rules

- **Write in the user's language** (this is usually Japanese). No preamble — start with the list.
- One line per task where possible; nest only when a task has distinct sub-steps.
- Each item must be **actionable**: what to do, and who (user / Claude / a named third party) when it isn't obvious.
- **Do not invent tasks** or pad the list with generic advice ("write tests", "add docs") that nobody asked for.
- **Do not list finished work.** If something was done but not verified, list the verification, not the work.
- Be explicit about verification state: "compiled, not run", "checked in Editor only", "unverified on hardware".
- If a task depends on another, say so briefly ("after X").
- Keep file paths and identifiers in backticks so they are clickable / greppable.
- End with nothing extra — no summary, no offer to start. If one item is clearly the next step, the user will ask.
