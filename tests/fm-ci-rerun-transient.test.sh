#!/usr/bin/env bash
# Behavioral coverage for bin/fm-ci-rerun-transient.sh with a fake gh: transient
# jobs rerun individually and count per head, real failures are ignored, the
# limit yields "exhausted", and a new head starts over.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-ci-rerun)
SCRIPT="$ROOT/bin/fm-ci-rerun-transient.sh"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
export FM_HOME="$TMP_ROOT/home"
export FAKE_JOBS="$TMP_ROOT/jobs.json" CALLS="$TMP_ROOT/calls" FAKE_SHA=sha1

# fake gh api: pulls -> head sha, runs -> one run, jobs -> $FAKE_JOBS through the
# caller's real jq filter, POST -> logged.
cat > "$FAKEBIN/gh" <<'GH'
#!/usr/bin/env bash
[ "$1" = api ] || exit 1
shift
if [ "$1" = -X ]; then echo "POST $3" >> "$CALLS"; exit 0; fi
case "$1" in
  */pulls/*) echo "$FAKE_SHA" ;;
  */actions/runs\?head_sha=*) echo 100 ;;
  */actions/runs/*/jobs*) jq -r "$3" "$FAKE_JOBS" ;;
  *) exit 1 ;;
esac
GH
chmod +x "$FAKEBIN/gh"
PATH="$FAKEBIN:$PATH"

run() { : > "$CALLS"; "$SCRIPT" --pr 9 -R o/r; }

test_transient_rerun_bounded_per_head() {
  local out st
  # one transient job, one real failure, one cancelled-after-start job
  cat > "$FAKE_JOBS" <<'J'
{"jobs":[
 {"id":1,"conclusion":"cancelled","runner_name":"","steps":[]},
 {"id":2,"conclusion":"failure","runner_name":"r","steps":[{"n":1}]},
 {"id":3,"conclusion":"cancelled","runner_name":"r","steps":[{"n":1}]}]}
J
  out=$(run); st=$?
  assert_equals "rerun 1" "$out" "first transient rerun reports attempt 1"
  assert_equals 0 "$st" "rerun exits 0"
  assert_equals "POST repos/o/r/actions/jobs/1/rerun" "$(cat "$CALLS")" "only the transient job is rerun"
  out=$(run); assert_equals "rerun 2" "$out" "second attempt counted"
  out=$(run); assert_equals "rerun 3" "$out" "third attempt counted"
  out=$(run); st=$?
  assert_equals exhausted "$out" "fourth attempt is refused"
  assert_equals 3 "$st" "exhausted exits 3"
  assert_equals "" "$(cat "$CALLS")" "no rerun once exhausted"
  out=$(FAKE_SHA=sha2 run)
  assert_equals "rerun 1" "$out" "a new head starts at zero"
  echo '{"jobs":[{"id":2,"conclusion":"failure","runner_name":"r","steps":[{"n":1}]}]}' > "$FAKE_JOBS"
  out=$(run)
  assert_equals none "$out" "real failure is not transient"
  assert_equals "" "$(cat "$CALLS")" "real failure triggers no rerun"
  pass "transient lanes rerun up to the limit per head; real failures ignored"
}

fm_test_run test_transient_rerun_bounded_per_head
