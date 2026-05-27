---
description: Autonomous black-box tester for Rust crates and Solidity contracts. Iteratively generates corner-case tests, runs them, classifies failures via an evidence-backed rubric, and (with --pr) opens draft PRs for real bugs. Tracks tested hypotheses in target/.gear-tester/ jsonl files. Routes compile errors through an opus-verifier (drop / regenerate-context / quarantine behind a feature gate). Auto-detects multi-workspace repos and skips binary/WASM-only crates without spawning a context builder.
argument-hint: <target-description> [--count N=3] [--loop INTERVAL] [--pr]
---

# /gear-dev:tester

Autonomous black-box testing loop. Each iteration: pick a unit, generate `<count>` corner-case test hypotheses for it, run them, classify, persist results. The working tree always returns to clean state after every iteration (modulo a one-time `[features] auto_tester_quarantine = []` line added to the unit's `Cargo.toml` the first time a quarantined test is created — see Step 7).

## Arguments

Parse `$ARGUMENTS` as:

- **`<target-description>`** (required, first positional) — free text. Examples: `all`, `all rust crates`, `all crates with prefix ethexe`, `crate ethexe-consensus`, `Mirror contract`, `demo-ping contract`.
- **`--count N`** (default `3`) — tests to generate per iteration.
- **`--loop INTERVAL`** (default: single run) — when set, schedules the next iteration via `ScheduleWakeup`. Accepts `Nm`, `Nh` (e.g. `15m`, `1h`).
- **`--pr`** (default off) — open **DRAFT** GitHub PRs for real bugs via `gh`.

If `$ARGUMENTS` is empty → ask the user what to test. Do not guess.

## Scope v1 (hard cap)

Only these target types are supported:

- **Rust crate** — a workspace member resolvable via `cargo metadata`, with at least one host-reachable library target (`lib` / `rlib`, not pure `cdylib`/WASM).
- **Solidity contract** — a `.sol` file under a Foundry root (detected via `foundry.toml`).

If the target description resolves to anything else (function, module, library, CLI, bash, WASM-only crate) → abort with `v1 supports only Rust crates and Solidity contracts`.

## State location

All state lives under **`target/.gear-tester/`**. This relies on `target/` already being in `.gitignore` (true for any Rust workspace by Cargo convention). On startup, verify with `git check-ignore target/.gear-tester`. If not gitignored → abort. **Never modify `.gitignore`.**

Files:

| Path | Purpose |
|---|---|
| `workspace_map.tsv` | TSV of `<unit_name>\t<workspace_root_relative_to_repo>` — built once per invocation |
| `contexts/<unit>.md` | Per-unit reference (built lazily by opus sub-agent, once per unit) |
| `ok.jsonl` | Passed hypotheses log |
| `failed.jsonl` | Real-bug hypotheses log (test source lives on disk under `tests/auto_tester_<hash>.rs`; jsonl carries only metadata) |
| `compile_failed.jsonl` | Quarantined tests — semantically correct but the crate's API does not expose what's needed |
| `dropped.jsonl` | Hypotheses dropped (test_wrong, compile_error+test_wrong, etc) — used for dedup |
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
   - `all` / `all rust crates` → discover all workspace roots, union their members (see Step 5).
   - `all crates with prefix X` → filter the above by name prefix.
   - `crate X` → assert X appears in at least one workspace's member list; t-list = [X].
   - `<Name> contract` → find foundry roots via `find . -maxdepth 4 -name foundry.toml -type f`; for each root, search `<root>/src/**/<Name>.sol`. Multiple matches across roots → abort, print candidates. Single match → t-list = [{`type`: `sol`, `path`: `<root>/src/.../<Name>.sol`, `root`: `<root>`, `name`: `<Name>`}].
   - Anything else (function, module, library, CLI, bash, wasm…) → abort: `v1 supports only Rust crates and Solidity contracts`.

   Empty t-list → abort.

5. **Build workspace map** (Rust crates in t-list only; skip if t-list is contracts-only).

   Many repos host multiple Cargo workspaces (e.g. `gear` has both `/Cargo.toml` and `/ethexe/Cargo.toml`). All subsequent cargo invocations for a given unit MUST run from the unit's owning workspace root, otherwise `cargo` errors with "package not found".

   Discovery:
   ```bash
   # Find every Cargo.toml that declares [workspace]
   find . -name Cargo.toml -not -path "*/target/*" -not -path "*/.git/*" \
     -print0 2>/dev/null \
     | xargs -0 grep -l '^\[workspace\]' 2>/dev/null \
     | sort -u
   ```

   For each discovered root, run cargo metadata and emit TSV `<name>\t<root>`:
   ```bash
   REPO_ROOT=$(git rev-parse --show-toplevel)
   : > target/.gear-tester/workspace_map.tsv
   for ws_toml in <discovered>; do
     ws_root=$(dirname "$ws_toml")
     ws_rel=$(realpath --relative-to="$REPO_ROOT" "$ws_root")
     cargo metadata --manifest-path "$ws_toml" --no-deps --format-version 1 \
       | jq -r --arg root "$ws_rel" \
         '.packages[] as $p
          | .workspace_members[] as $m
          | select($p.id == $m)
          | "\($p.name)\t\($root)"' \
       >> target/.gear-tester/workspace_map.tsv
   done
   ```

   For each Rust unit in the t-list, assert it appears in the map. Missing → abort with `unit <X> not found in any workspace (workspace_map.tsv)`.

   The map is rebuilt on every invocation (cheap, ~1-2 seconds total) so workspace membership changes between sessions are picked up automatically.

6. **If `--pr`:**
   - `gh auth status` succeeds (else abort).
   - Extract username: `GH_USER=$(gh api user -q .login)`.
   - **Print to user (consent moment):**
     ```
     PRs will be authored as gh user @<GH_USER> against base branch <base-branch>.
     ```

7. **Baseline tooling check** (always required): `git`, `gh`, `jq`, `flock`, `cargo` (if t-list has Rust units), `forge` (if t-list has Solidity units). Abort with install hints if missing.

8. **Verify state dir is gitignored:**
   ```bash
   mkdir -p target/.gear-tester
   git check-ignore target/.gear-tester
   ```
   If `git check-ignore` exits non-zero → abort with: `target/.gear-tester is not gitignored. Add /target to .gitignore manually, or run in a repo where target/ is already gitignored.`

9. **Print startup summary:**
   ```
   /gear-dev:tester startup
     t-list:       <N> units (<first 3, …>)
     workspaces:   <N> workspace root(s) detected
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

Skip units where `ok.jsonl + failed.jsonl + dropped.jsonl + compile_failed.jsonl` already have ≥ 15 entries for this unit (per-unit budget exhaustion). If all units are budget-exhausted → exit with `all units saturated; increase --count or extend scope`.

#### Step 3: Per-target tooling + lib presence + workspace resolution

Determine target type from the unit's entry:

- **Rust crate:**
  1. **Workspace resolution.**
     ```bash
     WORKSPACE_REL=$(awk -F'\t' -v u="$UNIT" '$1==u{print $2; exit}' target/.gear-tester/workspace_map.tsv)
     [ -z "$WORKSPACE_REL" ] && fail "unit $UNIT not in workspace_map.tsv (run aborted)"
     WORKSPACE_DIR="$REPO_ROOT/$WORKSPACE_REL"
     CD_PREFIX="cd \"$WORKSPACE_DIR\" &&"
     ```
     `$CD_PREFIX` is the literal shell snippet that EVERY downstream cargo command (here and in sub-agent prompts) must be prefixed with.

  2. **Lib-presence pre-check** — skip binary-only and WASM-only crates without spawning the opus context builder ($5–10 saved per skipped crate):
     ```bash
     eval "$CD_PREFIX cargo metadata --no-deps --format-version 1" \
       | jq -e --arg n "$UNIT" '
         .packages[]
         | select(.name == $n)
         | .targets[]
         | select(.kind | any(. == "lib" or . == "rlib"))
         | .crate_types
         | any(. == "lib" or . == "rlib")
       ' > /dev/null
     ```
     Exit 0 → has a host-reachable library target. Continue.
     Non-zero → log to `skipped.jsonl` and continue to next iteration:
     ```json
     {"ts":"<ISO8601>","unit":"<unit>","reason":"no_host_lib_target_or_wasm_only"}
     ```
     This catches binary-only (`bin`-target-only) crates and pure WASM crates (`crate-type = ["cdylib"]` only).

  3. **Tooling check:** require `cargo` + `cargo-nextest` reachable from `$WORKSPACE_DIR`. If missing → `skipped.jsonl` with `tooling_missing: <tool>`, continue.

  4. **Build sanity:** `eval "$CD_PREFIX cargo check -p $UNIT"`. If fails → `skipped.jsonl` with `build_broken: <stderr first line>`, continue.

- **Solidity contract:**
  1. `WORKSPACE_DIR="$REPO_ROOT/<foundry-root>"`, `CD_PREFIX="cd \"$WORKSPACE_DIR\" &&"`.
  2. Tooling check: require `forge`.
  3. Skip workspace-wide `forge build` (would fail on any unrelated broken contract). Per-test compile errors are caught at run-time.

#### Step 4: Build context (opus sub-agent, lazy)

If `target/.gear-tester/contexts/<unit>.md` does **not** exist, invoke the `Agent` tool with:

- `subagent_type`: `general-purpose`
- `model`: `opus`
- `description`: `Build tester context for <unit>`
- `prompt` (template, with substitutions):

````
Produce a dense knowledge file for <type> "<unit>" in this repository, to be
consumed by an autonomous tester. Output MARKDOWN, max 3000 words.

Workspace cd prefix for this unit (use it for any cargo invocations you make):
<CD_PREFIX>

Required sections:

## Public API
Every public function, type, trait, constant. For each: signature, 1-line
purpose, source `file:line` (REPO-ROOT-RELATIVE path, e.g.
`ethexe/consensus/src/lib.rs:42`). Be exhaustive but concise.

For each `pub` item, verify it is reachable from an external integration test
(i.e., the module chain from the crate root to the item is `pub` end-to-end).
If an item is technically `pub` but unreachable (parent module is private),
flag it inline as `(unreachable from external tests)` — the test agent must
not pick these.

## State assumptions and lifecycle
What state must be set up before calls? Construction patterns? Cite source
`file:line` for each.

## Documented invariants
For each invariant present in code comments (///, //!, //, /* */), README, or
linked spec:
- Quote the invariant text VERBATIM (exact characters; no `…` ellipsis)
- Cite `file:line` of the comment containing the quote
- One-sentence rephrasing in plain prose

If no invariant is documented for a concern, write `(no documented
invariant)`. **Do NOT fabricate.** The tester's bug classifier verifies these
citations by grep-ing your quote in the cited file.

## Existing tests
List existing test files (paths only) and the area each covers (1 line each).
No need to read every test in detail.

## Known dependencies
Which other crates/contracts this unit relies on (1 line each).

Do not include implementation reasoning, hypothetical bugs, or suggestions.
This is reference material for a separate test-writing agent.
````

Save the agent's text output to `target/.gear-tester/contexts/<unit>.md`.

#### Step 5: Run iteration (sonnet sub-agent)

Invoke the `Agent` tool with:

- `subagent_type`: `general-purpose`
- `model`: `sonnet`
- `description`: `Tester iteration for <unit>`
- `prompt` (template, with substitutions):

````
You are one iteration of the autonomous black-box tester for <type> "<unit>".

Workspace cd prefix (THIS REPO HAS MULTIPLE WORKSPACES — prefix EVERY cargo
or forge command with this exact snippet; never run cargo from the repo root):
<CD_PREFIX>

Reference material to READ FIRST:
- CONTEXT FILE: target/.gear-tester/contexts/<unit>.md
- ALREADY TESTED: target/.gear-tester/ok.jsonl, failed.jsonl, dropped.jsonl,
  compile_failed.jsonl
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
    Path: <crate-path-relative-to-workspace>/tests/auto_tester_<hash>.rs
    Single #[test] function named `auto_tester_<hash>`.
    Integration test only — no inline `mod`, do not edit any other file.
- Solidity contract target:
    Path: <foundry-root>/test/AutoTester_<Contract>_<hash>.t.sol
    Contract AutoTester<Hash> inherits forge-std `Test`.
    Single function `function test_<hash>() public { … }`.
    Do not edit any other file.

Run each test in isolation:
- Rust:  eval "<CD_PREFIX> cargo nextest run -p <unit> --test auto_tester_<hash>"
- Sol:   eval "<CD_PREFIX> forge test --match-path test/AutoTester_<Contract>_<hash>.t.sol"

Classify each outcome:
- PASSED        → outcome: "pass"
- COMPILE_ERROR → outcome: "compile_error". DO NOT retry (orchestrator handles
                  via a separate opus-verifier). Leave the test file on disk
                  so the verifier can inspect it.
- FAILED (test ran but assertion/panic occurred) → apply the rubric below.
                  If REAL_BUG → outcome: "bug". Else → outcome: "test_wrong"
                  (drop).

## Bug classification rubric

A failure is a REAL_BUG ONLY if at least one of the following is satisfied
with concrete evidence cited inline:

(a) Contradicts a documented invariant.
    Evidence: quoted invariant text + `file:line` from the context file's
    "Documented invariants" section. The quote MUST come from a real
    source-code comment (///, //!, //, /* */). Quoting prose from the
    context file's "## State assumptions" or "## Public API" sections is
    NOT valid evidence — the orchestrator will reject it.
(b) Violates a math identity (gas conservation, monotonicity, idempotence,
    associativity).
    Evidence: name the identity + observed values that violate it.
(c) Panics/aborts/reverts on an input the API explicitly admits as valid.
    Evidence: cite the signature accepting that input type + the
    panic/abort/revert message.
(d) Produces non-deterministic output on identical input across 3 re-runs.
    Evidence: the 3 differing output values.

If NONE is satisfied with concrete evidence → outcome: "test_wrong" (drop).
DO NOT retry.

## Handling test files

- For PASSED tests: LEAVE THE TEST FILE ON DISK. The orchestrator will
  delete it after recording.
- For COMPILE_ERROR tests: LEAVE THE TEST FILE ON DISK. The opus-verifier
  needs to read it. The orchestrator will delete or quarantine it later.
- For BUG / TEST_WRONG tests: LEAVE THE TEST FILE ON DISK. The orchestrator
  decides keep vs delete based on --pr and rubric verification.

DO NOT delete any test file yourself. DO NOT touch Cargo.toml, any source
file, .gitignore, or any file outside `tests/auto_tester_*.rs` (Rust) or
`test/AutoTester_*.t.sol` (Solidity). The orchestrator owns all cleanup
and quarantine setup.

## Return value

Emit a single JSON object as the FINAL LINE of your output (so the orchestrator
can parse it):

{
  "iteration_summary": "<one line>",
  "tests": [
    {
      "hash": "<hash>",
      "scenario": "<scenario_type>",
      "param_signature": "<stringified params>",
      "outcome": "pass" | "compile_error" | "bug" | "test_wrong",
      "test_path": "<repo-root-relative path>",
      "summary": "<one-line>",
      "compile_stderr_first_line": "<only for compile_error>",
      "rubric_items": [   /* only for outcome=bug */
        {"id": "a"|"b"|"c"|"d",
         "evidence": "<concrete citation or values>",
         "cite_file": "<repo-root-relative path, only for a>",
         "cite_line": <line number, only for a>,
         "cite_text": "<verbatim quoted text from the source comment, only for a>"
        }
      ],
      "panic_message": "<only for c, the exact panic/abort message>"
    }
  ]
}

DO NOT open PRs, switch branches, modify git state, or modify Cargo.toml.
That is the orchestrator's job.
````

After sonnet returns, parse the JSON object from the **last line** of its output.

#### Step 6: Verify compile errors (opus-verifier sub-agent)

For each test with `outcome: "compile_error"` in sonnet's response, invoke the `Agent` tool with:

- `subagent_type`: `general-purpose`
- `model`: `opus`
- `description`: `Verify compile error for <unit>:<hash>`
- `prompt` (template):

````
You are the compile-error verifier for the autonomous tester.

Inputs:
- Test source: <repo-root>/<test_path>  (READ this file)
- Compile error: <compile_stderr_first_line>
- Full stderr (re-run if needed):
    eval "<CD_PREFIX> cargo nextest run -p <unit> --test auto_tester_<hash>"
- Context file the test was generated from:
    target/.gear-tester/contexts/<unit>.md
- Crate source: <repo-root>/<crate_path_from_workspace_map>

Decide exactly one of three verdicts:

1. "test_wrong" — the test code is wrong: uses an API not in the context
   file, calls a function with wrong arguments, missing imports the
   sonnet should have known to add, etc. Most common verdict.

2. "context_wrong" — the test code is reasonable: it uses ONLY items
   declared `pub` in the context file with the documented signatures.
   But the context file is misleading: e.g. it said an item is `pub` but
   the parent module is private, so the item is not actually reachable
   from an integration test. The orchestrator will invalidate the context
   so the next iteration regenerates it.

3. "api_gap" — the test code is semantically correct AND the context file
   is correct, but the crate's PUBLIC API does not expose what's needed
   to actually exercise the documented behavior from outside. Examples:
   - A `pub fn returns_T()` but `T` itself is private with no public
     constructor.
   - A `pub trait Foo` with `pub fn bar(&self) -> Baz` where `Baz` is
     private.
   - Required conversion between two documented `pub` types is missing.
   This is a potential API design bug worth keeping as a quarantined
   test for human review.

Output STRICTLY this JSON on the LAST LINE:

{
  "verdict": "test_wrong" | "context_wrong" | "api_gap",
  "reason": "<one line>",
  "evidence_file": "<file:line, for context_wrong or api_gap>"
}
````

Orchestrator action by verdict:

- `test_wrong` → delete the test file. Append to `dropped.jsonl`:
  ```json
  {"ts":"…","unit":"…","hash":"…","scenario":"…","reason":"compile_error_test_wrong: <reason>"}
  ```

- `context_wrong` → delete the test file. Delete `target/.gear-tester/contexts/<unit>.md` so the NEXT iteration on this unit rebuilds it. Append to `dropped.jsonl`:
  ```json
  {"ts":"…","unit":"…","hash":"…","scenario":"…","reason":"compile_error_context_wrong: <reason>; context invalidated"}
  ```

- `api_gap` → KEEP the test, route to Step 7 (quarantine setup).

#### Step 7: Quarantine setup (for `api_gap` verdicts only)

For each test marked `api_gap`:

1. **Ensure the feature flag exists** in the unit's `Cargo.toml`:
   ```bash
   CARGO_TOML="$WORKSPACE_DIR/<crate_path>/Cargo.toml"

   # Idempotent: add [features] section if missing, add feature line if missing
   if ! grep -q '^auto_tester_quarantine\s*=' "$CARGO_TOML"; then
     if grep -q '^\[features\]' "$CARGO_TOML"; then
       # Insert after [features] header
       sed -i.bak '/^\[features\]/a\
auto_tester_quarantine = []
' "$CARGO_TOML"
     else
       # Append new section
       printf '\n[features]\nauto_tester_quarantine = []\n' >> "$CARGO_TOML"
     fi
     rm -f "$CARGO_TOML.bak"
   fi
   ```

2. **Gate the test file** by prepending the feature attribute as the first line:
   ```rust
   #![cfg(feature = "auto_tester_quarantine")]
   ```
   (For Solidity, the analog is `vm.skip(true);` at the top of the test function — but Solidity contracts under v1 do not have an analog of api_gap currently, so quarantine is Rust-only.)

3. Append to `compile_failed.jsonl`:
   ```json
   {"ts":"…","unit":"…","hash":"…","scenario":"…","verdict":"api_gap",
    "test_path":"…","reason":"…","evidence_file":"…"}
   ```

4. The test stays in the working tree (untracked unless `--pr` adds it on a PR branch, see Step 9). To run quarantined tests later:
   ```bash
   cd <workspace_dir> && cargo nextest run -p <unit> --features auto_tester_quarantine
   ```

**Note on Cargo.toml modification.** This is the ONLY file outside `tests/auto_tester_*.rs` that the orchestrator is permitted to modify, and only to add the `auto_tester_quarantine` feature once per crate. The diff is left in the working tree alongside the quarantined test files. Without `--pr` it is reverted by Step 11. With `--pr` it is committed onto the PR branch alongside the test.

#### Step 8: Handle outcomes (main agent)

For each test in sonnet's `tests` array:

- `outcome: "pass"`:
  1. Append to `ok.jsonl`:
     ```json
     {"ts":"…","unit":"…","hash":"…","scenario":"…","summary":"…"}
     ```
  2. (File is deleted in Step 10.)

- `outcome: "test_wrong"`:
  1. Append to `dropped.jsonl`:
     ```json
     {"ts":"…","unit":"…","hash":"…","scenario":"…","reason":"test_wrong: <summary>"}
     ```
  2. (File is deleted in Step 10.)

- `outcome: "compile_error"`: handled by Step 6 above (verifier already ran).

- `outcome: "bug"`: handled by Step 9.

#### Step 9: Handle bugs

For each test with `outcome: "bug"`:

**WITHOUT `--pr`:**
1. Read test source from `<test_path>` (orchestrator-side, NOT inline in sonnet's response).
2. Append to `failed.jsonl`:
   ```json
   {"ts":"…","unit":"…","hash":"…","scenario":"…","summary":"…",
    "test_path":"…","test_source":"<full text from disk>",
    "rubric_items":[…],"pr_url":null,"branch":null}
   ```
3. (File is deleted in Step 10.)

**WITH `--pr`** — process bugs sequentially. Working tree at this point contains untracked bug test files plus any Cargo.toml additions from Step 7.

For each bug:

1. Compute branch name: `auto-tester/<unit-slug>-<hash>` where `<unit-slug>` is the unit name with `/`, `.`, and ` ` replaced by `-` and lowercased.
2. `git checkout -b <branch-name> <base-branch>` — switches to a new branch off the **detected base** (NOT the original branch). Untracked test files and uncommitted Cargo.toml changes follow.
3. Stage: `git add <test_path>` plus the Cargo.toml diff IF this bug's hash also appears in `compile_failed.jsonl` (quarantined). For normal bugs, stage only the test file.
4. `git commit -m "test: corner-case repro for <unit> (auto-tester) <hash>"`
5. `git push -u origin <branch-name>`
   - On failure (branch protection, network, rate limit): append `{ts, unit, reason: "push_failed: …"}` to `skipped.jsonl`, `git checkout <original-branch>`, `git stash drop` any stash, continue to next bug.
6. `gh pr create --draft --base <base-branch> --head <branch-name> --title "test: <unit> corner-case (auto-tester) <hash>" --body "$(BODY)"`

   where `BODY` is:
   ````
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
   ````
   - On failure: log to `skipped.jsonl`, switch back, continue.
7. Capture `pr_url` from `gh pr create` output.
8. `git checkout <original-branch>` — the test file and any Cargo.toml additions vanish from the working tree (they were tracked only on the PR branch).
9. Append to `failed.jsonl`:
   ```json
   {"ts":"…","unit":"…","hash":"…","scenario":"…","summary":"…",
    "test_path":"…","test_source":"…","rubric_items":[…],
    "pr_url":"<url>","branch":"<branch-name>"}
   ```

#### Step 10: Orchestrator-side cleanup

This step OWNS the working-tree-clean guarantee — it does not rely on sub-agents to delete anything.

1. **Enumerate every `auto_tester_*` test file** the iteration could have produced:
   ```bash
   # Rust crate target:
   ACTUAL_TESTS=$(find "$WORKSPACE_DIR/<crate_path>/tests" -maxdepth 1 \
     -name 'auto_tester_*.rs' -printf '%f\n' 2>/dev/null | sort)
   # Solidity target:
   ACTUAL_TESTS=$(find "$WORKSPACE_DIR/test" -maxdepth 1 \
     -name 'AutoTester_*.t.sol' -printf '%f\n' 2>/dev/null | sort)
   ```

2. **Compute the keep-list** for THIS iteration:
   - Quarantined tests (`compile_failed.jsonl` entries appended in this iteration).
   - Bug tests not yet PR'd (only without `--pr`; with `--pr`, bugs are already on the PR branch and removed locally after `git checkout`).

3. **Delete every test file NOT in the keep-list:**
   ```bash
   comm -23 <(echo "$ACTUAL_TESTS") <(echo "$KEEP_TESTS" | sort) \
     | while read f; do
         rm -v "$WORKSPACE_DIR/<crate_path>/tests/$f"
       done
   ```

4. **Final invariant check:**
   ```bash
   STATUS=$(git status --porcelain)
   ```
   Without `--pr`: `$STATUS` must be empty. If not → abort with `git status --porcelain` output as diagnostic (this is a tester bug; should not happen).
   With `--pr` after quarantine: `$STATUS` may show the modified `Cargo.toml` and untracked quarantined tests; these are intentional (quarantine lives in the working tree). They are tracked in `compile_failed.jsonl` for next-iteration reconciliation.

#### Step 11: Release lock

```bash
flock -u 200
exec 200>&-
rm -f target/.gear-tester/lock
```

#### Step 12: Schedule next iteration

If `--loop` set → call `ScheduleWakeup` as described in Phase 2. Otherwise exit.

## Hash-based dedup

```
hash = sha256(<unit> + ":" + <scenario_type> + ":" + <param_signature>)[:12]
```

Same hash → already tested or dropped → sonnet must skip. Dedup pool is the union of `ok.jsonl`, `failed.jsonl`, `dropped.jsonl`, and `compile_failed.jsonl`.

## Hard rules

- **Never modify `.gitignore`** or any file outside (a) test files in standard test paths, (b) files inside `target/.gear-tester/`, (c) the unit's `Cargo.toml` — and only to add `auto_tester_quarantine = []` under `[features]`, once per crate, idempotently.
- **Working tree is always clean after every iteration** in the no-`--pr` path. With `--pr`, the only allowed residue is quarantined tests + their Cargo.toml feature line (tracked in `compile_failed.jsonl`).
- **PR branches always come off detected base**, never off the current branch. PRs contain only the test commit (and feature-gate Cargo.toml diff for quarantined bugs), not any in-flight work from the user's branch.
- **PRs are always draft.** Never publish-ready. Human review required before merge.
- **Compile errors never silently drop.** They always route through the opus-verifier, which decides test_wrong / context_wrong / api_gap.
- **Bug rubric requires concrete evidence**, not "model intuition". `file:line` citation or numeric demonstration is mandatory; rubric (a) is verified by the orchestrator (Commit-3 feature).
- **Per-target build sanity, not workspace.** One broken unrelated crate must not block testing of healthy ones.
- **Workspace cd is mandatory.** Every cargo/forge invocation in a sub-agent's prompt is prefixed with the resolved `$CD_PREFIX` for the unit's workspace. Sub-agents that run cargo from the wrong directory get "package not found".
- **Lib-presence pre-check is mandatory** for Rust units. Skip binary-only / WASM-only crates before spawning the opus context builder (saves $5–10 per skipped crate).
- **Orchestrator owns test cleanup.** Sub-agents leave all files on disk; the orchestrator's Step 10 enumerates and removes them based on the keep-list. Don't trust sub-agents to clean up after themselves.

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
| Rust unit not in `workspace_map.tsv` | abort with map path |
| `--pr` and `gh auth status` fails | abort |
| Required baseline tooling missing | abort with install hints |

### Mid-iteration soft failures (log to `skipped.jsonl`, continue to next iteration)

- Per-target build broken
- Per-target tooling missing (no `cargo-nextest`, no `forge`)
- No host-reachable lib target (binary-only / WASM-only crate)
- Push rejected (branch protection)
- `gh pr create` rejected (rate limit, permissions)
- Lock file present with live PID

### Mid-iteration hard aborts (with diagnostic)

- Step 10 final invariant check fails (working tree dirty in unexpected way) — this is a tester bug; abort, print `git status --porcelain` and `git diff`, do NOT auto-revert (operator inspection required).

## Examples

```
/gear-dev:tester all rust crates --count 5 --loop 30m --pr
/gear-dev:tester crate ethexe-consensus
/gear-dev:tester crate ethexe-consensus --pr
/gear-dev:tester Mirror contract --count 2
/gear-dev:tester all crates with prefix ethexe --loop 1h --pr
```
