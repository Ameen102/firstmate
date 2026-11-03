#!/bin/bash
# scen.sh <scenario> <code-root>; real daemon in disposable lab home, reports persisted digest buffer + daemon log
scenario=$1; CODE=$2; WT=/Users/ameen/.no-mistakes/worktrees/263a936a3c0b/01M6H4NY8VZ0QMTREE93PYZ0X5
cd "$WT"; . /tmp/fmv/lab.sh; lab_up; trap lab_down EXIT
hist() { local i; : > "$1"; for i in $(seq 1 ${2:-60}); do printf 'failed: HISTORY %s event %s from september\nneeds-decision [key=h%s]: HISTORY question %s\nresolved [key=h%s]: answered\n' "${1##*/}" $i $i $i $i >> "$1"; done; printf 'done: HISTORY %s finished weeks ago\n' "${1##*/}" >> "$1"; }
settle() { for _ in $(seq 1 30); do [ -e "$STATE/.subsuper-last-scan" ] && break; sleep 1; done; sleep ${1:-22}; }
wait_buf() { for _ in $(seq 1 ${2:-40}); do grep -Fq "$1" "$STATE/.subsuper-escalations" "$STATE/.supervise-daemon.log" 2>/dev/null && return 0; sleep 1; done; return 1; }
lib() { (export FM_TEST_DAEMON_SOURCED=1 FM_STATE_OVERRIDE="$STATE"; . "$CODE/bin/fm-supervise-daemon.sh" >/dev/null 2>&1; "$@"); }
sig() { lib status_observed_signature "$1"; }
ident() { lib _fm_open_decisions_file_ident "$1"; }
rpt() { echo "== $1"; echo "buffer_bytes=$(wc -c < "$STATE/.subsuper-escalations" 2>/dev/null || echo 0) HISTORY_mentions=$(cat "$STATE/.subsuper-escalations" 2>/dev/null | grep -o 'HISTORY' | wc -l | tr -d ' ') catchall_items=$(grep -o 'catch-all scan' "$STATE/.subsuper-escalations" 2>/dev/null | wc -l | tr -d ' ')"; echo "buffer: $(cut -c1-600 "$STATE/.subsuper-escalations" 2>/dev/null)"; for m in "$STATE"/.subsuper-seen-status-*; do [ -e "$m" ] && echo "marker ${m##*/}: $(cut -f3 "$m" 2>/dev/null | sed 's/@.*//') of size $(wc -c < "$STATE/${m##*-status-}.status" 2>/dev/null)"; done; echo "cursor: $(cut -f1,3 "$STATE/.status-presentation-cursor" 2>/dev/null | tr '\n' ';')"; echo "daemon_alive=$(kill -0 "$(cat "$STATE/.supervise-daemon.pid" 2>/dev/null)" 2>/dev/null && echo yes || echo no)"; }
log_tail() { echo "-- daemon log"; cut -c1-300 "$STATE/.supervise-daemon.log" 2>/dev/null | sed "s#$LAB#\$LAB#g" | tail -${1:-12}; }
case $scenario in
absent)
  hist "$STATE/octA.status"; hist "$STATE/octB.status"; hist "$STATE/octC.status"; : > "$STATE/fresh-empty.status"
  daemon_start "$CODE"; settle; rpt "after fresh start, no new lines"
  printf 'failed: NEW-A appended after start\n' >> "$STATE/octA.status"
  wait_buf 'NEW-A'; sleep 3; rpt "after new line on octA"
  printf 'failed: NEW-EMPTY first ever line\n' >> "$STATE/fresh-empty.status"
  printf 'done: NEW-BRAND task created after start\n' > "$STATE/brandnew.status"
  wait_buf 'NEW-BRAND'; wait_buf 'NEW-EMPTY' 20; sleep 3; rpt "after first line on empty log and brand-new log"; log_tail ;;
unclassified)
  hist "$STATE/octA.status"; printf 'v2\t%s\t-' "$(sig "$STATE/octA.status")" > "$STATE/.subsuper-seen-status-octA"
  daemon_start "$CODE"; settle; rpt "after fresh start, unclassified marker"
  printf 'failed: NEW-A appended after start\n' >> "$STATE/octA.status"; wait_buf 'NEW-A'; sleep 3; rpt "after new line"; log_tail 6 ;;
cursor)
  hist "$STATE/octA.status"; mid=$(($(wc -c < "$STATE/octA.status"))); printf 'failed: UNPRESENTED past cursor\n' >> "$STATE/octA.status"
  printf 'octA\t%s\t%s\n' "$(ident "$STATE/octA.status")" "$mid" > "$STATE/.status-presentation-cursor"
  echo "cursor offset=$mid size=$(wc -c < "$STATE/octA.status")"
  daemon_start "$CODE"; settle; rpt "after fresh start, cursor mid-file"; log_tail 6 ;;
