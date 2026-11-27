# Fusion Compute MCP — verified capabilities and gotchas

Generic knowledge for agents that script Autodesk Fusion through the **Fusion Compute MCP** (cloud Fusion sessions).
Everything here was verified in real team sessions on a large assembly (~3,000 bodies, ~250 occurrences, ~1,800 timeline
items, full recompute ≈ 45 s) with engine build 2706.1.14 (November 2026, public beta). Behaviour may change with newer
builds: when something here turns out wrong, fix it and note the build.

Findings that only concern your design go into `project/fusion/notes.md`.
Placeholders in snippets: `<MAIN_URN>` (lineage URN of MAIN), `<WIP_FOLDER_URN>`, `<ARCHIVE_FOLDER_URN>`, `<COPY_URN>` —
the real values are in `project/fusion/documents.md`.

## MCP tools
Server `fusion-cloud` = `https://developer.api.autodesk.com/da/v3/mcp/fusion` (tool mode **Execute**, the default).
- **Orchestrator tools** (call directly, prefix `mcp__fusion-cloud__`): `start_fusion`, `fusion_status`, `fusion_sessions`,
  `stop_fusion`, `invoke_fusion`, `fusion_call_result`, `fusion_view_3d`, `fusion_api_index`, `fusion_get_sample`.
  `fusion_api_index` and `fusion_get_sample` need no session — use them while preparing offline.
- **Worker tools** — ONLY via `invoke_fusion({engine_session_id, tool, arguments})`:
  `MCP.Documents` (list/open/activate/save/saveAs/close/closeAll), `MCP.FusionTeam` (hubs/projects/folders/search/resolve),
  `MCP.IO` (screenshot/export/import), `MCP.BundleInfo`, `MCP.ExecuteTypeScript` (`{code}` only — no parameters channel;
  edit constants in the code instead).

## Capability matrix
| Capability | Result | How |
|---|---|---|
| Session lifecycle (`fusion_sessions` / `start_fusion` / `fusion_status` / `stop_fusion`) | ✅ start ≈ 7 s without queue; status `active`; `pendingCall` shows a running call | S1 |
| Desktop Fusion counts against the cloud sessions? | ✅ **No** — `fusion_sessions` listed 0 sessions while the desktop app was open with the same account | — |
| Open a document by hub / project / folder / name | ✅ `MCP.FusionTeam resolveDocumentTargets` → lineage URN → `start_fusion(designUrn)` or `MCP.Documents open` | S2 |
| Read the version list | ✅ `dataFile.versions` (number + description; order NOT sorted — sort yourself) | S3 |
| Save-As into another folder | ✅ `MCP.Documents saveAs` (name, targetFolderUrn, description). **The open document becomes the copy**; the source stays untouched | S4 |
| Save with a version description | ✅ `MCP.Documents save {description}` | S4 |
| Restore an older version as latest (rollback) | ⚠️ `doc.save()` on an opened old version returns true but creates **no** version (silent no-op). ✅ `oldVersion.promote()` creates a new latest version with the old content; then add a marker save | S5 |
| Read/write user parameters | ✅ `userParameters.itemByName(n).expression = "…"`, `add(...)`, `deleteMe()` | S6 |
| Physical properties | ✅ `component.getPhysicalProperties(accuracy)`; out-params come back as tuples (`getXYZMomentsOfInertia()` → `[ok, xx, yy, zz, xy, yz, xz]`) | inventory.ts |
| Interference analysis | ✅ scoped sets (92 occurrences: 0.9 s). ❌ whole assembly (250 top-level occurrences) → `analyzeInterference` returns `undefined` after ~60 s | S7 |
| Drive joints, read joint values | ✅ `asBuiltJoint.jointMotion.rotationValue = rad` solves the linkage (≈ 85 ms); reading back works | S8 |
| Timeline health | ✅ `timeline.item(i).healthState` (0 ok, 1 warning, 2 error, 3 suppressed, 4 rolled back), `isSuppressed`, `isRolledBack`; as-built joints report `unknown` | inventory.ts |
| Export STEP | ✅ `MCP.IO export {format:"step"}` (async; 21.5 MB in ~20 s); the signed-URL body is **base64** → `curl … \| base64 -d > x.step`; also returns a 15-min hosted viewer URL | S9 |
| Render | ✅ `MCP.IO screenshot {delivery:"signedUrl", directions:[…]}` → PNG URL (download with curl — saves context compared with inline images). `fusion_view_3d` = viewer alias of `MCP.IO export` | S9 |
| Create folders, move files | ✅ `rootFolder.dataFolders.add("WIP")`; `(dataFile as any).move(folder)` works at runtime although it is missing from the TS typings; lineage unchanged | S10 |
| Full recompute time | ✅ `design.computeAll()` timed in a script | S11 |

