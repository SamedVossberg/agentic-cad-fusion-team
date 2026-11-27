#!/usr/bin/env bash
# Fusion Compute session slot leases (the whole team shares MAX_SLOTS cloud sessions).
#
#   scripts/fusion-slot.sh claim <name> <T###> <priority>   exit 0 = slot is yours, 1 = waitlisted
#   scripts/fusion-slot.sh release <slot> <name>             owner only; hands over to best waiter (prints NEXT: <name>)
#   scripts/fusion-slot.sh note <slot> <engine_session_id>   record the Fusion engine session id
#   scripts/fusion-slot.sh status                            leases + waitlist + ages
#   scripts/fusion-slot.sh reap [<slot>]                     drop leases > REAP_MIN (or the given slot); hands over
#   scripts/fusion-slot.sh leave <name>                      remove <name> from the waitlist
#   scripts/fusion-slot.sh holds <name>                      exit 0 + slot numbers if <name> holds a lease
#   scripts/fusion-slot.sh ticket-held <T###>                exit 0 + slot numbers if a lease is held for the ticket
#
# Priorities: reviewer 1, merge 2, worker 3, planner 4 (lower = more urgent).
# A claim succeeds only if a slot is free AND no other waiter ranks ahead (lower priority number,
# or same priority queued earlier). Handover order: priority, then FIFO.
# Lease dirs: .fusion-slots/slot-<n>/{owner,ticket,priority,claimed,session}; waitlist: "<prio> <epoch> <name> <ticket>".
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="${FUSION_SLOTS_DIR:-$ROOT/.fusion-slots}"
MAX_SLOTS="${FUSION_MAX_SLOTS:-2}"
REAP_MIN="${FUSION_REAP_MIN:-65}"
LOG="$ROOT/project/log/fusion-sessions.log"
WAIT="$DIR/waitlist"
LOCK="$DIR/.lock"

mkdir -p "$DIR" "$(dirname "$LOG")"
touch "$WAIT"

die() { echo "fusion-slot.sh: $*" >&2; exit 2; }
ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "$(ts) | $*" >> "$LOG"; }
now() { date +%s; }
age() { local m=$(( ($(now) - $1) / 60 )); if [ $m -lt 60 ]; then echo "${m}m"; else printf '%dh%02dm' $((m / 60)) $((m % 60)); fi; }
valid_name() { [[ "$1" =~ ^[A-Za-z0-9_.-]+$ ]] || die "invalid name '$1'"; }
norm_slot() { local s="${1#slot-}"; [[ "$s" =~ ^[0-9]+$ ]] || die "invalid slot '$1'"; echo "$s"; }
norm_ticket() { [[ "$1" =~ ^[Tt]?0*([0-9]+)$ ]] || die "invalid ticket '$1' (expected T###)"; printf 'T%03d' "$((10#${BASH_REMATCH[1]}))"; }

lock() {
  local i=0
  until mkdir "$LOCK" 2>/dev/null; do
    if [ -d "$LOCK" ] && [ $(( $(now) - $(stat -f %m "$LOCK" 2>/dev/null || stat -c %Y "$LOCK" 2>/dev/null || now) )) -gt 20 ]; then
      rmdir "$LOCK" 2>/dev/null; continue   # stale lock from a killed process
    fi
    i=$((i + 1)); [ $i -gt 150 ] && die "could not acquire $LOCK"
    sleep 0.1
  done
  trap 'rmdir "$LOCK" 2>/dev/null' EXIT
}

rd() { cat "$1" 2>/dev/null || true; }
owner_of() { rd "$DIR/slot-$1/owner"; }

# best waiter line (priority, then FIFO), optionally excluding a name
best_waiter() { awk -v ex="${1:-}" '$3 != ex' "$WAIT" | sort -s -n -k1,1 -k2,2 | head -1; }
in_waitlist() { awk -v n="$1" '$3 == n {f=1} END {exit !f}' "$WAIT"; }
waitlist_remove() { local tmp="$WAIT.tmp.$$"; awk -v n="$1" '$3 != n' "$WAIT" > "$tmp" && mv "$tmp" "$WAIT"; }

write_lease() { # slot name ticket prio
  local d="$DIR/slot-$1"
  printf '%s\n' "$2" > "$d/owner"; printf '%s\n' "$3" > "$d/ticket"; printf '%s\n' "$4" > "$d/priority"
  now > "$d/claimed"; rm -f "$d/session"
}

