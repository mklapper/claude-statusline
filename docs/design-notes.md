# Design notes

Why the git segment looks the way it does. The README covers *what* each symbol
means; this covers *why* it was chosen, for anyone adapting the script.

## Reading order is priority order

```
🌿 branch  ↑2 ↓1  [MERGE]  !!1  +3 ~2 -1 ?4  ·  📦2
```

Left to right, most urgent first:

- **The conflict count leads the dirty buckets rather than trailing them.** An
  unmerged path is the one state that blocks everything else you might do, so it
  should be the first thing your eye reaches, not the last.
- **Ahead/behind sits immediately after the branch name with no separator**,
  because it modifies the branch — it is not an independent fact about the tree.
- **Stash count trails after a `·` separator.** It is the least urgent thing on
  the line and is often stale; it earns its place only because a forgotten stash
  is easy to lose entirely.

## Color carries meaning, not decoration

- **The branch name is a traffic light** — green clean, yellow dirty, red when
  conflicts exist. Red overrides yellow, driven by the same test as the `!!`
  badge, so the two can never disagree.
- **Untracked is blue, not dim grey.** Grey is reserved for punctuation and the
  stash. Making untracked grey looked fine on a dark theme and became nearly
  invisible on a light one, and it also freed cyan to mean *only* ahead/behind.
- **Magenta means "unusual repo state"** — the in-progress operation badge and a
  detached HEAD. It is the same semantic the permission-mode segment already used
  for its fallback case, so one color means one thing across both lines.
- **Detached HEAD replaces the branch chunk entirely** rather than coloring it.
  There is no branch, so a traffic light would be asserting something false; you
  get `⚠ {short-sha}` instead.

## `!!` for conflicts, not a glyph

An earlier version used `✖`. It was retired after a symbol from the same glyph
family (`✓ ✗ →`) caused a `UnicodeEncodeError` crash in a different tool when it
hit a Windows console code page. A status line renders on every prompt, so a
rendering failure shows up constantly rather than occasionally.

`!!` is plain ASCII. It cannot fail to render on any font or code page, and it
reads as urgent without relying on color. The emoji that remain (`🌿`, `📦`) are
decorative: if they fall back to a box glyph the line is still readable.

## One `git` call, not four

The git segment is a single invocation:

```sh
git status --porcelain=v1 --branch
```

That one call yields the branch, upstream ahead/behind, and every dirty path;
the per-file `XY` status codes carry enough to separate conflicts, staged,
modified, deleted and untracked in one pass. An earlier version shelled out
three times — `numstat`, `ls-files`, and a branch read — and lumped deletions in
with modifications because `numstat` could not tell them apart.

Results are cached for 5 seconds keyed on the session id, so rapid refreshes do
not re-run it at all.

## One field per line, not tab-delimited

The git-state cache is written one field per line and read with `mapfile`. The
obvious alternative — tab-delimited, read with `IFS=$'\t' read -r a b c` — does
not work here: tab is IFS whitespace, so `read` collapses consecutive delimiters
and strips leading and trailing ones even when `IFS` is only a tab. Any field
that can be empty vanishes and shifts every later field.

That rules it out because the in-progress-operation field is empty on any
ordinary run, so the record would misalign in the common case and align correctly
only in the rare one.

Either of these avoids it:

```sh
mapfile -t FIELDS < "$CACHE"           # newline splitting neither collapses nor trims
IFS=$'\x1f' read -r a b c <<< "$rec"   # a non-whitespace delimiter
```
