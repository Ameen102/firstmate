#!/usr/bin/env bash
# Behavioral coverage for bin/fm-ci-rerun-transient.sh with a fake gh: transient
# jobs rerun one per run and count per head before the request, real failures and
# superseded runs are ignored, all-skipped runs supersede nothing, in-progress
# runs defer, the limit yields "exhausted", a new head starts over, and a missing
# required option or option value is a usage error.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-ci-rerun)
SCRIPT="$ROOT/bin/fm-ci-rerun-transient.sh"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
export FM_HOME="$TMP_ROOT/home"
export FAKE_DIR="$TMP_ROOT" CALLS="$TMP_ROOT/calls" FAKE_SHA=sha1

# fake gh api: pulls -> head sha, runs -> runs.json and jobs -> jobs-<run>.json
# through the caller's real jq filter, POST -> logged, then fails on FAKE_POST_FAIL.
cat > "$FAKEBIN/gh" <<'GH'
#!/usr/bin/env bash
[ "$1" = api ] || exit 1
shift
if [ "$1" = -X ]; then
  echo "POST $3" >> "$CALLS"
  [ -z "${FAKE_POST_FAIL:-}" ]
  exit
fi
case "$1" in
  */pulls/*) echo "$FAKE_SHA" ;;
  */actions/runs\?head_sha=*) jq -r "$3" "$FAKE_DIR/runs.json" ;;
  */actions/runs/*/jobs*)
    r=${1#*/actions/runs/}
    jq -r "$3" "$FAKE_DIR/jobs-${r%%/*}.json" ;;
  *) exit 1 ;;
esac
GH
chmod +x "$FAKEBIN/gh"
PATH="$FAKEBIN:$PATH"

TRANSIENT1='{"id":1,"conclusion":"cancelled","runner_name":"","steps":[]}'
TRANSIENT2='{"id":2,"conclusion":"cancelled","runner_name":null,"steps":[]}'
FAILED='{"id":3,"conclusion":"failure","runner_name":"r","steps":[{"n":1}]}'
STARTED='{"id":4,"conclusion":"cancelled","runner_name":"r","steps":[{"n":1}]}'
QUEUED='{"id":1,"conclusion":null,"runner_name":"","steps":[]}'
SKIPPED='{"id":5,"conclusion":"skipped","runner_name":"","steps":[]}'

run() { : > "$CALLS"; "$SCRIPT" --pr 9 -R o/r; }
post() { printf 'POST repos/o/r/actions/jobs/%s/rerun' "$1"; }
set_runs() { echo "{\"workflow_runs\":[$1]}" > "$FAKE_DIR/runs.json"; }
one_run() { set_runs "{\"id\":100,\"workflow_id\":1,\"status\":\"${1:-completed}\"}"; }
set_jobs() { # <run-id> <job-json>...
  local r=$1 IFS=,
  shift
  echo "{\"jobs\":[$*]}" > "$FAKE_DIR/jobs-$r.json"
}

test_transient_rerun_bounded_per_head() {
  local out st
  one_run
  set_jobs 100 "$TRANSIENT1" "$FAILED" "$STARTED"
  out=$(run); st=$?
  assert_equals "rerun 1" "$out" "first transient rerun reports attempt 1"
  assert_equals 0 "$st" "rerun exits 0"
  assert_equals "$(post 1)" "$(cat "$CALLS")" "only the transient job is rerun"
  out=$(run); assert_equals "rerun 2" "$out" "second attempt counted"
  out=$(run); assert_equals "rerun 3" "$out" "third attempt counted"
  out=$(run); st=$?
  assert_equals exhausted "$out" "fourth attempt is refused"
  assert_equals 3 "$st" "exhausted exits 3"
  assert_equals "" "$(cat "$CALLS")" "no rerun once exhausted"
  out=$(FM_CI_RERUN_MAX=9 run)
  assert_equals exhausted "$out" "the limit is not overridable from the environment"
  out=$(FAKE_SHA=sha2 run)
  assert_equals "rerun 1" "$out" "a new head starts at zero"
  set_jobs 100 "$FAILED"
  out=$(run)
  assert_equals none "$out" "real failure is not transient"
  assert_equals "" "$(cat "$CALLS")" "real failure triggers no rerun"
  pass "transient lanes rerun up to the limit per head; real failures ignored"
}

