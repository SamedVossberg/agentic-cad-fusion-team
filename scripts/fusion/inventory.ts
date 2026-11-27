// Fusion design inventory → compact JSON (schema "fusion-inventory/2", consumed by scripts/diff-inventory.py).
// Run on the ACTIVE design via the Fusion Compute MCP — read-only, never saves:
//   invoke_fusion({ engine_session_id, tool: "MCP.ExecuteTypeScript", arguments: { code: <this file> }, async: true })
//   then fusion_call_result({ callId, engine_session_id }) until done.
// MCP.ExecuteTypeScript takes only `code` (no parameters channel) → edit the OPTIONS line below, nothing else.
// Save the result with:  python3 scripts/fusion/save-result.py <tool-result file | -> <out.json>
//
// Built for large assemblies (tested with ~3000 bodies in ~250 occurrences): bodies are summarised PER COMPONENT DEFINITION
// (count, hidden names, summed volume, union bbox in component space, name hash, geometry hash) and
// placements per component as a transform hash. Full per-body rows only for OPTIONS.detail components
// (put the ticket's touch set there). Units: mm, mm², mm³, g, g·mm², deg (Fusion internal: cm, kg, rad).
//
// OPTIONS:
//   detail:   component names whose bodies are listed individually ([] = none, ["*"] = all — huge, avoid)
//   recompute: true → time design.computeAll() → recomputeMs. Slow on large designs; use for baselines/reviews.
//   physical: "all" (every component with geometry) | "root" (whole assembly only) | "none"
//   physicalAccuracy: "low" | "medium" | "high" | "veryhigh"  — keep identical between compared inventories
const OPTIONS = { detail: [] as string[], recompute: false, physical: "all", physicalAccuracy: "medium" };

type Design = import("@adsk/fusion").adsk.fusion.Design;
type Component = import("@adsk/fusion").adsk.fusion.Component;

