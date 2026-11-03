#!/usr/bin/env bash
# Behavior tests for bin/fm-wake-judge.sh and the watcher step that calls it
# (signal_wake_judge_routine in bin/fm-watch.sh). A fake curl on PATH records each
# call and answers with a canned System One response, so no case touches the
# network. The argv log proves the key never reaches argv, and a call count of
# zero proves a wake the bash gate refuses is never sent anywhere.
set -u

# shellcheck source=tests/watch-triage-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/watch-triage-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-judge)
JUDGE="$ROOT/bin/fm-wake-judge.sh"
mkdir -p "$TMP_ROOT/crew-state-bin"
FM_CREW_STATE_BIN=$(make_fake_crew_state "$TMP_ROOT/crew-state-bin")
export FM_CREW_STATE_BIN

ROUTINE='{"answers":{"verdict":{"choice":"routine","confidence":0.95}}}'
NEEDS='{"answers":{"verdict":{"choice":"needs_orchestrator","confidence":0.95}}}'
LOW='{"answers":{"verdict":{"choice":"routine","confidence":0.6}}}'

# Installs the fake curl into <fakebin>: it logs argv and the fd 3 header under
# $FM_FAKE_CURL_LOG, then answers per FM_FAKE_CURL_BODY and FM_FAKE_CURL_HTTP.
install_fake_curl() {  # <fakebin>
  cat > "$1/curl" <<'SH'
#!/usr/bin/env bash
out=
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  [ "${args[$i]}" = -o ] && out=${args[$((i + 1))]}
done
{ printf 'CALL %s\n' "$*"; cat /dev/fd/3 2>/dev/null; } >> "$FM_FAKE_CURL_LOG"
cat > "$FM_FAKE_CURL_LOG.body"
[ -z "${FM_FAKE_CURL_FAIL:-}" ] || exit 28
printf '%s' "${FM_FAKE_CURL_BODY:-}" > "$out"
printf '%s' "${FM_FAKE_CURL_HTTP:-200}"
SH
  chmod +x "$1/curl"
}

curl_calls() {  # <log>
  [ -e "$1" ] || { printf 0; return 0; }
  grep -c '^CALL ' "$1"
}

# --- the tool itself ---------------------------------------------------------

judge_case() {  # <name>: sets JC_HOME, JC_BIN, JC_LOG
  local dir="$TMP_ROOT/judge-$1"
  JC_HOME="$dir/home"; JC_BIN="$dir/bin"; JC_LOG="$dir/curl.log"
  mkdir -p "$JC_HOME/config" "$JC_BIN"
  install_fake_curl "$JC_BIN"
}

run_judge() {  # <evidence>; sets JC_OUT and JC_RC. The ambient key is cleared.
  JC_OUT=$(printf '%s\n' "$1" | env -u TYPESAFE_API_KEY PATH="$JC_BIN:$PATH" FM_HOME="$JC_HOME" \
    FM_CONFIG_OVERRIDE="$JC_HOME/config" FM_FAKE_CURL_LOG="$JC_LOG" \
    ${JC_KEY:+TYPESAFE_API_KEY="$JC_KEY"} "$JUDGE" 2>&1)
  JC_RC=$?
}

test_off_without_the_opt_in_even_with_a_key() {
  judge_case no-flag
  JC_KEY=sk-secret FM_FAKE_CURL_BODY=$ROUTINE run_judge 'task: paused: waiting on CI'
  JC_KEY=
  [ "$JC_RC" -eq 1 ] || fail "a home with no config/wake-judge judged routine"
  case "$JC_OUT" in *'off (no config/wake-judge)'*) ;; *) fail "the off reason was not named: $JC_OUT" ;; esac
  [ "$(curl_calls "$JC_LOG")" = 0 ] || fail "a home with no opt-in sent status lines"
  pass "config/wake-judge is required even when a key is available"
}

