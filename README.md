# claude-statusline

A two-line status line for [Claude Code](https://claude.com/claude-code), in bash
and `jq`. Shows the model, effort level, permission mode, a detailed git segment,
a context-window bar, and rate-limit usage with a reset countdown.

Everything is local. The session JSON arrives on stdin, and permission mode is
read from the transcript file Claude Code already maintains. **Nothing here
contacts the network.**

## What it looks like

Typical case — clean tree, nothing unusual:

<!-- SCREENSHOT SLOT 1: clean/typical case. Replace the code block below. -->

```
Claude Opus 5 · HIGH · 🌿 main
██████░░░░ 62% ctx · 5h 34% · ⟳ 2h11m · 7d 18%
```

Everything at once — the kitchen sink, so each symbol has a reference:

<!-- SCREENSHOT SLOT 2: kitchen-sink case. Replace the code block below. -->

```
Claude Opus 5 · HIGH · PLAN · 🌿 main ↑2 ↓1 [REBASE] !!1 +3 ~2 -1 ?4 · 📦2
█████████░ 91% ctx · 5h 78% · ⟳ 0h42m · 7d 55%
```

## Legend

**Line 1 — model · effort · permission mode · git**

| Element | Meaning |
|---|---|
| `PLAN` / `accept-edits` / `BYPASS` | Permission mode. Hidden in normal mode, so the line stays quiet. |
| 🌿 `main` | Branch. **Green** clean · **yellow** dirty · **red** conflicts present. |
| ⚠ `a1b2c3d` | Detached HEAD — replaces the branch chunk entirely. |
| `↑2` `↓1` | Commits ahead of / behind upstream. Purely local, no fetch. |
| `[REBASE]` `[MERGE]` `[CHERRY-PICK]` | An operation is in progress. |
| `!!1` | Unmerged paths. Leads the dirty buckets — most urgent, read first. |
| `+3` `~2` `-1` `?4` | Staged · modified · deleted · untracked. |
| 📦`2` | Stash entries. |

**Line 2 — context · usage · reset**

The bar is the context window, scaled so 100% lands at the auto-compact point
rather than the hard limit. Then the 5-hour usage percentage, the countdown to
that window resetting, and the 7-day percentage. Each segment hides itself when
the underlying data isn't present.

## Install

Requires **bash 4+**, **`jq`**, and GNU coreutils (`tac`, `stat -c`) — so Linux in
practice. See *Limits* below.

1. Put `statusline.sh` somewhere and make it executable:

   ```sh
   install -m 755 statusline.sh ~/.claude/statusline.sh
   ```

2. Point Claude Code at it in `~/.claude/settings.json`:

   ```json
   {
     "statusLine": { "type": "command", "command": "~/.claude/statusline.sh" },
     "refreshInterval": 10
   }
   ```

That's it — no build step and nothing to install beyond `jq`.

## How it works

Two parts are less obvious than the rest, and are most of why this exists.

**Permission mode isn't in the status line payload.** Claude Code pushes a JSON
object on stdin with the model, context percentage, and rate limits — but not the
current permission mode. It *is* recoverable locally: Claude Code writes a
`permissionMode` entry into the session transcript (JSONL) every time you toggle,
so reading the last one back gives a live value. `tac` + `jq` + `head -1` keeps
that around 40 ms even on a 1.5 MB transcript, which is comfortably inside a
refresh tick.

**The whole git segment is one `git` call.** An earlier version shelled out three
times — `numstat`, `ls-files`, and a branch read. Instead,

```sh
git status --porcelain=v1 --branch
```

returns branch, upstream ahead/behind, and every dirty path in a single
invocation, and the per-file `XY` status codes carry enough to separate
conflicts, staged, modified, deleted, and untracked with one pass. That matters
because a status line runs on a refresh interval — the difference between one
subprocess and four is the difference between a status line that keeps up with
typing and one that lags it. Results are cached for 5 seconds, keyed on session
id, so rapid refreshes don't re-run it at all.

## Limits

- **Linux, realistically.** `mapfile` needs bash 4+ (macOS ships 3.2 as
  `/bin/bash`), and `tac` / `stat -c` are GNU coreutils. Homebrew bash plus the
  BSD equivalents would get most of the way there; that port isn't done.
- **Rate-limit segments are plan-dependent.** `rate_limits` is only present on
  some plans, and is absent until the first API response — those segments hide
  themselves rather than showing zeros.
- **`COMPACT_AT=92` is a tunable guess.** No auto-compact threshold is exposed, so
  the context bar is scaled against a constant at the top of the script. Adjust it
  to taste.
- Built against Claude Code's status line schema as of **August 2026**, and
  provided as-is.

## License

MIT — see [LICENSE](LICENSE).
