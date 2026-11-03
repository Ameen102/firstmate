#!/usr/bin/env bash
# Live handover drive: two disposable firstmate homes (git archive of the branch)
# behind a real private sshd on loopback. Only home paths differ from the skill's commands.
set -u
W=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/cow.XXXXXX"); LAB=$(cd "$LAB" && pwd -P)
PC=$LAB/pc; MACH=$LAB/mac; SD=$LAB/sshd; mkdir -p "$SD"
for h in "$PC" "$MACH"; do "$W/bin/fm-lab-home.sh" create "$h" >/dev/null; git -C "$W" archive HEAD | tar -x -C "$h"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$h/data/backlog.md"; done
ssh-keygen -q -t ed25519 -N '' -f "$SD/host"; ssh-keygen -q -t ed25519 -N '' -f "$SD/client"; cp "$SD/client.pub" "$SD/auth"; chmod 600 "$SD/auth"
PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
cat > "$SD/sshd_config" <<EOF
Port $PORT
ListenAddress 127.0.0.1
HostKey $SD/host
PidFile $SD/pid
AuthorizedKeysFile $SD/auth
StrictModes no
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF
/usr/sbin/sshd -f "$SD/sshd_config" -E "$SD/log" || { echo "sshd failed"; cat "$SD/log"; exit 9; }
sleep 1
cat > "$SD/ssh_config" <<EOF
Host omarchy mac
  HostName 127.0.0.1
  Port $PORT
  IdentityFile $SD/client
  IdentitiesOnly yes
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  LogLevel ERROR
  BatchMode yes
EOF
ssh() { command ssh -F "$SD/ssh_config" "$@"; }
cleanup() { kill "$(cat "$SD/pid" 2>/dev/null)" 2>/dev/null; rm -rf "$LAB"; }; trap cleanup EXIT
unset NO_MISTAKES_GATE FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
say() { printf '\n=== %s\n' "$*"; }
run() { printf '$ %s\n' "$*"; "$@"; rc=$?; echo "[exit $rc]"; return $rc; }
hold() { (cd "$1" && shift && FM_HOME=$OLDPWD bin/fm-captain-hold.sh "$@"); }
holdin() { local h=$1; shift; printf '[in %s] fm-captain-hold.sh %s\n' "$(basename "$h")" "$*"; (cd "$h" && FM_HOME="$h" bin/fm-captain-hold.sh "$@"); echo "[exit $?]"; }
ts() { date -u +%Y%m%dT%H%M%S%N 2>/dev/null | tr -d N; }
send_pc() { ssh omarchy "cd $PC && FM_HOME=$PC bin/fm-inbox.sh note --request-id $1 -" < "$2"; echo "[exit $?]"; }
send_mac() { ssh mac "cd $MACH && FM_HOME=$MACH bin/fm-inbox.sh note --request-id $1 -" < "$2"; echo "[exit $?]"; }
TODAY=$(date -u +%F)

say "S1 setup: owners table on pc, mac reads over ssh"
printf '| item | owner | since |\n|---|---|---|\n| proj-x | pc | 2026-11-01 |\n' > "$PC/data/owners.md"
ssh omarchy cat "$PC/data/owners.md"; echo "[exit $?]"

say "S2 pc holds a captain call on proj-x, writes note, flips line, sends over ssh into mac home"
holdin "$PC" hold x-call --title 'Pick X rollout' --reason 'Needs captain (blue or green)' --until 2030-01-15
cat > "$LAB/note1.txt" <<'EOF'
handoff: proj-x
What: proj-x service.
Stands: PR open, review pending.
In flight: none.
Open decisions: x-call | Pick X rollout | Needs captain (blue or green) | until 2030-01-15
Links: https://example.invalid/pr/1
EOF
sed -i '' "s/| proj-x | pc | 2026-11-01 |/| proj-x | mac | $TODAY |/" "$PC/data/owners.md"; cat "$PC/data/owners.md"
RID1=handoff-proj-x-$(date -u +%Y%m%dT%H%M%S)
send_mac "$RID1" "$LAB/note1.txt"
echo "--- mac wake queue:"; cat "$MACH/state/.wake-queue"
echo "--- mac inbox list:"; (cd "$MACH" && FM_HOME=$MACH bin/fm-inbox.sh list)
echo "--- pc inbox list (must be empty; FM_HOME names receiver):"; (cd "$PC" && FM_HOME=$PC bin/fm-inbox.sh list)

