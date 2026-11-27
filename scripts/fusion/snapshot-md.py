#!/usr/bin/env python3
"""Render project/fusion/snapshot/README.md from a fusion-inventory/2 JSON (run after every merge).

  python3 scripts/fusion/snapshot-md.py project/fusion/snapshot/inventory.json > project/fusion/snapshot/README.md
"""
import json
import sys
from datetime import date

d = json.load(open(sys.argv[1], encoding="utf-8"))
doc, cnt, tl = d["document"], d["counts"], d["timeline"]
P = {p["component"]: p for p in d.get("physical") or []}
root = P.get("(root)", {})
o = []
w = o.append
w(f"# MAIN snapshot — {doc['name']} v{doc['version']}\n")
w(f"_Generated {date.today()} from `inventory.json` by `scripts/fusion/snapshot-md.py`. Read this before opening any Fusion session._\n")
w("| Item | Value |\n|---|---|")
w(f"| Document | `{doc['name']}` v{doc['version']} (lineage `{doc['lineageUrn']}`) |")
w(f"| Inventory taken | {d['generatedAt']} — options `{json.dumps(d.get('options'))}` |")
w(f"| Components / occurrences / bodies (world) | {cnt['components']} / {cnt['occurrences']} / {cnt['worldBodies']} |")
w(f"| Sketches / construction geometry | {cnt['sketches']} (visible {sum(1 for s in d['sketches'] if s[1])}, not fully constrained {sum(1 for s in d['sketches'] if not s[2])}) / {cnt['construction']} (visible {len(d['construction']['visible'])}) |")
w(f"| Joints | {cnt['joints']} ({', '.join(sorted({j['kind'] + ' ' + j['type'] for j in d['joints']}))}) |")
w(f"| Timeline | {tl['count']} items, marker at end: {tl['markerAtEnd']}, errors {len(tl['errors'])}, warnings {len(tl['warnings'])}, suppressed {len(tl['suppressed'])}, rolled back {len(tl['rolledBack'])} |")
rc = d.get("recomputeMs")
w(f"| Full recompute (`computeAll`) | {f'{rc / 1000:.1f} s' if rc else 'not measured'}{' — ' + d['recomputeSource'] if d.get('recomputeSource') else ''} |")
if root:
    w(f"| Total mass / volume | {root['mass']:.1f} g / {root['volume']:.0f} mm³ (physicalAccuracy {d['options'].get('physicalAccuracy')}; materials: {', '.join(sorted({c.get('material') or '?' for c in d['components']}))}) |")
    w(f"| Centre of mass | {root.get('com')} mm |")
    w(f"| Inertia about origin [xx, yy, zz, xy, yz, xz] | {root.get('inertia')} g·mm² |")
if d.get("overall"):
    w(f"| Overall bounding box | {d['overall']} |")
w("\n## Joints (driven values / limits in deg)\n")
w("| Joint | Type | Value | Limits | Occurrence 1 ↔ 2 |\n|---|---|---|---|---|")
for j in d["joints"]:
    w(f"| `{j['name']}` | {j['kind']} {j['type']} | {j.get('rotDeg', j.get('slideMm'))} | {j.get('rotLimits', j.get('slideLimits'))} | {j.get('one')} ↔ {j.get('two')} |")
w("\n## User parameters\n")
w("| Name | Expression | Referenced | Comment |\n|---|---|---|---|")
for p in d["userParameters"]:
    w(f"| `{p['name']}` | {p['expression']} | {p['referenced']} | {p['comment']} |")
w("\n## Components\n")
w("| Component | Occ. | Bodies (hidden) | Volume mm³ | Mass g | Sketches (vis.) | Features | bbox (component space, mm) |\n|---|---|---|---|---|---|---|---|")
for c in sorted(d["components"], key=lambda c: c["name"].lower()):
    m = P.get(c["name"], {}).get("mass")
    w(f"| `{c['name']}` | {c['occurrences']} | {c['bodies']} ({c['hiddenBodies']}) | {c['volume']:.0f} | {'' if m is None else f'{m:.2f}'} | {c['sketches']} ({c['visibleSketches']}) | {c['features']} | {c['bbox']} |")
if tl["suppressed"] or tl["rolledBack"] or tl["errors"] or tl["warnings"]:
    w("\n## Timeline items needing attention\n")
    for k in ("errors", "warnings"):
        for e in tl[k]:
            w(f"- {k[:-1]}: `{e['name']}` — {e['message']}")
    if tl["suppressed"]:
        w(f"- suppressed ({len(tl['suppressed'])}): " + ", ".join(f"`{n}`" for n in tl["suppressed"]))
    if tl["rolledBack"]:
        w(f"- rolled back ({len(tl['rolledBack'])}): " + ", ".join(f"`{n}`" for n in tl["rolledBack"]))
print("\n".join(o))
