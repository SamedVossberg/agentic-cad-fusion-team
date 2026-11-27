#!/usr/bin/env bash
# Ticket state machine + board generator for the Fusion agent team (Agentic CAD Fusion Team).
# All ticket data lives under project/ (work/, log/DESIGN_LOG.md, BOARD.md).
#
#   scripts/ticket.sh new "<title>" [--depends T001,T002] [--priority high|normal|low]
#                                   [--request "<user request verbatim>"] [--by <name>]
#   scripts/ticket.sh set T### STATE --by <name> [--assign <worker>] [--force] "note"
#   scripts/ticket.sh list            board table (also regenerates BOARD.md)
#   scripts/ticket.sh open            open tickets only; exit 0 if none open, 1 otherwise
#   scripts/ticket.sh deps T###       exit 0 if all dependencies are MERGED, else 1
#   scripts/ticket.sh show T###       ticket dir, state, round, score, files
#   scripts/ticket.sh states          print the state machine
#
# State machine: see CLAUDE.md "Ticket states". CANCELLED only --by lead|user.
# --force (lead only) skips transition validation; it is logged as forced.
set -euo pipefail
TEAM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TEAM_ROOT
exec python3 - "$@" <<'PY'
import os, re, sys, time, datetime

ROOT = os.environ["TEAM_ROOT"]
PROJECT = os.path.join(ROOT, "project")
WORK = os.path.join(PROJECT, "work")
LOG = os.path.join(PROJECT, "log", "DESIGN_LOG.md")
BOARD = os.path.join(PROJECT, "BOARD.md")
LOCK = os.path.join(WORK, ".lock")

STATES = ["NEW", "PLANNING", "PLANNED", "IN_WORK", "IN_REVIEW", "REWORK",
          "APPROVED", "MERGING", "MERGE_REVIEW", "MERGED", "ESCALATED", "CANCELLED"]
TERMINAL = {"MERGED", "CANCELLED"}
TRANSITIONS = {
    "NEW":          {"PLANNING"},
    "PLANNING":     {"PLANNED"},
    "PLANNED":      {"IN_WORK", "PLANNING"},          # PLANNING = re-plan (e.g. requirement changed)
    "IN_WORK":      {"IN_REVIEW", "ESCALATED"},
    "IN_REVIEW":    {"APPROVED", "REWORK", "ESCALATED"},
    "REWORK":       {"IN_WORK", "ESCALATED"},
    "APPROVED":     {"MERGING", "ESCALATED"},         # ESCALATED = user answer differs / merge gate rejected
    "MERGING":      {"MERGE_REVIEW", "REWORK"},       # REWORK = rebase dry-run mismatch
    "MERGE_REVIEW": {"MERGED", "REWORK"},             # REWORK = merge verification failed (rollback)
    "ESCALATED":    {"PLANNED", "PLANNING"},
    "MERGED":       set(),
    "CANCELLED":    set(),
}
# Who is expected to act next, per state (worker states resolve to the ticket's Worker:)
ROLE = {"NEW": "lead", "PLANNING": "planner", "PLANNED": "lead",
        "IN_WORK": "@worker", "IN_REVIEW": "reviewer", "REWORK": "@worker", "APPROVED": "lead",
        "MERGING": "@worker", "MERGE_REVIEW": "reviewer", "ESCALATED": "planner",
        "MERGED": "-", "CANCELLED": "-"}


def die(msg, code=2):
    print(f"ticket.sh: {msg}", file=sys.stderr)
    sys.exit(code)


def now():
    return datetime.datetime.now().strftime("%Y-%m-%d %H:%M")


class Lock:
    def __enter__(self):
        os.makedirs(WORK, exist_ok=True)
        deadline = time.time() + 15
        while True:
            try:
                os.mkdir(LOCK)
                return self
            except FileExistsError:
                try:
                    if time.time() - os.stat(LOCK).st_mtime > 30:  # stale lock
                        os.rmdir(LOCK)
                        continue
                except FileNotFoundError:
                    continue
                if time.time() > deadline:
                    die("could not acquire project/work/.lock (another ticket.sh running?)")
                time.sleep(0.1)

    def __exit__(self, *a):
        try:
            os.rmdir(LOCK)
        except FileNotFoundError:
            pass


