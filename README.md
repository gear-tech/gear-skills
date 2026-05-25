# gear-skills

Claude Code plugin marketplace for **Gear Protocol** development (Vara, ethexe).

This repository hosts the `gear-dev` plugin — a collection of slash commands and skills that help engineers working in [gear-tech/gear](https://github.com/gear-tech/gear) and related repos move faster with Claude Code.

## Install

In any Claude Code session:

```
/plugin marketplace add gear-tech/gear-skills
/plugin install gear-dev@gear-skills
```

That is it — commands become available as `/gear-dev:<name>` immediately.

To update later:

```
/plugin marketplace update gear-skills
```

## What's included

### `/gear-dev:explain`

Explain a PR, issue, commit, diff, file, or pasted code. Produces a TL;DR plus a walkthrough of the most important / hardest spots, each with a permalink and inline commentary in the language you choose.

```
/gear-dev:explain <source> [--lang ru|en|…] [--deep]
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

- `--lang <code>` — prose language for the explanation. Default: `en`. Code, identifiers, file paths, and command examples always stay English.
- `--deep` — walk through every significant change instead of capping at 2–5 key spots.

**Examples:**

```
/gear-dev:explain https://github.com/gear-tech/gear/pull/4321
/gear-dev:explain gear-tech/gear#4321 --lang ru
/gear-dev:explain master...HEAD
/gear-dev:explain abc1234 --deep
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
        │   └── plugin.json           # plugin manifest
        └── commands/
            └── explain.md            # /gear-dev:explain
```

## Contributing

New commands go in `plugins/gear-dev/commands/<name>.md`. New skills go in `plugins/gear-dev/skills/<name>/SKILL.md`. Update `marketplace.json` and this README when adding new top-level capabilities.

When editing existing commands or skills, bump the plugin `version` in both `.claude-plugin/marketplace.json` and `plugins/gear-dev/.claude-plugin/plugin.json` if the change is user-visible.

Keep skill and command content in English. Output language is the user's choice at invocation time (e.g. `--lang ru`).

## License

[MIT](./LICENSE)