## Protocol consequences (already built into CLAUDE.md)
1. **Rollback** = `promote()` the pre-merge version (S5), then open the latest version, make a reversible no-op change
   (set a user parameter to a temporary value and back) and save with `[ROLLBACK T###] …` so the history carries a marker.
2. **Scoped interference only.** Check the touch set + every neighbouring occurrence (and anything within the range of
   motion), on MAIN@base and on the submission with the **same entity set**; only new pairs count.
3. **Inventory per component definition**: hashes and totals per component; per-body rows only for `OPTIONS.detail`.
4. **Large results** land in a file (Claude Code persists MCP outputs > ~25k tokens and prints the path). Never read them
   in full: `python3 scripts/fusion/save-result.py <that path> <out.json>`.
5. **Long calls**: `invoke_fusion(..., async: true)` + `fusion_call_result`. Never re-send a call that returned
   `working` — it would run twice. If the MCP transport drops, check `fusion_status.pendingCall` first.

## Sessions and script execution
- **One call at a time per engine session.** A second EXECUTE while one runs is rejected with the pending callId.
- **`fusion_call_result` waits ≤ 25 s** were reliable; 40 s waits often dropped the transport.
- **A call that passes 300 s is reported failed and the engine reloads its start document** (the `designUrn` of
  `start_fusion`). Unsaved work in any other open document is gone and the active document silently becomes the start
  document. Check `app.activeDocument.name` before saving after any timeout. Make long changes resumable with a per-call
  time budget, and save WIP copies between calls.
- **A thrown exception does NOT roll the model back** in `MCP.ExecuteTypeScript` (unlike the desktop Python bridge).
  Features created before the throw stay. Validate before editing, make scripts idempotent (skip-if-exists), and discard
  a bad state with `stop_fusion` + `start_fusion(designUrn)` — never by saving.
- **Same-engine reopen can corrupt the in-memory model.** After `closeAll` + `open` of the same document in the same
  engine, followed by `computeAll`, most bodies once read the wrong material (and the total mass was off by 80 %) while
  the geometry was fine. The saved version was correct. Do reopen checks (fresh-open timing, rerun-after-reopen) with a
  fresh `stop_fusion` → `start_fusion`. Check materials and total mass before any save that follows a same-engine reopen.
- **Recompute timing drifts within a session**: consecutive `computeAll` calls get slower regardless of content
  (44.8 → 58.5 → 61.9 → 63.4 s). Compare recompute times only on the **first `computeAll` after a fresh open**.
- **Opening a large assembly marks it `isModified`** (references/recompute). Never call save on MAIN outside [MERGE].
- **Only close documents you created.** A script that closed "every unsaved document" also closed the MCP capture-helper
  document ("Capture helper document was not found after TypeScript.Execute returned"). Keep the reference from
  `app.documents.add(...)` and close only that one.

## TypeScript rules (`MCP.ExecuteTypeScript`)
- No top-level `import`/`export`; `adsk` is ambient; types via `type X = import("@adsk/fusion").adsk.fusion.X;`.
- Return data with the literal spelling `adsk.result = JSON.stringify(...)`; progress with `adsk.log(...)`.
- **const enums cannot be aliased** (`const CA = adsk.fusion.CalculationAccuracy` → compile error). Write
  `adsk.fusion.CalculationAccuracy.MediumCalculationAccuracy` in full.
