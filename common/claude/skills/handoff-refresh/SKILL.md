---
name: handoff-refresh
description: Refresh context by saving a handoff, clearing the session, and resuming. Use when the conversation has grown large and you want a clean context window while preserving working state. Triggers on phrases like "refresh context", "reset with handoff", "context too big — restart", or explicit /handoff-refresh.
---

# handoff-refresh — three-step context refresh

Goal: free up context-window tokens **without losing working state** by chaining
`handoff:create` → user-side `/clear` → `handoff:resume`.

## Why three steps and not one

`/clear` is a Claude Code harness command, not a skill. It wipes the current
session, including the running skill itself. A skill therefore cannot invoke
`/clear` automatically — the user must press it. This skill owns the work
*either side* of `/clear`:

1. **Before `/clear`** — automatically invoke `handoff:create` so working state
   is captured to disk.
2. **At `/clear`** — hand off to the user with explicit, copy-pasteable
   instructions.
3. **After `/clear`** — in the fresh session the user invokes `handoff:resume`
   (or this skill again, which detects the existing handoff and resumes).

## Workflow

### Step 1 — Save state

Use the **Skill** tool to invoke `handoff:create`. Pass through any context
the user gave you (specific files, decisions in flight, the goal of the
current task) so the handoff is rich enough to restart cold.

If `handoff:create` reports it created a `HANDOFF.md` (or returns the path it
wrote), capture that path for the message in Step 2.

### Step 2 — Hand off to the user

Stop tool calls. Print exactly this block to the user (substitute the actual
handoff path):

```
Handoff written to <path/to/HANDOFF.md>.

Next steps (manual — /clear cannot be invoked from a skill):
  1. Run /clear to drop the conversation context.
  2. Run /handoff:resume in the fresh session, or just say "resume from
     handoff" and I will pick it up.
```

Do **not** continue with other work in this session — the whole point is to
reach a clean state.

### Step 3 — Resume (fresh session)

If a user invokes `/handoff-refresh` again in a *new* session and a recent
`HANDOFF.md` is present in the working directory (or wherever
`handoff:resume` looks), skip Step 1 entirely and instead invoke
`handoff:resume`. This makes the skill idempotent across sessions: same
command, correct behavior on either side of the `/clear`.

Detection rule: if `HANDOFF.md` exists and was modified within the last 60
minutes, treat that as "post-`/clear` state" and call `handoff:resume`.
Otherwise treat it as "pre-`/clear` state" and run Step 1.

## Notes

- Don't write anything to `HANDOFF.md` yourself — delegate entirely to the
  `handoff:create` skill so its formatting conventions are preserved.
- If the project already had a stale `HANDOFF.md` from days ago, mention it
  in Step 2 so the user knows the file is being overwritten.
- This skill assumes the `handoff` plugin is enabled in
  `settings.json.enabledPlugins`. If `handoff:create` / `handoff:resume` are
  unavailable, abort and tell the user to enable the handoff marketplace
  plugin.
