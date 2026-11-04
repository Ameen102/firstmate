#!/usr/bin/env bash
# Seeds a disposable fleet: real tmux panes, real meta/status logs, real holds.
set -u
. "$(dirname "$0")/lab.env"
NOW=$(date +%s)
M=$LAB-mate
mkdir -p "$LAB/projects/wt" "$M"/{data,state,config,projects/wt,bin}
printf '# mate\n' > "$M/AGENTS.md"; printf 'mate\n' > "$M/.fm-secondmate-home"
cat > "$LAB/data/projects.md" <<EOF
- alpha [no-mistakes] - payments; Linear project "Alpha Payments" at https://linear.app/acme/project/alpha-1 (added 2026-07-11)
- beta [direct-PR] - see https://linear.app/acme/project/beta-2. (added 2026-07-11)
- gamma [direct-PR] - no Linear project yet (added 2026-07-11)
- delta [direct-PR] - Linear project "Delta Docs" (added 2026-07-11)
EOF
printf -- '- mate - ops domain; Linear project "Mate Ops" (home: %s; scope: ops; projects: delta; added 2026-07-11)\n' "$M" > "$LAB/data/secondmates.md"
cat > "$LAB/data/backlog.md" <<EOF
## In flight
- [ ] ship-alpha - Ship the checkout retry (repo: alpha) (kind: ship) (since 2026-11-01)
- [ ] fix-beta - Repair flaky webhook (repo: beta) (kind: ship) (since 2026-11-01)
- [ ] scout-gamma - Investigate cache drift (repo: gamma) (kind: scout) (since 2026-11-01)

## Queued
- [ ] next-gamma - Follow-up on cache (repo: gamma) (kind: ship)

## Done
- [x] old-alpha - Landed thing https://github.com/acme/alpha/pull/7 (repo: alpha) (kind: ship) (merged 2026-11-01)
EOF
tmux new-session -d -s fmlab -n fm-ship-alpha 'sleep 7200'
for w in fm-fix-beta fm-scout-gamma fm-mate fm-child-delta; do tmux new-window -d -t fmlab -n $w 'sleep 7200'; done
meta() { f=$1; shift; printf '%s\n' "$@" > "$f"; }
meta "$LAB/state/ship-alpha.meta" window=fmlab:fm-ship-alpha worktree=$LAB/projects/wt project=alpha harness=claude kind=ship mode=direct-PR pr=https://github.com/acme/alpha/pull/41
meta "$LAB/state/fix-beta.meta" window=fmlab:fm-fix-beta worktree=$LAB/projects/wt project=beta harness=claude kind=ship mode=direct-PR
meta "$LAB/state/scout-gamma.meta" window=fmlab:fm-scout-gamma worktree=$LAB/projects/wt project=gamma harness=claude kind=scout mode=scout
meta "$LAB/state/mate.meta" window=fmlab:fm-mate worktree=$M project=$M harness=codex kind=secondmate mode=secondmate home=$M projects=delta
busy() { g=$("$WT/bin/fm-busy-event.sh" arm "$1" "$2"); "$WT/bin/fm-busy-event.sh" apply "$1" "$2" "$3" --gen "$g" --source claude-hook --event "$4"; }
busy "$LAB/state" ship-alpha busy user-prompt-submit
busy "$LAB/state" fix-beta idle stop
busy "$LAB/state" scout-gamma idle stop
printf 'working [at=%s]: wiring retries\nworking [at=%s]: writing tests\n' $((NOW-3600)) $((NOW-300)) > "$LAB/state/ship-alpha.status"
printf 'working [at=%s]: reproducing\nblocked [at=%s]: staging webhook secret is missing\n' $((NOW-7200)) $((NOW-1500)) > "$LAB/state/fix-beta.status"
printf 'working [at=%s]: reading traces\nworking: no stamp on this latest line\n' $((NOW-5000)) > "$LAB/state/scout-gamma.status"
printf 'working [at=%s]: coordinating\nneeds-decision [key=race]: pick subscribe order\n' $((NOW-900)) > "$LAB/state/mate.status"
cat > "$M/data/backlog.md" <<EOF
## In flight
- [ ] child-delta - Update docs (repo: delta) (kind: ship) (since 2026-11-01)

## Queued
- [ ] mate-decision-race - Choose subscription order (repo: delta) (kind: captain) (hold: captain choice pending) (hold-kind: captain)

## Done
- [x] mate-landed - Mate-managed fix https://github.com/acme/delta/pull/50 (repo: delta) (kind: ship) (merged 2026-11-02)
EOF
meta "$M/state/child-delta.meta" window=fmlab:fm-child-delta worktree=$M/projects/wt project=delta harness=claude kind=ship mode=direct-PR
busy "$M/state" child-delta busy user-prompt-submit
printf 'working [at=%s]: drafting docs\n' $((NOW-120)) > "$M/state/child-delta.status"
FM_ROOT_OVERRIDE=$WT FM_HOME=$M TMUX_TMPDIR=$TMUX_TMPDIR "$WT/bin/fm-home-summary-refresh.sh" || echo "summary refresh rc=$?"
# Real captain holds through the owner.
"$WT/bin/fm-captain-hold.sh" hold authored-call --title "Pick the rollout" --repo alpha --reason "which rollout route"
"$WT/bin/fm-captain-hold.sh" hold plain-call --title "Choose retention window" --repo beta --reason "how long to keep data"
"$WT/bin/fm-captain-hold.sh" hold landed-call --title "Merge the hotfix" --repo alpha --reason "merge route"