- Internal units: cm, kg, rad. `unitsManager.convert(v, "cm", "mm")`.
- `SurfaceEvaluator.parametricRange()` (there is no `getParameterRange`). `getPointAtParameter` / `getNormalAtParameter`
  return `[ok, value]`.

## Measuring geometry
- **`getPhysicalProperties(Medium).volume` is not deterministic across loads** (masses shift by up to 0.017 %). Never use
  it as a script input; compare across sessions with a tolerance (±0.1 %). `Σ bRepBody.volume` (exact B-rep) was stable.
- **`BRepBody.volume` differences are unreliable on bodies with NURBS pipe faces** (bias up to 0.29 mm³ on a 7.9 mm³
  change). Measure added/removed material with booleans (TemporaryBRepManager `base − final`), not by subtracting volumes.
- **`root.boundingBox` can be stale** on large assemblies (it missed whole subassemblies). For the envelope, use the union of
  `occurrence.boundingBox` over the top-level occurrences.
- **`measureManager.measureMinimumDistance` rejects native faces of a sub-component** ("invalid argument geometryOne").
  Pass `face.createForAssemblyContext(root.allOccurrencesByComponent(comp).item(0))` for both arguments.
- **Face evaluators of proxy faces do not take world points** (`getParameterAtPoint` + `isParameterOnFace` false
  everywhere). `BRepBody.pointContainment` on a proxy body works (0 inside, 2 outside). Contact test: a point 0.02 mm on
  each side of the face.
- `pointContainment` costs ≈ 10 ms per call on complex bodies. For line scans, step coarsely, then bisect.
- **Section views**: `TemporaryBRepManager.planeIntersection(body, Plane)` returns a wire body. Sample it with
  `edge.evaluator.getStrokes(t0, t1, tol)` (`getPointAtParameter` threw on some section edges). Polygons can keep one
  sub-0.1 mm endpoint gap: snap odd endpoints before an even-odd fill, otherwise whole sections drop out silently. Plot as
  SVG locally; on macOS `qlmanage -t -s <px> -o <dir> file.svg` makes a PNG.
- **Count micro faces (< 0.01 mm²) and micro edges (< 0.01 mm) before and after every boolean.** Sliver faces of 0.1 µm
  are invisible to volume checks; one review round failed on ~40 of them.

## Modelling with TemporaryBRepManager and features
- **Throw-away prototyping without touching MAIN**: `tbm.copy(body)` → `app.documents.add(FusionDesignDocumentType)` →
  `designType = Parametric` → BaseFeature `startEdit` / `bRepBodies.add(tmp, bf)` / `finishEdit` → features → `doc.close(false)`.
- **Bodies of BaseFeatures are not driven by upstream sketches** any more. Edit them with new features at the end of the
  timeline.
- **Read consumed tool bodies without editing**: `tl.item(i).rollTo(false)` right after the BaseFeature,
  `tbm.copy(bf.bodies.item(0))`, then `tl.moveToEnd()` (in `finally`). Same for a body "before feature X":
  `timelineObject.rollTo(true)`. TBM copies die with the script call — do everything in one call.
- **Coincident seams merge only if the transform is exact.** Booleans of exactly transformed copies give one clean solid,
  but targets derived from occurrence origins or bbox planes were 0.02–0.16 µm off and left sliver faces. Derive
  transforms from the body's own geometry (cylinder axes from `BRepFace.geometry`, planar faces). A mirrored "copy" in a
  model is not necessarily exact — check before relying on it.
- **Near-coincident booleans** (gap < ~5 µm) fail with `ASM_INCONS_FACE`. Keep a clear gap (0.03 mm worked) or reuse the
  exact same surface.
- **Occurrences are not always at identity.** Build tools in world space on the proxy body and map them with
  `tbm.transform(tool, inverse(occ.transform2))` before `bRepBodies.add(tool, baseFeature)`.
