# Regression reproduction: terminal bound's captain-call scope

Subject: uncommitted edit in bin/fm-watch.sh (terminal-stale branch, ~line 4570),
committed as d7824f42. It records the settled-delivery throttle under the
captain call's own identity (`captain-hold:<identity>:<status-sig>`) instead of
the status signature alone, falling back to `declared:<status-sig>` when no call
is open.

## Without the edit (HEAD e379beee, edit reverted)

$ FM_TEST_ONLY=test_reheld_captain_call_starts_its_own_resurface_window \
    bash tests/fm-watch-triage-pause.test.sh
wait_for_exit: owned pid 96021 exceeded 100 polls; sending TERM
96021 78330 S  bash .../bin/fm-watch.sh
not ok - the second captain call inherited the first call's silence
exit=1

## With the edit (committed d7824f42, fm-watch.sh sha256 6e7651dd...4cd03)

$ FM_TEST_ONLY=test_reheld_captain_call_starts_its_own_resurface_window \
    bash tests/fm-watch-triage-pause.test.sh
ok - a released-then-re-held task is a distinct captain call whose first sight still alarms
exit=0  (37s)

The scenario: a captain-held delivery surfaces once, its pane churns inside
FM_PAUSE_RESURFACE_SECS (absorbed), the captain answers --release and the task is
held again with no status append, then a new hash must alarm again. Before the
edit the second call inherited the first call's silence, so a live decision
waiting on the captain was swallowed.
