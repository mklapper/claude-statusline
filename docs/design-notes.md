# Design notes

Why the git segment looks the way it does. The README covers *what* each symbol
means; this covers *why* it was chosen, for anyone adapting the script.

## Reading order is priority order

```
🌿 branch  ↑2 ↓1  [MERGE]  !!1  +3 ~2 -1 ?4  ·  📦2
```

Left to right, most urgent first. Two consequences worth stating because they
were deliberate rather than incidental:

- **The conflict count leads the dirty buckets rather than trailing them.** An
  unmerged path is the one state that blocks everything else you might do, so it
  should be the first thing your eye reaches, not the last.
- **Ahead/behind sits immediately after the branch name with no separator**,
  because it modifies the branch — it is not an independent fact about the tree.
- **Stash count trails after a `·` separator.** It is the least urgent thing on
  the line and is often stale; it earns its place only because a forgotten stash
  is easy to lose entirely.

## Colour carries meaning, not decoration

- **The branch name is a traffic light** — green clean, yellow dirty, red when
  conflicts exist. Red overrides yellow, driven by the same test as the `!!`
  badge, so the two can never disagree.
- **Untracked is blue, not dim grey.** Grey is reserved for punctuation and the
  stash. Making untracked grey looked fine on a dark theme and became nearly
  invisible on a light one, and it also freed cyan to mean *only* ahead/behind.
- **Magenta means "unusual repo state"** — the in-progress operation badge and a
  detached HEAD. It is the same semantic the permission-mode segment already used
  for its fallback case, so one colour means one thing across both lines.
- **Detached HEAD replaces the branch chunk entirely** rather than colouring it.
  There is no branch, so a traffic light would be asserting something false; you
  get `⚠ {short-sha}` instead.

## `!!` for conflicts, not a glyph

An earlier version used `✖`. It was retired for a boring, real reason: a symbol
from the same glyph family (`✓ ✗ →`) had already caused a `UnicodeEncodeError`
crash in a different tool when it hit a Windows console code page. A status line
runs on every prompt, so a rendering failure is not cosmetic — it is a broken
terminal.

`!!` is plain ASCII. It cannot fail to render on any font or code page, and it
reads urgently on its own without needing colour to carry the alarm. The emoji
that remain (`🌿`, `📦`) are decorative: if they fall back to a box glyph the
line is still readable.

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

This matters because a status line runs on a refresh interval. Results are cached
for 5 seconds keyed on the session id, so rapid refreshes do not re-run it at all.

## A bash gotcha worth knowing

The git state is cached one field per line and read with `mapfile`. The obvious
alternative — tab-delimited, read with `IFS=$'\t' read -r a b c` — is broken in a
way that is easy to miss.

**Tab is IFS whitespace.** `read` collapses *consecutive* IFS-whitespace
delimiters and strips leading and trailing ones — even when `IFS` is set to only
a tab. So any field that can be empty silently disappears, and every field after
it shifts left by one.

That is exactly what happened here. The in-progress-operation field is empty on
every normal run, so it collapsed into its neighbour and shifted the rest of the
line along: the stash count came back empty, numeric comparisons on it threw
`integer expression expected`, and the operation badge rendered a stray `[0]` on
an ordinary clean tree.

The fix is to avoid IFS whitespace entirely for records with optional fields:

```sh
# safe — newline splitting neither collapses nor trims
mapfile -t FIELDS < "$CACHE"

# also safe — a non-whitespace delimiter
IFS=$'\x1f' read -r a b c <<< "$record"
```

Worth internalising if you write shell that caches structured data: **the bug
does not appear until a field happens to be empty**, so it survives every test
where everything is populated.
