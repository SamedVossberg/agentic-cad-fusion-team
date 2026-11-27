#!/usr/bin/env bash
# TeammateIdle hook. Input (stdin JSON): teammate_name, team_name.
# Blocks going idle (exit 2, stderr → teammate) while the teammate still owns a Fusion slot lease.
# Unparseable input / unknown name → exit 0.
HOOK_INPUT="$(cat 2>/dev/null || true)" \
HOOK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)" \
python3 - <<'PY'
import json, os, subprocess, sys

try:
    data = json.loads(os.environ.get("HOOK_INPUT") or "")
    name = (data.get("teammate_name") or "").strip()
    root = os.environ.get("CLAUDE_PROJECT_DIR") or os.environ.get("HOOK_ROOT") or data.get("cwd") or "."
    if not name:
        sys.exit(0)
    r = subprocess.run([os.path.join(root, "scripts", "fusion-slot.sh"), "holds", name],
                       capture_output=True, text=True, timeout=30)
except Exception:
    sys.exit(0)
if r.returncode == 0 and r.stdout.strip():
    slots = r.stdout.strip()
    print(f"You still hold Fusion slot {slots}: save, stop_fusion, release before going idle "
          f"(scripts/fusion-slot.sh release {slots.split()[0]} {name}).", file=sys.stderr)
    sys.exit(2)
sys.exit(0)
PY
rc=$?; [ "$rc" -eq 2 ] && exit 2; exit 0   # only an explicit block (2) blocks; any crash → allow
