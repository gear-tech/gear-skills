# gear-skills

Claude Code plugin marketplace for **Gear Protocol** development (Vara, ethexe).

This repository hosts the `gear-dev` plugin — a collection of slash commands, skills, and MCP servers that help engineers working in [gear-tech/gear](https://github.com/gear-tech/gear) and related repos move faster with Claude Code.

## Install

In any Claude Code session:

```
/plugin marketplace add gear-tech/gear-skills
/plugin install gear-dev@gear-skills
```

That's it. Commands become available as `/gear-dev:<name>` immediately, and the bundled MCP servers (Serena, repomix) auto-register and start on session start.

### Verifying setup

To check the status of the bundled MCP servers' prerequisites (`uvx` for Serena, `node 18+` for repomix), run:

```
/gear-dev:doctor
```

Sample output when all good:

```
[gear-dev preflight]
  ✓ uvx 0.4.18 (Serena MCP ready)
  ✓ node v20.10.0 (repomix MCP ready)
  ℹ first run in this workspace — rust-analyzer will index ~30–90s (Serena cold-start)
```

If a prerequisite is missing, the diagnostic prints a one-line install command. The plugin's slash commands still work regardless — only the corresponding MCP server is degraded until you install the missing tool. After installing a missing prereq, **restart Claude Code** so the MCP server picks up the new `PATH`.

### Updates

```
/plugin marketplace update gear-skills
/plugin update gear-dev@gear-skills
```

Then **restart Claude Code** — slash commands are cached at session start. If the update commands don't surface new files, the lowest-friction fallback is a direct `git pull` in the installed copy:

```
cd ~/.claude/plugins/marketplaces/gear-skills && git pull
```

Then restart.

## What's included

### Bundled MCP servers (auto-registered)

When the plugin is enabled, these MCP servers start automatically. They merge with your existing `.mcp.json` — if you already have a server named `serena` or `repomix` configured locally, your version wins.

| Server | Purpose | Source |
|---|---|---|
| **`serena`** | LSP-backed code intelligence over the current workspace: `find_definition`, `find_references`, `get_symbols_overview`. Uses `rust-analyzer` under the hood, so it understands proc-macros (e.g. `construct_runtime!`, `pallet::call`) correctly. | [oraios/serena](https://github.com/oraios/serena) via `uvx` |
| **`repomix`** | On-demand flattening of a directory (or whole workspace) into a single token-efficient blob — useful when an agent genuinely needs a whole crate at once rather than navigating symbol-by-symbol. | [yamadashy/repomix](https://github.com/yamadashy/repomix) via `npx` |

To inspect what's running: `/mcp` shows status of all servers. To disable just the plugin's MCPs without removing the plugin itself, you can override them in your user-level `.mcp.json` (your config wins) or disable the plugin entirely with `/plugin disable gear-dev`.

### Commands

#### `/gear-dev:doctor`

Print the bundled-MCP preflight diagnostic to the session. Use after install, or when an MCP server shows as failed in `/mcp`.

```
/gear-dev:doctor
```

#### `/gear-dev:tester`

Autonomous black-box tester for Rust crates and Solidity contracts. Iteratively generates corner-case tests for a chosen unit, runs them, and classifies failures via an evidence-backed rubric. With `--pr`, opens **draft** GitHub PRs for real bugs into the detected base branch.

```
/gear-dev:tester <target> [--count N=3] [--loop INTERVAL] [--time-budget DURATION] [--max-entries-per-unit N] [--pr] [--pr-min SEVERITY]
```

**Target description** is free text, resolved deterministically:

- `all` or `all rust crates` — every workspace member
- `all crates with prefix ethexe` — name filter
- `crate <name>` — a single workspace member
- `<Name> contract` — a Solidity contract by file name under any detected Foundry root

v1 supports **only** Rust crates and Solidity contracts. Other target types (function, module, library, CLI, bash, WASM) abort with a clear error.

**Flags:**

- `--count N` — tests to generate per iteration (default 3).
- `--loop INTERVAL` — re-schedule the next iteration via `ScheduleWakeup` (e.g. `15m`, `1h`). Interval is **start-to-start**: a fast iteration shortens the next wakeup, a slow one re-fires at the 60s floor (no drift). The loop runs only while the current Claude Code session is open.
- `--time-budget DURATION` — soft total wall-clock budget for the entire loop (e.g. `2h`, `30m`). No default. Checked at the start of each iteration; in-flight iterations are not interrupted.
- `--max-entries-per-unit N` — optional hard ceiling on per-unit entries (ok + failed + dropped + quarantine). No default — without the flag, units iterate indefinitely (saturation still deprioritizes).
- `--pr` — open **draft** PRs for real bugs, authored as your `gh`-authenticated user against the detected base branch. The user is printed at startup as a consent moment.
- `--pr-min SEVERITY` — only PR bugs at or above this tier (`info|low|medium|high|critical`, default `medium`). Below-threshold bugs still land in `failed.jsonl` with their tier; PR-noise is filtered. Has no effect without `--pr`.

**State** lives under `target/.gear-tester/` (relies on existing `target/` gitignore — the command never modifies `.gitignore`). Files: `ok.jsonl`, `failed.jsonl`, `dropped.jsonl`, `compile_failed.jsonl`, `skipped.jsonl`, `contexts/<unit>.md`, `lock`, `cursor`, `start_ts`, `stop`, `SESSION_NOTES.md`, `saturation.json`, `workspace_map.tsv`.

**Bug classification** requires concrete evidence (cited invariant `file:line`, math identity violation, panic on admissible input, or non-determinism across 3 re-runs). Orchestrator independently verifies citations (grep the quote in the cited source file) and re-runs each bug 3 times before recording it. Per-bug `severity` (`critical|high|medium|low|info`) controls whether `--pr` opens a PR — `low`/`info` findings stay in `failed.jsonl` without PR noise.

**Architecture:** the main agent orchestrates; an `opus` sub-agent builds a per-unit context file once (lazy, cached); a `sonnet` sub-agent runs each iteration; a second `opus` sub-agent verifies compile errors (drop / regenerate-context / quarantine behind a feature gate). Sub-agents return JSON only, write large artifacts to disk — this keeps the main context small across long loops.

**Stopping the loop:** four mechanisms — `--time-budget` elapses, every unit reaches `--max-entries-per-unit` (if set), the session closes, or you invoke [`/gear-dev:tester-stop`](#gear-devtester-stop).

**Examples:**

```
/gear-dev:tester all rust crates --count 5 --loop 30m --pr --time-budget 4h
/gear-dev:tester crate ethexe-consensus
/gear-dev:tester crate ethexe-consensus --pr --pr-min high
/gear-dev:tester Mirror contract --count 2
/gear-dev:tester all crates with prefix ethexe --loop 5m --time-budget 8h --max-entries-per-unit 100 --pr
```

#### `/gear-dev:tester-stop`

Soft-stop a running `/gear-dev:tester` loop without ending the Claude Code session. Writes a marker file the loop checks at every iteration start; the next iteration exits cleanly without scheduling another wakeup. The currently-running iteration (if any) finishes — sub-agents are not interrupted.

```
/gear-dev:tester-stop [optional reason text]
```

Use when you want to stop iterating but keep working in the same session (e.g., you saw enough findings, you want to switch to triage, the loop is running on a saturated unit). State (cursor, jsonl files, contexts, draft PRs) is preserved — re-running `/gear-dev:tester ...` with the same args resumes from where you stopped.

#### `/gear-dev:doc`

Generate or update **crate-level documentation** (`//!` doc comments in `lib.rs`/`main.rs`) for one or more Rust crates. Runs a write→verify→fix refinement loop with a multi-model verifier panel (opus + sonnet + optional codex), asks the user via `AskUserQuestion` only when the code genuinely cannot disambiguate intent, and optionally opens a draft PR.

```
/gear-dev:doc <crate-spec> [--refine N=3] [--verifiers opus:N,sonnet:M,codex:K] [--pr] [--scope crate-root|with-modules]
```

**Crate spec** (same conventions as `/gear-dev:tester`):

- `crate <name>` — one workspace member
- `all rust crates` — every member
- `all crates with prefix <prefix>` — name filter

**Flags:**

- `--refine N` — write→verify→fix iterations after the initial draft. Default `3`. Loop exits early on verifier consensus (`approve` from all).
- `--verifiers opus:N,sonnet:M,codex:K` — verifier panel composition. Default `opus:1,sonnet:1,codex:1`. `codex` is skipped silently if the CLI is not installed.
- `--pr` — create a new branch and open a **draft** PR into the detected base branch (`master`/`main`/`develop`, auto-detected). Authored as the `gh`-authenticated user; the username is printed at startup as a consent moment.
- `--scope crate-root|with-modules` — default `crate-root` (only `//!` in `lib.rs`/`main.rs`). `with-modules` extends to first-level module files.

Pass any free text after the flags as additional per-crate direction (e.g. "focus on the public RPC surface").

**State** lives under `target/.gear-doc/` — context files, drafts, verifier findings, summary. Preserved across runs for inspection. The skill does NOT touch `.gitignore`, `Cargo.toml`, `README.md`, `ARCHITECTURE.md`, or any non-Rust file.

**Verification:** every backticked identifier in the final draft is grep-verified against actual source before writing. Hallucinated identifiers fail loud — the doc is dropped, not written with broken intra-doc links.

**Style:** baseline rules are Rust API guidelines + RFC 1574. If `.gear-doc/style.md` exists in the workspace root, it overrides the baseline (use this to encode project-specific conventions).

**Examples:**

```
/gear-dev:doc crate ethexe-service
/gear-dev:doc all crates with prefix ethexe --refine 2 --pr
/gear-dev:doc crate ethexe-runtime-common --verifiers opus:2,sonnet:1,codex:0
/gear-dev:doc crate ethexe-service --scope with-modules focus on the validator state machine
```

#### `/gear-dev:explain`

Explain a PR, issue, commit, diff, file, or pasted code. Produces a TL;DR plus a walkthrough of the most important / hardest spots, each with a permalink and inline commentary in the language you choose.

```
/gear-dev:explain <source> [--lang ru|en|…] [--depth low|middle|deep]
```

**Source** can be any of:

- GitHub PR URL — `https://github.com/owner/repo/pull/123`
- GitHub PR shorthand — `owner/repo#123`
- GitHub issue URL or shorthand
- Local commit SHA — `abc1234`
- Git range or branch — `master...HEAD`, `feature/foo`
- File path — `./ethexe/processor/src/lib.rs`
- Pasted text or code

**Flags:**

- `--lang <code>` — prose language for the explanation. Default: `en`. All natural-language (headings, labels, prose, inline code commentary) is translated; only code identifiers, syntax, file paths, and command names stay in the source language.
- `--depth <level>` — how much detail to produce. Default: `middle`. Each level has hard length budgets so output stays predictable.
  - `low` — short overview, **≤ 100 rendered lines**. TL;DR + tight inventory + one walkthrough subsection with a single trimmed code excerpt (≤ 25 lines) for the most important piece.
  - `middle` — **≤ 300 rendered lines**. TL;DR + inventory + up to 3 walkthrough subsections, each with a single code excerpt (≤ 40 lines), covering the main parts of the solution.
  - `deep` — no overall cap. Exhaustive walkthrough covering every significant change; individual code excerpts still capped at 60 lines (split across subsections or elide with `// ...` if longer).

**Examples:**

```
/gear-dev:explain https://github.com/gear-tech/gear/pull/4321
/gear-dev:explain gear-tech/gear#4321 --lang ru
/gear-dev:explain gear-tech/gear#4321 --lang ru --depth low
/gear-dev:explain master...HEAD --depth deep
/gear-dev:explain abc1234 --depth deep
/gear-dev:explain ./ethexe/processor/src/lib.rs --lang ru
```

## Layout

```
gear-skills/
├── .claude-plugin/
│   └── marketplace.json              # marketplace manifest
└── plugins/
    └── gear-dev/
        ├── .claude-plugin/
        │   └── plugin.json           # plugin manifest (includes mcpServers)
        ├── commands/
        │   ├── doc.md                # /gear-dev:doc
        │   ├── doctor.md             # /gear-dev:doctor
        │   ├── explain.md            # /gear-dev:explain
        │   ├── tester.md             # /gear-dev:tester
        │   └── tester-stop.md        # /gear-dev:tester-stop
        └── scripts/
            └── preflight.sh          # MCP prereq + rust-analyzer warmth check
                                      #   (invoked by /gear-dev:doctor)
```

## Contributing

New commands go in `plugins/gear-dev/commands/<name>.md`. New skills go in `plugins/gear-dev/skills/<name>/SKILL.md`. Update `marketplace.json` and this README when adding new top-level capabilities.

When editing existing commands or skills, bump the plugin `version` in both `.claude-plugin/marketplace.json` and `plugins/gear-dev/.claude-plugin/plugin.json` if the change is user-visible.

Keep skill and command content in English. Output language is the user's choice at invocation time (e.g. `--lang ru`).

## License

[MIT](./LICENSE)
