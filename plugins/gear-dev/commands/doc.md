---
description: Generate or update crate-level Rust documentation (`//!` doc comments in lib.rs/main.rs) for one or more crates. Runs a write→verify→fix refinement loop with multi-model verifiers (opus + sonnet + optional codex), asks the user via AskUserQuestion only when the code genuinely cannot disambiguate intent, and optionally opens a draft PR against the detected base branch. Uses Serena LSP (with rust-analyzer under the hood) and repomix for context, falls back to direct reads when MCPs are unavailable.
argument-hint: <crate-spec> [--refine N=3] [--verifiers opus:N,sonnet:M,codex:K] [--pr] [--scope crate-root|with-modules]
---

# /gear-dev:doc

Generate or update **crate-level documentation** (`//!` in `lib.rs` / `main.rs`) for one or more Rust crates. Multi-agent verification, refinement loop, human-in-the-loop on truly ambiguous spots.

## When to use

- A crate has no `//!` header at all, or has a stale/sparse one.
- You want a coherent narrative of what the crate is, how it fits into the workspace, what its public surface is, and what invariants callers must respect.
- You want the result cross-checked by independent reviewers (opus + sonnet + optionally codex) before it lands.

This skill does NOT generate per-item `///` docs (use davidbarsky/rustdoc rules or a separate skill for that). It also does NOT touch `README.md`, `ARCHITECTURE.md`, or `CLAUDE.md` — only Rust source files.

## Arguments

```
/gear-dev:doc <crate-spec> [flags]
```

**Crate spec** (free text, resolved deterministically — same conventions as `/gear-dev:tester`):

- `crate <name>` — a single workspace member by name (e.g. `crate ethexe-service`)
- `all rust crates` — every workspace member
- `all crates with prefix <prefix>` — name filter (e.g. `all crates with prefix ethexe`)
- A bare crate name also works if it matches exactly one workspace member.

Multi-workspace repos: if both `Cargo.toml` and `ethexe/Cargo.toml` exist, both are scanned. Ambiguous names abort with a list.

**Flags:**

