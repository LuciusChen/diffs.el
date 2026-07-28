# diffs.el

Fast, pretty file-level diff viewing for Emacs, inspired by
[diffs.com](https://diffs.com/).

Diffs.el turns the built-in `diff-mode` into a native review surface:
aligned old/new line numbers, full-width change backgrounds, fringe
bars, source syntax, within-line refinement, comments, accept/reject
previews, and merge-conflict actions. Reviews open side by side by
default; set `diffs-default-view` to `stacked` for a unified initial
layout.

It requires Emacs 29.1 or newer. Rendering is pure Elisp; VC or Git is
used only to produce the input patch.

## Why diffs.el

- No renderer subprocess and no ANSI parsing.  (The commands still use
  VC/Git to produce their input.)  Opening a diff costs one cheap scan
  (≈17 ms for 22k lines / 800 files); on large diffs even the decorations
  are applied lazily through jit-lock, so only what you see is rendered.
- The diff text is never modified: `diff-goto-source` (RET), isearch,
  `diff-apply-hunk` and the rest of diff-mode keep working; line
  numbers live in `line-prefix`, so copying and searching stay clean.
- Theme-native: everything inherits from the standard `diff-*` faces.
- Revision-aware syntax highlighting: the old side is fontified from
  the file contents at the reference revision.
- Native within-line rendering globally pairs corresponding changed
  lines before applying a diffs.com-style `word-alt` token diff.

## Quick start

Run `M-x diffs-file` in a tracked file or `M-x diffs-project` anywhere
inside a project. The first view is split; `s` switches layouts and `q`
returns to the previous window configuration.

### Entry points

| Command | Description |
|---|---|
| `diffs-file` | Current file vs the reference revision, including staged and unsaved changes when diff-hl is available |
| `diffs-project` | Saved project working tree vs the reference revision |
| `diffs-commit` | Show a commit (Git) |
| `diffs-commit-at-line` | Show the commit that last touched the current line |
| `diffs-conflicts` | Resolve merge markers in place with Current, Incoming, Both, and Reset |
| `diffs-minor-mode` | Use the renderer in any diff-mode buffer |
| `diffs-diff-hl-mode` | Render diff-hl's current inline or posframe hunk with diffs.el |

### Review keys

| Key | Action |
|---|---|
| `n` / `p` | Next / previous hunk |
| `N` / `P` | Next / previous file in stacked view |
| `RET` | Visit the source line |
| `i` | Toggle the changed-file index |
| `e` | Reveal more unchanged context |
| `TAB` | Fold or unfold a hunk in stacked view |
| `v` / `x` | Select / clear a stable review range |
| `a` | Add a comment to the selected range |
| `[` / `]` | Previous / next comment |
| `A` / `R` / `U` | Accept / reject / reset a change block |
| `C-c C-c` | Apply reviewed decisions without saving or staging |
| `s` | Enter split view or return to stacked view |
| `g` | Refresh the review transactionally |
| `q` | Quit the complete review; in split view both columns close |

A review is an explicit snapshot. Use `g` after source, formatter, Git,
or Agent changes should be reflected. Refresh preserves the current
side and source-row identity; a failure leaves the existing review and
window layout untouched.

## Accept and reject changes

Press `A` on a changed line to keep its complete contiguous change
block, or `R` to restore the old version in the review preview. A
prefix argument (`C-u A` or `C-u R`) resolves every change block in
the current hunk. This matches diffs.com's model: resolved additions
or deletions become context, later result line numbers are adjusted,
and the original patch remains unchanged.

The preview is shared by stacked and split layouts. In stacked view
the discarded side is hidden beneath a decision label. In split view
both columns collapse to the chosen result while retaining stable
block identity. Press `U` on that label or result block to reset one
decision; `C-u U` resets the complete review. Reset changes only the
preview decision: if a result was already applied to a source buffer,
its physical line shifts remain tracked so later `RET` navigation and
applications still address the live worktree correctly.

Decisions do not modify files by themselves. After reviewing several
blocks, press `C-c C-c` to validate and apply the combined result.
Accepted blocks already match the new-side source. Rejected blocks
replace the corresponding new-side text with the old text. Changed
source buffers remain unsaved and nothing is staged, so normal Emacs
undo and a final source review remain available.

## Merge conflicts

Open a source file containing Git conflict markers and run
`M-x diffs-conflicts`. The existing source buffer remains in its
language major mode, so syntax highlighting, Eldoc, Xref, LSP state,
file identity, and unrelated unsaved edits stay in place. Diffs.el adds
a stacked action row above each conflict and theme-native backgrounds
for its Current, optional Base, and Incoming sections. Current and
Incoming marker rows use a stronger background than their code blocks,
visually join those blocks, carry explicit section labels, and use
matching fringe bars without changing the underlying Git marker text.

Actions use the `C-c C-d` prefix:

| Key | Action |
|---|---|
| `C-c C-d c` | Keep Current |
| `C-c C-d i` | Keep Incoming |
| `C-c C-d b` | Keep Current followed by Incoming |
| `C-c C-d u` | Restore the complete original marker block |
| `C-c C-d n` / `C-c C-d p` | Visit the next / previous conflict |
| `C-c C-d q` | Remove the presentation while retaining source edits |

The unresolved action row provides Accept current change, Accept
incoming change, and Accept both with mouse-1. After a selection, Reset
appears alongside the alternative choices. Every selection immediately
replaces that block in the real buffer as one ordinary undoable edit. It
never saves the file, stages a change, or runs Git. The resulting file
is therefore the preview, and Reset remains available after every
conflict has been resolved.

Two-way and diff3 markers are supported. For diff3 input, Base remains
visible while unresolved but is not included in any result; Both is
exactly Current followed by Incoming. Marker widths greater than seven
are accepted. Malformed or nested conflicts are rejected before the mode
is enabled, and a block edited by another command must be undone before
diffs.el will replace it. Standard blocks use smerge's public matcher
and Current/Incoming operations. Diffs.el keeps the stronger visual
layer, strict preflight, diff3 Both-without-Base behavior, extended
marker fallback, and persistent Reset state. Existing `smerge-mode`
state is left enabled and its `C-c ^` bindings are not changed.

## Review selection and comments

Press `v` on a changed line to select that old- or new-side source line.
For a range, activate a normal Emacs region (`C-SPC`), extend it over
changed lines on the same file and side, then press `v`. The stored
selection is a one-based file/side/line range rather than a buffer
position, so it survives stacked/split switches and context rebuilds.

Press `a` to add a summary and optional rationale. Comments render below
their target line; in split view the peer column receives an invisible
equal-height spacer, so later code stays aligned. Use `[` and `]` to
navigate comments, `x` to clear only the selection, and
`M-x diffs-review-remove-annotation` or
`M-x diffs-review-clear-annotations` to remove comments.

Comments live in the review session until explicitly persisted.
`M-x diffs-review-export` writes a Hunk-compatible version-1 sidecar
using `oldRange`/`newRange`; `M-x diffs-review-import` restores it
only after validating every known field and old/new target against the
current diff. Unknown fields are ignored for compatibility with newer
producers, and an annotation may carry both old and new ranges. An
invalid import or display failure leaves existing comments intact.

### Live Agent sessions

Code agents can read human comments and write their own directly
against the live owner buffer. No sidecar or temporary export is used.
Start the normal Emacs server with `M-x server-start`, then run:

```sh
diffs session list --json
diffs session review --repo . --include-notes --json
diffs session comment list --repo . --type user --json
```

Each live review has a stable `diffs-session:…` id. `--repo` selects the
matching repository when there is only one session; use `--session ID`
when the same repository has multiple reviews. Review snapshots also
include the user's pending accept/reject decisions per file.

Agents write one atomic stdin batch:

```sh
printf '%s\n' \
  '{"comments":[{"filePath":"src/example.el","newLine":42,"summary":"This branch drops the error value.","author":"codex"}]}' \
  | diffs session comment apply --repo . --stdin --focus --json
```

An invalid file, target, or comment rejects the entire batch. The CLI
also provides `comment list`, `comment rm`, and guarded `comment clear`
commands; run `diffs --help` for their exact forms.

Run `M-x diffs-review-install-agent-tools` once to copy the bundled
[CLI](bin/diffs) to `~/.local/bin/diffs` and the bundled
[Codex skill](skills/diffs-review/SKILL.md) at
`~/.agents/skills/diffs-review`. Ensure `~/.local/bin` is on `PATH`.
The installed files are durable copies rather than links into a
straight/MELPA build directory, so package upgrades cannot leave them
dangling. Installation preflights every destination and rolls back all
targets if a later write fails. Use a prefix argument once to replace
links from an older installation. Set the `EMACS` environment variable
when the CLI should launch a particular Emacs executable.
After that, ask Codex CLI or Codex App to “read my live Emacs diff
comments”; the skill uses `diffs session`, never screen scraping or
temporary files.

The CLI directly contacts the existing Emacs Unix socket. A restricted
agent sandbox may ask for one-time permission to access that local
socket, just as other live-session tools do.

## Expandable context

Collapsed hunk separators report how many unchanged lines they hide.
On a separator or anywhere in its hunk, press `e` repeatedly to reveal
`diffs-context-step` more lines. Expansion is one-way within a review;
once every hidden line is visible, the separator disappears. `TAB`
remains available for Emacs's separate hunk/outline folding. The same
`e` command works directly in the side-by-side view, where both columns
rebuild together.

Expanded lines are display overlays backed by the complete old and new
file contents; the underlying patch is unchanged, so applying hunks,
searching, and copying retain normal `diff-mode` behavior.  Expanded
lines use the file's source-language syntax faces above the context
background.  Complete file contents are fontified lazily and cached
per file.

## Changed-file index and sticky context

The header line stays pinned to the file and hunk at the top of the
window.  It shows the current file position (`[3/42]`), per-file
addition/deletion counts, hunk line starts, and the hunk's function
context when available.

Press `i` to open a left side window containing only files present in
the diff—not the complete repository tree.  Each entry includes
addition/deletion counts and follows the current file while the diff
scrolls.  In the index, `n`/`p` preview adjacent files without moving
focus, `RET` or mouse-1 visits a file, and `i`/`q` hides the index.
The index remains available with the side-by-side view.

## Side-by-side view

The default view splits the frame into two synchronized windows — old
on the left, new on the right — with row-perfect alignment (dimmed
filler bands pad insertions and deletions), per-side line numbers, and
the same native refinement and syntax faces as the unified view.
Theme-native added/removed backgrounds cover the line-number gutter
and extend to the right edge.  `n`/`p` move by hunk in both windows,
`RET` visits the source, `s` returns to the unified view, and `q`
closes both columns and quits the complete diff view.

Long lines are truncated by default and support horizontal scrolling.
Horizontal offsets, paired cursor rows, and display columns stay
synchronized; `C-a` and `C-e` move both sides to their respective line
beginnings or ends.
Set `diffs-split-wrap-lines` to non-nil to wrap them into aligned
physical rows so the two sides never drift apart.

Very large diffs bulk-insert complete old/new text, so normal isearch,
copying, source navigation, and scrollbar semantics work immediately.
Expensive visual work—line backgrounds, gutters, fringe bars, source
syntax, and within-line emphasis—is materialized only for the viewport
plus `diffs-split-overscan`, and both columns are updated together while
scrolling.  Completed rows and the rendered pair are cached, so
returning to a split with the same width is effectively immediate.

## Within-line changes

Consecutive removed and added lines are globally aligned by normalized
edit distance before their contents are compared.  This prevents a
single inserted row from shifting every later comparison in the
change block.  The default `word-alt` renderer follows diffs.com's
visual grouping rule for tiny unchanged separators; exact `word`,
Unicode-character `char`, and disabled `none` modes are also available.
The `word-alt` grouping follows the complete two-sided edit sequence,
including one-sided insertions between shared separators. Unicode
whitespace is handled consistently by the show/ignore option. Unified
and side-by-side views consume the same cached changed ranges.

Lines over 1,000 characters skip within-line comparison by default,
and change blocks over 64 lines per side use bounded ordinal fallback.
Both limits are configurable.

## Configuration

All options belong to the `diffs` customization group.

### Layout and presentation

| Option | Default | Purpose |
|---|---:|---|
| `diffs-default-view` | `split` | `split` or `stacked` layout for reviews and diff-hl hunk previews |
| `diffs-fullscreen` | `t` | Let a review take over the frame until `q` |
| `diffs-split-wrap-lines` | `nil` | Wrap long split rows with aligned fillers |
| `diffs-line-numbers` | `t` | Show old and new line-number columns |
| `diffs-hide-markers` | `t` | Hide leading unified-diff markers |
| `diffs-prettify-headers` | `t` | Replace raw file/hunk headers with compact headers |
| `diffs-fringe-bars` | `t` | Show theme-native added/removed fringe bars |
| `diffs-fringe-bar-width` | `2` | Fringe-bar width in pixels, clamped to 1–8 |
| `diffs-split-full-width-backgrounds` | `t` | Extend split change backgrounds across each row |
| `diffs-index-width` | `36` | Changed-file index width in columns |
| `diffs-buffer-name` | `"*diffs*"` | First-party review buffer name |

### Context and within-line refinement

| Option | Default | Purpose |
|---|---:|---|
| `diffs-context-step` | `10` | Unchanged lines revealed by each `e` |
| `diffs-line-diff-type` | `word-alt` | `word-alt`, exact `word`, Unicode `char`, or `none` |
| `diffs-refine-whitespace` | `show` | Show or ignore whitespace-only token changes |
| `diffs-max-line-diff-length` | `1000` | Longest line eligible for token comparison; zero disables the limit |
| `diffs-line-pair-threshold` | `0.6` | Maximum normalized edit distance for corresponding lines |
| `diffs-line-pair-limit` | `64` | Largest change block per side using global alignment |

### Large-review rendering

| Option | Default | Purpose |
|---|---:|---|
| `diffs-lazy-threshold` | `10000` | Start applying stacked decorations through jit-lock |
| `diffs-split-overscan` | `60` | Extra split rows prepared above and below the viewport |

The Agent installer destinations are controlled by
`diffs-review-cli-install-path`,
`diffs-review-skill-install-directory`, and
`diffs-review-assets-directory`.

On an M-series Mac running Emacs 32, the included synthetic benchmark
(800 files, 22,000 lines, 536 KB) measures about 17 ms for scanning,
275 ms for the first side-by-side render, 20 ms to materialize a first
deep viewport, and 0.7 ms for a cached toggle.  This includes line
numbers, fringe bars, source syntax, and native corresponding-line/word
refinement with the default non-wrapping split.  The v0.7 first-split
baseline was about 332 ms.  The same fixture also exercises the public
split-view `A` and `R` decision path: those rebuilds take about 340 ms
and 400 ms respectively, down from about 943 ms and 1,016 ms after
deferring hidden stacked-overlay projection until stacked is requested.
Run it on your machine with:

```sh
make benchmark
```

## Integrations

- **diff-hl**: `diff-hl-reference-revision` and its public project
  cache are respected, so `diff-hl-set-reference-rev-in-project`
  gives both file and project commands a branch-point ("PR") view.
  Saved and unsaved file views use the same base; a nil reference means
  the last revision rather than the Git index. The project command
  intentionally reads the saved working tree and does not combine
  unrelated unsaved buffers.

  Diffs.el can render diff-hl's compact current-hunk views through the
  standard `diff-hl-show-hunk-function` extension point. Enable
  diff-hl's mouse mode and the optional integration mode:

  ```elisp
  (global-diff-hl-show-hunk-mouse-mode 1)
  (diffs-diff-hl-mode 1)
  ```

  Mouse-1 on a diff-hl-enabled margin or fringe and
  `M-x diff-hl-show-hunk` now show only the selected hunk, using
  diffs.el's line numbers, marker-free rows, source syntax, line
  pairing, and word refinement. Diffs.el uses the complete patch that
  diff-hl already generated to compute those results, but decorates
  only the narrowed current hunk and does not open a full-file review.
  The raw patch remains intact, so diff-hl's quit, previous/next, copy,
  revert, and stage actions continue to work.

  Content layout follows `diffs-default-view`: the default `split`
  renders the current hunk as aligned old/new columns inside the inline
  popup or posframe, while `stacked` uses the unified presentation.
  This is independent of `diffs-diff-hl-display-function`, which decides
  where that content is displayed.

  The integration mode changes no mouse bindings and does not enable
  diff-hl or its mouse mode. By default it preserves the inline,
  posframe, or other public backend that it replaces; disabling it
  restores that backend. Set `diffs-diff-hl-display-function` to choose
  placement explicitly:

  ```elisp
  (setq diffs-diff-hl-display-function
        #'diff-hl-show-hunk-posframe)
  ```

  Declarative configurations can install the adapter directly instead.
  With no explicit display function this form uses the inline backend:

  ```elisp
  (setq diff-hl-show-hunk-function #'diffs-diff-hl-show-hunk)
  ```

  Use `diffs-file` when you want the complete stacked or split review;
  the compact diff-hl entry intentionally remains a single-hunk view.

- **blame / blame-reveal**: `diffs-commit-at-line` shows the commit
  behind the line you are on.

## Modal editing (meow / evil)

First-party stacked reviews use `diffs-mode`, a read-only major mode
derived from `diff-mode`.  Its native mode map suppresses self
insertion and owns the review bindings, so modal editors can infer a
motion/read-only state without any Meow- or Evil-specific integration.
The split and index modes follow the same view-oriented convention.

`diffs-minor-mode` remains available for arbitrary external
`diff-mode` buffers.  When it is enabled in an editable host buffer,
that host mode and the user's modal configuration continue to decide
its editing state.

## Format handling

Metadata-only Git changes such as renames and mode changes remain
visible instead of being reported as an empty diff.  Quoted Git paths
are decoded for source navigation.  Commit views use a first-parent
two-way diff, including for merge commits, since the UI has an old and
a new side.  A combined diff supplied directly remains visible as raw
metadata instead of being hidden or rejected.

## Development

Run the ERT suite with:

```sh
make test
```

See [ROADMAP.md](ROADMAP.md) for the current feature-gap audit against
diffs.com and the planned development order.