test_superseded_run_is_never_rerun() {
  local out
  export FAKE_SHA=sha-super
  set_jobs 100 "$TRANSIENT1"
  set_jobs 101 "$FAILED"
  set_runs '{"id":101,"workflow_id":1,"status":"completed"},{"id":100,"workflow_id":1,"status":"completed"}'
  out=$(run)
  assert_equals none "$out" "a real failure on the newest run escalates despite a superseded transient"
  assert_equals "" "$(cat "$CALLS")" "superseded run gets no rerun"
  set_runs '{"id":101,"workflow_id":1,"status":"in_progress"},{"id":100,"workflow_id":1,"status":"completed"}'
  out=$(run)
  assert_equals none "$out" "a running replacement is not disturbed"
  assert_equals "" "$(cat "$CALLS")" "running replacement gets no competing rerun"
  set_jobs 200 "$TRANSIENT2"
  set_runs '{"id":200,"workflow_id":2,"status":"completed"},{"id":101,"workflow_id":1,"status":"completed"},{"id":100,"workflow_id":1,"status":"completed"}'
  out=$(run)
  assert_equals "rerun 1" "$out" "the newest run of another workflow still qualifies"
  assert_equals "$(post 2)" "$(cat "$CALLS")" "only the other workflow's transient job is rerun"
  pass "only the newest run per workflow on the head is considered"
}

test_all_skipped_run_supersedes_nothing() {
  local out st
  export FAKE_SHA=sha-label
  local both='{"id":101,"workflow_id":1,"status":"completed"},{"id":100,"workflow_id":1,"status":"completed"}'
  set_runs "$both"
  set_jobs 100 "$TRANSIENT1"
  set_jobs 101 "$SKIPPED" "$SKIPPED"
  out=$(run)
  assert_equals "rerun 1" "$out" "an all-skipped label run does not mask the transient lane"
  assert_equals "$(post 1)" "$(cat "$CALLS")" "the older run's transient job is rerun"
  set_runs '{"id":101,"workflow_id":1,"status":"completed"},{"id":100,"workflow_id":1,"status":"in_progress"}'
  set_jobs 100 "$QUEUED" "$FAILED"
  out=$(run); st=$?
  assert_contains "$out" "error: run 100 still in progress" "an all-skipped run does not hide the active rerun"
  assert_equals 1 "$st" "deferral behind an all-skipped run exits 1"
  set_runs "$both"
  set_jobs 100 "$TRANSIENT1"
  set_jobs 101 "$SKIPPED" "$FAILED"
  out=$(run)
  assert_equals none "$out" "a partly skipped newer run still supersedes"
  assert_equals "" "$(cat "$CALLS")" "a superseded run stays untouched"
  pass "a run whose jobs all skipped supersedes nothing"
}

test_unresolved_run_defers() {
  local out st jobs_state
  export FAKE_SHA=sha-starting
  set_jobs 100 "$TRANSIENT1"
  set_runs '{"id":101,"workflow_id":1,"status":"queued"},{"id":100,"workflow_id":1,"status":"completed"}'
  for jobs_state in "" "$QUEUED" "$SKIPPED,$QUEUED"; do
    echo "{\"jobs\":[$jobs_state]}" > "$FAKE_DIR/jobs-101.json"
    out=$(run); st=$?
    assert_contains "$out" "error: run 101 still in progress" "unresolved newer run defers: [$jobs_state]"
    assert_equals 1 "$st" "unresolved newer run exits 1"
    assert_equals "" "$(cat "$CALLS")" "unresolved newer run starts no rerun"
  done
  set_jobs 101 "$SKIPPED" "$SKIPPED"
  out=$(run)
  assert_equals "rerun 1" "$out" "the deferral counted nothing and clears once the run resolves"
  export FAKE_SHA=sha-nojobs
  set_runs '{"id":101,"workflow_id":1,"status":"completed"}'
  set_jobs 101
  out=$(run)
  assert_equals none "$out" "a completed run with no jobs has nothing to rerun"
  assert_equals "" "$(cat "$CALLS")" "a completed run with no jobs starts no rerun"
  pass "a live run whose jobs have not resolved defers instead of masking older runs"
}

