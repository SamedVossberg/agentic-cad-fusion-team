#!/usr/bin/env bash
# TaskCompleted hook. Input (stdin JSON): task_id, task_subject, task_description, teammate_name, team_name.
# Blocks completion (exit 2, stderr → model) unless the step's artifacts exist (CLAUDE.md / role files):
#   PLAN          plan.md with all 11 template sections, every questions.md block has an Answer or a planner Decision
#                 (tickets never wait for the user, CLAUDE.md "Questions & autonomy"), status PLANNED
#   WORK r<N>     report-r<N>.md, changes/r<N>.ts (or .py), no Fusion lease for the ticket, status IN_REVIEW|ESCALATED
#   REVIEW r<N>   review-r<N>.md with parseable Score/Verdict/Blockers, status APPROVED|REWORK|ESCALATED
#                 (APPROVED must also pass scripts/check-review.sh --review-only; open merge gates only block [MERGE])
#   MERGE         merge.md with "Verification: PASS|FAIL", project/fusion/snapshot/ refreshed since MERGING, no lease
#                 (rebase mismatch: status REWORK + merge.md documenting it)
#   MERGE-REVIEW  verdict line in merge.md ("Verdict: PASS|FAIL"), status MERGED|REWORK
# Subject not matching [T###][TYPE], unknown ticket, or unparseable input → exit 0 (never deadlock the team).
HOOK_INPUT="$(cat 2>/dev/null || true)" \
HOOK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)" \
python3 - <<'PY'
import datetime, glob, json, os, re, subprocess, sys

def allow():
    sys.exit(0)

problems = []

try:
    data = json.loads(os.environ.get("HOOK_INPUT") or "")
    subject = (data.get("task_subject") or data.get("subject") or data.get("task_title") or "").strip()
    root = os.environ.get("CLAUDE_PROJECT_DIR") or os.environ.get("HOOK_ROOT") or data.get("cwd") or "."
except Exception:
    allow()
m = re.match(r"^\[(T\d{3,})\]\[(PLAN|WORK r(\d+)|REVIEW r(\d+)|MERGE|MERGE-REVIEW)\]", subject)
if not m:
    allow()
tid, typ = m.group(1), m.group(2)
dirs = glob.glob(os.path.join(root, "project", "work", f"{tid}-*"))
if not dirs:
    allow()
D = dirs[0]
rel = os.path.relpath(D, root)


def read(name):
    try:
        with open(os.path.join(D, name), encoding="utf-8") as f:
            return f.read()
    except (FileNotFoundError, IsADirectoryError):
        return None


status = (read("status") or "").strip()


def need_status(*ok):
    if status not in ok:
        problems.append(f"ticket status is {status or '?'}, expected {' or '.join(ok)} — set it with "
                        f"scripts/ticket.sh set {tid} <STATE> --by <name> \"note\" before completing the task")


def lease_held():
    try:
        r = subprocess.run([os.path.join(root, "scripts", "fusion-slot.sh"), "ticket-held", tid],
                           capture_output=True, text=True, timeout=30)
        if r.returncode == 0:
            problems.append(f"a Fusion lease is still held for {tid} (slot {r.stdout.strip()}): save, stop_fusion, "
                            "scripts/fusion-slot.sh release <slot> <name> first")
    except Exception:
        pass


def header(text, key):
    mm = re.search(rf"(?m)^[*_]*{key}[*_]*:[*_]*[ \t]*(.*?)[*_ \t]*$", text)
    return mm.group(1).strip() if mm else None


PLAN_SECTIONS = [("1 Goal & acceptance criteria", r"goal"), ("2 Current state", r"current\s+state"),
                 ("3 Approach", r"approach"), ("4 Touch set & dependencies", r"touch\s*set"),
                 ("5 Parameter changes", r"parameter\s+changes"), ("6 Step-by-step instructions", r"step[- ]by[- ]step"),
                 ("7 Cleanup list", r"clean-?up"), ("8 Verification plan", r"verification\s+plan"),
                 ("9 Risks & mitigations", r"risks?"), ("10 Work packages & session estimate", r"work\s+packages?"),
                 ("11 Assumptions & answered questions", r"assumptions")]
EMPTY_ANSWER = re.compile(r"^(|tbd|todo|pending|open|unanswered|\?+|-+|…|\.\.\.|<.*>|\(.*\))$", re.I)


def undecided_questions(text):
    """Questions are '## Q<n> …' blocks; each needs the user's 'Answer:' (intake) or the planner's 'Decision:'."""
    out = []
    text = re.sub(r"<!--.*?-->", "", text, flags=re.S)  # ignore the format instructions in the stub
    for b in re.split(r"(?m)^(?=#{1,4}\s*Q[-A-Za-z]*\d+\b)", text):
        mm = re.match(r"#{1,4}\s*(Q[-A-Za-z]*\d+)", b)
        if not mm:
            continue
        filled = [v for v in (header(b, "Answer"), header(b, "Decision"))
                  if v is not None and not EMPTY_ANSWER.match(v.strip("*_ "))]
        if not filled:
            out.append(mm.group(1))
    return out


