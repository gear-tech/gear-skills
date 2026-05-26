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
```

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

Run the preflight diagnostic on demand and print the result to the session (the SessionStart hook only feeds Claude's context, not the user transcript). Use after install, or when an MCP server shows as failed in `/mcp`.

```
/gear-dev:doctor
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
        │   ├── doctor.md             # /gear-dev:doctor
        │   └── explain.md            # /gear-dev:explain
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