roundtrip)
  hist "$STATE/octA.status" 50
  daemon_start "$CODE"; settle 12; printf 'failed: AWAY1 during first away session\n' >> "$STATE/octA.status"; wait_buf 'AWAY1'; sleep 8; rpt "session 1 running"
  fmenv "$CODE/bin/fm-afk-return.sh" begin > "$LAB/ret.out" 2>&1; echo "return begin rc=$?"; fmenv "$CODE/bin/fm-afk-return.sh" check >> "$LAB/ret.out" 2>&1; echo "return check rc=$?"; wait "$DPID" 2>/dev/null
  rpt "after return"
  printf 'failed: ATTENDED1 presented by main while attended\n' >> "$STATE/octA.status"
  fmenv "$CODE/bin/fm-wake-drain.sh" > "$LAB/drain.out" 2>&1; echo "drain rc=$?; drain shows ATTENDED1: $(grep -c ATTENDED1 "$LAB/drain.out")"
  rpt "after attended drain"
  daemon_start "$CODE"; settle; rpt "session 2 fresh start"
  printf 'failed: AWAY2 during second away session\n' >> "$STATE/octA.status"; wait_buf 'AWAY2'; sleep 3; rpt "session 2 new line"; log_tail 8 ;;
unpresented)
  hist "$STATE/octA.status" 50
  daemon_start "$CODE"; settle 12; printf 'failed: AWAY1 during first away session\n' >> "$STATE/octA.status"; wait_buf 'AWAY1'; sleep 8
  fmenv "$CODE/bin/fm-afk-return.sh" begin > "$LAB/ret.out" 2>&1; fmenv "$CODE/bin/fm-afk-return.sh" check >> "$LAB/ret.out" 2>&1; wait "$DPID" 2>/dev/null; rpt "after return"
  printf 'failed: UNPRESENTED while daemon down, nobody drained\n' >> "$STATE/octA.status"
  daemon_start "$CODE"; settle; rpt "session 2 fresh start: unpresented line must surface"; log_tail 6 ;;
ahead)
  printf 'failed: PRESENTED by main\n' > "$STATE/octA.status"; c=$(($(wc -c < "$STATE/octA.status"))); printf 'failed: CLASSIFIED while away\n' >> "$STATE/octA.status"; m=$(($(wc -c < "$STATE/octA.status")))
  id=$(ident "$STATE/octA.status"); lib status_presentation_marker_commit "$STATE/.subsuper-seen-status-octA" "$STATE/octA.status" "$m" "$id"; printf 'octA\t%s\t%s\n' "$id" "$c" > "$STATE/.status-presentation-cursor"
  printf 'failed: TAIL unclassified\n' >> "$STATE/octA.status"; rpt "before start"
  daemon_start "$CODE"; settle; rpt "after start: only TAIL expected"; log_tail 6 ;;
unreadable)
  hist "$STATE/octA.status" 20; hist "$STATE/octB.status" 20; printf 'v2\tx\t-' > "$STATE/.subsuper-seen-status-octA"; chmod 000 "$STATE/.subsuper-seen-status-octA"
  daemon_start "$CODE"; settle; rpt "unreadable marker octA, none on octB"; log_tail 8; chmod 600 "$STATE/.subsuper-seen-status-octA";;
badcursor)
  hist "$STATE/octA.status" 20; printf 'garbage\trow\tnot-a-number\textra\tfields\n' > "$STATE/.status-presentation-cursor"
  daemon_start "$CODE"; settle; rpt "malformed presentation cursor"; log_tail 8; echo "-- err"; cut -c1-200 "$LAB/daemon.err" | tail -5 ;;
piggy)
  hist "$STATE/octA.status"; hist "$STATE/octB.status"
  daemon_start "$CODE"; for _ in $(seq 1 30); do [ -e "$STATE/.subsuper-last-scan" ] && break; sleep 1; done
  printf 'failed: NEW-A right after first scan\n' >> "$STATE/octA.status"; sleep 30; rpt "new line racing watcher first sighting"; log_tail 8 ;;
big)
  hist "$STATE/octA.status" 400; hist "$STATE/octB.status" 400; hist "$STATE/octC.status" 400; start=$SECONDS
  wc -w "$STATE"/oct*.status | tail -1
  daemon_start "$CODE"; for _ in $(seq 1 240); do [ "$(grep -c catch-all "$STATE/.subsuper-escalations" 2>/dev/null)" = 3 ] && break; sleep 1; done; echo "waited $((SECONDS-start))s"; rpt "large fleet history"; wc -w "$STATE/.subsuper-escalations" 2>/dev/null; log_tail 6 ;;
esac