handover_or_free() { # slot  → prints HANDOVER/NEXT or frees the slot
  local s="$1" w; w="$(best_waiter)"
  if [ -n "$w" ]; then
    set -- $w   # prio epoch name ticket
    write_lease "$s" "$3" "$4" "$1"
    waitlist_remove "$3"
    log "handover | $3 | $4 | slot-$s | prio $1 | waited $(age "$2")"
    echo "HANDOVER slot-$s → $3 ($4). SendMessage $3: \"Fusion slot $s is yours ($4)\""
    echo "NEXT: $3"
  else
    rm -rf "$DIR/slot-$s"
    echo "slot-$s is now free"
  fi
}

holds() { local found=""; for d in "$DIR"/slot-*; do [ -d "$d" ] || continue; [ "$(rd "$d/owner")" = "$1" ] && found="$found ${d##*slot-}"; done; echo "${found# }"; }

cmd_claim() {
  [ $# -eq 3 ] || die "usage: claim <name> <T###> <priority 1-4>"
  local name="$1" ticket prio="$3"; valid_name "$name"; ticket="$(norm_ticket "$2")"
  [[ "$prio" =~ ^[1-9]$ ]] || die "priority must be 1-9 (reviewer 1, merge 2, worker 3, planner 4)"
  lock
  local mine; mine="$(holds "$name")"
  if [ -n "$mine" ]; then echo "ALREADY HOLDING slot-$mine ($name)"; exit 0; fi
  local my_epoch; my_epoch="$(awk -v n="$name" '$3 == n {print $2}' "$WAIT" | head -1)"; my_epoch="${my_epoch:-$(now)}"
  local my_nr; my_nr="$(awk -v n="$name" '$3 == n {print NR; exit}' "$WAIT")"; my_nr="${my_nr:-999999}"
  # waiters ranked ahead: lower priority number, or same priority queued earlier (epoch, then file order)
  local ahead; ahead="$(awk -v n="$name" -v p="$prio" -v e="$my_epoch" -v r="$my_nr" \
    '$3 != n && ($1 < p || ($1 == p && ($2 < e || ($2 == e && NR < r)))) {print $3 "(" $4 ",p" $1 ")"}' "$WAIT" | tr '\n' ' ' | sed 's/ $//')"
  if [ -z "$ahead" ]; then
    local s
    for s in $(seq 1 "$MAX_SLOTS"); do
      if mkdir "$DIR/slot-$s" 2>/dev/null; then
        write_lease "$s" "$name" "$ticket" "$prio"
        waitlist_remove "$name"
        log "claim | $name | $ticket | slot-$s | prio $prio"
        echo "CLAIMED slot-$s for $name ($ticket). Next: start_fusion, then: scripts/fusion-slot.sh note $s <engine_session_id>"
        exit 0
      fi
    done
  fi
  if in_waitlist "$name"; then
    # keep FIFO position, but update priority/ticket if they changed
    local tmp="$WAIT.tmp.$$"
    awk -v n="$name" -v p="$prio" -v t="$ticket" '$3 == n {$1 = p; $4 = t} {print}' "$WAIT" > "$tmp" && mv "$tmp" "$WAIT"
  else
    echo "$prio $(now) $name $ticket" >> "$WAIT"
    log "wait | $name | $ticket | - | prio $prio"
  fi
  local pos; pos="$(sort -s -n -k1,1 -k2,2 "$WAIT" | awk -v n="$name" '$3 == n {print NR}')"
  echo "WAITLISTED $name ($ticket, prio $prio) at position $pos of $(wc -l < "$WAIT" | tr -d ' ')${ahead:+; ahead: $ahead}. Message lead \"waiting for Fusion slot ($ticket)\" and go idle."
  exit 1
}

cmd_release() {
  [ $# -eq 2 ] || die "usage: release <slot> <name>"
  local s; s="$(norm_slot "$1")"; valid_name "$2"
  lock
  [ -d "$DIR/slot-$s" ] || die "slot-$s is not leased"
  local o; o="$(owner_of "$s")"
  [ "$o" = "$2" ] || die "slot-$s is owned by '$o', not '$2' — only the owner may release"
  log "release | $2 | $(rd "$DIR/slot-$s/ticket") | slot-$s | held $(age "$(rd "$DIR/slot-$s/claimed")") | session $(rd "$DIR/slot-$s/session")"
  handover_or_free "$s"
}

cmd_note() {
  [ $# -eq 2 ] || die "usage: note <slot> <engine_session_id>"
  local s; s="$(norm_slot "$1")"
  lock
  [ -d "$DIR/slot-$s" ] || die "slot-$s is not leased"
  printf '%s\n' "$2" > "$DIR/slot-$s/session"
  log "note | $(owner_of "$s") | $(rd "$DIR/slot-$s/ticket") | slot-$s | session $2"
  echo "slot-$s session = $2"
}

cmd_status() {
  local s d free=0
  echo "Fusion slots (max $MAX_SLOTS, reap after ${REAP_MIN}m):"
  for s in $(seq 1 "$MAX_SLOTS"); do
    d="$DIR/slot-$s"
    if [ -d "$d" ]; then
      printf '  slot-%s  %-10s %-5s prio %s  held %-6s session %s\n' "$s" "$(rd "$d/owner")" "$(rd "$d/ticket")" \
        "$(rd "$d/priority")" "$(age "$(rd "$d/claimed")")" "$(rd "$d/session" | grep . || echo '-')"
    else
      echo "  slot-$s  free"; free=$((free + 1))
    fi
  done
  for d in "$DIR"/slot-*; do  # leases beyond MAX_SLOTS (e.g. MAX_SLOTS lowered)
    [ -d "$d" ] || continue; s="${d##*slot-}"; [ "$s" -le "$MAX_SLOTS" ] && continue
    echo "  slot-$s  $(rd "$d/owner") $(rd "$d/ticket") (outside MAX_SLOTS!)"
  done
  if [ -s "$WAIT" ]; then
    echo "Waitlist (in handover order):"
    sort -s -n -k1,1 -k2,2 "$WAIT" | while read -r p e n t; do echo "  $n  $t  prio $p  waiting $(age "$e")"; done
  else
    echo "Waitlist: empty"
  fi
  echo "Free slots: $free (lease files only — live sessions per fusion_sessions are authoritative)"
}

cmd_reap() {
  local only="" s d c reaped=0
  [ $# -ge 1 ] && only="$(norm_slot "$1")"
  lock
  for d in "$DIR"/slot-*; do
    [ -d "$d" ] || continue; s="${d##*slot-}"
    [ -n "$only" ] && [ "$s" != "$only" ] && continue
    c="$(rd "$d/claimed")"; c="${c:-0}"
    if [ -n "$only" ] || [ $(( ($(now) - c) / 60 )) -ge "$REAP_MIN" ]; then
      echo "REAPED slot-$s: owner $(rd "$d/owner"), ticket $(rd "$d/ticket"), held $(age "$c"), engine session $(rd "$d/session" | grep . || echo '-') → check fusion_sessions and stop_fusion it if still live"
      log "reap | $(rd "$d/owner") | $(rd "$d/ticket") | slot-$s | held $(age "$c") | session $(rd "$d/session")"
      reaped=$((reaped + 1))
      if [ "$s" -le "$MAX_SLOTS" ]; then handover_or_free "$s"; else rm -rf "$d"; fi
    fi
  done
  [ $reaped -eq 0 ] && echo "nothing to reap${only:+ (slot-$only not leased)}"
  return 0
}

cmd_leave() {
  [ $# -eq 1 ] || die "usage: leave <name>"
  lock
  if in_waitlist "$1"; then waitlist_remove "$1"; log "leave | $1 | - | - | -"; echo "$1 removed from waitlist"; else echo "$1 not on waitlist"; fi
}

cmd_holds() {
  [ $# -eq 1 ] || die "usage: holds <name>"
  local h; h="$(holds "$1")"
  if [ -n "$h" ]; then echo "$h"; exit 0; fi
  exit 1
}

cmd_ticket_held() {
  [ $# -eq 1 ] || die "usage: ticket-held <T###>"
  local t d found=""; t="$(norm_ticket "$1")"
  for d in "$DIR"/slot-*; do [ -d "$d" ] || continue; [ "$(rd "$d/ticket")" = "$t" ] && found="$found ${d##*slot-}($(rd "$d/owner"))"; done
  if [ -n "$found" ]; then echo "${found# }"; exit 0; fi
  exit 1
}

cmd="${1:-}"; [ $# -gt 0 ] && shift
case "$cmd" in
  claim) cmd_claim "$@" ;;
  release) cmd_release "$@" ;;
  note) cmd_note "$@" ;;
  status) cmd_status ;;
  reap) cmd_reap "$@" ;;
  leave) cmd_leave "$@" ;;
  holds) cmd_holds "$@" ;;
  ticket-held) cmd_ticket_held "$@" ;;
  *) die "usage: claim|release|note|status|reap|leave|holds|ticket-held (see header)" ;;
esac