- **`deleteFaceFeatures` can remove real material** while reporting healthy (a 0.007 mm step removed 35.6 mm³). Always
  compare the volume change with the expected fill.
- `PipeFeatures` work along a 3D `sketchFittedSplines.add(points)` path; `sectionSize` is the **diameter**.
- `tbm.createTorus(center, axis, R, r)` exists.

## Materials and appearances
- **Never write a property of a material that is in use** (e.g. `structural_Density`). Fusion keeps the old entry and adds
  a second one with the same name; both report `isUsed = true`, so neither can be deleted. Set properties only right after
  `addByCopy`, before assigning; on reruns verify, don't edit.
- `addByCopy` keeps the base id (several materials can share one `PrismMaterial-…` id). Look materials up by name.
- `Material.appearance` is read-only. Change looks with a body appearance override (`body.appearance = designAppearance`).
- `BRepBody.visibleOpacity` throws InternalValidationError on native bodies. `Occurrence.visibleOpacity`,
  `Component.opacity` and `BRepBody.opacity` work.
- **Enumeration order and `isUsed` of `design.appearances` / `design.materials` depend on the load.** Compare lists as a
  multiset of (name, id), never by order or `isUsed`.

## Assemblies and joints
- **Moving rigid-grouped occurrences**: `rigidGroup.deleteMe()` → set `occurrence.transform2` → `design.snapshots.add()`
  (`hasPendingSnapshot` is true first) → `rootComponent.rigidGroups.add(members, false)` + restore the old name →
  `computeAll`. A 180° turn about a line ∥ Y through (x0, z0): negate rows 0 and 2 of `transform2.asArray()` and set
  `tx' = 2·x0 − tx`, `tz' = 2·z0 − tz`.
- **Joint sweeps change other joints.** Driving a joint and setting it back can leave linkage joints reading ±360°.
  Normalise to (−π, π] and never save after a sweep.
- **The solver for closed linkage loops is path dependent.** Jumping straight from home to a range corner sometimes stops
  short. Approach corners in steps; a stop-short is not a range-of-motion limit by itself.
- **Revolute joint limits are wrapped into 0..360°**: `minimumValue = -264°` is stored as 96° and the solver moves the
  joint into the new range. Multi-turn ranges cannot be Fusion limits (joint values themselves are multi-turn).
- **`asBuiltJoint.geometry` can throw** "Cannot find joint geometry data, please roll back timeline". The joint still moves
  but exporters cannot read an origin. Derive pivots from geometry instead, or rebuild the joint:
  `JointGeometry.createByNonPlanarFace(face, StartKeyPoint)` + `setAsRevoluteJointMotion(ZAxisJointDirection)`.
  Delete its motion link first; recreate with `motionLinks.createInput(j1, j2)`, `valueOne/valueTwo`, `isReversed`.
- **`asBuiltJoints.add` cost**: ~0.5 s each on a freshly opened large design, 1–2.4 s right after large unsaved edits. A
  `computeAll()` or a save brings it back down. 225 joints = 2–9 min → split across calls (300 s limit).
- `Occurrence.isGrounded = false` creates an "Unpin" timeline item.
- **`analyzeInterference`** returns `undefined` for the whole assembly and for any set that contains a very large
  occurrence (one with 300+ bodies). Use TBM booleans there. `interferenceBody.volume` reads 0 → use the pair list.
  Line-to-line fits (vendor models, coincident faces) are still reported with coincident faces excluded — record them in
  the interference baseline.

## Documents, versions, folders
- `dataFile.versions` is not sorted. `app.documents.open(dataFile.versions.item(i))` opens an older version (read-only
  use); close it with `close(false)` and re-activate the working document.
- Avoid `listFolderContents` on a large project root (69 files ≈ 60 KB of output); resolve by name (S2).

