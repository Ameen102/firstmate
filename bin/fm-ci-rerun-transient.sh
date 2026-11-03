#!/usr/bin/env bash
# fm-ci-rerun-transient.sh - rerun CI jobs that were cancelled before any runner
# was assigned, a bounded number of times per PR head, before anyone is asked.
#
# Usage:
#   fm-ci-rerun-transient.sh (--pr <number> | --run <run-id>) [-R <owner/repo>]
#
# A transient lane is a job on the PR's current head whose conclusion is
# cancelled, whose runner_name is empty and which ran no steps: GitHub never
# gave it a machine. Only those jobs are rerun, at most one job per run per
# call because GitHub refuses a second rerun while the run is active; the next
# call takes the next job. Real failures, and jobs cancelled after a runner
# started, are never touched. --run resolves the run's PR and then behaves as
# --pr. Only the newest run per workflow on the PR's current head is considered,
# so a lane cancelled by a newer push or a same-head supersession is left alone.
# A run whose jobs all skipped executes nothing (a non-full-ci label event) and
# supersedes nothing, so it is passed over.
#
# The attempt count lives in <state>/ci-rerun/<repo>-pr<N>-<head>.count, where
# <state> is $FM_STATE_OVERRIDE or else $FM_HOME/state (FM_HOME defaults to this
# code root), so a new head starts at zero and the count never passes 3. It is
# written before the first rerun request, so a request that fails still spends
# its attempt and the limit holds.
#
# Output (one line) and exit status:
#   rerun N     exit 0  attempt N of the limit was started for the transient jobs
#   exhausted   exit 3  transient jobs remain but the limit was already spent;
#                       escalate the finding
#   none        exit 0  no transient job; any failure is real, escalate unchanged
#   error: ...  exit 1  nothing is decided; retry. A run still in progress (holding
#                       a transient job, with no job resolved yet, or with this head
#                       already rerun) or a read or count-write failure starts and
#                       counts nothing; a failed rerun request has spent its attempt.
# Usage errors exit 2.
#
# Callers: a worker or firstmate runs this before escalating a CI-gate failure
# (.agents/skills/validation-supervision/SKILL.md "CI transient lanes").
set -u

max=3
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
state_dir=${FM_STATE_OVERRIDE:-${FM_HOME:-$root}/state}/ci-rerun
pr='' run='' repo=''

usage() { echo "usage: fm-ci-rerun-transient.sh (--pr N | --run ID) [-R owner/repo]" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case $1 in
    --pr) [ $# -ge 2 ] || usage; pr=$2; shift 2 ;;
    --run) [ $# -ge 2 ] || usage; run=$2; shift 2 ;;
    -R) [ $# -ge 2 ] || usage; repo=$2; shift 2 ;;
    -h | --help) sed -n '2,/^set -u/p' "$0" | sed '$d'; exit 0 ;;
    *) usage ;;
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

slug=$(printf '%s' "$repo" | tr '/' '_')
count_file=$state_dir/$slug-pr$pr-$sha.count
n=0
if [ -r "$count_file" ]; then n=$(cat "$count_file" 2>/dev/null); fi
case "$n" in '' | *[!0-9]*) n=0 ;; esac

runs=$(gh api "repos/$repo/actions/runs?head_sha=$sha&per_page=100" --jq \
  '.workflow_runs | sort_by(-.id) | .[] | "\(.id):\(.workflow_id):\(.status)"') || fail "cannot list runs"
jobs='' seen=''
for entry in $runs; do
  IFS=: read -r r wf status <<<"$entry"
  case " $seen " in *" $wf "*) continue ;; esac
  j=$(gh api "repos/$repo/actions/runs/$r/jobs?per_page=100" --jq \
    'if ([.jobs[].conclusion] | unique) == ["skipped"] then "skipped" elif any(.jobs[]; (.conclusion // "skipped") != "skipped" or (.runner_name // "") != "") | not then "unresolved" else first(.jobs[] | select(.conclusion == "cancelled" and ((.runner_name // "") == "") and ((.steps // []) | length) == 0) | .id) end') \
    || fail "cannot list jobs of run $r"
  [ "$j" != skipped ] || continue
  seen="$seen $wf"
  if [ "$status" != completed ] && { [ -n "$j" ] || [ "$n" -gt 0 ]; }; then
    fail "run $r still in progress, retry when complete"
  fi
  case $j in '' | unresolved) ;; *) jobs="$jobs $j" ;; esac
done
[ -n "$jobs" ] || { echo none; exit 0; }

[ "$n" -lt "$max" ] || { echo exhausted; exit 3; }

n=$((n + 1))
mkdir -p "$state_dir" || fail "cannot record count; nothing rerun"
printf '%s\n' "$n" > "$count_file" || fail "cannot record count; nothing rerun"
for id in $jobs; do
  gh api -X POST "repos/$repo/actions/jobs/$id/rerun" >/dev/null || fail "rerun of job $id failed; attempt $n spent"
done
echo "rerun $n"