def norm_id(s):
    m = re.fullmatch(r"[Tt]?0*(\d+)", s.strip())
    if not m:
        die(f"bad ticket id '{s}' (expected T###)")
    return "T%03d" % int(m.group(1))


def ticket_dirs():
    if not os.path.isdir(WORK):
        return []
    out = []
    for d in sorted(os.listdir(WORK)):
        if re.match(r"T\d{3,}-", d) and os.path.isdir(os.path.join(WORK, d)):
            out.append(d)
    return out


def find(tid):
    for d in ticket_dirs():
        if d.split("-", 1)[0] == tid:
            return os.path.join(WORK, d)
    die(f"ticket {tid} not found under project/work/")


def read(path, default=""):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except FileNotFoundError:
        return default


def write(path, text):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, path)


def append(path, line):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "a", encoding="utf-8") as f:
        f.write(line.rstrip("\n") + "\n")


def header(text, key):
    m = re.search(rf"^{key}:\s*(.*)$", text, re.M)
    return m.group(1).strip() if m else ""


def set_header(text, key, value):
    if re.search(rf"^{key}:", text, re.M):
        return re.sub(rf"^{key}:.*$", f"{key}: {value}", text, count=1, flags=re.M)
    return re.sub(r"^(# .*\n)", rf"\1{key}: {value}\n", text, count=1, flags=re.M)


def max_round(d, prefix):
    n = 0
    for f in os.listdir(d):
        m = re.fullmatch(rf"{prefix}-r(\d+)\.md", f)
        if m:
            n = max(n, int(m.group(1)))
    return n


def info(d):
    tid = os.path.basename(d).split("-", 1)[0]
    t = read(os.path.join(d, "ticket.md"))
    m = re.search(r"^# T\d+\s+—\s+(.*)$", t, re.M)
    title = m.group(1).strip() if m else os.path.basename(d)
    state = read(os.path.join(d, "status")).strip() or "?"
    rnd = max_round(d, "report")
    rv = max_round(d, "review")
    score = ""
    if rv:
        s = re.search(r"^Score:\s*([0-9]+(?:\.[0-9]+)?)", read(os.path.join(d, f"review-r{rv}.md")), re.M)
        score = f"{s.group(1)} (r{rv})" if s else f"? (r{rv})"
    worker = header(t, "Worker") or "-"
    role = ROLE.get(state, "?")
    assignee = (worker if worker != "-" else "worker?") if role == "@worker" else role
    deps = header(t, "Depends") or "-"
    prio = header(t, "Priority") or "normal"
    try:
        age = time.time() - os.stat(os.path.join(d, "status")).st_mtime
    except FileNotFoundError:
        age = 0
    return dict(id=tid, dir=d, title=title, state=state, round=rnd, score=score,
                assignee=assignee, deps=deps, prio=prio, age=age, worker=worker)


