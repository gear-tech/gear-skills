---
description: Explain a PR, issue, commit, diff, file, or pasted code — coherent narrative walkthrough that helps a reviewer understand the work, with heavy inline commentary and permalinks, fully localized to the requested language.
argument-hint: <pr-url|issue-url|commit|range|file|"text"> [--lang ru|en|…] [--deep]
---

# /explain

Help a reviewer understand a piece of work fast. Given a source (GitHub PR/issue, commit, diff, file, or pasted code), produce a **connected narrative** that explains *what* was done, *why*, and *how the tricky parts work* — with permalinks and heavy inline commentary in the language the user asked for.

## Arguments

`$ARGUMENTS`

Parse them as:

- **First non-flag token / quoted string / pasted block** → the **source** (required).
- `--lang <code>` → output language (default: `en`). See "Language rules" below.
- `--deep` → cover the full walkthrough exhaustively instead of focusing on the parts most useful to a reviewer.

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

## Step 3 — Plan a narrative, not a checklist

The output is a **coherent story**, not a list of disconnected findings. Before writing, sketch the story in your head:

1. **Frame the problem.** What was the situation before, and why did this change need to happen? Pull from PR description, linked issues, and commit messages.
2. **Identify the approach.** What strategy did the author take — a migration, a new abstraction, a bug fix, a refactor? Sketch the shape of the solution.
3. **Trace the implementation.** Walk through the changes in an order that makes the story flow — usually top-down (high-level entry points → specific tricky details), not file-by-file in alphabetical order.
4. **Highlight what is hard.** Slow down on places where the code is dense, non-obvious, or touches invariants. Code blocks with heavy inline commentary are evidence inside the narrative — not standalone exhibits.

The reader should come away with a mental model of the whole change, with the tricky parts illuminated — not a checklist of disconnected facts.

## Step 4 — Scope the walkthrough

Cover everything important to the story. There is no hard cap on subsections — but stay focused on what helps a reviewer understand the work. With `--deep`, also cover every other significant change exhaustively. Without it, **skip** (mention briefly in the inventory, do not walk through):

- Renames, moves, formatting changes.
- Trivial one-liners and mechanical dependency bumps.
- Generated files (ABI JSON, lockfiles, build artifacts).

## Step 5 — Flag suspicions honestly

If something looks like a bug, broken invariant, unexplained decision, or missing test for a behavior change — call it out in the final "Possible issues" section. Tie each finding to specific lines. Do **not** fabricate concerns. If everything checks out, omit the section.

## Language rules

`--lang <code>` controls **all natural-language text** in the output. The default is English.

**Translate** (everything the reader reads in prose form):

- Section headings, subheadings, table headers, bullet prefixes, labels.
- Prose explanations and TL;DR.
- Inline commentary you add to code blocks (`// <your explanation>`).
- Original source comments quoted inside snippets — translate them. The source-of-truth is the permalink; the snippet is reader-facing and should not force a language switch mid-paragraph.

**Keep in source language** (English / original):

- Code itself: keywords, syntax, identifiers, type names, function names, macro names, struct fields.
- File paths, command names, flag names, environment variables.
- PR/issue titles and external references (CVE IDs, RFC numbers, RFC text).

If `--lang` is `en` or omitted, English everywhere.

## Inline commentary — comment generously

Every non-trivial code snippet must carry inline `// <commentary>` (or `# `, `//` per language) explaining **what** the code does and **why** at each interesting step. Aim for a comment density where a reader can follow the snippet from comments alone, without re-reading the surrounding prose.

- Mark AI-added commentary clearly distinct in tone from original code comments. A reader should understand the snippet *as code* with your guidance layered in.
- Translate both your added comments and any original source comments into the requested language.
- Do not pad: every comment should add information not obvious from the line itself.

## Output format

Use natural-language conventions of the target language for headings. Below is the structure with Russian labels shown as an example when `--lang ru`; for English, use the natural English equivalents (`## What changed`, `## Walkthrough`, `## Possible issues`).

```markdown
## TL;DR

<1 paragraph in the requested language: what this change does, the underlying
intent, and any context the reviewer needs (e.g. "marked do-not-merge, waiting
for X"). Adds information beyond the PR title.>

## Что изменилось                           ← localized heading

- **Добавлено:** …                         ← localized labels
- **Изменено:** …
- **Удалено:** …
- **Рефакторинг:** …
- **Конфиг/сборка:** …

(Omit empty buckets. Be specific about files and areas, not vague.)

## Разбор                                   ← localized; this is the narrative

<Connected prose telling the story of the change. Break into ### subsections
by sub-topic of the solution (not by "spot N"). Each subsection explains a
piece of the solution and how it fits the whole, embedding code as evidence
with heavy inline commentary.>

### <Подзаголовок 1: имя подсистемы или этапа решения>

<2–5 sentences setting up what this part of the change does and why it matters
to the overall story.>

[`path/to/file.rs:L42-L58`](https://github.com/<owner>/<repo>/blob/<sha>/path/to/file.rs#L42-L58)

```rust
// <translated commentary: что делает функция и зачем она здесь>
fn handle_request(req: Request) -> Result<Response> {
    // <translated original comment, либо AI-комментарий: почему именно validate, а не parse>
    let parsed = validate(&req)?;
    // <inline note: тут происходит дорогая операция, поэтому кэш ниже>
    let cached = CACHE.get_or_init(|| build_cache());
    cached.lookup(parsed)
}
```

<continuation of the narrative — how the code above accomplishes the goal,
what to watch out for, and how it connects to the next subsection>

### <Подзаголовок 2: следующая часть истории>

<flows from the previous section as the next beat of the story, not a fresh
enumeration. Reference back to subsection 1 where relevant>

…

## ⚠️ Возможные проблемы                    ← only when concrete

(Tie each item to specific lines.)

- …
```

## Hard rules

- **One coherent narrative, not a list of spots.** The walkthrough reads top-to-bottom as a story. Subsections are beats of that story. Code snippets are evidence inside the narrative, not numbered standalone items.
- **Comment generously and in the right language.** Every non-trivial code block carries inline commentary in the requested language. Translate both AI-added commentary and any quoted original comments.
- **Localize everything natural-language.** Section headings, labels, bullet prefixes, prose, code comments — all in the requested language. Only identifiers, paths, syntax, and external references stay English.
- **Permalinks only when verifiable.** If no published SHA is available (uncommitted local diff, pasted snippet, file with unpushed changes), write `path/to/file.rs:42-58 (no permalink available)` — never fake links.
- **Do not invent issues.** Empty "Possible issues" is fine.
- **Do not restate the PR title.** TL;DR must add information the title alone does not convey.
- **Ask when ambiguous.** If `#123` could resolve to multiple repos, or the source pattern is unclear, ask the user before fetching.