test_one_job_per_run_per_call() {
  local out
  export FAKE_SHA=sha-two
  one_run
  set_jobs 100 "$TRANSIENT1" "$TRANSIENT2"
  out=$(run)
  assert_equals "rerun 1" "$out" "two transient jobs spend one attempt"
  assert_equals "$(post 1)" "$(cat "$CALLS")" "one request per run per call"
  set_jobs 100 '{"id":1,"conclusion":"success","runner_name":"r","steps":[{"n":1}]}' "$TRANSIENT2"
  out=$(run)
  assert_equals "rerun 2" "$out" "the next call takes the remaining job"
  assert_equals "$(post 2)" "$(cat "$CALLS")" "remaining job rerun on the next call"
  pass "a run gets at most one job rerun per call"
}

test_count_precedes_request() {
  local out st
  export FAKE_SHA=sha-post
  one_run
  set_jobs 100 "$TRANSIENT1"
  out=$(FAKE_POST_FAIL=1 run); st=$?
  assert_contains "$out" "error:" "a refused rerun reports an error"
  assert_equals 1 "$st" "a refused rerun exits 1"
  out=$(FAKE_POST_FAIL=1 run)
  out=$(FAKE_POST_FAIL=1 run)
  out=$(FAKE_POST_FAIL=1 run); st=$?
  assert_equals exhausted "$out" "repeatedly refused reruns stay bounded"
  assert_equals 3 "$st" "bounded refusals exit 3"
  export FAKE_SHA=sha-nowrite
  out=$(FM_HOME="$CALLS" run 2>/dev/null); st=$?
  assert_contains "$out" "error:" "an unwritable count reports an error"
  assert_equals 1 "$st" "an unwritable count exits 1"
  assert_equals "" "$(cat "$CALLS")" "an unwritable count starts no rerun"
  pass "the attempt is recorded before the request and the write fails closed"
}

test_in_progress_defers() {
  local out st
  export FAKE_SHA=sha-live
  one_run in_progress
  set_jobs 100 "$TRANSIENT1" "$FAILED"
  out=$(run); st=$?
  assert_contains "$out" "error: run 100 still in progress" "a transient job on a live run defers"
  assert_equals 1 "$st" "deferral exits 1"
  assert_equals "" "$(cat "$CALLS")" "a live run gets no rerun"
  one_run
  out=$(run)
  assert_equals "rerun 1" "$out" "deferral counted nothing"
  one_run in_progress
  set_jobs 100 "$QUEUED" "$FAILED"
  out=$(run); st=$?
  assert_contains "$out" "error: run 100 still in progress" "a repeat call during the helper's rerun defers"
  assert_equals 1 "$st" "repeat call exits 1"
  one_run
  set_jobs 100 "$FAILED"
  out=$(run)
  assert_equals none "$out" "a finished rerun with a real failure escalates"
  export FAKE_SHA=sha-live-real
  one_run in_progress
  out=$(run)
  assert_equals none "$out" "a live run with nothing transient and no rerun stays none"
  pass "in-progress runs defer rather than report none"
}

test_missing_option_is_usage_error() {
  local args pid i st
  for args in "" "--pr" "--pr 9 -R" "--pr 9" "-R o/r" "--run 5 -R o/r"; do
    # shellcheck disable=SC2086
    "$SCRIPT" $args >/dev/null 2>&1 &
    pid=$!
    i=0
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 100 ]; do
      sleep 0.1
      i=$((i + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -9 "$pid"
      fail "'$args' hung"
    fi
    wait "$pid"; st=$?
    assert_equals 2 "$st" "'$args' exits 2"
  done
  pass "--pr and -R are required and unknown options are usage errors"
}

fm_test_run \
  test_transient_rerun_bounded_per_head \
  test_superseded_run_is_never_rerun \
  test_all_skipped_run_supersedes_nothing \
  test_unresolved_run_defers \
  test_one_job_per_run_per_call \
  test_count_precedes_request \
  test_in_progress_defers \
  test_missing_option_is_usage_error