test_off_without_a_key() {
  judge_case no-key
  : > "$JC_HOME/config/wake-judge"
  JC_KEY='' FM_FAKE_CURL_BODY=$ROUTINE run_judge 'task: paused: waiting on CI'
  [ "$JC_RC" -eq 1 ] || fail "no key judged routine"
  [ "$(curl_calls "$JC_LOG")" = 0 ] || fail "no key still made a call"
  pass "no key means off with no call"
}

test_routine_reads_the_env_file_and_hides_the_key() {
  judge_case routine
  : > "$JC_HOME/config/wake-judge"
  printf 'TYPESAFE_API_KEY=sk-from-env-file\n' > "$JC_HOME/.env"
  JC_KEY='' FM_FAKE_CURL_BODY=$ROUTINE run_judge 'task: paused: waiting on CI'
  [ "$JC_RC" -eq 0 ] || fail "a clear routine answer did not exit 0: $JC_OUT"
  case "$JC_OUT" in *sk-from-env-file*) fail "the key was printed" ;; esac
  grep '^CALL ' "$JC_LOG" | grep -q sk-from-env-file && fail "the key reached argv"
  grep -Fxq 'Authorization: Bearer sk-from-env-file' "$JC_LOG" || fail "the key did not reach the request header"
  jq -e '.state.wake.new_status_lines | contains("waiting on CI")' "$JC_LOG.body" >/dev/null \
    || fail "the evidence was not sent as state"
  pass "a clear routine verdict exits 0, reading the key from the home's .env, never through argv"
}

test_every_other_answer_reaches_the_orchestrator() {
  local spec name body http
  for spec in "needs|$NEEDS|200" "low|$LOW|200" "http|$ROUTINE|500" 'garbage|{"answers":{}}|200' 'badchoice|{"answers":{"verdict":{"choice":"maybe","confidence":1}}}|200'; do
    name=${spec%%|*}; body=${spec#*|}; http=${body##*|}; body=${body%|*}
    judge_case "$name"
    : > "$JC_HOME/config/wake-judge"
    JC_KEY=sk-secret FM_FAKE_CURL_BODY=$body FM_FAKE_CURL_HTTP=$http run_judge 'task: paused: waiting on CI'
    JC_KEY=
    [ "$JC_RC" -eq 1 ] || fail "[$name] did not fall back to the orchestrator: $JC_OUT"
    case "$JC_OUT" in *'routine confidence=0.95'*) fail "[$name] printed a routine verdict" ;; esac
  done
  judge_case timeout
  : > "$JC_HOME/config/wake-judge"
  JC_KEY=sk-secret FM_FAKE_CURL_FAIL=1 run_judge 'task: paused: waiting on CI'
  JC_KEY=
  [ "$JC_RC" -eq 1 ] || fail "a failed call did not fall back to the orchestrator"
  pass "needs_orchestrator, low confidence, an HTTP error, a failed call, and a malformed answer all exit 1"
}

test_never_send_list_applies() {
  judge_case never-send
  : > "$JC_HOME/config/wake-judge"
  printf 'Secret Project\n' > "$JC_HOME/config/dispatch-never-send"
  JC_KEY=sk-secret FM_FAKE_CURL_BODY=$ROUTINE run_judge 'task: paused: waiting on secret   project CI'
  JC_KEY=
  [ "$JC_RC" -eq 1 ] || fail "a never-send match judged routine"
  [ "$(curl_calls "$JC_LOG")" = 0 ] || fail "a never-send match was sent"
  case "$JC_OUT" in *'Secret Project'*) fail "the list value was printed" ;; *'line 1'*) ;; *) fail "the list line was not named: $JC_OUT" ;; esac
  pass "the never-send list stops the send and names only its line number"
}

# --- the watcher's gate ------------------------------------------------------

