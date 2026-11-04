#!/usr/bin/env bash
# Live drive of bin/fm-watch.sh against a REAL tmux server (private lab socket),
# the real backend classification, and the real bin/fm-crew-state.sh, inside a
# disposable lab home. Each round prints one evidence line.
#
# Rounds:
#   L1   a presented declared pause: the first recheck reaches firstmate
#   L1b  the due recheck inside the 24h ceiling: absorbed, never woken
#   L2   the same wait past the ceiling: exactly one wake
#   L3   the same wait with a dead agent behind it: wakes on the cadence
#   L4   a presented wait's turn-end re-announcement: absorbed
#   L5   a blocker signal: still wakes
#   L6   a presented delivery on an idle wedge: absorbed, never escalated
#   L7   an undeclared stall on an idle wedge: still escalates
#   L8a  a presented delivery's first new pane hash: still alarms
#   L8b  a later new hash inside the window: absorbed
#   L8c  past the window: re-surfaces once
set -u
ROOT=/Users/ameen/.no-mistakes/worktrees/263a936a3c0b/01M6KGRMKWZME6YWQP2EBCRVX8
cd "$ROOT" || exit 1
SOCK=fm-lab
FAILS=0

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
TMUXDIR=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$LAB")
export TMUX_TMPDIR="$TMUXDIR"
tm() { TMUX_TMPDIR="$TMUXDIR" tmux -L "$SOCK" "$@" ; }
cleanup() {
  tm kill-server 2>/dev/null
  "$ROOT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1
  rm -rf "$LAB"
}
trap cleanup EXIT

STATE="$LAB/state"
mkdir -p "$LAB/out" "$LAB/work"
log() { printf '%s\n' "$*" ; }
ok() { log "PASS $*" ; }
bad() { log "FAIL $*"; FAILS=$((FAILS + 1)) ; }

# --- fleet: real panes. `exec -a claude` gives the backend a real agent process --
# --- to classify; the second pane runs a bare shell (a dead agent).             --
tm new-session -d -s crew -n agent -c "$LAB/work" -x 120 -y 40 "grok"
tm new-window -d -t crew -n shell -c "$LAB/work" "exec zsh -f"
sleep 8
AGENT=crew:agent
SHELL=crew:shell
log "== rig lab=$LAB tmuxdir=$TMUXDIR"
log "== agent pane comm=$(tm display-message -p -t "$AGENT" '#{pane_current_command}'), shell pane comm=$(tm display-message -p -t "$SHELL" '#{pane_current_command}')"

key_of() { printf '%s' "$1" | tr ':/.' '___' ; }
# The record firstmate writes at spawn: crew-state reads the worktree it names.
write_meta() {  # <id> <window>
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\nworktree=%s\nproject=lab\nmode=ship\n' \
    "$2" "$LAB/work" > "$STATE/$1.meta"
}
pane_hash() { local c; c=$(tm capture-pane -p -t "$1" -S -40); printf '%s' "$c" | md5 ; }
status_sig() { FM_HOME="$LAB" bash -c '. bin/fm-wake-lib.sh; fm_wake_signal_sig "$1"' _ "$1" ; }
declaration_of() { FM_HOME="$LAB" bash -c '. bin/fm-wake-lib.sh; printf "declared:%s" "$(fm_wake_signal_sig "$1")"' _ "$1" ; }
mark_seen() {  # <id> <status-file>
  local sig ident
  sig=$(status_sig "$2")
  ident=$(FM_HOME="$LAB" bash -c '. bin/fm-classify-lib.sh; _fm_open_decisions_file_ident "$1"' _ "$2")
  printf 'v2\t%s\t%s@%s' "$sig" "$(LC_ALL=C wc -c < "$2" | tr -d ' ')" "$ident" > "$STATE/.seen-${1}_status"
}
backdate() { local stamp; stamp=$(date -r "$1" +%Y%m%d%H%M.%S) || return 1; touch -t "$stamp" "$2" ; }
queued() { cat "$STATE/.wake-queue" 2>/dev/null || true ; }
triage() { cat "$STATE/.watch-triage.log" 2>/dev/null || true ; }
drain_ack() {
  local err="$LAB/out/drain.err" seq gen
  FM_HOME="$LAB" bin/fm-wake-drain.sh >/dev/null 2>"$err" || true
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$err")
  if [ -n "$seq" ] && [ -n "$gen" ]; then
    FM_HOME="$LAB" bin/fm-wake-drain.sh --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1
  fi
  rm -f "$err"
  : > "$STATE/.wake-queue"
  : > "$STATE/.watch-triage.log"
}
clear_round() { rm -f "$STATE/.last-watcher-beat"; : > "$STATE/.wake-queue"; : > "$STATE/.watch-triage.log"; }

