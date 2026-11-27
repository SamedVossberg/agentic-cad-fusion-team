#!/usr/bin/env python3
"""Diff two Fusion inventory JSONs (schema fusion-inventory/2 from scripts/fusion/inventory.ts) → markdown.

  python3 scripts/diff-inventory.py base.json new.json [--out diff.md]
  python3 scripts/diff-inventory.py approved.json main.json --check [--tol-mass-pct 0.1] [--tol-len-mm 0.01]

Default mode: added / removed / changed components (body sets, geometry, placements, sketches, features),
per-body changes for components listed in OPTIONS.detail of BOTH inventories, sketches, joints, user
parameters, timeline and physical properties, with numeric deltas. Flags (new inventory, marked new or
pre-existing): hidden bodies, visible sketches, visible construction geometry, unused user parameters,
empty components, suppressed / rolled-back features, timeline marker, timeline errors/warnings,
recompute-time delta in % (> +20 % flagged), overall size growth (growth of length X or width Y beyond
--growth-gate-mm, default $FUSION_GROWTH_GATE_MM, is flagged as a user merge gate; unset = only "justify").
Exit 0 (3 if the new inventory has timeline errors).

--check (merge verification, CLAUDE.md tolerances): identical sets of components, bodies (per-component
name hash + count), joints and user parameters (incl. values); per-component mass within ±0.1 %;
per-component bbox within ±0.01 mm; identical placements; zero timeline errors.
Prints "Verification: PASS" / "Verification: FAIL" and exits 0 / 1.
"""
import argparse
import json
import math
import os
import sys

EPS_ABS = 1e-4
EPS_REL = 1e-6


def load(path):
    with open(path, encoding="utf-8") as f:
        d = json.load(f)
    if not str(d.get("schema", "")).startswith("fusion-inventory/2"):
        sys.exit(f"diff-inventory.py: {path} is not a fusion-inventory/2 file (schema={d.get('schema')!r})")
    return d


def is_num(x):
    return isinstance(x, (int, float)) and not isinstance(x, bool)


def num_changed(a, b):
    return abs(a - b) > max(EPS_ABS, EPS_REL * max(abs(a), abs(b)))


def fmt(v):
    if is_num(v):
        return f"{v:.6g}"
    s = v if isinstance(v, str) else json.dumps(v, ensure_ascii=False)
    return s if len(s) <= 70 else s[:67] + "…"


def flatten(d, prefix=""):
    out = {}
    if isinstance(d, dict):
        for k, v in d.items():
            out.update(flatten(v, f"{prefix}.{k}" if prefix else str(k)))
    elif isinstance(d, list) and d and all(is_num(x) or x is None for x in d):
        for i, v in enumerate(d):
            out[f"{prefix}[{i}]"] = v
    else:
        out[prefix] = d
    return out


def changes(a, b, skip=()):
    fa, fb = flatten(a), flatten(b)
    rows = []
    for k in sorted(set(fa) | set(fb)):
        if k.split(".")[0].split("[")[0] in skip:
            continue
        va, vb = fa.get(k), fb.get(k)
        if is_num(va) and is_num(vb):
            if num_changed(va, vb):
                pct = f", {(vb - va) / va * 100:+.3g} %" if va else ""
                rows.append(f"{k}: {fmt(va)} → {fmt(vb)} (Δ {vb - va:+.6g}{pct})")
        elif va != vb:
            rows.append(f"{k}: {fmt(va)} → {fmt(vb)}")
    return rows


def keyed(items, key):
    out = {}
    for it in items or []:
        k = it[key] if isinstance(it, dict) else it[0]
        base, n = str(k), 2
        k = base
        while k in out:
            k = f"{base}#{n}"
            n += 1
        out[k] = it
    return out


