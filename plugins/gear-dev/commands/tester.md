---
description: Autonomous black-box tester for Rust crates and Solidity contracts. Iteratively generates corner-case tests, runs them, classifies failures via evidence-backed rubric, and (with --pr) opens draft PRs for real bugs. Tracks tested hypotheses in target/.gear-tester/ jsonl files. Never modifies .gitignore or any file outside test paths and the gitignored target/.gear-tester/ scratch area.
argument-hint: <target-description> [--count N=3] [--loop INTERVAL] [--pr]
---

# /gear-dev:tester

Autonomous black-box testing loop. Each iteration: pick a unit, generate `<count>` corner-case test hypotheses for it, run them, classify, persist results. The working tree always returns to clean state after every iteration.

## Arguments

Parse `$ARGUMENTS` as:

- **`<target-description>`** (required, first positional) — free text. Examples: `all`, `all rust crates`, `all crates with prefix ethexe`, `crate ethexe-consensus`, `Mirror contract`, `demo-ping contract`.
- **`--count N`** (default `3`) — tests to generate per iteration.
- **`--loop INTERVAL`** (default: single run) — when set, schedules the next iteration via `ScheduleWakeup`. Accepts `Nm`, `Nh` (e.g. `15m`, `1h`).
- **`--pr`** (default off) — open **DRAFT** GitHub PRs for real bugs via `gh`.

If `$ARGUMENTS` is empty → ask the user what to test. Do not guess.

## Scope v1 (hard cap)

Only these target types are supported:

- **Rust crate** — a workspace member resolvable via `cargo metadata`
- **Solidity contract** — a `.sol` file under a Foundry root (detected via `foundry.toml`)

If the target description resolves to anything else (function, module, library, CLI, bash, WASM) → abort with `v1 supports only Rust crates and Solidity contracts`.

## State location

All state lives under **`target/.gear-tester/`**. This relies on `target/` already being in `.gitignore` (true for any Rust workspace by Cargo convention). On startup, verify with `git check-ignore target/.gear-tester`. If not gitignored → abort. **Never modify `.gitignore`.**

Files:

| Path | Purpose |
|---|---|
| `contexts/<unit>.md` | Per-unit context (built lazily by opus sub-agent, once per unit) |
| `ok.jsonl` | Passed hypotheses log |
| `failed.jsonl` | Real-bug hypotheses log (includes `test_source` as a string field) |
| `dropped.jsonl` | Hypotheses dropped (compile error or test-wrong) — used for dedup |
| `skipped.jsonl` | Units skipped per iteration with reason |
| `lock` | flock-based iteration lock |
| `cursor` | Round-robin position in t-list |

## Workflow

### Phase 1 — Startup (once per invocation)

1. **Parse arguments.** Empty target description → ask the user.

2. **Verify git state:**
   - In a git repo: `git rev-parse --git-dir` succeeds
   - Working tree clean: `git status --porcelain` is empty
   - Not detached HEAD: `git symbolic-ref --short HEAD` succeeds; save as `<original-branch>`
   
   Any failure → abort with the specific reason.

3. **Detect base branch:**
   ```bash
   gh pr view --json baseRefName -q .baseRefName 2>/dev/null \
     || gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null \
     || git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' \
     || echo master
   ```
   Save as `<base-branch>`.

4. **Resolve target description to a deterministic t-list:**
   - `all` / `all rust crates` →
     ```bash
     cargo metadata --no-deps --format-version 1 \
       | jq -r '.packages[] | select(.id as $id | $id == (.id) and ($id | IN(.. | .id?))) | .name' 2>/dev/null \
       || cargo metadata --no-deps --format-version 1 \
       | jq -r --argjson m "$(cargo metadata --no-deps --format-version 1 | jq '.workspace_members')" '.packages[] | select([.id] | inside($m)) | .name'
     ```
     (or any equivalent: iterate `packages[]`, keep those whose `id` is in `workspace_members[]`, output `name`).
   - `all crates with prefix X` → filter the above by name prefix.
   - `crate X` → assert X is in the workspace-member list; t-list = [X].
   - `<Name> contract` → find foundry roots via `find . -maxdepth 4 -name foundry.toml -type f`; for each root, search `<root>/src/**/<Name>.sol`. Multiple matches across roots → abort, print candidates. Single match → t-list = [{`type`: `sol`, `path`: `<root>/src/.../<Name>.sol`, `root`: `<root>`, `name`: `<Name>`}].
   - Anything else (function, module, library, CLI, bash, wasm…) → abort: `v1 supports only Rust crates and Solidity contracts`.
   
   Empty t-list → abort.