function run() {
  const app = adsk.core.Application.get();
  if (!app) throw Error("No adsk.core.Application.");
  const design = app.activeProduct as Design;
  if (!design || !design.rootComponent) throw Error("Active product is not a Fusion design.");
  const root = design.rootComponent;
  const opts: any = OPTIONS;
  const t0 = Date.now();

  const r = (x: number, d: number) => { const f = Math.pow(10, d); return Math.round(x * f) / f; };
  const mm = (cm: number) => r(cm * 10, 4);
  const deg = (rad: number) => r(rad * 180 / Math.PI, 4);
  const HS = ["healthy", "warning", "error", "suppressed", "rolledBack", "unknown"];
  const safe = (f: () => any, d: any = null) => { try { const v = f(); return v === undefined ? d : v; } catch (e) { return d; } };
  const fnv = (s: string) => { let h = 0x811c9dc5; for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 0x01000193) >>> 0; } return ("0000000" + h.toString(16)).slice(-8); };
  const isParametric = safe(() => design.designType === adsk.fusion.DesignTypes.ParametricDesignType, false);
  // const enums cannot be aliased (compile error) — always write the full adsk.fusion.<Enum>.<Member>
  const acc = String(opts.physicalAccuracy).toLowerCase();
  const accuracy = acc === "low" ? adsk.fusion.CalculationAccuracy.LowCalculationAccuracy
    : acc === "high" ? adsk.fusion.CalculationAccuracy.HighCalculationAccuracy
    : acc === "veryhigh" ? adsk.fusion.CalculationAccuracy.VeryHighCalculationAccuracy
    : adsk.fusion.CalculationAccuracy.MediumCalculationAccuracy;

  // ---- document -------------------------------------------------------------------------------
  const doc = app.activeDocument;
  const df: any = safe(() => doc.dataFile);
  const document = {
    name: safe(() => df.name, safe(() => doc.name)), lineageUrn: safe(() => df.id), versionId: safe(() => df.versionId),
    version: safe(() => df.versionNumber), latestVersion: safe(() => df.latestVersionNumber),
    project: safe(() => df.parentProject.name), folder: safe(() => df.parentFolder.name),
    isModified: safe(() => doc.isModified), designType: isParametric ? "parametric" : "direct",
  };

  let recomputeMs: number | null = null;
  if (opts.recompute && isParametric) { const tr = Date.now(); design.computeAll(); recomputeMs = Date.now() - tr; }

  // ---- components (bodies summarised per definition) ------------------------------------------
  const comps: Component[] = [];
  for (let i = 0; i < design.allComponents.count; i++) comps.push(design.allComponents.item(i));
  const wantDetail = (n: string) => opts.detail.indexOf("*") >= 0 || opts.detail.indexOf(n) >= 0;
  const bodiesDetail: any = {};
  const components = comps.map((c) => {
    const occList = c === root ? null : root.allOccurrencesByComponent(c);
    const rows: string[] = []; const names: string[] = []; const hidden: string[] = []; const det: any[] = [];
    let vol = 0; let bb: number[] | null = null; let solids = 0;
    for (let k = 0; k < c.bRepBodies.count; k++) {
      const b = c.bRepBodies.item(k);
      const box = b.boundingBox;
      const v = b.volume * 1000; const a = b.area * 100;
      const bx = [mm(box.minPoint.x), mm(box.minPoint.y), mm(box.minPoint.z), mm(box.maxPoint.x), mm(box.maxPoint.y), mm(box.maxPoint.z)];
      vol += v; if (b.isSolid) solids++;
      bb = bb ? [Math.min(bb[0], bx[0]), Math.min(bb[1], bx[1]), Math.min(bb[2], bx[2]), Math.max(bb[3], bx[3]), Math.max(bb[4], bx[4]), Math.max(bb[5], bx[5])] : bx.slice();
      names.push(b.name);
      if (!b.isLightBulbOn) hidden.push(b.name);
      rows.push(`${b.name}|${b.isLightBulbOn ? 1 : 0}|${v.toFixed(1)}|${a.toFixed(1)}|${bx.map((x) => x.toFixed(2)).join(",")}`);
      if (wantDetail(c.name)) det.push([b.name, b.isLightBulbOn ? 1 : 0, r(v, 3), r(a, 3), bx]);
    }
    if (det.length) bodiesDetail[c.name] = det;
    // placements of every occurrence of this component (world transform, rounded)
    const pl: string[] = [];
    if (occList) for (let k = 0; k < occList.count; k++) {
      const o = occList.item(k); const m = o.transform2.asArray();
      pl.push(`${o.fullPathName}|${m.map((x: number, idx: number) => (idx === 3 || idx === 7 || idx === 11 ? (x * 10).toFixed(2) : x.toFixed(4))).join(",")}|${safe(() => o.isLightBulbOn ? 1 : 0, 1)}`);
    }
    let visSk = 0; let unconSk = 0;
    for (let k = 0; k < c.sketches.count; k++) { const s = c.sketches.item(k); if (s.isLightBulbOn) visSk++; if (!safe(() => s.isFullyConstrained, true)) unconSk++; }
    const isEmpty = c !== root && c.bRepBodies.count === 0 && c.occurrences.count === 0 && c.sketches.count === 0 && c.features.count === 0;
    return {
      name: c.name, occurrences: occList ? occList.count : 1, bodies: c.bRepBodies.count, solids, hiddenBodies: hidden.length,
      hidden: hidden.slice(0, 30), sketches: c.sketches.count, visibleSketches: visSk, unconstrainedSketches: unconSk,
      features: c.features.count, childOccurrences: c.occurrences.count, asBuiltJoints: c.asBuiltJoints.count,
      joints: c.joints.count, rigidGroups: safe(() => c.rigidGroups.count, 0), material: safe(() => c.material.name),
      isEmpty, volume: r(vol, 2), bbox: bb, namesHash: fnv(names.slice().sort().join("\n")),
      geomHash: fnv(rows.sort().join("\n")), placementHash: pl.length ? fnv(pl.sort().join("\n")) : null,
    };
  });

  // ---- sketches: [path, visible, fullyConstrained, health] ------------------------------------
  const sketches: any[] = [];
  const construction: any = { total: 0, visible: [] as string[] };
  for (const c of comps) {
    const cp = c === root ? "root" : c.name;
    for (let k = 0; k < c.sketches.count; k++) {
      const s = c.sketches.item(k);
      sketches.push([`${cp}/${s.name}`, s.isLightBulbOn ? 1 : 0, safe(() => s.isFullyConstrained, null) ? 1 : 0, HS[safe(() => s.healthState, 5)]]);
    }
    for (const coll of [c.constructionPlanes, c.constructionAxes, c.constructionPoints] as any[]) {
      for (let k = 0; k < coll.count; k++) { construction.total++; const g = coll.item(k); if (safe(() => g.isLightBulbOn, false)) construction.visible.push(`${cp}/${g.name}`); }
    }
  }

  // ---- joints -----------------------------------------------------------------------------------
  const JT = ["rigid", "revolute", "slider", "cylindrical", "pinSlot", "planar", "ball"];
  const lim = (l: any, conv: (x: number) => number) => !l ? null : [
    safe(() => l.isMinimumValueEnabled ? conv(l.minimumValue) : null), safe(() => l.isMaximumValueEnabled ? conv(l.maximumValue) : null)];
  const joints: any[] = [];
  for (const c of comps) {
    const prefix = c === root ? "" : `${c.name}/`;
    for (const [coll, kind] of [[c.joints, "joint"], [c.asBuiltJoints, "asBuilt"]] as any[]) {
      for (let k = 0; k < coll.count; k++) {
        const j = coll.item(k); const m: any = safe(() => j.jointMotion, {});
        const e: any = { name: `${prefix}${j.name}`, kind, type: JT[safe(() => m.jointType, -1)] || "unknown",
          one: safe(() => j.occurrenceOne.fullPathName), two: safe(() => j.occurrenceTwo.fullPathName),
          suppressed: safe(() => j.isSuppressed, false), health: HS[safe(() => j.healthState, 5)] };
        if (m.rotationValue !== undefined) { e.rotDeg = safe(() => deg(m.rotationValue)); e.rotLimits = lim(safe(() => m.rotationLimits), deg); }
        if (m.slideValue !== undefined) { e.slideMm = safe(() => mm(m.slideValue)); e.slideLimits = lim(safe(() => m.slideLimits), mm); }
        joints.push(e);
      }
    }
  }

  // ---- user parameters --------------------------------------------------------------------------
  const um = design.unitsManager;
  const userParameters: any[] = [];
  for (let i = 0; i < design.userParameters.count; i++) {
    const p = design.userParameters.item(i);
    let value: any = p.value;
    try {
      if (["mm", "cm", "m", "in", "ft", "um"].indexOf(p.unit) >= 0) value = r(um.convert(p.value, "cm", p.unit), 6);
      else if (["deg", "rad"].indexOf(p.unit) >= 0) value = r(um.convert(p.value, "rad", p.unit), 6);
      else value = r(p.value, 6);
    } catch (e) { /* raw */ }
    userParameters.push({ name: p.name, expression: p.expression, value, unit: p.unit, comment: safe(() => p.comment, ""),
      referenced: safe(() => p.dependentParameters.count > 0, null) });
  }

  // ---- timeline health --------------------------------------------------------------------------
  const timeline: any = { count: 0, markerAtEnd: null, suppressed: [], rolledBack: [], errors: [], warnings: [] };
  if (isParametric) {
    const tl = design.timeline;
    timeline.count = tl.count; timeline.markerAtEnd = tl.markerPosition === tl.count;
    for (let i = 0; i < tl.count; i++) {
      const t = tl.item(i); const nm = safe(() => t.name, `#${i}`);
      if (safe(() => t.isSuppressed, false)) timeline.suppressed.push(nm);
      if (safe(() => t.isRolledBack, false)) timeline.rolledBack.push(nm);
      const hs = safe(() => t.healthState, 5);
      if (hs === 2) timeline.errors.push({ index: i, name: nm, message: safe(() => t.errorOrWarningMessage, "") });
      else if (hs === 1) timeline.warnings.push({ index: i, name: nm, message: safe(() => t.errorOrWarningMessage, "") });
    }
  }

  // ---- physical properties ----------------------------------------------------------------------
  const physical: any[] = [];
  if (opts.physical !== "none") for (const c of comps) {
    if (opts.physical === "root" && c !== root) continue;
    if (c !== root && c.bRepBodies.count === 0) continue;
    const pp = c.getPhysicalProperties(accuracy);
    const inert = safe(() => pp.getXYZMomentsOfInertia(), null);
    physical.push({ component: c === root ? "(root)" : c.name, mass: r(pp.mass * 1000, 4), volume: r(pp.volume * 1000, 2),
      com: safe(() => [mm(pp.centerOfMass.x), mm(pp.centerOfMass.y), mm(pp.centerOfMass.z)], null),
      inertia: inert && inert[0] ? inert.slice(1).map((v: number) => r(v * 1e5, 1)) : null });  // xx,yy,zz,xy,yz,xz g·mm² about world origin
  }

  let worldBodies = root.bRepBodies.count;
  for (let i = 0; i < root.allOccurrences.count; i++) worldBodies += root.allOccurrences.item(i).bRepBodies.count;
  const rb = root.boundingBox;  // whole assembly, world space, current pose
  const overall = { bboxMin: [mm(rb.minPoint.x), mm(rb.minPoint.y), mm(rb.minPoint.z)], bboxMax: [mm(rb.maxPoint.x), mm(rb.maxPoint.y), mm(rb.maxPoint.z)],
    sizeMm: [mm(rb.maxPoint.x - rb.minPoint.x), mm(rb.maxPoint.y - rb.minPoint.y), mm(rb.maxPoint.z - rb.minPoint.z)] };
  adsk.result = JSON.stringify({
    schema: "fusion-inventory/2", generatedAt: new Date().toISOString(), options: opts, document, recomputeMs, overall,
    counts: { components: comps.length, occurrences: root.allOccurrences.count, worldBodies, sketches: sketches.length,
      construction: construction.total, joints: joints.length, userParameters: userParameters.length, timeline: timeline.count },
    components, bodiesDetail, sketches, construction, joints, userParameters, timeline, physical, scriptMs: Date.now() - t0,
  });
}

run();