def section(title, a, b, key, details, summary, skip=()):
    A, B = keyed(a, key), keyed(b, key)
    added, removed = sorted(set(B) - set(A)), sorted(set(A) - set(B))
    changed = {}
    for k in sorted(set(A) & set(B)):
        va = A[k] if isinstance(A[k], dict) else dict(enumerate(A[k]))
        vb = B[k] if isinstance(B[k], dict) else dict(enumerate(B[k]))
        rows = changes(va, vb, skip)
        if rows:
            changed[k] = rows
    summary.append(f"| {title} | {len(A)} → {len(B)} | {len(added)} | {len(removed)} | {len(changed)} |")
    if added or removed or changed:
        details.append(f"\n## {title}")
        details += [f"- **added** `{k}`" for k in added]
        details += [f"- **removed** `{k}`" for k in removed]
        for k, rows in changed.items():
            details.append(f"- **changed** `{k}`")
            details += [f"  - {r}" for r in rows]
    return added, removed, changed


SKETCH_COLS = {0: "path", 1: "visible", 2: "fullyConstrained", 3: "health"}
BODY_COLS = ("name", "visible", "volume", "area", "bbox")


def flags(inv):
    f = []
    for c in inv.get("components") or []:
        if c.get("hiddenBodies"):
            more = f" (+{c['hiddenBodies'] - len(c['hidden'])} more)" if c["hiddenBodies"] > len(c.get("hidden") or []) else ""
            f.append(f"hidden bodies in `{c['name']}`: {', '.join(c.get('hidden') or [])}{more}")
        if c.get("isEmpty"):
            f.append(f"empty component: `{c['name']}`")
    for s in inv.get("sketches") or []:
        if s[1]:
            f.append(f"visible sketch: `{s[0]}`")
        if s[3] not in ("healthy", "unknown"):
            f.append(f"sketch `{s[0]}` health: {s[3]}")
    for g in (inv.get("construction") or {}).get("visible") or []:
        f.append(f"visible construction geometry: `{g}`")
    for p in inv.get("userParameters") or []:
        if p.get("referenced") is False:
            f.append(f"unused user parameter: `{p['name']}` = {p.get('expression')}")
    tl = inv.get("timeline") or {}
    for n in tl.get("suppressed") or []:
        f.append(f"suppressed feature: `{n}`")
    for n in tl.get("rolledBack") or []:
        f.append(f"rolled-back feature: `{n}`")
    if tl.get("markerAtEnd") is False:
        f.append("timeline marker is not at the end")
    for w in tl.get("warnings") or []:
        f.append(f"timeline warning: `{w.get('name')}` — {w.get('message')}")
    for e in tl.get("errors") or []:
        f.append(f"**TIMELINE ERROR**: `{e.get('name')}` — {e.get('message')}")
    return f


def label(inv):
    d = inv.get("document") or {}
    return f"{d.get('name', '?')} v{d.get('version', '?')}"


