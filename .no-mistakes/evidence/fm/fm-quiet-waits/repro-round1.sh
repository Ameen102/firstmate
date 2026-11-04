#!/usr/bin/env bash
# Repro driver for the round-1 pause-ceiling case: prints what the watcher did.
set -u
ROOT=/Users/ameen/.no-mistakes/worktrees/263a936a3c0b/01M6KGRMKWZME6YWQP2EBCRVX8
cd "$ROOT" || exit 1
# shellcheck source=tests/watch-triage-helpers.sh
. tests/watch-triage-helpers.sh

TMP_ROOT=$(fm_test_tmproot fm-repro-round1)
mkdir -p "$TMP_ROOT/crew-state-bin"
FM_CREW_STATE_BIN=$(make_fake_crew_state "$TMP_ROOT/crew-state-bin")
export FM_CREW_STATE_BIN

dir=$(make_case pause-ceiling); state="$dir/state"; fakebin="$dir/fakebin"
out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/held.status"
window="test:fm-ceiling"; key=$(printf '%s' "$window" | tr ':/.' '___')
printf 'idle, holding for the CI rerun' > "$capture_file"
printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/held.meta"
printf 'paused: waiting on the CI rerun of run 1234\n' > "$statusf"
set_mtime "$(( $(date +%s) - 500 ))" "$statusf"
sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held_status"
printf '%s' "$(hash_text 'idle, holding for the CI rerun')" > "$state/.hash-$key"
printf '1\n' > "$state/.count-$key"
export FM_FAKE_CREW_STATE='state: paused · source: status-log · waiting on the CI rerun'
export FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" FM_FAKE_TMUX_CURRENT_COMMAND=grok

echo "--- primed marker: $(cat "$state/.seen-held_status")"
echo "--- current sig:   $(FM_STATE_OVERRIDE="$state" bash -c '. bin/fm-wake-lib.sh; fm_wake_signal_sig "$1"' _ "$statusf")"
echo "--- seen current?  $(FM_STATE_OVERRIDE="$state" bash -c '. bin/fm-wake-lib.sh; fm_wake_signal_seen_current "$1" "$2" && echo YES || echo NO' _ "$state" "$statusf")"
watch_bg "$state" "$fakebin" "$out" env FM_PAUSE_RESURFACE_SECS=240 FM_STALE_ESCALATE_SECS=1
pid=$!
wait_for_exit "$pid" 200
echo "--- watch.out:"; cat "$out"
echo "--- triage:"; cat "$state/.watch-triage.log" 2>/dev/null
echo "--- wake-queue:"; cat "$state/.wake-queue" 2>/dev/null
echo "--- paused markers:"; ls -a "$state" | grep -E 'paused|stale' || true