if typ == "PLAN":
    plan = read("plan.md")
    if plan is None:
        problems.append(f"{rel}/plan.md does not exist")
    else:
        missing = [name for name, kw in PLAN_SECTIONS
                   if not re.search(rf"(?mi)^\s*(#{{1,6}}\s*)?(\d{{1,2}}\s*[.)]\s*)?(\*\*|__)?\s*{kw}", plan)]
        if missing:
            problems.append("plan.md is missing template section(s): " + "; ".join(missing)
                            + " (every section is mandatory; write 'n/a — reason' if not applicable)")
    q = read("questions.md")
    if q:
        open_q = undecided_questions(q)
        if open_q:
            problems.append(f"questions.md: {', '.join(open_q)} has neither an Answer nor a Decision — don't wait for "
                            "the user: decide by the rules in CLAUDE.md \"Questions & autonomy\", write 'Decision:' "
                            "(and plan §11), then tell lead the Q-IDs")
    need_status("PLANNED")

elif typ.startswith("WORK"):
    n = m.group(3)
    if read(f"report-r{n}.md") is None:
        problems.append(f"{rel}/report-r{n}.md does not exist")
    if status != "ESCALATED" and not (os.path.isfile(os.path.join(D, "changes", f"r{n}.ts"))
                                      or os.path.isfile(os.path.join(D, "changes", f"r{n}.py"))):
        problems.append(f"{rel}/changes/r{n}.ts does not exist (the consolidated change script is mandatory)")
    lease_held()
    need_status("IN_REVIEW", "ESCALATED")

elif typ.startswith("REVIEW"):
    n = m.group(4)
    rv = read(f"review-r{n}.md")
    if rv is None:
        problems.append(f"{rel}/review-r{n}.md does not exist")
    else:
        s, v, b = header(rv, "Score"), header(rv, "Verdict"), header(rv, "Blockers")
        if not (s and re.fullmatch(r"\d+(\.\d+)?", s)):
            problems.append(f"review-r{n}.md: no parseable 'Score: x.x' header line")
        if not (v and re.fullmatch(r"APPROVED|CHANGES_REQUESTED", v)):
            problems.append(f"review-r{n}.md: 'Verdict:' must be APPROVED or CHANGES_REQUESTED (got {v!r})")
        if not (b and b.isdigit()):
            problems.append(f"review-r{n}.md: no parseable 'Blockers: n' header line")
    need_status("APPROVED", "REWORK", "ESCALATED")
    if status == "APPROVED" and rv is not None:
        try:
            r = subprocess.run([os.path.join(root, "scripts", "check-review.sh"), tid, "--review-only"],
                               capture_output=True, text=True, timeout=30)
            if r.returncode != 0:
                problems.append(f"status is APPROVED but the review gate fails: {r.stdout.strip()} — set REWORK instead")
        except Exception:
            pass

elif typ == "MERGE":
    mg = read("merge.md")
    if mg is None:
        problems.append(f"{rel}/merge.md does not exist")
    elif status == "REWORK":
        pass  # rebase dry-run mismatch: merge.md documents it, MAIN untouched
    else:
        if not re.search(r"(?mi)^[*_\s-]*verification[*_]*:[*_]*\s*(PASS|FAIL)\b", mg):
            problems.append("merge.md has no 'Verification: PASS' or 'Verification: FAIL' line")
        # snapshot must be refreshed after the ticket entered MERGING
        since = None
        try:
            with open(os.path.join(root, "project", "log", "DESIGN_LOG.md"), encoding="utf-8") as f:
                for line in f:
                    p = [x.strip() for x in line.split("|")]
                    if len(p) >= 3 and p[1] == tid and p[2].endswith("→ MERGING"):
                        since = datetime.datetime.strptime(p[0], "%Y-%m-%d %H:%M").timestamp()
        except Exception:
            since = None
        snaps = [f for f in glob.glob(os.path.join(root, "project", "fusion", "snapshot", "*")) if not f.endswith(".gitkeep")]
        newest = max((os.path.getmtime(f) for f in snaps), default=None)
        if newest is None:
            problems.append("project/fusion/snapshot/ is empty — refresh it from the merged MAIN")
        elif since is not None and newest < since:
            problems.append("project/fusion/snapshot/ was not refreshed after the merge (files older than the MERGING transition)")
        need_status("MERGE_REVIEW", "MERGING")
    lease_held()

elif typ == "MERGE-REVIEW":
    mg = read("merge.md") or ""
    if not re.search(r"(?mi)^[*_\s-]*(merge[- ]?review(\s+verdict)?|verdict)[*_]*:[*_]*\s*(PASS|FAIL)\b", mg):
        problems.append("merge.md has no merge-review verdict line ('Verdict: PASS' or 'Verdict: FAIL')")
    need_status("MERGED", "REWORK")

if problems:
    print(f"Cannot complete '{subject}':\n- " + "\n- ".join(problems), file=sys.stderr)
    sys.exit(2)
allow()
PY
rc=$?; [ "$rc" -eq 2 ] && exit 2; exit 0   # only an explicit block (2) blocks; any crash → allow
