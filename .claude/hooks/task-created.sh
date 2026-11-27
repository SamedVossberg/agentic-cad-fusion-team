#!/usr/bin/env bash
# TaskCreated hook. Input (stdin JSON): task_id, task_subject, task_description, teammate_name, team_name.
# Blocks (exit 2, stderr → model) when:
#   - the subject does not start with [T###][TYPE]  (TYPE: PLAN | WORK r<N> | REVIEW r<N> | MERGE | MERGE-REVIEW)
#   - the ticket directory does not exist
#   - a [MERGE] task's ticket fails scripts/check-review.sh
# Housekeeping tasks outside the ticket flow may be prefixed with [ADMIN]. Unparseable input → exit 0.
HOOK_INPUT="$(cat 2>/dev/null || true)" \
HOOK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)" \
python3 - <<'PY'
import glob, json, os, re, subprocess, sys

def allow():
    sys.exit(0)

def block(msg):
    print(msg, file=sys.stderr)
    sys.exit(2)

try:
    data = json.loads(os.environ.get("HOOK_INPUT") or "")
    subject = (data.get("task_subject") or data.get("subject") or data.get("task_title") or "").strip()
    root = os.environ.get("CLAUDE_PROJECT_DIR") or os.environ.get("HOOK_ROOT") or data.get("cwd") or "."
except Exception:
    allow()
if not subject or subject.upper().startswith("[ADMIN]"):
    allow()

m = re.match(r"^\[(T\d{3,})\]\[(PLAN|WORK r\d+|REVIEW r\d+|MERGE|MERGE-REVIEW)\]", subject)
if not m:
    block(f"Task subject '{subject}' violates the task-list convention (CLAUDE.md): it must start with "
          "[T###][TYPE], TYPE ∈ PLAN | WORK r<N> | REVIEW r<N> | MERGE | MERGE-REVIEW, followed by a short title, "
          "e.g. '[T007][WORK r1] Widen gearbox housing'. Housekeeping tasks outside the ticket flow: prefix with [ADMIN].")
tid, typ = m.group(1), m.group(2)
if not glob.glob(os.path.join(root, "project", "work", f"{tid}-*")):
    block(f"{tid} does not exist under project/work/. Create the ticket first: scripts/ticket.sh new \"<title>\".")
if typ == "MERGE":
    try:
        r = subprocess.run([os.path.join(root, "scripts", "check-review.sh"), tid], capture_output=True, text=True, timeout=30)
    except Exception:
        allow()
    if r.returncode != 0:
        block(f"[MERGE] task for {tid} rejected by the review gate: {(r.stdout + r.stderr).strip()} "
              "(needs Score > 9.5, Blockers: 0, Verdict: APPROVED on the latest round).")
allow()
PY
rc=$?; [ "$rc" -eq 2 ] && exit 2; exit 0   # only an explicit block (2) blocks; any crash → allow
