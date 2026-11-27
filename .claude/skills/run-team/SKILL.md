---
name: run-team
description: Start or resume the planner/worker/reviewer agent team and run it until no tickets are open.
disable-model-invocation: true
---
You are the **lead**. Follow CLAUDE.md. You coordinate only: never plan, model, review or touch Fusion documents yourself.

## Preflight
1. `project/PROJECT.md` exists? If not, tell the user to run `/setup-project` and stop. Agent teams enabled? Fusion MCP (`fusion-cloud`) connected and authenticated (`/mcp`)? If not, stop and tell the user.
2. `scripts/fusion-slot.sh reap`; compare `fusion_sessions` with the leases. Unknown live sessions → ask the user before stopping them.
3. `scripts/ticket.sh open` — nothing open → tell the user and stop.
4. Ask the user once (AskUserQuestion) whether, for this session, you may save a teammate's report or review text verbatim if the harness refuses the teammate's own write of that file (header: "Saved by lead for <name>, unedited, with the user's authorization"). Without that OK, a refused write means: tell the user and wait.

## Spawn the team (agent team, in-process mode)
Spawn exactly these teammates, using the subagent definitions as agent types and these names:
- `planner` (agent type planner), `reviewer` (agent type reviewer), `worker-1` and `worker-2` (agent type worker).
Do NOT name a model in the spawn prompt — the definitions set model and effort. Each spawn prompt: "You are <name>. Read CLAUDE.md and your role instructions. Current board: <project/BOARD.md summary>. Wait for tasks or messages."

## Routing loop
| State | Lead action |
|---|---|
| NEW | dependencies merged? → create `[T###][PLAN]`, assign planner, set PLANNING |
| PLANNED | conflict domain free and a worker idle? → create `[T###][WORK r1]`, assign worker, set IN_WORK |
| IN_WORK / IN_REVIEW / REWORK / MERGING / MERGE_REVIEW | monitor only (reviewer hands rework directly back to the worker) |
| APPROVED | `scripts/check-review.sh T###` passes? → create `[T###][MERGE]`, assign a worker, set MERGING. Fails only on an open merge gate → leave it APPROVED and continue with other tickets |
| ESCALATED | make sure planner has it (the planner settles requirement conflicts itself, CLAUDE.md "Questions & autonomy") |
| MERGED | archive WIP copies per CLAUDE.md, unblock dependent tickets |

## Questions (non-blocking; tickets never wait for the user)
- **Planner reports new questions** → in your next reply to the user, list each one as plain text, once: T###, Q-ID, the question in one line, the options, the planner's decision, merge gate yes/no. Never use AskUserQuestion here, because it stops all routing until the user replies. Keep routing while you wait.
- **User answers, at any time** → write it into that question's `Answer:` line (user, date) and message the planner. Same as the decision → nothing else. Different → apply "Late answers" in CLAUDE.md (PLANNED → PLANNING; IN_WORK / IN_REVIEW / REWORK / APPROVED → ESCALATED and tell the active teammate to finish its step; MERGING or later → follow-up ticket with `--depends T###`).
- **Open merge gates** → remind the user once per question, when the ticket reaches APPROVED.

Scheduling rules: at most as many Fusion users as slots (default 2; the slot script enforces it); never run tickets with overlapping conflict domains in parallel; reviews and merges take priority over new work; respect ticket dependencies.

## Monitoring (every time you wake up)
`scripts/ticket.sh list` and `scripts/fusion-slot.sh status`. Fix task-status lag (verify artifacts, nudge the teammate). Reap stale leases. A ticket in IN_WORK > 90 min without a log entry → ask the worker for status. A teammate that errored → re-instruct it or spawn a replacement with the same name and role.

## Termination
Stop only when `scripts/ticket.sh open` reports nothing, no leases exist and `fusion_sessions` shows no live session. If the only open tickets are APPROVED tickets waiting on merge gates, list the open gate questions for the user and end your turn; resume when they answer. Then: final table (ticket | rounds | final score | merged MAIN version), point the user to project/spec/backlog.md, shut down all teammates. If `project/` is a git repository, commit it there with a summary message (the framework repo ignores `project/`).
Never end your turn while a ticket is in NEW, PLANNED, APPROVED or ESCALATED without having acted on it.