5. **If `--pr`:**
   - `gh auth status` succeeds (else abort).
   - Extract username: `GH_USER=$(gh api user -q .login)`.
   - **Print to user (consent moment):**
     ```
     PRs will be authored as gh user @<GH_USER> against base branch <base-branch>.
     ```

6. **Baseline tooling check** (always required): `git`, `gh`, `jq`, `flock`. Abort with install hints if missing.

7. **Verify state dir is gitignored:**
   ```bash
   mkdir -p target/.gear-tester
   git check-ignore target/.gear-tester
   ```
   If `git check-ignore` exits non-zero → abort with: `target/.gear-tester is not gitignored. Add /target to .gitignore manually, or run in a repo where target/ is already gitignored.`

8. **Print startup summary:**
   ```
   /gear-dev:tester startup
     t-list:       <N> units (<first 3, …>)
     base branch:  <base-branch>
     gh user:      @<GH_USER>           (only if --pr)
     count:        <N> tests/iteration
     loop:         <INTERVAL> | single
     pr mode:      on | off
     loop ends when this Claude Code session closes
   ```

### Phase 2 — Loop control

- **Without `--loop`:** run one iteration, exit.
- **With `--loop X`:** at end of each iteration, call `ScheduleWakeup` with:
  - `delaySeconds`: parse `X` to seconds (`15m` → 900, `1h` → 3600), clamped by ScheduleWakeup to [60, 3600]
  - `prompt`: the original `/gear-dev:tester ...` invocation verbatim
  - `reason`: `next tester iteration in <X>`

### Phase 3 — Per-iteration

#### Step 1: Acquire lock

```bash
exec 200>target/.gear-tester/lock
flock -n 200 || { echo "another iteration is running; skipping"; exit 0; }
echo "$$ $(date +%s)" > target/.gear-tester/lock
```

Stale lock: if the PID stored in `lock` is not alive (`kill -0 <pid>` fails) **and** the timestamp is > 1800s old, force-break by removing and re-acquiring. Print a warning.

#### Step 2: Pick next unit

Read `target/.gear-tester/cursor` (default `0`). Unit = `t-list[cursor % len(t-list)]`. Increment cursor, write back.

Skip units where `ok.jsonl + failed.jsonl + dropped.jsonl` already have ≥ 15 entries for this unit (per-unit budget exhaustion). If all units are budget-exhausted → exit with `all units saturated; increase --count or extend scope`.

#### Step 3: Per-target tooling + build sanity

Determine target type from unit:

- **Rust crate:** require `cargo` + `cargo-nextest`. Run `cargo check -p <unit>`. If fails → append `{ts, unit, reason: "build_broken: <stderr first line>"}` to `skipped.jsonl`, release lock, continue.
- **Solidity contract:** require `forge`. Skip a separate workspace-wide `forge build` (it would fail on any unrelated broken contract). Per-test compile errors are caught at run-time and classified as `compile_error`.

If required tooling missing → append `{ts, unit, reason: "tooling_missing: <tool>"}` to `skipped.jsonl`, continue.

#### Step 4: Build context (opus sub-agent, lazy)

If `target/.gear-tester/contexts/<unit>.md` does **not** exist, invoke the `Agent` tool with:

- `subagent_type`: `general-purpose`
- `model`: `opus`
- `description`: `Build tester context for <unit>`
- `prompt` (template):

```
Produce a dense knowledge file for <type> "<unit>" in this repository, to be
consumed by an autonomous tester. Output MARKDOWN, max 3000 words.

Required sections:

## Public API
Every public function, type, trait, constant. For each: signature, 1-line
purpose, source `file:line`. Be exhaustive but concise.

## State assumptions and lifecycle
What state must be set up before calls? Construction patterns?
Cite source `file:line` for each.

## Documented invariants
For each invariant present in code comments, doc-comments, README, or
linked spec:
- Quote the invariant text verbatim
- Cite `file:line` of the comment
- One-sentence rephrasing in plain prose

If no invariant is documented for a concern, write `(no documented
invariant)`. **Do NOT fabricate.** The tester's bug classifier depends
on these citations being real and verifiable.

## Existing tests
List existing test files (paths only) and the area each covers
(1 line each). No need to read every test in detail.

## Known dependencies
Which other crates/contracts this unit relies on (1 line each).

Do not include implementation reasoning, hypothetical bugs, or suggestions.
This is reference material for a separate test-writing agent.
```

Save the agent's text output to `target/.gear-tester/contexts/<unit>.md`.

#### Step 5: Run iteration (sonnet sub-agent)

Invoke the `Agent` tool with:

- `subagent_type`: `general-purpose`
- `model`: `sonnet`
- `description`: `Tester iteration for <unit>`
- `prompt` (template, with substitutions):