## Snippets (all verified)
**S1 — session lifecycle** (orchestrator tools)
```
fusion_sessions({})                                   → engineSessions[] (authoritative live sessions)
start_fusion({engine_session_id: "<name>-T###", designUrn: "<MAIN_URN>"})
fusion_status({engine_session_id})                    → Status active / queuedStart / pendingCall
stop_fusion({engine_session_id})
```
**S2 — resolve by names**
```
invoke_fusion({engine_session_id, tool: "MCP.FusionTeam", arguments: {mode: "resolveDocumentTargets",
  projectName: "<project>", fileName: "<document name>"}})
→ lineageUrn, versionNumber, folderId; then {tool:"MCP.Documents", arguments:{mode:"open", lineageUrn}}
```
**S3 — version list (TypeScript)**
```ts
const df = app.data.findFileById("<MAIN_URN>");
const vs = df.versions; for (let i = 0; i < vs.count; i++) { const v = vs.item(i); /* v.versionNumber, v.description */ }
// df.latestVersionNumber; current doc: app.activeDocument.dataFile.versionNumber
```
**S4 — Save-As / save with description**
```
{tool:"MCP.Documents", arguments:{mode:"saveAs", dataFileUrn: "<MAIN_URN>", name:"<Doc>__T###_r<N>",
  targetFolderUrn:"<WIP_FOLDER_URN>", description:"[T### r<N>][<name>] base MAIN v<x>"}}
{tool:"MCP.Documents", arguments:{mode:"save", description:"[T### r<N>][<name>] submission"}}
```
**S5 — rollback (promote + marker save)**
```ts
const df = app.data.findFileById("<MAIN_URN>"); let pre: any = null;
for (let i = 0; i < df.versions.count; i++) if (df.versions.item(i).versionNumber === PRE_MERGE_VERSION) pre = df.versions.item(i);
pre.promote();   // → new latest version with the pre-merge content
// then: MCP.Documents close (saveChanges:false) + open lineage (latest); toggle a user parameter and back; MCP.Documents save
//       {description: "[ROLLBACK T###] restore v<pre>"}; verify inventory == pre-merge snapshot
```
**S6 — user parameters**
```ts
const p = design.userParameters.itemByName("wall_t"); p.expression = "1.2 mm";
const q = design.userParameters.add("name", adsk.core.ValueInput.createByString("3 mm"), "mm", "comment"); q.deleteMe();
```
**S7 — scoped interference**
```ts
const ents: any[] = [/* occurrences of the touch set + neighbours */];
const res = design.analyzeInterference(design.createInterferenceInput(ents));
const nm = (e: any) => (e.assemblyContext ? e.assemblyContext.component.name + "/" : "") + e.name;
for (let i = 0; i < res.count; i++) { const r: any = res.item(i); /* nm(r.entityOne), nm(r.entityTwo) */ }
```
**S8 — drive a joint and read values**
```ts
let j: any = null; for (let i = 0; i < root.asBuiltJoints.count; i++) if (root.asBuiltJoints.item(i).name === "<joint>") j = root.asBuiltJoints.item(i);
j.jointMotion.rotationValue = 30 * Math.PI / 180;      // solves the linkage; read occurrence.transform2 / other joints
const deg = j.jointMotion.rotationValue * 180 / Math.PI; // limits: j.jointMotion.rotationLimits.minimumValue / maximumValue (rad)
```
**S9 — render / STEP**
```
{tool:"MCP.IO", arguments:{mode:"screenshot", delivery:"signedUrl", directions:["isoTopRight"], width:1024, height:768}}  → curl -o render.png "<url>"
{tool:"MCP.IO", arguments:{mode:"export", format:"step"}, async:true} → fusion_call_result → curl -s "<url>" | base64 -d > model.step
```
**S10 — folders / archive**
```ts
const rootF = app.activeDocument.dataFile.parentProject.rootFolder;
const wip = rootF.dataFolders.itemByName("WIP") || rootF.dataFolders.add("WIP");
(app.data.findFileById("<COPY_URN>") as any).move(app.data.findFolderById("<ARCHIVE_FOLDER_URN>"));
```
**S11 — recompute time**
```ts
const t0 = Date.now(); design.computeAll(); const ms = Date.now() - t0;   // first computeAll after a fresh open only
```