def report(base, new, growth_gate=None):
    out = ["# Inventory diff\n", f"Base: **{label(base)}** → New: **{label(new)}**\n"]
    if (base.get("options") or {}).get("physicalAccuracy") != (new.get("options") or {}).get("physicalAccuracy"):
        out.append("> ⚠ physicalAccuracy differs between the inventories — mass/inertia deltas are not comparable.\n")
    summary, details = ["| Section | Count | Added | Removed | Changed |", "|---|---|---|---|---|"], []
    section("Components", base.get("components"), new.get("components"), "name", details, summary, skip=("hidden",))
    # per-body detail where both sides have it
    bd_a, bd_b = base.get("bodiesDetail") or {}, new.get("bodiesDetail") or {}
    for comp in sorted(set(bd_a) | set(bd_b)):
        if comp in bd_a and comp in bd_b:
            rows_a = [dict(zip(BODY_COLS, r)) for r in bd_a[comp]]
            rows_b = [dict(zip(BODY_COLS, r)) for r in bd_b[comp]]
            section(f"Bodies in `{comp}`", rows_a, rows_b, "name", details, summary)
        else:
            details.append(f"\n> body detail for `{comp}` only in the {'base' if comp in bd_a else 'new'} inventory — "
                           "put it into OPTIONS.detail of both runs for a body-level diff")
    sk = lambda inv: [{SKETCH_COLS[i]: v for i, v in enumerate(s)} for s in inv.get("sketches") or []]
    section("Sketches", sk(base), sk(new), "path", details, summary)
    section("Joints", base.get("joints"), new.get("joints"), "name", details, summary)
    section("User parameters", base.get("userParameters"), new.get("userParameters"), "name", details, summary)
    section("Physical properties", base.get("physical"), new.get("physical"), "component", details, summary)
    tl_rows = changes({k: (base.get("timeline") or {}).get(k) for k in ("count", "markerAtEnd")},
                      {k: (new.get("timeline") or {}).get(k) for k in ("count", "markerAtEnd")})
    ca, cb = base.get("construction") or {}, new.get("construction") or {}
    if ca.get("total") != cb.get("total"):
        tl_rows.append(f"construction geometry total: {ca.get('total')} → {cb.get('total')}")
    if tl_rows:
        details.append("\n## Timeline / construction")
        details += [f"- {r}" for r in tl_rows]
    out += summary
    out.append("\n## Flags (new inventory)")
    a, b = base.get("recomputeMs"), new.get("recomputeMs")
    if is_num(a) and is_num(b) and a > 0:
        pct = (b - a) / a * 100
        out.append(f"- Recompute time: {a:.0f} ms → {b:.0f} ms ({pct:+.1f} %)" + (" ⚠ > +20 % (performance issue unless justified)" if pct > 20 else ""))
    elif not is_num(b):
        out.append("- Recompute time: not measured in the new inventory (set OPTIONS.recompute = true for reviews)")
    sa, sb = (base.get("overall") or {}).get("sizeMm"), (new.get("overall") or {}).get("sizeMm")
    if sa and sb:
        grow = [f"{ax} {x:.2f} → {y:.2f} mm ({y - x:+.2f})" for ax, x, y in zip(("length X", "width Y", "height Z"), sa, sb) if abs(y - x) > 0.01]
        if grow:
            # growth of length (X) or width (Y) beyond the project's gate needs user approval (merge gate,
            # project/PROJECT.md); any growth must be justified in the plan
            need = growth_gate is not None and any(y - x > growth_gate for x, y in zip(sa[:2], sb[:2]))
            note = (f" ⚠ > {growth_gate:g} mm in length/width — merge gate, needs user approval" if need
                    else (" — grows: justify in plan" if any(y - x > 0.01 for x, y in zip(sa, sb)) else ""))
            out.append("- Overall size changed: " + "; ".join(grow) + note)
    old = set(flags(base))
    fl = flags(new)
    out += [f"- {x}  _({'pre-existing' if x in old else 'NEW'})_" for x in fl] or ["- none"]
    out += details
    return "\n".join(out) + "\n", bool((new.get("timeline") or {}).get("errors"))


