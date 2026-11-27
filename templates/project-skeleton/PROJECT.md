# Project rules — <design name>

Project-specific additions to CLAUDE.md, imported into every agent's context. `/setup-project` fills this in; the user
owns it and may edit it at any time. Keep it short: details belong in spec/requirements.md.

## Design in one paragraph
<What is designed, what it is for, key purchased parts, fabrication process.>

## Merge gates (decisions reserved for the user)
The team plans, builds and reviews these variants; only the [MERGE] waits for the user's answer (CLAUDE.md "Questions & autonomy").
- Any exception to a requirement in spec/requirements.md (always).
- <e.g. overall length or width grows by more than 8 mm (R2.1) — also set FUSION_GROWTH_GATE_MM, see below>
- <e.g. a new fastener type or size (R1.1)>
- <e.g. changed interface dimensions: bearing seats, connector cut-outs, mounting holes (R1.3)>

## Priorities when goals conflict (planner decision rule 4)
1. <e.g. compactness>
2. <e.g. mass>
3. <e.g. print time>

## Units & naming
mm, deg, g. Naming examples from this design: <`GearboxHousing_Left`, `MotorMount_Front`>.

## Scale hints (from the snapshot)
<components / occurrences / bodies / timeline items / full recompute time. Tells agents how expensive inventories,
recomputes and interference checks are, and whether OPTIONS.detail must be narrow.>

## Envelope gate
`scripts/diff-inventory.py` flags length/width growth above `FUSION_GROWTH_GATE_MM` as a merge gate. Set it per user in
`.claude/settings.local.json`: `{"env": {"FUSION_GROWTH_GATE_MM": "8"}}`.

## Standing user decisions
Decisions that apply to every ticket (quote the user, with date).
- A MAIN version the user saves outside the team counts as intended: keep it and rebase (framework default).
