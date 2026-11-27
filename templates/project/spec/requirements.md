# Requirements — <design name>

**Status: draft (<date>).** Requirements change only by the user (via lead). Number every requirement (R<n>.<m>) so
plans, reviews and merge gates can cite it. Quote user decisions verbatim with date.

## User statement (verbatim, <date>)
> <design intent in the user's words>

## R1 — Standard and purchased parts (hard constraints)
- **R1.1 Fasteners:** <allowed types/sizes; which existing screws are approved>
- **R1.2 <Bearings / motors / electronics>:** <part numbers that must not change; fit and access to keep>

## R2 — Envelope
- **R2.1 Overall size:** baseline MAIN v<n>, rest pose: length X <…> × width Y <…> × height Z <…> mm (from the snapshot).
  Growth beyond <…> mm in length or width needs the user (merge gate).
- **R2.2** <compactness / mass goals>

## R3 — Function
- **R3.1 Ranges of motion must not shrink:** <joint names and limits from the snapshot>
- **R3.2 No interference** over the full range of every affected joint, except the intended fits recorded in
  `project/fusion/snapshot/interference-baseline.json` (scoped checks, see `fusion/capabilities.md`).
- **R3.3 Model health:** zero timeline errors; MAIN stays fully recomputable (baseline `computeAll` <…> s; > 20 % slower = performance issue).

## R4 — Fabrication (reviewer enforces)
| Rule | Value |
|---|---|
| Process / material | <e.g. SLA, Formlabs Tough 2000; FDM PETG; CNC 6061> |
| Minimum wall thickness | <mm> |
| Clearance fit | <mm, diametral> |
| Press fit | <mm> |
| Minimum hole Ø | <mm> |

## Open points for the user
None.
