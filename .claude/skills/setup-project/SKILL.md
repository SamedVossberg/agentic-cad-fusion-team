---
name: setup-project
description: Connect the Fusion design team to a design — interview the user, create project/ from templates/project/, run the Phase 0 capability check and take the first MAIN snapshot.
disable-model-invocation: true
---
You are the **lead**, connecting the team to a Fusion design. Follow CLAUDE.md. Arguments (optional design name or notes): $ARGUMENTS

## 1. Preflight
- `project/PROJECT.md` already exists → this is a re-run. Summarise what is configured and ask (AskUserQuestion) whether to refresh only the snapshot (step 5) or redo the interview. Never overwrite the user's files without asking.
- The Fusion Compute MCP server `fusion-cloud` (`.mcp.json`) must be connected and authenticated. If `/mcp` shows it unauthenticated, ask the user to sign in with their Autodesk account there, then continue.
- `python3` available, `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` set (`.claude/settings.json` does this).

## 2. Interview (AskUserQuestion, up to 4 questions per call, concrete options, recommended option first)
1. Fusion Team hub / project / folder that contains MAIN, and the MAIN document name. MAIN = the joint version; only [MERGE] tasks write it.
2. Folder for work-in-progress copies (default `WIP` next to MAIN, archive `WIP/_archive`; agents move, never delete).
3. Fabrication method and the tolerances the reviewer enforces: minimum wall, clearance fit, press fit, minimum hole Ø.
4. Hard constraints: purchased parts that must not change, envelope limits, what must stay functional (joints and ranges of motion).
5. Merge gates: which decisions stay with the user (any requirement exception is always one). Envelope growth limit in mm, if any.
6. Priorities when goals conflict (e.g. compactness > mass > print time).
Also ask for a verbatim statement of design intent; quote it in requirements.md.

## 3. Create project/
`mkdir -p project && cp -Rn templates/project/. project/` (`-n`: never overwrite). Fill `project/PROJECT.md` and `project/spec/requirements.md` from the answers: number every requirement (R<n>.<m>) so plans, reviews and merge gates can cite it. If the user gave an envelope limit, add `"env": {"FUSION_GROWTH_GATE_MM": "<mm>"}` to `.claude/settings.local.json` (create or merge; never touch `.claude/settings.json` for project values).
Ask whether `project/` should become its own private git repository (`git -C project init`). The framework repo ignores `project/`.

## 4. Phase 0 — capability check (one Fusion slot)
Prepare offline from `fusion/capabilities.md` (snippets S1–S11). Then `scripts/fusion-slot.sh claim lead T000 1` (T000 = setup) and `start_fusion` on MAIN.
1. Resolve MAIN by names (S2) → lineage URN and current version. Create `WIP` and `WIP/_archive` if missing (S10) → folder URNs.
2. Save-As MAIN to `WIP/_archive/<Doc>__T000_capcheck` (S4). On that copy only: write a user parameter and set it back, save with a description, promote an older version and save a marker version (S5). Never save MAIN.
3. Re-open MAIN (fresh `start_fusion` on its URN) and run `scripts/fusion/inventory.ts` with `recompute: true` (async). Save it with `save-result.py` to `project/fusion/snapshot/inventory.json`, then `python3 scripts/fusion/snapshot-md.py project/fusion/snapshot/inventory.json > project/fusion/snapshot/README.md`. Render `isoTopRight` (S9) to `project/fusion/snapshot/render-isoTopRight.png`.
4. If the design has joints: drive one through its range and back (S8). Run a scoped interference check (S7) on each moving subassembly with its neighbours and save the pairs to `project/fusion/snapshot/interference-baseline.json`. Ask the user which pairs are intended (press fits, threads modelled at nominal size) and label them.
5. Record every result in `project/fusion/notes.md` (date, engine build from `fusion_status`, what worked). Anything that behaves differently from `fusion/capabilities.md`: write it down and tell the user; change the protocol only with their agreement.
6. `stop_fusion`, `scripts/fusion-slot.sh release <slot> lead`.

## 5. Fill the rest from the snapshot
- `project/fusion/documents.md`: hub, project, folder and lineage URNs, naming table with the real `<Doc>` name, first row of the MAIN version history.
- `project/spec/parameters.md`: one row per user parameter (name, value, unit, meaning from the comment, referenced yes/no).
- `project/PROJECT.md` → Scale hints: components / occurrences / bodies / timeline items / full recompute time.
- `project/spec/requirements.md`: baseline envelope (overall bbox), joints with their limits, recompute baseline.
- Pre-existing fragments the inventory shows (suppressed features, unused parameters, hidden leftovers, timeline warnings): list them in `project/spec/backlog.md` for the user to decide. They are not tickets yet.

## 6. Finish
Run `scripts/ticket.sh list` (creates `project/BOARD.md`). Report to the user: what was set up, Phase 0 results and deviations, the backlog findings, and the next steps: `/new-ticket <request>` to add work, `/run-team` to let the team work until the board is empty, `/board` for status.
