# sourced helpers. REPO=<code root>; creates lab home and tmux server with a `cat` captain pane.
lab_up() {
  LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); "$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
  SOCK=$("$WT/bin/fm-lab-home.sh" tmux-dir "$LAB")
  STATE="$LAB/state"; touch "$LAB/config/supervision-host-off"
  env -u TMUX TMUX_TMPDIR="$SOCK" tmux -L fm-lab new-session -d -s primary -x 200 -y 50 "cat"
  TGT=$(env -u TMUX TMUX_TMPDIR="$SOCK" tmux -L fm-lab display -p -t primary '#{session_name}:#{window_index}.#{pane_index}')
}
fmenv() {
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$LAB" TMUX_TMPDIR="$SOCK" TMUX="$SOCK/tmux-$(id -u)/fm-lab,0,0" TMUX_PANE=%0 FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET="$TGT" FM_DAEMON_PRIMARY_HARNESS=claude "$@"
}
daemon_start() { # <code root>
  fmenv "$1/bin/fm-afk-launch.sh" enter --words "lab validation" >>"$LAB/afk.out" 2>&1
  fmenv "$1/bin/fm-afk-launch.sh" start-native >>"$LAB/afk.out" 2>&1
  FM_AFK_STATE_PREPARED=1 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_ESCALATE_BATCH_SECS=2 FM_INJECT_SKIP=__none__ fmenv "$1/bin/fm-afk-start.sh" >"$LAB/daemon.out" 2>"$LAB/daemon.err" &
  DPID=$!
}
daemon_stop() { local p; p=$(cat "$STATE/.supervise-daemon.pid" 2>/dev/null); [ -n "$p" ] && kill "$p" 2>/dev/null; for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$p" 2>/dev/null || break; sleep 1; done; wait "$DPID" 2>/dev/null; }
pane() { env -u TMUX TMUX_TMPDIR="$SOCK" tmux -L fm-lab capture-pane -p -S - -t primary | grep -v "^$"; }
lab_down() { daemon_stop; env -u TMUX TMUX_TMPDIR="$SOCK" tmux -L fm-lab kill-server 2>/dev/null; "$WT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1; rm -rf "$LAB"; }