- `--refine N` — number of write→verify→fix iterations after the initial draft. Default `3`. `--refine 0` writes the draft and ships without verification (not recommended).
- `--verifiers opus:N,sonnet:M,codex:K` — verifier panel composition. Default `opus:1,sonnet:1,codex:1`. `codex` is skipped silently if the `codex` CLI is not on `PATH`. Set `codex:0` to disable explicitly. The skill aborts if the total panel size is `0`.
- `--pr` — at the end, create a new branch and open a **draft** PR into the detected base branch (`main`/`master`/`develop`, auto-detected from the current branch's merge-base). Authored as the `gh`-authenticated user; the username is printed at startup as a consent moment.
- `--scope crate-root|with-modules` — default `crate-root`. `with-modules` extends coverage to `//!` headers on first-level modules (`src/foo/mod.rs`, `src/foo.rs`). Does NOT touch nested submodules. Use `with-modules` for large crates where module-level narrative matters (e.g. `ethexe-service`); use the default for everything else. Users can override per-crate in the free-text prompt portion (e.g. "also do mod consensus").

**Pass-through prompt:** any free text after the flags is appended to the per-crate plan as "additional user direction". Use this for crate-specific scope ("focus on the public RPC surface", "explain the storage layout in depth", "skip the deprecated foo module").

## Hard rules

1. **English only.** All generated documentation is in English regardless of the session language. Code identifiers, file paths, command names stay verbatim. This is non-negotiable — gear-skills enforces English-only in all repo files.
2. **No fabrication.** If a fact about the crate is not supported by code, tests, comments, or workspace `Cargo.toml`, the doc must not state it. Verifiers flag any unsupported claim as `medium` and the writer must remove or qualify it.
3. **No unrelated edits.** The only files this skill may write are `src/lib.rs` / `src/main.rs` (and first-level module files under `--scope with-modules`). No `Cargo.toml` changes, no formatting sweeps on unrelated lines, no test edits. The git diff at the end must be exactly the `//!` blocks + the lines around them needed for syntactic correctness (e.g. inserting a doc block above the first `use`).
4. **Idempotent re-runs.** Running the skill twice in a row on the same crate with no code changes between runs must produce a no-op diff (or near-no-op — minor wording tweaks are acceptable but no structural rewrites). The refinement loop must converge.
5. **AskUserQuestion only when stuck.** Reserve human polling for cases the code genuinely cannot resolve (e.g. "this struct is `pub` but never re-exported from `lib.rs` — is it part of the public API or accidentally pub?"). Do NOT poll on style preferences, wording choices, or whether to include an example — make the call from `.gear-doc/style.md` (if present) or sensible defaults.
6. **No `cargo build` / `cargo test` runs.** This skill is read-only with respect to compilation. It can run `cargo metadata`, `cargo doc --no-deps --document-private-items --dry-run` if needed for verification, but never invokes the compiler in a way that produces artifacts.

## State location

All state lives under `target/.gear-doc/` (relies on existing `target/` gitignore — the command never modifies `.gitignore`).

```
target/.gear-doc/
├── plan.md                          # Phase 0 output, human-readable
├── <crate>/
│   ├── context.md                   # built once per invocation by Serena+repomix
│   ├── iter-0-draft.md              # initial draft
│   ├── iter-N-findings.json         # verifier outputs (one per refinement iteration)
│   ├── iter-N-fixed.md              # post-fix draft
│   └── final.md                     # final accepted draft (= what was written into lib.rs)
└── summary.json                     # cross-crate summary for Phase 6
```

State is preserved across runs so the user can inspect or resume. Re-running with no code changes between invocations should produce identical artifacts.

## Workflow

### Phase 0 — Analysis and plan

1. Parse args. Validate `--verifiers` (sum > 0; codex availability check via `command -v codex`). Auto-detect base branch via `gh pr view 2>/dev/null` or `git symbolic-ref refs/remotes/origin/HEAD`.
2. Resolve crate spec → ordered list of `(workspace_root, crate_name, manifest_path, lib_or_main_path)` tuples. Skip crates with no `lib.rs` AND no `main.rs` (pure binary-less wrappers don't exist; if both missing, log a `skipped` entry with reason).
3. Print a **pretty plan** to the user. Block format:

   ```
   [/gear-dev:doc plan]
     scope          : crate-root        (extend with --scope with-modules)
     refine iters   : 3
     verifiers      : opus×1  sonnet×1  codex×1
     pr             : yes → draft PR into `master` as user `gsobol`
     style override : .gear-doc/style.md (found)

   crates (3):
     ✓ ethexe-service           ethexe/service/src/lib.rs        (no //! header)
     ✓ ethexe-consensus         ethexe/consensus/src/lib.rs      (//! present, 4 lines — will rewrite)
     ✓ ethexe-runtime-common    ethexe/runtime/common/src/lib.rs (//! present, 80 lines — will refine)

   estimated work: 9 sub-agent calls per crate × 3 crates = ~27 LLM rounds
   ```

   Do NOT ask the user to confirm — the user invoked the command, that's consent. Just show what's about to happen so they can Ctrl+C if it's wrong.

4. Write `target/.gear-doc/plan.md` with the same content for the record.

### Phase 1 — Context build (per crate, lazy, cached)

For each crate, build `target/.gear-doc/<crate>/context.md` exactly once per invocation. If the file exists and `lib.rs`/`main.rs` mtime is older than the context file → reuse. Otherwise rebuild via an **opus sub-agent**.

**Context builder sub-agent prompt** (opus):

> Build a self-contained context document for writing the crate-level doc comment of `<crate_name>` at `<lib_or_main_path>`. The document will be consumed by a `sonnet` agent that has no access to the codebase. Output English markdown.
>
> Required sections (write each one or explicitly state "n/a"):
>
> 1. **Crate purpose** — one paragraph: what this crate exists to do, and what it does NOT do. Infer from `lib.rs` doc comment (if any), `Cargo.toml` `description`, and the names + signatures of the top public items.
> 2. **Workspace position** — which other workspace crates depend on this one (`cargo metadata` → reverse dependency search), and which workspace crates this one depends on (filter `Cargo.toml` deps to workspace members only). One line per relationship.
> 3. **Public API surface** — bullet list of items re-exported from `lib.rs` (the `pub use` lines and `pub mod` declarations). Annotate each with one phrase explaining what it is.
> 4. **Key types / traits** — for the 3–7 most central types/traits, give name, kind, and a one-sentence purpose. Use Serena `find_symbol` to inspect each (signatures, doc comments, where defined). If Serena is unavailable, fall back to grep + Read.
> 5. **Invariants / state assumptions** — anything documented in existing comments, type-level docs, or test names that constrains how the crate is used. Quote the source verbatim with file:line.
> 6. **Usage example** — if there is an `examples/` dir or doc tests, summarize the canonical usage in 5–15 lines. If none, state "no canonical example in tree" and synthesize the minimum-viable one from public signatures only (mark as `[synthesized]`).
> 7. **Open questions** — anything you found that you genuinely cannot resolve from the code (e.g. "is `pub struct Foo` part of the public API or an accidental pub?"). These become AskUserQuestion candidates later. Empty section is fine and common.
>
> Budget: 15 tool calls total. Prefer Serena `get_symbols_overview` and `find_symbol` over Read-everything. Use repomix `pack_codebase` with `--include "src/**/*.rs"` for one-shot crate flattening if you need >5 files at once.
>
> Return JSON: `{"status": "ok"|"failed", "context_file": "<path>", "bytes": N, "sections_present": [...], "open_questions": N}`. Write the actual document to disk yourself.

Orchestrator reads only the JSON, then reads the context file in Phase 2.

### Phase 2 — Initial draft (per crate, sonnet)

Sonnet sub-agent gets: `context.md`, `style.md` (if present), the existing `//!` block verbatim (or "none"), the user's free-text override (if any).

**Draft writer sub-agent prompt** (sonnet):

> Write the crate-level `//!` doc comment for `<crate_name>`. The output is markdown that will be placed in `src/lib.rs` (or `src/main.rs`) as a `//!` block, one space after `//!`, no trailing whitespace.
>
> **Style baseline** (always applies):
> - First line: one-sentence summary, third-person present, no trailing period if it's a noun phrase.
> - Then a blank `//!` line, then 2–6 paragraphs covering: what the crate does, how it fits the workspace, public API entry points, key invariants.
> - Use intra-doc links in backticks for types: `[`Foo`]`, `[`bar::Baz`]`. Don't link items the reader can't reach from this crate.
> - No marketing language ("powerful", "robust", "comprehensive"). No section headers above H2.
> - If the crate has a canonical usage example, include it as a ` ```rust no_run` code block, ≤ 20 lines.
>
> **Style overrides:** if `style.md` was provided, every rule there overrides the baseline. Apply silently.
>
> **Hard prohibitions:**
> - No claim unsupported by the context document. If `context.md` doesn't mention something, don't invent it.
> - No reference to git history, recent changes, or who-wrote-what.
> - No "TODO" / "FIXME" / "we should" — write final prose only.
> - No emoji.
>
> **Output JSON only:** `{"draft_file": "<path to iter-0-draft.md>", "byte_count": N, "open_questions_addressed": [...indices from context.md section 7...]}`. Write the actual draft to `target/.gear-doc/<crate>/iter-0-draft.md` yourself. The draft file contents are the `//!` block body WITHOUT the `//! ` prefix (orchestrator adds that when injecting into source).

### Phase 3 — Refinement loop (`--refine N` iterations, default 3)

For each iteration `i` from 1 to `N`:

**Step 3a — Verify (parallel).** Spawn the verifier panel: by default 1 opus + 1 sonnet + 1 codex (if installed). Each verifier gets the current draft (`iter-(i-1)-draft.md` for the first iter, `iter-(i-1)-fixed.md` afterwards) AND the context document AND the actual source file paths. They run in parallel.

Verifier sub-agent prompt (model-agnostic, sent to all):

> Adversarially review the proposed crate-level `//!` doc for `<crate_name>`. You have:
> - The draft (markdown, no `//!` prefix).
> - The context document used to write it (`context.md`).
> - The actual crate source root (read freely via Serena or Read).
>
> Find issues in three categories:
>
> 1. **Factual errors** — any claim in the draft that contradicts the code, the workspace structure, or itself. Cite `file:line` for the contradicting evidence.
> 2. **Missing essentials** — a public type / trait / entry point that a first-time reader of this crate would need to know about, but the draft doesn't mention. Be conservative: "missing" only means "a reader would be unable to start using the crate without grepping" — not "would be nice to have".
> 3. **Hallucinated specifics** — function names, type names, paths, or trait names that don't exist. Verify each backticked identifier in the draft by `find_symbol` or grep.
>
> Severity per finding: `critical` (factually wrong), `high` (missing essential public API), `medium` (hallucinated identifier or unsupported claim), `low` (wording could mislead but isn't wrong), `info` (style nit).
>
> Return JSON ONLY:
> ```
> {
>   "verdict": "approve" | "needs_changes",
>   "findings": [
>     {"category": "fact"|"missing"|"hallucination", "severity": "...",
>      "quote_from_draft": "<≤80 chars>", "issue": "<one sentence>",
>      "evidence": "<file:line or 'absent from source'>", "fix_suggestion": "<short>"}
>   ],
>   "open_questions": [{"about": "...", "options": ["A", "B", "C"]}]
> }
> ```
> "approve" means zero findings at severity `medium` or above. `open_questions` are things YOU cannot resolve from the code that the human writer should answer (rare — use sparingly).

Codex variant: invoke via the `/codex` skill (if available in this session) OR via Bash `codex` CLI. If codex CLI is not on PATH AND `/codex` skill is unavailable, log "codex skipped (not installed)" and shrink the panel.

**Step 3b — Aggregate.** Write `target/.gear-doc/<crate>/iter-<i>-findings.json` with all verifier outputs concatenated and a computed aggregate:

```json
{
  "iteration": 1,
  "verifiers": [
    {"model": "opus", "verdict": "needs_changes", "findings": [...]},
    {"model": "sonnet", "verdict": "approve", "findings": []},
    {"model": "codex", "verdict": "needs_changes", "findings": [...]}
  ],
  "aggregate": {
    "verdict": "needs_changes",
    "consensus_findings": [...],     // ≥2 verifiers flag same quote
    "single_voice_findings": [...],   // 1 verifier only — apply only if severity ≥ high
    "open_questions": [...]
  }
}
```

Convergence rule: stop the loop early if `aggregate.verdict == "approve"` (all verifiers approved). Also stop if iteration N-1 and N produced identical fix sets (cycling on style → ship current draft).

**Step 3c — Ask user (only when stuck).** If `aggregate.open_questions` is non-empty AND those same questions appeared in iteration `i-1`'s aggregate (i.e. verifiers are stuck on the same ambiguity twice), use `AskUserQuestion` to poll the human:

```
Question: "<the verifier's question, paraphrased>"
Header: "<crate>:<topic>"
Options: derived from the verifier's `options` array, plus an automatic "skip — leave ambiguous in doc" option.
```

Apply the answer to the next fix round. Do NOT ask on the first iteration — give verifiers a chance to converge themselves.

**Step 3d — Fix.** Sonnet sub-agent (cheaper for narrow edits) gets the current draft + `iter-<i>-findings.json` aggregate + any user answers from 3c. Returns the fixed draft.

Fix prompt:

> Apply the following findings to the draft. Resolve consensus findings (≥2 verifiers agreed) unconditionally. Apply single-voice findings only at severity high or critical — ignore single-voice medium/low/info. Preserve everything else verbatim — no opportunistic rewording.
>
> Return JSON: `{"fixed_file": "<path to iter-<i>-fixed.md>", "applied": N, "skipped": M, "applied_findings": [...indices...]}`. Write the file yourself.

If the verifier panel approved at Step 3b, skip Step 3d and use the unchanged draft as `final.md`.

### Phase 4 — Final review (orchestrator-side)

Before writing to source:

1. **Grep verification.** For every backticked identifier in `final.md` of the form `[`Foo`]` or `[`mod::Bar`]`, grep the actual crate source. If any identifier is absent, fail loud — drop the doc with a clear error, do NOT write a draft with hallucinated identifiers.
2. **Diff size sanity.** Compute the diff that would land if `final.md` replaced the existing `//!` block. If new diff is >10× the existing block size, ask the user via `AskUserQuestion` whether to proceed ("draft is 800 lines vs existing 80 — proceed / shorten / drop").
3. **Write to source.** Replace the existing `//!` block (or insert above the first non-attribute, non-`use` line if no `//!` block exists). Prefix every line of `final.md` with `//! ` (with the trailing space; empty lines become `//!`). Do not touch any other lines in the file.

### Phase 5 — Ship

**Without `--pr`:** leave changes in the working tree. Print:
```
[/gear-dev:doc] wrote 3 crates → working tree
  ethexe/service/src/lib.rs        +64 -4
  ethexe/consensus/src/lib.rs      +52 -8
  ethexe/runtime/common/src/lib.rs +18 -22
review with `git diff --stat ethexe/`
```

**With `--pr`:**
1. Detect base branch (default `master` — fall back to `main` / `develop` / `origin/HEAD`).
2. Create branch `<gh-user>/doc/crate-level-<YYYYMMDD>` (e.g. `gsobol/doc/crate-level-20260529`). If branch exists, append `-N` until unique.
3. Stage only the files this skill wrote: `git add <list>`.
4. Commit with message: `docs(<scope>): refresh crate-level documentation` (scope = crate name if one crate, comma-list if 2–3, "multiple crates" if 4+).
5. Push: `git push -u origin <branch>`.
6. `gh pr create --draft --base <base> --title "..." --body "..."`. Body includes: list of crates, refinement iterations used, verifier panel composition, link to `target/.gear-doc/` for reviewers who want to inspect the verification trail.
7. Print the PR URL.

PR author is the `gh`-authenticated user — surfaced at Phase 0 for consent. If `gh auth status` fails, abort Phase 5 with a clear error.

### Phase 6 — Pretty summary

Always last, regardless of `--pr`:

```
[/gear-dev:doc summary]
  duration       : 8m 24s
  crates written : 3  (1 skipped — see below)
  total iters    : 6  (2 + 3 + 1 — convergence)
  verifier panel : opus×1 sonnet×1 codex×1
  ask-user polls : 1   (ethexe-consensus: "is `pub struct Foo` public API?")

  by crate:
    ethexe-service           iters=2  verdict=approve         +64 -4
    ethexe-consensus         iters=3  verdict=approve         +52 -8
    ethexe-runtime-common    iters=1  verdict=approve         +18 -22
    gprimitives              skipped  reason=no_lib_or_main

  pr             : https://github.com/gear-tech/gear/pull/5530  (draft, base=master, author=gsobol)
  artifacts      : target/.gear-doc/  (plans, drafts, findings — keep for inspection)
```

Write the same summary as JSON to `target/.gear-doc/summary.json` for tooling.

## Failure modes

### Early aborts (Phase 0)
- `--verifiers` parses but total = 0 → abort with usage hint.
- Crate spec resolves to 0 crates → abort with "no matching crates" + list of nearby names.
- `--pr` set but `gh auth status` fails → abort with "gh not authenticated; run `gh auth login`".

### Mid-loop soft failures (log, continue)
- Serena MCP not running → fall back to Read+grep, log "context build degraded" in plan output.
- repomix not available → same, fall back to per-file reads.
- codex CLI absent → panel shrinks, single line "codex skipped (CLI not installed)" in plan output.
- One verifier crashes mid-iteration → log, treat as "abstain", continue with others. If all crash, fail loud.

### Late aborts (Phase 4)
- Grep verification finds hallucinated identifiers → drop draft for this crate, log to summary, continue with remaining crates. Do NOT write a doc with broken intra-doc links.
- Diff sanity check rejected by user (Phase 4 step 2) → skip this crate, log to summary, continue.

### Phase 5 failures
- `git push` fails → keep commit local, print recovery instructions, do not lose the work.
- `gh pr create` fails → same — commit and branch are intact, user can open PR manually.

## What this skill does NOT do

- Generate `///` doc comments on individual items (different scope, different rules — RFC 1574).
- Update `README.md`, `ARCHITECTURE.md`, `CLAUDE.md`, `CHANGELOG.md`.
- Run `cargo build` / `cargo test` / `cargo doc` to produce artifacts.
- Touch non-Rust files.
- Modify `.gitignore`, CI configs, IDE configs.
- Auto-trigger on git hooks or file save events (manual invocation only — by design, so the user sees the plan first).
- Run in a `--loop` for periodic re-runs (use `/loop /gear-dev:doc ...` from the gstack skill if you really want that — but for docs, manual is the right cadence).
