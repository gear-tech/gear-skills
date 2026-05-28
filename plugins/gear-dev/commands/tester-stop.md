---
description: Soft-stop a running /gear-dev:tester loop without ending the Claude Code session. Writes a marker file the loop checks at every iteration start. The current in-progress iteration (if any) finishes; the next wakeup exits cleanly. Use when you want to halt iteration but keep working in the same session.
argument-hint: [optional reason text]
---

# /gear-dev:tester-stop

Soft-stop the active `/gear-dev:tester` loop. The current iteration (if one is in flight) finishes; no next wakeup is scheduled.

## What to do

1. Verify we are in a workspace where the tester runs from. Look for `target/.gear-tester/` — if it does not exist, the user has never run `/gear-dev:tester` here, and writing the marker would be pointless. In that case, tell the user "no tester state found at `target/.gear-tester/` — nothing to stop" and exit.

2. Write the stop marker:
   ```bash
   mkdir -p target/.gear-tester
   echo "stopped at $(date -u +%Y-%m-%dT%H:%M:%SZ)${ARGUMENTS:+ — $ARGUMENTS}" \
     > target/.gear-tester/stop
   ```
   The marker body is a single human-readable line. The presence of the file is what matters; the body is for the operator's later inspection in case the marker was written by mistake.

3. Report to the user:
   ```
   stop marker written → target/.gear-tester/stop
   the next /gear-dev:tester iteration will exit cleanly without scheduling another wakeup
   (any iteration currently in progress will finish first — sub-agents are NOT interrupted)
   ```

   If a lock file exists at `target/.gear-tester/lock` AND its PID is alive, additionally tell the user: "an iteration is in progress (lock held by PID <pid>); it will complete normally before the marker is consumed".

## What this does NOT do

- Does **not** interrupt the currently-running iteration. Sonnet sub-agents and cargo invocations finish; the orchestrator only checks the marker at iteration boundaries (Step 0 of the per-iteration workflow).
- Does **not** delete state files. `cursor`, `saturation.json`, `SESSION_NOTES.md`, `ok.jsonl`, `failed.jsonl`, etc. all stay. Running `/gear-dev:tester ...` again with the same args resumes from the same cursor with the same dedup state.
- Does **not** cancel already-opened draft PRs on GitHub. Those stay open for human review.
- Does **not** clean up `target/.gear-tester/` itself. If you want a fresh start, `rm -rf target/.gear-tester/` is the right tool — not this command.

## If you wrote the marker by mistake

Remove it before the next iteration fires:
```bash
rm -f target/.gear-tester/stop
```

The tester's startup (Phase 1, first invocation only) also clears any stale marker, so a marker written when no tester is running will not affect a fresh `/gear-dev:tester` invocation.

## Arguments

`$ARGUMENTS` is optional free text that gets embedded in the marker body as the stop reason. Useful for postmortem inspection:

```
/gear-dev:tester-stop saturation across all crates, will resume after refactor
/gear-dev:tester-stop budget exhausted, switching to manual triage
/gear-dev:tester-stop accidental
```

If no arguments, the marker carries only the timestamp.