# A stopped worker or secondmate, so no proof absorbs the signal first. Sets
# WC_DIR, WC_STATE, WC_OUT, WC_LOG. <line> is what its status log just gained.
watch_case() {  # <name> <kind> <opt-in: 1|0> <line> [turn-ended: 1|0]
  local name=$1 kind=$2 opted=$3 line=$4 turn=${5:-1} config
  WC_DIR=$(make_case "$name"); WC_STATE="$WC_DIR/state"; WC_OUT="$WC_DIR/watch.out"; WC_LOG="$WC_DIR/curl.log"
  install_fake_curl "$WC_DIR/fakebin"
  config="$WC_DIR/config"; mkdir -p "$config"
  [ "$opted" -eq 0 ] || : > "$config/wake-judge"
  printf 'window=test:fm-judged\nkind=%s\n' "$kind" > "$WC_STATE/judged.meta"
  printf 'idle prompt' > "$WC_DIR/pane.txt"
  printf '%s\n' "$line" > "$WC_STATE/judged.status"
  [ "$turn" -eq 0 ] || : > "$WC_STATE/judged.turn-ended"
  WC_CONFIG=$config
}

start_watch() {  # <curl-body>; sets WC_PID
  PATH="$WC_DIR/fakebin:$PATH" FM_FAKE_TMUX_WINDOW=test:fm-judged FM_FAKE_TMUX_CAPTURE="$WC_DIR/pane.txt" \
    FM_FAKE_CURL_LOG="$WC_LOG" FM_FAKE_CURL_BODY="$1" TYPESAFE_API_KEY=sk-secret \
    FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available' \
    FM_CONFIG_OVERRIDE="$WC_CONFIG" FM_STATE_OVERRIDE="$WC_STATE" FM_CREW_STATE_BIN="$WC_DIR/fakebin/fm-crew-state.sh" \
    FM_POLL=3 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$WC_OUT" &
  WC_PID=$!
}

