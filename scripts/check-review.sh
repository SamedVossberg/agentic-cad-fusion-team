#!/usr/bin/env bash
# Merge gate: scripts/check-review.sh T### [--review-only]
# Passes (exit 0) only if the latest review-r<N>.md exists, matches the latest report-r<N>.md round,
# and its header states  Score > 9.5,  Blockers: 0,  Verdict: APPROVED,  and no '## Q<n>' block in
# questions.md has 'Merge gate: yes' without an Answer (CLAUDE.md "Questions & autonomy").
# --review-only skips the merge-gate check (used when a review is completed).  Otherwise exit 1 with the reason.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL $TID: $*"; exit 1; }
REVIEW_ONLY=0
[ "${2:-}" = "--review-only" ] && REVIEW_ONLY=1 && set -- "$1"
[ $# -eq 1 ] || { echo "usage: check-review.sh T### [--review-only]" >&2; exit 2; }
[[ "$1" =~ ^[Tt]?0*([0-9]+)$ ]] || { echo "invalid ticket '$1'" >&2; exit 2; }
TID="$(printf 'T%03d' "$((10#${BASH_REMATCH[1]}))")"

D=""
for d in "$ROOT"/project/work/"$TID"-*; do [ -d "$d" ] && D="$d" && break; done
[ -n "$D" ] || fail "ticket directory project/work/$TID-* not found"

max_round() { # prefix → highest N of <prefix>-r<N>.md (0 if none)
  local n=0 f r
  for f in "$D"/"$1"-r*.md; do
    [ -f "$f" ] || continue
    r="${f##*-r}"; r="${r%.md}"
    [[ "$r" =~ ^[0-9]+$ ]] && [ "$r" -gt "$n" ] && n="$r"
  done
  echo "$n"
}
REP="$(max_round report)"; REV="$(max_round review)"
[ "$REV" -gt 0 ] || fail "no review-r<N>.md found"
[ "$REP" -gt 0 ] || fail "no report-r<N>.md found"
[ "$REV" -eq "$REP" ] || fail "latest review is r$REV but latest report is r$REP (review must match the latest submission)"

F="$D/review-r$REV.md"
field() { grep -m1 -E "^[*_]*$1[*_]*:" "$F" | sed -E "s/^[*_]*$1[*_]*:[*_]*[[:space:]]*//; s/[*_[:space:]]+\$//"; }
SCORE="$(field Score)"; VERDICT="$(field Verdict)"; BLOCKERS="$(field Blockers)"
[[ "$SCORE" =~ ^[0-9]+(\.[0-9]+)?$ ]] || fail "review-r$REV.md: unparseable 'Score:' line ('$SCORE')"
[[ "$BLOCKERS" =~ ^[0-9]+$ ]] || fail "review-r$REV.md: unparseable 'Blockers:' line ('$BLOCKERS')"
[ -n "$VERDICT" ] || fail "review-r$REV.md: missing 'Verdict:' line"

awk -v s="$SCORE" 'BEGIN { exit !(s > 9.5) }' || fail "r$REV score $SCORE is not > 9.5"
[ "$BLOCKERS" -eq 0 ] || fail "r$REV has $BLOCKERS blocker(s)"
[ "$VERDICT" = "APPROVED" ] || fail "r$REV verdict is '$VERDICT', not APPROVED"
if [ "$REVIEW_ONLY" -eq 0 ] && [ -f "$D/questions.md" ]; then
  GATES="$(python3 - "$D/questions.md" <<'PYGATE'
import re, sys
text = re.sub(r"<!--.*?-->", "", open(sys.argv[1], encoding="utf-8").read(), flags=re.S)
EMPTY = re.compile(r"^(|tbd|todo|pending|open|unanswered|\?+|-+|…|\.\.\.|<.*>|\(.*\))$", re.I)
def field(block, key):
    m = re.search(rf"(?mi)^[*_ \t-]*{key}[*_]*:[*_]*[ \t]*(.*?)[*_ \t]*$", block)
    return m.group(1).strip("*_ \t") if m else ""
open_ = []
for b in re.split(r"(?m)^(?=#{1,4}\s*Q[-A-Za-z]*\d+\b)", text):
    m = re.match(r"#{1,4}\s*(Q[-A-Za-z]*\d+)", b)
    if m and re.match(r"(?i)yes\b", field(b, "Merge gate")) and EMPTY.match(field(b, "Answer")):
        open_.append(m.group(1))
print(" ".join(open_))
PYGATE
)" || fail "could not parse questions.md"
  [ -z "$GATES" ] || fail "r$REV is approved, but merge gate $GATES in questions.md has no user answer yet"
fi
echo "PASS $TID: review r$REV — Score $SCORE, Blockers 0, Verdict APPROVED"
