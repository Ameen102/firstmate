# Targeted validation - quiet-waits terminal bound

HEAD d7824f42 (branch fm/fm-quiet-waits). All runs drive the real bin/fm-watch.sh
with the repository's own fixtures (fake tmux pane adapter, real tasks-axi backlog)
via the repo test runner / FM_TEST_ONLY selectors.

| command | result |
| --- | --- |
| `bin/fm-test-run.sh tests/fm-watch-triage-pause.test.sh --json pause-suite.json` | exit 0, 31/31 tests, 928s (`pause-suite.full.log`) |
| `FM_TEST_ONLY=test_open_captain_call_bounds_stale_churn` | ok, 73s (`test_open_captain_call_bounds_stale_churn.log`) |
| `FM_TEST_ONLY=test_stale_churn_without_a_captain_call_still_alarms` | ok, 45s |
| `FM_TEST_ONLY=test_failed_wake_append_does_not_arm_the_captain_hold_throttle` | ok, 13s |
| `FM_TEST_ONLY=test_terminal_stale_delivery_reannouncement_is_bounded` | ok, 31s |
| `FM_TEST_ONLY=test_pause_recheck_absorption_is_bounded_by_the_ceiling` | ok, 32s |
| `FM_TEST_ONLY=test_dead_agent_behind_a_standing_wait_wakes_on_the_cadence` | ok, 24s |
| `FM_TEST_ONLY=test_nonterminal_stale_paused_absorbed_then_resurfaced` | ok, 8s |
| `FM_TEST_ONLY=test_reheld_captain_call_starts_its_own_resurface_window` | fails without the edit, ok with it |
| `FM_TEST_ONLY=test_reannounced_signal_keeps_waking_for_an_unpresented_wait` (tests/fm-watch-triage.test.sh) | ok, 5s |

No live fleet/Herdr scenario was improvised (operator instruction); every run is
isolated in a throwaway TMP_ROOT built by the suite and torn down by it.
