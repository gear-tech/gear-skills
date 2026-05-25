---
description: Explain a PR, issue, commit, diff, file, or pasted code — TL;DR plus walkthrough of the most important spots, with permalinks.
argument-hint: <pr-url|issue-url|commit|range|file|"text"> [--lang ru|en|…] [--deep]
---

# /explain

Help a reviewer understand a piece of work fast. Given a source (GitHub PR/issue, commit, diff, file, or pasted code), produce a TL;DR and walk through the most important / hardest spots with permalinks and inline commentary.

## Arguments

`$ARGUMENTS`

Parse them as:

- **First non-flag token / quoted string / pasted block** → the **source** (required).
- `--lang <code>` → output prose language (default: `en`). Code, identifiers, paths, commands, and inline code comments stay English regardless.
- `--deep` → walk through every significant change instead of the default 2–5 cap.

If `$ARGUMENTS` is empty or only flags, ask the user what to explain. Do not guess.

## Step 1 — Detect the source

Try these patterns in order, first match wins:

| Pattern | How to fetch context |
|---|---|
| `https://github.com/<o>/<r>/pull/<N>` or `<o>/<r>#<N>` (resolves to PR) | `gh pr view <N> --repo <o>/<r> --json title,body,author,state,baseRefName,headRefOid,additions,deletions,changedFiles,commits,labels,closingIssuesReferences,url` and `gh pr diff <N> --repo <o>/<r>` and `gh pr view <N> --repo <o>/<r> --comments` |
| `https://github.com/<o>/<r>/issues/<N>` or `<o>/<r>#<N>` (resolves to issue) | `gh issue view <N> --repo <o>/<r> --comments` |
| 7+ hex matching a commit in the current repo | `git show --stat <sha>` then `git show <sha>` |
| Git ref or range (e.g. `master...HEAD`, `feature/foo`) | `git diff --stat <range>` then `git diff <range>` |
| Existing file path | `Read` the file |
| Anything else | Treat as pasted text/code — explain it directly, no permalinks |

For GitHub PRs, capture `headRefOid` as the **permalink SHA**. For local commits, only build a permalink if `git branch -r --contains <sha>` shows the commit on a published branch and `git config --get remote.origin.url` points to a GitHub remote.

## Step 2 — Build context before saying anything

- Read the **full** PR body, **full** diff, **all** review comments, and any linked/closing issues. Do not skim.
- For diffs that reference symbols not present in the changed files, `Read` the surrounding code to understand them in context.
- Classify the categories of change: feature, refactor, fix, config/build, docs, migration, dependency bump.
- If something is genuinely unclear after reading everything, mark it for the "Possible issues" section instead of papering over it.

## Step 3 — Pick what to walk through

Default scope: **2–5** key spots. With `--deep`: every significant change.

Pick by:

- Highest semantic complexity (state machines, concurrency, lifecycle changes).
- Non-obvious decisions where the raw diff is misleading without context.
- Places that touch invariants, public APIs, on-disk/on-chain formats, or consensus-sensitive logic.
- New mechanisms the team has not seen before.

Skip (mention in the bullet list, do not walk through):

- Renames, moves, formatting changes.
- Trivial one-liners and mechanical dependency bumps.
- Generated files (ABI JSON, lockfiles, build artifacts).

A small PR with 1–2 worthwhile spots is fine. Do not pad up to 5.

## Step 4 — Flag suspicions honestly

If something looks like a bug, a broken invariant, an unexplained decision, or a missing test for a behavior change — call it out under `⚠️ Possible issues`. Tie each finding to specific lines. Do **not** fabricate concerns. If everything checks out, omit the section.

## Output format

Output prose in the requested `--lang` (default English). Identifiers, file paths, command names, code blocks, and inline code comments stay in English.

```markdown
## TL;DR

<1 paragraph: what this change does and the underlying intent>

## What changed

- **Added:** …
- **Changed:** …
- **Removed:** …
- **Refactored:** …
- **Config/build:** …

(Omit empty buckets. Be specific about files and areas, not vague.)

## Key spots

### 1. <short label> — <why this matters>

[`path/to/file.rs:L42-L58`](https://github.com/<owner>/<repo>/blob/<sha>/path/to/file.rs#L42-L58)

```<lang>
<the code from those lines>
```

<2–5 sentences in the requested language: what it does, why it is written this way,
what to look at carefully>

### 2. …

## ⚠️ Possible issues / open questions

(Only when concrete. Tie each to specific lines.)

- …
```

## Hard rules

- **Permalinks only when verifiable.** If no published SHA is available (uncommitted local diff, pasted snippet, file with unpushed changes), write `path/to/file.rs:42-58 (no permalink available)` — never fake links.
- **Do not translate code.** Even with `--lang ru`, code blocks, identifiers, command examples, and inline code comments stay English.
- **Do not invent issues.** An empty "Possible issues" section is fine.
- **Do not restate the PR title.** TL;DR must add information the title alone does not convey.
- **Ask when ambiguous.** If `#123` could resolve to multiple repos, or the source pattern is unclear, ask the user before fetching.