def check(ref, cand, tol_mass_pct, tol_len):
    fails, notes = [], []
    if (ref.get("options") or {}).get("physicalAccuracy") != (cand.get("options") or {}).get("physicalAccuracy"):
        fails.append("physicalAccuracy differs between the inventories — rerun with identical OPTIONS")
    CA, CB = keyed(ref.get("components"), "name"), keyed(cand.get("components"), "name")
    if set(CA) != set(CB):
        fails.append(f"component sets differ — missing: {sorted(set(CA) - set(CB)) or '-'}; extra: {sorted(set(CB) - set(CA)) or '-'}")
    worst_bb, hash_only = 0.0, []
    for k in sorted(set(CA) & set(CB)):
        a, b = CA[k], CB[k]
        if a.get("bodies") != b.get("bodies") or a.get("namesHash") != b.get("namesHash"):
            fails.append(f"`{k}`: body set differs ({a.get('bodies')} → {b.get('bodies')} bodies, namesHash {a.get('namesHash')} → {b.get('namesHash')})")
        if a.get("occurrences") != b.get("occurrences"):
            fails.append(f"`{k}`: occurrence count {a.get('occurrences')} → {b.get('occurrences')}")
        if a.get("placementHash") != b.get("placementHash"):
            fails.append(f"`{k}`: occurrence placements differ (check joint values / pose)")
        if a.get("bbox") and b.get("bbox"):
            dev = max(abs(x - y) for x, y in zip(a["bbox"], b["bbox"]))
            worst_bb = max(worst_bb, dev)
            if dev > tol_len:
                fails.append(f"`{k}`: bbox deviates {dev:.4f} mm (tol ±{tol_len} mm)")
        elif bool(a.get("bbox")) != bool(b.get("bbox")):
            fails.append(f"`{k}`: bbox present on one side only")
        if a.get("geomHash") != b.get("geomHash") and not any(f.startswith(f"`{k}`") for f in fails):
            hash_only.append(k)
    JA, JB = set(keyed(ref.get("joints"), "name")), set(keyed(cand.get("joints"), "name"))
    if JA != JB:
        fails.append(f"joint sets differ — missing: {sorted(JA - JB) or '-'}; extra: {sorted(JB - JA) or '-'}")
    PA, PB = keyed(ref.get("userParameters"), "name"), keyed(cand.get("userParameters"), "name")
    if set(PA) != set(PB):
        fails.append(f"user parameter sets differ — missing: {sorted(set(PA) - set(PB)) or '-'}; extra: {sorted(set(PB) - set(PA)) or '-'}")
    for k in sorted(set(PA) & set(PB)):
        va, vb = PA[k].get("value"), PB[k].get("value")
        if is_num(va) and is_num(vb) and num_changed(va, vb) or PA[k].get("expression") != PB[k].get("expression"):
            fails.append(f"user parameter `{k}`: {PA[k].get('expression')} ≠ {PB[k].get('expression')}")
    MA, MB = keyed(ref.get("physical"), "component"), keyed(cand.get("physical"), "component")
    for k in sorted(set(MA) & set(MB)):
        a, b = MA[k].get("mass"), MB[k].get("mass")
        if is_num(a) and is_num(b):
            dev = abs(b - a) / a * 100 if a else (0.0 if b == 0 else math.inf)
            if dev > tol_mass_pct:
                fails.append(f"mass `{k}`: {a:.4f} g → {b:.4f} g ({dev:.4f} %, tol ±{tol_mass_pct} %)")
            elif k == "(root)":
                notes.append(f"total mass {a:.4f} g → {b:.4f} g ({dev:.4f} %)")
    if set(MA) != set(MB):
        fails.append(f"physical-property components differ: {sorted(set(MA) ^ set(MB))}")
    for e in (cand.get("timeline") or {}).get("errors") or []:
        fails.append(f"timeline error `{e.get('name')}`: {e.get('message')}")
    notes.append(f"worst component bbox deviation: {worst_bb:.4f} mm")
    if hash_only:
        notes.append(f"geometry hash differs within tolerance (rounding) for: {', '.join(hash_only)}")
    return fails, notes


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("base")
    ap.add_argument("new")
    ap.add_argument("--out")
    ap.add_argument("--check", action="store_true", help="merge verification against CLAUDE.md tolerances")
    ap.add_argument("--tol-mass-pct", type=float, default=0.1)
    ap.add_argument("--tol-len-mm", type=float, default=0.01)
    env_gate = os.environ.get("FUSION_GROWTH_GATE_MM")
    ap.add_argument("--growth-gate-mm", type=float, default=float(env_gate) if env_gate else None,
                    help="flag length/width growth above this as a user merge gate (default $FUSION_GROWTH_GATE_MM)")
    a = ap.parse_args()
    base, new = load(a.base), load(a.new)
    md, has_errors = report(base, new, a.growth_gate_mm)
    code = 3 if has_errors else 0
    if a.check:
        fails, notes = check(base, new, a.tol_mass_pct, a.tol_len_mm)
        md += "\n## Verification (CLAUDE.md tolerances)\n"
        md += "".join(f"- FAIL: {f}\n" for f in fails) + "".join(f"- ok: {n}\n" for n in notes)
        md += f"\nVerification: {'FAIL' if fails else 'PASS'}\n"
        code = 1 if fails else 0
    if a.out:
        with open(a.out, "w", encoding="utf-8") as f:
            f.write(md)
    sys.stdout.write(md)
    sys.exit(code)


if __name__ == "__main__":
    main()