# --- the product: the real watcher, launched in a lab pane so every tmux call  --
# --- it makes addresses the lab socket through the inherited $TMUX.            --
watch_start() {  # <name> <extra env assignments...>
  local name=$1; shift
  rm -f "$LAB/out/$name.log" "$LAB/out/$name.rc"
  tm new-window -d -n "watch-$name" -c "$ROOT" \
    "cd '$ROOT' && env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u FM_CREW_STATE_BIN FM_HOME='$LAB' FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_SECONDMATE_LIVENESS_SECS=99999999 $* bin/fm-watch.sh > '$LAB/out/$name.log' 2>&1; echo \$? > '$LAB/out/$name.rc'"
}
watch_wait_exit() {  # <name> <ticks(0.1s)>
  local i=0
  while [ "$i" -lt "$2" ]; do
    [ -e "$LAB/out/$1.rc" ] && { cat "$LAB/out/$1.rc"; return 0; }
    sleep 0.1; i=$((i + 1))
  done
  return 1
}
watch_cycles() {  # <ticks>
  local beat="$STATE/.last-watcher-beat" first now i=0
  rm -f "$beat"
  while [ "$i" -lt "$1" ]; do
    first=$(stat -f %m "$beat" 2>/dev/null || true)
    [ -n "$first" ] && break
    sleep 0.1; i=$((i + 1))
  done
  while [ "$i" -lt "$1" ]; do
    now=$(stat -f %m "$beat" 2>/dev/null || true)
    [ -n "$now" ] && [ "$now" != "$first" ] && return 0
    sleep 0.1; i=$((i + 1))
  done
  return 1
}
watch_stop() { tm kill-window -t "watch-$1" >/dev/null 2>&1; sleep 0.6; rm -rf "$STATE/.watch.lock"; drain_ack; }

