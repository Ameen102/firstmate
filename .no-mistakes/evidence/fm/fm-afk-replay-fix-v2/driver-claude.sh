WT=$PWD; . /tmp/fmv/lab.sh
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); "$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null; mkdir -p "$LAB/tmux"; SOCK="$LAB/tmux"; STATE="$LAB/state"; touch "$LAB/config/supervision-host-off"
SOCK=$("$WT/bin/fm-lab-home.sh" tmux-dir "$LAB")
trap lab_down EXIT
for t in octA octB octC; do : > "$STATE/$t.status"; for i in $(seq 1 40); do printf 'failed: HISTORY %s event %s from september\n' $t $i >> "$STATE/$t.status"; done; printf 'done: HISTORY %s finished weeks ago\n' $t >> "$STATE/$t.status"; done
T() { env -u TMUX TMUX_TMPDIR="$SOCK" tmux -L fm-lab "$@"; }
env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN -u CLAUDE_CODE_EXECPATH -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ATTENDED -u CLAUDE_PID -u CLAUDE_EFFORT -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX TMUX_TMPDIR="$SOCK" tmux -L fm-lab new-session -d -s primary -x 180 -y 50 -c "$WT" -e FM_HOME="$LAB" claude
TGT=primary:0.0; sleep 12; T capture-pane -p -t primary | tail -25 > /tmp/fmv/boot1.txt
for k in 1 2 3; do if grep -qiE 'trust|do you|enter to confirm|❯ 1' /tmp/fmv/boot1.txt && ! grep -q 'for shortcuts\|bypass\|plan mode' /tmp/fmv/boot1.txt; then T send-keys -t primary Enter; sleep 6; T capture-pane -p -t primary | tail -25 > /tmp/fmv/boot1.txt; fi; done
echo "== primary boot"; grep -v '^$' /tmp/fmv/boot1.txt | cut -c1-170
fmenv "$WT/bin/fm-afk-launch.sh" enter --words "lab validation" >"$LAB/afk.out" 2>&1; fmenv "$WT/bin/fm-afk-launch.sh" start-native >>"$LAB/afk.out" 2>&1
FM_AFK_STATE_PREPARED=1 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_ESCALATE_BATCH_SECS=2 fmenv "$WT/bin/fm-afk-start.sh" >"$LAB/daemon.out" 2>"$LAB/daemon.err" &
DPID=$!
for _ in $(seq 1 30); do [ -e "$STATE/.subsuper-last-scan" ] && break; sleep 1; done; sleep 35
echo "== pane 35s after fresh start (no new lines)"; T capture-pane -p -S - -t primary | grep -v '^$' | tail -12 | cut -c1-170
echo "pane HISTORY mentions: $(T capture-pane -p -S - -t primary | grep -c HISTORY); buffer: $(cat "$STATE/.subsuper-escalations" 2>/dev/null | wc -c)"
printf 'failed: NEW-LIVE appended after fresh start\n' >> "$STATE/octB.status"
for _ in $(seq 1 90); do T capture-pane -p -S - -t primary | grep -q 'NEW-LIVE' && break; sleep 1; done; sleep 4
echo "== pane after new line"; T capture-pane -p -S - -t primary | grep -v '^$' | tail -25 | cut -c1-170
echo "pane HISTORY mentions: $(T capture-pane -p -S - -t primary | grep -c 'HISTORY'); NEW-LIVE mentions: $(T capture-pane -p -S - -t primary | grep -c 'NEW-LIVE')"
echo "-- log"; sed "s#$LAB#\$LAB#g" "$STATE/.supervise-daemon.log" | cut -c1-260
