#!/usr/bin/env bash
# fm-ci-rerun-transient.sh - rerun CI jobs that were cancelled before any runner
# was assigned, a bounded number of times per PR head, before anyone is asked.
#
# Usage:
#   fm-ci-rerun-transient.sh (--pr <number> | --run <run-id>) [-R <owner/repo>]
#
# A transient lane is a job on the PR's current head whose conclusion is
# cancelled, whose runner_name is empty and which ran no steps: GitHub never
# gave it a machine. Only those jobs are rerun (one job-level rerun each);
# real failures, and jobs cancelled after a runner started, are never touched.
# --run resolves the run's PR and then behaves as --pr. Only runs for the PR's
# current head are considered, so a lane cancelled by a newer push is left alone.
#
# The attempt count lives in $FM_HOME/state/ci-rerun/<repo>-pr<N>-<head>.count
# (FM_HOME defaults to this code root), so a new head starts at zero and the
# count never passes FM_CI_RERUN_MAX (default 3).
#
# Output (one line) and exit status:
#   rerun N     exit 0  attempt N of the limit was started for the transient jobs
#   exhausted   exit 3  transient jobs remain but the limit was already spent;
#                       escalate the finding
#   none        exit 0  no transient job; any failure is real, escalate unchanged
#   error: ...  exit 1  a gh call failed; nothing is counted
# Usage errors exit 2.
#
# Callers: a worker or firstmate runs this before escalating a CI-gate failure
# (.agents/skills/validation-supervision/SKILL.md "CI transient lanes").
set -u

max=${FM_CI_RERUN_MAX:-3}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
state_dir=${FM_HOME:-$root}/state/ci-rerun
pr='' run='' repo=''

while [ $# -gt 0 ]; do
  case $1 in
    --pr) pr=${2:-}; shift 2 ;;
    --run) run=${2:-}; shift 2 ;;
    -R) repo=${2:-}; shift 2 ;;
    -h | --help) sed -n '2,/^set -u/p' "$0" | sed '$d'; exit 0 ;;
    *) echo "usage: fm-ci-rerun-transient.sh (--pr N | --run ID) [-R owner/repo]" >&2; exit 2 ;;
  esac
done
{ [ -n "$pr" ] || [ -n "$run" ]; } || { echo "usage: need --pr or --run" >&2; exit 2; }
case "$pr$run" in *[!0-9]*) echo "usage: --pr/--run take a number" >&2; exit 2 ;; esac
if [ -n "$pr" ] && [ -n "$run" ]; then echo "usage: give --pr or --run, not both" >&2; exit 2; fi

fail() { echo "error: $*"; exit 1; }

if [ -z "$repo" ]; then
  repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) || fail "cannot resolve repo; pass -R"
fi
if [ -z "$pr" ]; then
  pr=$(gh api "repos/$repo/actions/runs/$run" --jq '.pull_requests[0].number // empty') || fail "cannot read run $run"
  [ -n "$pr" ] || fail "run $run has no pull request"
fi
sha=$(gh api "repos/$repo/pulls/$pr" --jq .head.sha) || fail "cannot read PR $pr"
[ -n "$sha" ] || fail "no head sha for PR $pr"

# One "<run-id> <job-id>" line per transient job on the current head's completed runs.
runs=$(gh api "repos/$repo/actions/runs?head_sha=$sha&status=completed&per_page=100" --jq '.workflow_runs[].id') || fail "cannot list runs"
jobs=''
for r in $runs; do
  j=$(gh api "repos/$repo/actions/runs/$r/jobs?per_page=100" --jq \
    '.jobs[] | select(.conclusion == "cancelled" and ((.runner_name // "") == "") and ((.steps // []) | length) == 0) | .id') \
    || fail "cannot list jobs of run $r"
  for id in $j; do jobs="$jobs $id"; done
done
[ -n "$jobs" ] || { echo none; exit 0; }

slug=$(printf '%s' "$repo" | tr '/' '_')
count_file=$state_dir/$slug-pr$pr-$sha.count
n=0
if [ -r "$count_file" ]; then n=$(cat "$count_file" 2>/dev/null); fi
case "$n" in '' | *[!0-9]*) n=0 ;; esac
[ "$n" -lt "$max" ] || { echo exhausted; exit 3; }

for id in $jobs; do
  gh api -X POST "repos/$repo/actions/jobs/$id/rerun" >/dev/null || fail "rerun of job $id failed"
done
n=$((n + 1))
mkdir -p "$state_dir" || fail "reran but cannot record count"
printf '%s\n' "$n" > "$count_file" || fail "reran but cannot record count"
echo "rerun $n"
