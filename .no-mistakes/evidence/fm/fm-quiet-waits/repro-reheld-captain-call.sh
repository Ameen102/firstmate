#!/usr/bin/env bash
# Driver for the re-held captain call: drives the REAL bin/fm-watch.sh against a
# disposable captain-hold fixture made with the real tasks-axi backlog, then
# prints what the watcher decided for the second call's first sight.
set -u
ROOT=/Users/ameen/.no-mistakes/worktrees/263a936a3c0b/01M6KGRMKWZME6YWQP2EBCRVX8
cd "$ROOT" || exit 1
# shellcheck source=tests/watch-triage-helpers.sh
. tests/watch-triage-helpers.sh

TMP_ROOT=$(fm_test_tmproot fm-repro-reheld)
# The hold fixtures come from the pause suite itself, extracted so this driver
# exercises exactly the same captain-hold fixture the suite does.
sed -n '/^hold_key() {/,/^# Both status lines a held task really carries/p' \
  tests/fm-watch-triage-pause.test.sh | sed '$d' > "$TMP_ROOT/hold-helpers.sh"
# shellcheck source=/dev/null
. "$TMP_ROOT/hold-helpers.sh"
dir=$(make_hold_home reheld-call 'done: PR https://example.invalid/pull/1 checks green' hold) \
  || { echo "could not build the fixture"; exit 1; }
state="$dir/state"; out="$dir/watch.out"; capture="$dir/pane.txt"

hold_watch_surface "$dir" "$out" "$capture" 'idle, elapsed 1s' \
  && echo "STEP first sight of call 1: surfaced (wake=$(hold_stale_wakes "$state"))" \
  || echo "STEP first sight of call 1: NOT surfaced"
ack_stopped_cycle "$state" || echo "ack failed"
hold_watch_churn "$dir" "$out" "$capture" 'idle, tick' 1 \
  && echo "STEP call 1 churn: absorbed (wake=$(hold_stale_wakes "$state"))" \
  || echo "STEP call 1 churn: NOT absorbed"

printf 'go ahead\n' > "$dir/decision.txt"
run_hold "$dir" answer held-merge --decision-file "$dir/decision.txt" --release || echo "answer failed"
run_hold "$dir" hold held-merge --reason 'awaiting the captain a second time' || echo "re-hold failed"
echo "== backlog rows: $(FM_HOME="$dir" tasks-axi list 2>/dev/null | tr '\n' '|')"

: > "$out"
hold_watch_surface "$dir" "$out" "$capture" 'idle, elapsed 3s' \
  && echo "STEP second call first sight: SURFACED" \
  || echo "STEP second call first sight: SILENCED"
echo "== wake queue: [$(cat "$state/.wake-queue" 2>/dev/null | tr '\n' '|')]"
echo "== stale wakes: $(hold_stale_wakes "$state")"
echo "== triage:"; cat "$state/.watch-triage.log" 2>/dev/null
echo "== markers:"; ls -a "$state" | grep -E 'paused|stale' || true
