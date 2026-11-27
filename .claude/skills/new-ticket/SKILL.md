---
name: new-ticket
description: Create a new design ticket for the Fusion agent team from the user's request, with a short intake interview.
---
Create a ticket with `scripts/ticket.sh new "<short title>" --request "<request verbatim>"` from: $ARGUMENTS
Add the dependencies (`--depends`) and priority (`--priority`) the user mentioned, and their explicit constraints under Constraints in ticket.md. Do not plan or propose solutions; that is the planner's job.

## Intake: the one time the team asks
After intake the team works without waiting for the user (CLAUDE.md "Questions & autonomy"), so ask everything that matters now, while the user is here.
1. Offline only, no Fusion session: read project/PROJECT.md, project/spec/requirements.md, project/spec/parameters.md, project/fusion/snapshot/README.md and the answered questions in project/work/*/questions.md.
2. List what the request leaves open that would change the design: scope (which parts, sides, variants), target values or limits, what must stay unchanged, how to trade off conflicting goals (e.g. size vs. strength), what "done" looks like, and anything that touches a merge gate (points the requirements or project/PROJECT.md reserve for the user). Leave out what the spec or an earlier answer already settles, and don't ask how to model it.
3. Ask with AskUserQuestion: up to 4 questions per call, concrete options, recommended option first. If nothing is open, ask nothing.
4. Write each question as a `## Q<n>` block in questions.md with `Asked: intake (lead, <date>)` and the user's `Answer:` (user, <date>). A skipped question gets `Answer: skipped — planner decides`. Hard constraints from the answers also go under Constraints in ticket.md.
5. Show the updated project/BOARD.md.