say "S3 adversarial: same request id on a NEW body returns replay and discards body"
printf 'handoff: proj-x\nDIFFERENT BODY\n' > "$LAB/note1b.txt"
send_mac "$RID1" "$LAB/note1b.txt"
grep -l 'DIFFERENT BODY' "$MACH"/state/inbox/* 2>/dev/null || echo "DIFFERENT BODY stored nowhere"

say "S4 adversarial: receiver owner-line check - mac reads table over ssh; names mac -> proceed"
ssh omarchy cat "$PC/data/owners.md" | grep proj-x

say "S5 mac re-files call with --title/--reason/--until, replies accepted into pc inbox"
holdin "$MACH" hold x-call --title 'Pick X rollout' --reason 'Needs captain (blue or green)' --until 2030-01-15
holdin "$MACH" open x-call
printf 'accepted proj-x\n' > "$LAB/acc.txt"
send_pc "accepted-proj-x-$(date -u +%Y%m%dT%H%M%S)" "$LAB/acc.txt"
echo "--- pc wake queue:"; cat "$PC/state/.wake-queue"
NOTE=$(cd "$MACH" && FM_HOME=$MACH bin/fm-inbox.sh list | grep -Eo '[0-9]+-[A-Za-z0-9]+' | head -1)
echo "note id: $NOTE"
run env FM_HOME="$MACH" "$MACH/bin/fm-inbox.sh" drain --ack "$NOTE"
(cd "$MACH" && FM_HOME=$MACH bin/fm-inbox.sh list)

say "S6 pc closes own copy on accept reply"
printf 'handed over to mac\n' > "$LAB/dec.txt"
holdin "$PC" answer x-call --decision-file "$LAB/dec.txt"
grep -n 'x-call' "$PC/data/backlog.md" | head -3
ACC=$(cd "$PC" && FM_HOME=$PC bin/fm-inbox.sh list | grep -Eo '[0-9]+-[A-Za-z0-9]+' | head -1); FM_HOME=$PC "$PC/bin/fm-inbox.sh" drain --ack "$ACC" >/dev/null

say "S7 adversarial round trip: mac hands back, pc's re-file of closed id refused; fallback <id>-<date> succeeds and is named in accept"
sed -i '' "s/| proj-x | mac | .* |/| proj-x | pc | $TODAY |/" "$PC/data/owners.md"; ssh omarchy cat "$PC/data/owners.md" | grep proj-x
printf 'handoff: proj-x\nOpen decisions: x-call | Pick X rollout | Needs captain\n' > "$LAB/note2.txt"
send_pc "handoff-proj-x-$(date -u +%Y%m%dT%H%M%S)-2" "$LAB/note2.txt"
holdin "$PC" hold x-call --title 'Pick X rollout' --reason 'Needs captain'
FB=x-call-$TODAY
holdin "$PC" hold "$FB" --title 'Pick X rollout' --reason 'Needs captain'
printf 'accepted proj-x\nre-filed as %s\n' "$FB" > "$LAB/acc2.txt"
send_mac "accepted-proj-x-$(date -u +%Y%m%dT%H%M%S)-2" "$LAB/acc2.txt"
holdin "$MACH" answer x-call --decision-file "$LAB/dec.txt"

say "S8 third handover of same item to same home with fresh id is NOT dropped"
sed -i '' "s/| proj-x | pc | .* |/| proj-x | mac | $TODAY |/" "$PC/data/owners.md"
printf 'handoff: proj-x\nThird handover body\n' > "$LAB/note3.txt"
sleep 1
send_mac "handoff-proj-x-$(date -u +%Y%m%dT%H%M%S)-3" "$LAB/note3.txt"
grep -l 'Third handover body' "$MACH"/state/inbox/*.note

say "S9 item with slash sanitized in request id; raw id refused"
printf 'forward: a/b\n' > "$LAB/f.txt"
send_mac "forward-a/b-20261103T000000" "$LAB/f.txt" 2>&1
send_mac "forward-a-b-20261103T000000" "$LAB/f.txt" 2>&1

say "S10 failure: send into unreachable/absent home exits nonzero, no delivery phrase (rollback trigger)"
send_pc_bad() { ssh omarchy "cd $LAB/nonexistent && FM_HOME=$LAB/nonexistent bin/fm-inbox.sh note --request-id x-1 -" < "$LAB/f.txt"; echo "[exit $?]"; }
send_pc_bad 2>&1
say "S10b wake append fails: saved but not woken, exit nonzero"
mv "$MACH/bin/fm-wake-lib.sh" "$MACH/bin/fm-wake-lib.sh.off"
before=$(ls "$MACH/state/inbox" | grep -c '\.note$')
sleep 1
RY=handoff-y-$(date -u +%Y%m%dT%H%M%S)
send_mac "$RY" "$LAB/note3.txt" 2>&1
echo "notes before=$before after=$(ls "$MACH/state/inbox" | grep -c '\.note$')"
mv "$MACH/bin/fm-wake-lib.sh.off" "$MACH/bin/fm-wake-lib.sh"
say "S10c resend same id after unconfirmed delivery now wakes (resend rule)"
send_mac "$RY" "$LAB/note3.txt" 2>&1
echo "pending wake rows naming it:"; grep -c "$(cat "$MACH/state/inbox/.requests/$RY")" "$MACH/state/.wake-queue"