# ============================== L1 / L1b / L2 ===============================
ID=waiting
KEY=$(key_of "$AGENT")
rm -f "$STATE"/*.meta "$STATE"/*.status "$STATE"/.paused-* "$STATE"/.stale-*
write_meta "$ID" "$AGENT"
printf 'paused: waiting on the CI rerun of run 1234\n' > "$STATE/$ID.status"
backdate "$(( $(date +%s) - 500 ))" "$STATE/$ID.status"
mark_seen "$ID" "$STATE/$ID.status"
clear_round
watch_start l1 env FM_STALE_ESCALATE_SECS=1 FM_PAUSE_RESURFACE_SECS=240
watch_wait_exit l1 400 >/dev/null || bad "L1 the first recheck of a presented declared wait never decided"
if grep -q "^stale: $AGENT" "$LAB/out/l1.log" 2>/dev/null; then
  ok "L1 first recheck of a presented declared wait reached firstmate: $(head -1 "$LAB/out/l1.log")"
else
  bad "L1 first recheck reason unexpected: $(cat "$LAB/out/l1.log" 2>/dev/null)"
fi
[ -e "$STATE/.paused-woken-$KEY" ] && ok "L1 the wake was recorded for this declaration" || bad "L1 no .paused-woken record"
drain_ack

# L1b: the same declaration comes due again inside the 24h ceiling.
backdate "$(( $(date +%s) - 500 ))" "$STATE/.paused-resurfaced-$KEY"
clear_round
watch_start l1b env FM_STALE_ESCALATE_SECS=1 FM_PAUSE_RESURFACE_SECS=240
if ! { watch_cycles 400 && watch_cycles 400; }; then bad "L1b watcher exited inside the ceiling: $(cat "$LAB/out/l1b.log" 2>/dev/null)"; fi
if [ ! -s "$LAB/out/l1b.log" ] && [ -z "$(queued)" ]; then
  ok "L1b the due recheck inside the 24h ceiling woke nobody"
else
  bad "L1b a settled pause recheck woke firstmate: $(cat "$LAB/out/l1b.log" 2>/dev/null) / $(queued)"
fi
triage | grep -F 'absorbed stale recheck' >/dev/null \
  && ok "L1b the absorbed recheck is recorded in the triage log" || bad "L1b no absorbed-recheck triage line"
watch_stop l1b

# L2: once the wake this declaration produced is older than the ceiling.
backdate "$(( $(date +%s) - 500 ))" "$STATE/.paused-resurfaced-$KEY"
backdate "$(( $(date +%s) - 90000 ))" "$STATE/.paused-woken-$KEY"
clear_round
watch_start l2 env FM_STALE_ESCALATE_SECS=1 FM_PAUSE_RESURFACE_SECS=240
watch_wait_exit l2 400 >/dev/null || bad "L2 a wait past the ceiling never re-surfaced"
grep -q "stale: $AGENT" "$LAB/out/l2.log" 2>/dev/null \
  && ok "L2 a wait past the 24h ceiling reaches firstmate once more: $(head -1 "$LAB/out/l2.log")" \
  || bad "L2 no ceiling re-surface: $(cat "$LAB/out/l2.log" 2>/dev/null)"
drain_ack

# L3: the agent behind the standing wait is gone (a bare shell pane), the wake
# record is fresh, and the cadence is due: only liveness can decide.
ID2=waitdead
KEY2=$(key_of "$SHELL")
write_meta "$ID2" "$SHELL"
printf 'paused: waiting on the CI rerun of run 1234\n' > "$STATE/$ID2.status"
backdate "$(( $(date +%s) - 500 ))" "$STATE/$ID2.status"
mark_seen "$ID2" "$STATE/$ID2.status"
printf '%s' "$(declaration_of "$STATE/$ID2.status")" > "$STATE/.paused-resurfaced-$KEY2"
printf '%s' "$(declaration_of "$STATE/$ID2.status")" > "$STATE/.paused-woken-$KEY2"
backdate "$(( $(date +%s) - 500 ))" "$STATE/.paused-resurfaced-$KEY2"
clear_round
watch_start l3 env FM_STALE_ESCALATE_SECS=1 FM_PAUSE_RESURFACE_SECS=240
watch_wait_exit l3 400 >/dev/null || bad "L3 a dead agent's standing wait was absorbed"
grep -q "stale: $SHELL" "$LAB/out/l3.log" 2>/dev/null \
  && ok "L3 a standing wait with no live agent still wakes on the cadence: $(head -1 "$LAB/out/l3.log")" \
  || bad "L3 dead-agent recheck did not wake: $(cat "$LAB/out/l3.log" 2>/dev/null)"
drain_ack

# =================================== L4 =====================================
# A presented wait's turn-end churn is a re-announcement of work already handled.
rm -f "$STATE"/*.meta "$STATE"/*.status "$STATE"/.seen-* "$STATE"/.paused-* "$STATE"/*.turn-ended
ID3=ciwait
write_meta "$ID3" "$AGENT"
printf 'paused [at=1793700000]: watching the CI rerun of run 1234 until 2099-01-01T00:00Z\n' > "$STATE/$ID3.status"
backdate "$(( $(date +%s) - 500 ))" "$STATE/$ID3.status"
mark_seen "$ID3" "$STATE/$ID3.status"
: > "$STATE/$ID3.turn-ended"
clear_round
watch_start l4 env FM_STALE_ESCALATE_SECS=60 FM_PAUSE_RESURFACE_SECS=14400
if ! { watch_cycles 400 && watch_cycles 400; }; then bad "L4 watcher exited for a turn-end behind a settled wait: $(cat "$LAB/out/l4.log" 2>/dev/null)"; fi
if [ ! -s "$LAB/out/l4.log" ] && [ -z "$(queued)" ]; then
  ok "L4 a turn-end behind an already-presented declared wait woke nobody"
else
  bad "L4 a settled wait's turn-end woke firstmate: $(cat "$LAB/out/l4.log" 2>/dev/null) / $(queued)"
fi
triage | grep -F 'absorbed re-announced signal' >/dev/null \
  && ok "L4 the absorbed re-announcement is recorded in the triage log" || bad "L4 no absorbed-re-announcement triage line"
watch_stop l4

# =================================== L5 =====================================
# A blocker is exactly what must keep waking firstmate.
rm -f "$STATE"/*.meta "$STATE"/*.status "$STATE"/.seen-* "$STATE"/*.turn-ended
ID4=blocked
write_meta "$ID4" "$AGENT"
printf 'blocked [at=%s]: the pipeline agent died twice with no findings\n' "$(date +%s)" > "$STATE/$ID4.status"
clear_round
watch_start l5 env FM_STALE_ESCALATE_SECS=60 FM_PAUSE_RESURFACE_SECS=14400
watch_wait_exit l5 400 >/dev/null || bad "L5 a blocker signal did not wake firstmate"
grep -q '^signal:' "$LAB/out/l5.log" 2>/dev/null \
  && ok "L5 a blocker still wakes: $(head -1 "$LAB/out/l5.log")" \
  || bad "L5 blocker not surfaced: $(cat "$LAB/out/l5.log" 2>/dev/null)"
drain_ack

# ================================= L6 / L7 ==================================
deliver_case() {  # <id> <status-line> [window]
  local k h
  rm -f "$STATE"/*.meta "$STATE"/*.status "$STATE"/.seen-* "$STATE"/.paused-* "$STATE"/.stale-* "$STATE"/.wedge-*
  local win=${3:-$SHELL}
  write_meta "$1" "$win"
  printf '%s\n' "$2" > "$STATE/$1.status"
  backdate "$(( $(date +%s) - 500 ))" "$STATE/$1.status"
  mark_seen "$1" "$STATE/$1.status"
  k=$(key_of "$win")
  h=$(pane_hash "$win")
  printf '%s' "$h" > "$STATE/.hash-$k"
  printf '3\n' > "$STATE/.count-$k"
  printf '%s' "$h" > "$STATE/.stale-$k"
  printf '%s\n' "$(( $(date +%s) - 500 ))" > "$STATE/.stale-since-$k"
}
deliver_case delivered 'done [at=1793700000]: PR https://example.test/pull/7 checks green'
clear_round
watch_start l6 env FM_STALE_ESCALATE_SECS=1 FM_PAUSE_RESURFACE_SECS=999
if ! { watch_cycles 400 && watch_cycles 400 && watch_cycles 400; }; then bad "L6 a presented delivery wedge-escalated: $(cat "$LAB/out/l6.log" 2>/dev/null)"; fi
if [ ! -s "$LAB/out/l6.log" ] && [ -z "$(queued)" ]; then
  ok "L6 an idle wedge on an already-presented delivery woke nobody at the threshold"
else
  bad "L6 a presented delivery was escalated: $(cat "$LAB/out/l6.log" 2>/dev/null) / $(queued)"
fi
triage | grep -F 'settled status' >/dev/null && ok "L6 the deferral is recorded as a settled status" || bad "L6 no settled-status triage line"
watch_stop l6

WEDGE_WIN=$AGENT
deliver_case stall 'working [at=1793700000]: implementing the change' "$WEDGE_WIN"
clear_round
watch_start l7 env FM_STALE_ESCALATE_SECS=1 FM_PAUSE_RESURFACE_SECS=999
watch_wait_exit l7 600 >/dev/null || bad "L7 an undeclared stall never escalated"
grep -q 'possible wedge' "$LAB/out/l7.log" 2>/dev/null \
  && ok "L7 an undeclared stall still escalates: $(head -1 "$LAB/out/l7.log")" \
  || bad "L7 undeclared stall not escalated: $(cat "$LAB/out/l7.log" 2>/dev/null)"
drain_ack

# =================================== L8 =====================================
deliver_case redelivered 'done [at=1793700000]: PR https://example.test/pull/9 checks green'
KEY8=$(key_of "$SHELL")
tm send-keys -t "$SHELL" 'echo frame-one' Enter >/dev/null 2>&1
sleep 1.5
clear_round
watch_start l8a env FM_STALE_ESCALATE_SECS=1 FM_PAUSE_RESURFACE_SECS=240
watch_wait_exit l8a 600 >/dev/null || bad "L8a the first new hash of a presented delivery did not alarm"
grep -q "stale: $SHELL" "$LAB/out/l8a.log" 2>/dev/null \
  && ok "L8a the first new pane hash of a presented delivery still alarms" \
  || bad "L8a the first new hash did not alarm: $(cat "$LAB/out/l8a.log" 2>/dev/null)"
[ -e "$STATE/.paused-resurfaced-$KEY8" ] && ok "L8a the alarm started the re-surface window" || bad "L8a no re-surface throttle"
drain_ack

tm send-keys -t "$SHELL" 'echo frame-two' Enter >/dev/null 2>&1
sleep 1.5
clear_round
watch_start l8b env FM_STALE_ESCALATE_SECS=1 FM_PAUSE_RESURFACE_SECS=240
if ! { watch_cycles 400 && watch_cycles 400 && watch_cycles 400; }; then bad "L8b a settled delivery re-alarmed inside its window: $(cat "$LAB/out/l8b.log" 2>/dev/null)"; fi
if [ ! -s "$LAB/out/l8b.log" ] && [ -z "$(queued)" ]; then
  ok "L8b a later new hash inside the window woke nobody"
else
  bad "L8b a later new hash woke firstmate: $(cat "$LAB/out/l8b.log" 2>/dev/null) / $(queued)"
fi
triage | grep -F 'settled delivery already re-surfaced this window' >/dev/null \
  && ok "L8b the absorbed terminal re-announcement is recorded" || bad "L8b no absorbed terminal triage line"
watch_stop l8b

backdate "$(( $(date +%s) - 500 ))" "$STATE/.paused-resurfaced-$KEY8"
tm send-keys -t "$SHELL" 'echo frame-three' Enter >/dev/null 2>&1
sleep 1.5
clear_round
watch_start l8c env FM_STALE_ESCALATE_SECS=1 FM_PAUSE_RESURFACE_SECS=240
watch_wait_exit l8c 600 >/dev/null || bad "L8c a settled delivery past its window never re-surfaced"
grep -q "stale: $SHELL" "$LAB/out/l8c.log" 2>/dev/null \
  && ok "L8c the bounded recheck re-surfaces the delivery after the window" \
  || bad "L8c no bounded re-surface: $(cat "$LAB/out/l8c.log" 2>/dev/null)"
drain_ack

log "== crew-state verdict for the paused declaration: $(FM_HOME="$LAB" bin/fm-crew-state.sh waiting 2>/dev/null | head -1)"
log "== RESULT: $FAILS failure(s)"