```
You are one iteration of the autonomous black-box tester for <type> "<unit>".

Reference material to READ FIRST:
- CONTEXT FILE: target/.gear-tester/contexts/<unit>.md
- ALREADY TESTED: target/.gear-tester/ok.jsonl, failed.jsonl, dropped.jsonl
  Read all entries with "unit": "<unit>" and build the set of used hypothesis
  hashes.

Your task: generate <count> NEW hypothesis tests for this unit.

For each hypothesis:
1. Pick a scenario_type from this menu:
   empty_input, max_size, negative_value, zero_value, overflow,
   duplicate_key, race, gas_boundary, value_boundary, unicode_malformed,
   invalid_combination, reentrancy (sol only), permission_bypass
2. Pick param_signature: stringified key parameters (e.g. "fn=foo:arg=empty_string")
3. Compute hash = first 12 hex chars of sha256("<unit>:" + scenario_type + ":" + param_signature)
4. If hash is in the used-hash set → discard, try a different combination.
   Cap attempts at 3 * <count> total to avoid infinite loops.

For each accepted hypothesis, write a minimal test:

- Rust crate target:
    Path: <crate-path>/tests/auto_tester_<hash>.rs
    Single #[test] function named `auto_tester_<hash>`.
    Integration test only — no inline `mod`, do not edit any other file.
- Solidity contract target:
    Path: <foundry-root>/test/AutoTester_<Contract>_<hash>.t.sol
    Contract AutoTester<Hash> inherits forge-std `Test`.
    Single function `function test_<hash>() public { … }`.
    Do not edit any other file.

Run each test in isolation:
- Rust:  `cargo nextest run -p <unit> --test auto_tester_<hash>`
- Sol:   `forge test --root <foundry-root> --match-path test/AutoTester_<Contract>_<hash>.t.sol`

Classify each outcome:
- PASSED        → mark for ok.
- COMPILE_ERROR → mark for dropped (reason: "compile_error: <first line of stderr>"). DO NOT retry.
- FAILED        → apply the rubric below.

## Bug classification rubric

A failure is a REAL_BUG ONLY if at least one of the following is satisfied
with concrete evidence cited inline:

(a) Contradicts a documented invariant.
    Evidence: quoted invariant text + `file:line` from the context file's
    "Documented invariants" section.
(b) Violates a math identity (gas conservation, monotonicity, idempotence,
    associativity).
    Evidence: name the identity + observed values that violate it.
(c) Panics/aborts/reverts on an input the API explicitly admits as valid.
    Evidence: cite the signature accepting that input type + the
    panic/abort/revert message.
(d) Produces non-deterministic output on identical input across 3 re-runs.
    Evidence: the 3 differing output values.

If NONE is satisfied with concrete evidence → mark as TEST_WRONG, drop
(reason: "no rubric item satisfied"). DO NOT retry.

## Persist outcomes (in this order, while still in this sub-agent)

- For PASSED tests:
    1. Delete the test file from disk.
    2. Append to ok.jsonl:
       {"ts":"<ISO8601 UTC>","unit":"<unit>","hash":"<hash>","scenario":"<scenario_type>","summary":"<one line>"}

- For DROPPED tests (compile_error or test_wrong):
    1. Delete the test file from disk.
    2. Append to dropped.jsonl:
       {"ts":"<ISO8601 UTC>","unit":"<unit>","hash":"<hash>","scenario":"<scenario_type>","reason":"<one line>"}

- For REAL_BUG tests:
    1. Leave the test file on disk.
    2. Capture test source as a string.

## Return value

Emit a single JSON object as the FINAL LINE of your output (so the orchestrator
can parse it):

{
  "iteration_summary": "<one line>",
  "passed": N,
  "dropped": N,
  "bugs": [
    {
      "hash": "<hash>",
      "scenario": "<scenario_type>",
      "summary": "<one line>",
      "test_path": "<repo-relative path>",
      "test_source": "<full text of the test file>",
      "rubric_items": [
        {"id": "a|b|c|d", "evidence": "<concrete citation or values>"}
      ]
    }
  ]
}

DO NOT open PRs, switch branches, or modify any git state. That is the
orchestrator's job.
```

After sonnet returns, parse the JSON object from the **last line** of its output.

#### Step 6: Handle bugs (main agent)

For each bug in sonnet's `bugs` array:

**WITHOUT `--pr`:**
1. `rm <test_path>` — remove from working tree.
2. Append to `failed.jsonl`:
   ```json
   {"ts":"…","unit":"…","hash":"…","scenario":"…","summary":"…","test_source":"…","rubric_items":[…],"pr_url":null,"branch":null}
   ```

**WITH `--pr`** — process bugs sequentially. At this point, sonnet has already deleted PASSED and DROPPED test files, so the working tree contains exactly the bug test files (untracked).