def fmt_age(sec):
    m = int(sec // 60)
    if m < 60:
        return f"{m}m"
    h, m = divmod(m, 60)
    if h < 48:
        return f"{h}h{m:02d}m"
    return f"{h // 24}d"


def table(rows):
    hdr = ["ID", "Title", "State", "Prio", "Round", "Last score", "Assignee", "Depends", "Age"]
    lines = ["| " + " | ".join(hdr) + " |", "|" + "---|" * len(hdr)]
    for r in rows:
        title = r["title"] if len(r["title"]) <= 48 else r["title"][:47] + "…"
        lines.append("| " + " | ".join([r["id"], title.replace("|", "/"), r["state"], r["prio"],
                                        f"r{r['round']}" if r["round"] else "-", r["score"] or "-",
                                        r["assignee"], r["deps"], fmt_age(r["age"])]) + " |")
    return "\n".join(lines)


def all_rows():
    return [info(os.path.join(WORK, d)) for d in ticket_dirs()]


def write_board():
    rows = all_rows()
    open_ = [r for r in rows if r["state"] not in TERMINAL]
    merged = sum(r["state"] == "MERGED" for r in rows)
    canc = sum(r["state"] == "CANCELLED" for r in rows)
    body = (f"# Ticket board\n\n_Auto-generated by `scripts/ticket.sh` — do not edit. Updated {now()}._\n\n"
            f"Open: {len(open_)} · Merged: {merged} · Cancelled: {canc}\n\n")
    body += table(rows) + "\n" if rows else "_No tickets yet. Create one with `/new-ticket <request>`._\n"
    write(BOARD, body)


def clean(s):
    """Keep log/history lines one-line and pipe-delimited."""
    return re.sub(r"\s+", " ", s.replace("|", "/")).strip()


def slugify(title):
    s = re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")
    s = s[:40].rstrip("-")
    return s or "ticket"


def parse(argv, flags, bools=()):
    pos, opt = [], {}
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in bools:
            opt[a] = True
        elif a in flags:
            if i + 1 >= len(argv):
                die(f"{a} needs a value")
            opt[a] = argv[i + 1]
            i += 1
        elif a.startswith("--"):
            die(f"unknown option {a}")
        else:
            pos.append(a)
        i += 1
    return pos, opt


def cmd_new(argv):
    pos, opt = parse(argv, {"--depends", "--priority", "--request", "--by"})
    if len(pos) != 1:
        die('usage: ticket.sh new "<title>" [--depends T001,..] [--priority high|normal|low] [--request "<text>"]')
    title = pos[0].strip()
    prio = opt.get("--priority", "normal")
    if prio not in ("high", "normal", "low"):
        die("--priority must be high, normal or low")
    by = opt.get("--by", "lead")
    with Lock():
        deps = []
        if opt.get("--depends"):
            for x in re.split(r"[,\s]+", opt["--depends"].strip()):
                if x:
                    tid = norm_id(x)
                    find(tid)
                    deps.append(tid)
        n = max([int(d[1:].split("-", 1)[0]) for d in ticket_dirs()] or [0]) + 1
        tid = "T%03d" % n
        d = os.path.join(WORK, f"{tid}-{slugify(title)}")
        os.makedirs(os.path.join(d, "changes"))
        os.makedirs(os.path.join(d, "artifacts"))
        request = opt.get("--request", "").strip() or "(lead: paste the user's request here verbatim)"
        ts = now()
        dep_txt = ", ".join(deps) if deps else "-"
        dep_list = "\n".join(f"- {x} must be MERGED before planning starts" for x in deps) or "- none"
        write(os.path.join(d, "ticket.md"),
              f"# {tid} — {title}\n\nPriority: {prio}\nDepends: {dep_txt}\nWorker: -\nCreated: {ts}\n\n"
              f"## Request (verbatim)\n{request}\n\n## Constraints\n- (none stated)\n\n"
              f"## Dependencies\n{dep_list}\n\n## History\n- {ts} | → NEW | {by} | created\n")
        write(os.path.join(d, "questions.md"),
              f"# {tid} — Questions for the user\n\n"
              "<!-- One block per question (CLAUDE.md \"Questions & autonomy\").\n"
              "Intake (lead, at ticket creation): asked with AskUserQuestion, Answer filled in right away, no Decision.\n"
              "Later (planner): never wait. Write Decision, keep working, tell lead the Q-IDs; the lead passes the\n"
              "question on and fills in Answer if and when the user replies.\n"
              "## Q1 — <topic>\nAsked: intake (lead, <date>) | planning (planner, <date>)\nContext: …\n"
              "Options: A) … (consequence) · B) … · C) …\n"
              "Decision: A, because … (planner questions only; the team proceeds with it)\n"
              "If otherwise: what changes if the user picks another option\n"
              "Merge gate: no   (yes only for points the requirements reserve for the user; [MERGE] waits for Answer)\n"
              "Answer:\n"
              "A [PLAN] task cannot be completed while a block has neither Answer nor Decision;\n"
              "scripts/check-review.sh fails while a 'Merge gate: yes' block has no Answer. -->\n")
        write(os.path.join(d, "status"), "NEW\n")
        append(LOG, f"{ts} | {tid} | → NEW | {by} | {clean(title)}")
        write_board()
    print(f"{tid} created: project/work/{os.path.basename(d)}/")


def cmd_set(argv):
    pos, opt = parse(argv, {"--by", "--assign"}, bools={"--force"})
    if len(pos) < 2 or "--by" not in opt:
        die('usage: ticket.sh set T### STATE --by <name> [--assign <worker>] [--force] "note"')
    tid, new = norm_id(pos[0]), pos[1].upper()
    note = clean(" ".join(pos[2:]))
    by = opt["--by"].strip()
    if new not in STATES:
        die(f"unknown state {new}. Valid: {', '.join(STATES)}")
    with Lock():
        d = find(tid)
        old = read(os.path.join(d, "status")).strip() or "NEW"
        forced = False
        if new == "CANCELLED":
            if by not in ("lead", "user"):
                die("CANCELLED may only be set --by lead (on the user's instruction) or --by user")
            if old in TERMINAL:
                die(f"{tid} is already {old}")
        elif new not in TRANSITIONS.get(old, set()):
            if opt.get("--force") and by == "lead":
                forced = True
            else:
                allowed = ", ".join(sorted(TRANSITIONS.get(old, set()) | ({"CANCELLED"} if old not in TERMINAL else set())))
                die(f"invalid transition {tid}: {old} → {new} (allowed from {old}: {allowed or 'none'})", 1)
        tpath = os.path.join(d, "ticket.md")
        t = read(tpath)
        worker = opt.get("--assign") or (by if re.fullmatch(r"worker-\d+", by) else None)
        if worker:
            t = set_header(t, "Worker", worker)
        ts = now()
        tag = " (forced)" if forced else ""
        t = t.rstrip("\n") + f"\n- {ts} | {old} → {new}{tag} | {by} | {note}\n"
        write(tpath, t)
        write(os.path.join(d, "status"), new + "\n")
        append(LOG, f"{ts} | {tid} | {old} → {new}{tag} | {by} | {note}")
        write_board()
    print(f"{tid}: {old} → {new}{tag}")


def cmd_list(argv, only_open=False):
    with Lock():
        write_board()
    rows = all_rows()
    if only_open:
        rows = [r for r in rows if r["state"] not in TERMINAL]
        if not rows:
            print("No open tickets.")
            sys.exit(0)
        print(table(rows))
        sys.exit(1)
    print(table(rows) if rows else "No tickets.")


def cmd_deps(argv):
    if len(argv) != 1:
        die("usage: ticket.sh deps T###")
    d = find(norm_id(argv[0]))
    deps = [x.strip() for x in re.split(r"[,\s]+", header(read(os.path.join(d, "ticket.md")), "Depends")) if x.strip() and x.strip() != "-"]
    blocking = []
    for x in deps:
        st = read(os.path.join(find(norm_id(x)), "status")).strip()
        if st != "MERGED":
            blocking.append(f"{x} ({st})")
    if blocking:
        print("blocked by: " + ", ".join(blocking))
        sys.exit(1)
    print("dependencies merged" if deps else "no dependencies")


def cmd_show(argv):
    if len(argv) != 1:
        die("usage: ticket.sh show T###")
    r = info(find(norm_id(argv[0])))
    print(f"{r['id']} — {r['title']}\n  dir: project/work/{os.path.basename(r['dir'])}/\n  state: {r['state']}  round: r{r['round']}  "
          f"last score: {r['score'] or '-'}  assignee: {r['assignee']}  depends: {r['deps']}  prio: {r['prio']}")
    for f in sorted(os.listdir(r["dir"])):
        print("  - " + f + ("/" if os.path.isdir(os.path.join(r["dir"], f)) else ""))


def cmd_states(argv):
    for s in STATES:
        print(f"{s:13} → {', '.join(sorted(TRANSITIONS[s])) or '(terminal)'}")
    print("any open state → CANCELLED (--by lead|user only)")


def main():
    if len(sys.argv) < 2:
        die("usage: ticket.sh new|set|list|open|deps|show|states …  (see header of scripts/ticket.sh)")
    cmd, argv = sys.argv[1], sys.argv[2:]
    if cmd != "states" and not os.path.isdir(PROJECT):
        die("project/ not found: run /setup-project first (it creates project/ from templates/project-skeleton/)")
    {"new": cmd_new, "set": cmd_set, "list": cmd_list, "open": lambda a: cmd_list(a, True),
     "deps": cmd_deps, "show": cmd_show, "states": cmd_states}.get(cmd, lambda a: die(f"unknown command {cmd}"))(argv)


main()
PY
