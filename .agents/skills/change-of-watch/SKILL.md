---
name: change-of-watch
description: >-
  Agent-only handoff protocol for captains who run more than one firstmate.
  Load before acting on, handing over, or accepting any project or second mate when data/owners.md exists in either firstmate home, and on any inbox note that starts with "handoff:" or "accepted".
user-invocable: false
metadata:
  internal: true
---

# change-of-watch

Hand projects and second mates between two firstmates so exactly one of them owns each thing at any time.
Transport is the existing `bin/fm-inbox.sh note` over SSH; this skill adds no scripts and no new state beyond one table.

## Fleet

- `pc`: the always-on firstmate on the Omarchy PC, home `/home/ameen/firstmate`; reached from the Mac as `ssh omarchy`.
- `mac`: the firstmate on the MacBook, home `/Users/ameen/firstmate`; reached from the PC as `ssh mac`.

Out of scope: live chat between firstmates, backlog syncing, new scripts.

## 1. One owner per thing

`data/owners.md` in the `pc` home is the only owner table.
It has one line per project or second mate: the item, its owner (`pc` or `mac`), and the since-date.
Both firstmates read it; the `mac` firstmate reads it with `ssh omarchy cat /home/ameen/firstmate/data/owners.md`.
Only the current owner changes its own line.
A `mac` owner edits the line over SSH on the `pc` host; never edit a line you do not own.

## 2. Check before acting

Before starting, steering, or merging anything for a project or second mate, read the table.
Not yours: do not touch it, and forward the request to its owner as in "Captain messages" below.

## 3. Handing over

1. Write a 5-10 line note: what the item is, where it stands, what is in flight, each open captain decision's task id, title, reason, and any deferral date, links.
   Start the first line with `handoff: <item>`.
2. Flip the item's owner line to the other firstmate and set the since-date.
3. Send the note into the other firstmate's inbox, running `fm-inbox.sh note` in that firstmate's home over SSH.
   `note` writes a durable record and appends one wake, so the receiver is woken and the note survives a crash.
   Pass `--request-id handoff-<item>-<UTC timestamp>`, fresh for each handover, with any character of `<item>` outside `A-Za-z0-9._:-` replaced by `-`.
   Reuse that id only to resend the same handover after an unconfirmed delivery: a repeat returns `replay` instead of a second note.

Command shapes (body on stdin avoids shell quoting of multi-line text):

```
# mac -> pc
ssh omarchy 'cd /home/ameen/firstmate && FM_HOME=/home/ameen/firstmate bin/fm-inbox.sh note --request-id <request-id> -' < note.txt

# pc -> mac
ssh mac 'cd /Users/ameen/firstmate && FM_HOME=/Users/ameen/firstmate bin/fm-inbox.sh note --request-id <request-id> -' < note.txt
```

`FM_HOME` selects whose `state/` and `data/` receive the note; set it explicitly to the receiver's home so the note can never land in the sender's own inbox.
The note is delivered only when the command exits 0 and prints `firstmate will pick this up at its next check.`; `queued <id>` or `replay <id>` alone is not proof, because the record can be saved without the wake.
Step 2 already flipped the owner line before this send, so if the command exits non-zero, flip the owner line back and tell the captain.

## 4. Receiving

Read the note when its `check: captain inbox note` wake arrives, then acknowledge it with `bin/fm-inbox.sh drain --ack <id>`.
Reply `accepted <item>` into the sender's inbox with the same stdin command shape and a fresh request id built the same way, `accepted-<item>-<UTC timestamp>`, then take over the item.
Re-file each open captain decision listed in the note as your own hold in your home with `bin/fm-captain-hold.sh hold <task-id> --title <title> --reason <reason>`, adding the decision's deferral date as `--until <date>` when the note carries one; the sender then closes its own copy as `handed over to <receiver>` through `bin/fm-captain-hold.sh answer <task-id> --decision-file <path>` with the file stating the handover, so the captain's later answer goes to you.
When that re-file is refused because the task id is already closed, re-file under `<id>-<handover date>` and name that id in the accept reply; the sender closes its own copy only after the accept reply confirms the re-file.
The owner line is already flipped by the sender; confirm it names you before acting.
Anything unclear: ask back through the sender's inbox; never guess.

## 5. Captain messages

The captain may talk to either firstmate.
A request for something you do not own is forwarded to the owner through its inbox, and you tell the captain which firstmate has it.

## 6. Second mates

A second mate moves with its owner.
Use the normal retire-then-reseed path from `secondmate-provisioning`: retire it in the old home, seed it in the new home, then hand over per step 3, re-filing its held captain calls as in Receiving.