wait_triage() {  # <needle>
  local i=0
  while [ "$i" -lt 600 ]; do
    grep -Fq "$1" "$WC_STATE/.watch-triage.log" 2>/dev/null && return 0
    kill -0 "$WC_PID" 2>/dev/null || return 1
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

assert_surfaced_without_a_call() {  # <label>
  start_watch "$ROUTINE"
  wait_for_exit "$WC_PID" 600 || { reap "$WC_PID"; fail "[$1] the watcher did not surface the wake"; }
  grep -q '^signal:' "$WC_OUT" || fail "[$1] no signal wake was printed: $(cat "$WC_OUT")"
  [ -s "$WC_STATE/.wake-queue" ] || fail "[$1] the wake was not queued"
  [ "$(curl_calls "$WC_LOG")" = 0 ] || fail "[$1] the bash gate let this wake reach Jev"
}

assert_absorbed_with_one_call() {  # <label>
  start_watch "$ROUTINE"
  wait_triage 'absorbed benign signal:' || { reap "$WC_PID"; fail "[$1] a routine verdict was not absorbed: $(cat "$WC_OUT")"; }
  reap "$WC_PID"
  [ ! -s "$WC_OUT" ] || fail "[$1] an absorbed wake printed a reason: $(cat "$WC_OUT")"
  [ ! -s "$WC_STATE/.wake-queue" ] || fail "[$1] an absorbed wake was queued"
  [ "$(curl_calls "$WC_LOG")" = 1 ] || fail "[$1] expected one question, saw $(curl_calls "$WC_LOG")"
  grep -Fq 'wake-judge: routine confidence=0.95' "$WC_STATE/.watch-triage.log" || fail "[$1] the verdict was not logged"
}

test_watcher_absorbs_a_worker_declared_wait() {
  watch_case worker-paused ship 1 'paused: waiting on external CI rerun'
  assert_absorbed_with_one_call "worker paused"
  pass "a stopped worker's declared wait costs no orchestrator turn when Jev calls it routine"
}

test_watcher_surfaces_when_jev_says_needs_orchestrator() {
  watch_case worker-needs ship 1 'paused: waiting on CI; approve ci-1 if it is cancelled again'
  start_watch "$NEEDS"
  wait_for_exit "$WC_PID" 600 || { reap "$WC_PID"; fail "needs_orchestrator did not surface the wake"; }
  grep -q '^signal:' "$WC_OUT" || fail "no signal wake was printed: $(cat "$WC_OUT")"
  [ "$(curl_calls "$WC_LOG")" = 1 ] || fail "expected one question"
  grep -Fq 'needs_orchestrator' "$WC_STATE/.watch-triage.log" || fail "the surfacing verdict was not logged"
  pass "a needs_orchestrator verdict surfaces the wake"
}

test_watcher_gate_never_asks_about_these() {
  watch_case gate-off ship 0 'paused: waiting on external CI rerun'
  assert_surfaced_without_a_call "no opt-in"
  watch_case gate-decision ship 1 'needs-decision [key=pick]: option A or B'
  assert_surfaced_without_a_call "needs-decision"
  watch_case gate-blocked ship 1 'blocked: the daemon socket refuses connections'
  assert_surfaced_without_a_call "blocked"
  watch_case gate-failed ship 1 'failed: could not build'
  assert_surfaced_without_a_call "failed"
  watch_case gate-worker-done ship 1 'done: corr=962216c06791e525 finished'
  assert_surfaced_without_a_call "worker done"
  watch_case gate-working ship 1 'working: starting the next step'
  assert_surfaced_without_a_call "worker stopped after a working note"
  watch_case gate-mate-pr secondmate 1 'done: corr=962216c06791e525 PR https://example.test/pr/1'
  assert_surfaced_without_a_call "secondmate done with a URL"
  watch_case gate-mate-key secondmate 1 'done [key=child-outcome] corr=962216c06791e525: child finished'
  assert_surfaced_without_a_call "secondmate keyed outcome"
  watch_case gate-mate-plain secondmate 1 'done: finished the routed work'
  assert_surfaced_without_a_call "secondmate done with no correlation"
  pass "decision verbs, finishes, a stopped working note, and keyed or linked outcomes never reach Jev and always surface"
}

test_watcher_bare_turn_end_never_asks() {
  watch_case gate-bare ship 1 'paused: waiting on external CI rerun'
  # The status span is already classified, so only the turn-end is new.
  printf '%s' "$(seen_sig "$WC_STATE/judged.status")" > "$WC_STATE/.seen-judged_status"
  assert_surfaced_without_a_call "bare turn-end"
  pass "a bare turn-end has nothing to judge and surfaces"
}

test_absorbed_secondmate_ack_is_deferred_not_lost() {
  local line='done: corr=962216c06791e525 re-read AGENTS.md (unchanged)'
  watch_case mate-ack secondmate 1 "$line" 0
  assert_absorbed_with_one_call "secondmate acknowledgement"
  FM_STATE_OVERRIDE="$WC_STATE" "$DRAIN" > "$WC_DIR/drain.out" 2>/dev/null || fail "the drain after an absorb failed"
  grep -Fq "$line" "$WC_DIR/drain.out" || fail "the next drain did not present the absorbed line: $(cat "$WC_DIR/drain.out")"
  pass "a routine secondmate acknowledgement costs no turn and the next drain still presents it"
}

fm_test_run \
  test_off_without_the_opt_in_even_with_a_key \
  test_off_without_a_key \
  test_routine_reads_the_env_file_and_hides_the_key \
  test_every_other_answer_reaches_the_orchestrator \
  test_never_send_list_applies \
  test_watcher_absorbs_a_worker_declared_wait \
  test_watcher_surfaces_when_jev_says_needs_orchestrator \
  test_watcher_gate_never_asks_about_these \
  test_watcher_bare_turn_end_never_asks \
  test_absorbed_secondmate_ack_is_deferred_not_lost