For each bug:

1. Compute branch name: `auto-tester/<unit-slug>-<hash>` where `<unit-slug>` is the unit name with `/`, `.`, and ` ` replaced by `-` and lowercased.
2. `git checkout -b <branch-name> <base-branch>` — switches to a new branch off the **detected base** (NOT the original branch). Untracked test files follow.
3. `git add <test_path>` — stage only this one bug's test file.
4. `git commit -m "test: corner-case repro for <unit> (auto-tester) <hash>"`
5. `git push -u origin <branch-name>`
   - On failure (branch protection, network, rate limit): append `{ts, unit, reason: "push_failed: …"}` to `skipped.jsonl`, `git checkout <original-branch>`, continue to next bug.
6. `gh pr create --draft --base <base-branch> --head <branch-name> --title "test: <unit> corner-case (auto-tester) <hash>" --body "$(BODY)"`
   
   where `BODY` is:
   ```
   <summary>

   **Scenario:** `<scenario_type>`
   **Hash:** `<hash>`
   **Unit:** `<unit>`

   ## Observed
   <observed failure / panic / revert message>

   ## Rubric items satisfied
   - **(<id>)** <evidence>
   - …

   ## Test source

   ```<rust|solidity>
   <test_source>
   ```

   ---
   Generated by `/gear-dev:tester` (auto-tester).
   This is a **draft** PR — requires human review before merge.
   ```
   - On failure: log to `skipped.jsonl`, switch back, continue.
7. Capture `pr_url` from `gh pr create` output.
8. `git checkout <original-branch>` — the test file vanishes from the working tree (it was tracked only on the PR branch).
9. Append to `failed.jsonl`:
   ```json
   {"ts":"…","unit":"…","hash":"…","scenario":"…","summary":"…","test_source":"…","rubric_items":[…],"pr_url":"<url>","branch":"<branch-name>"}
   ```

After all bugs processed, verify `git status --porcelain` is empty. If not → abort with diagnostic (a tester bug; should not happen).

#### Step 7: Release lock

```bash
flock -u 200
exec 200>&-
rm -f target/.gear-tester/lock
```

#### Step 8: Schedule next iteration

If `--loop` set → call `ScheduleWakeup` as described in Phase 2. Otherwise exit.

## Hash-based dedup

```
hash = sha256(<unit> + ":" + <scenario_type> + ":" + <param_signature>)[:12]
```

Same hash → already tested or dropped → sonnet must skip.

## Hard rules

- **Never modify `.gitignore`** or any file outside (a) test files in standard test paths, (b) files inside `target/.gear-tester/`.
- **Working tree is always clean at the end of every iteration.** Every code path returns to clean state. Verify with `git status --porcelain`.
- **PR branches always come off detected base**, never off the current branch. PRs contain only the test commit, not any in-flight work from the user's branch.
- **PRs are always draft.** Never publish-ready. Human review required before merge.
- **Compile errors → drop, no retry.** Adding a test that doesn't compile means the model misunderstood the API. Retry doesn't fix understanding.
- **Bug rubric requires concrete evidence**, not "model intuition". `file:line` citation or numeric demonstration is mandatory.
- **Per-target build sanity, not workspace.** One broken unrelated crate must not block testing of healthy ones.
- **Sub-agents are isolated.** Main agent never reads context files directly; sonnet reads context. This keeps main-agent context small across many iterations.

## Failure modes

### Early aborts (startup)

| Condition | Action |
|---|---|
| Working tree dirty | abort with `git status --porcelain` output |
| Not in git repo | abort |
| Detached HEAD | abort |
| `git check-ignore target/.gear-tester` non-zero | abort with instruction |
| t-list empty after resolution | abort with description echoed |
| t-list contains unsupported type | abort: `v1 supports only crate and contract` |
| Ambiguous description (multiple matches) | abort, print candidates |
| `--pr` and `gh auth status` fails | abort |
| Required baseline tooling missing (`git`, `gh`, `jq`, `flock`) | abort with install hints |

### Mid-iteration soft failures (log to `skipped.jsonl`, continue to next iteration)

- Per-target build broken
- Per-target tooling missing (no `cargo-nextest`, no `forge`)
- Push rejected (branch protection)
- `gh pr create` rejected (rate limit, permissions)
- Lock file present with live PID

## Examples

```
/gear-dev:tester all rust crates --count 5 --loop 30m --pr
/gear-dev:tester crate ethexe-consensus
/gear-dev:tester crate ethexe-consensus --pr
/gear-dev:tester Mirror contract --count 2
/gear-dev:tester all crates with prefix ethexe --loop 1h --pr
```
