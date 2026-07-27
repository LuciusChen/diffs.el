# diffs.el

Fast, pretty file-level diff viewing for Emacs, inspired by
[diffs.com](https://diffs.com/).

A rendering layer on top of `diff-mode`: old/new line-number columns,
no `+`/`-` marker noise, compact styled file and hunk headers,
full-width line backgrounds, word-level refinement, lazy
source-language syntax highlighting, and a two-window side-by-side
view with synchronized scrolling.

Pure Elisp — no external renderer. Compared to delta/magit-delta:

- No renderer subprocess and no ANSI parsing.  (The commands still use
  VC/Git to produce their input.)  Opening a diff costs one cheap scan
  (≈20 ms for 22k lines / 800 files); on large diffs even the decorations
  are applied lazily through jit-lock, so only what you see is rendered.
- The diff text is never modified: `diff-goto-source` (RET), isearch,
  `diff-apply-hunk` and the rest of diff-mode keep working; line
  numbers live in `line-prefix`, so copying and searching stay clean.
- Theme-native: everything inherits from the standard `diff-*` faces.
- Revision-aware syntax highlighting: the old side is fontified from
  the file contents at the reference revision.

## Commands

| Command | Description |
|---|---|
| `diffs-file` | Current file vs the reference revision (includes unsaved changes when diff-hl is available) |
| `diffs-project` | Whole project vs the reference revision |
| `diffs-commit` | Show a commit (Git) |
| `diffs-commit-at-line` | Show the commit that last touched the current line |
| `diffs-minor-mode` | Use the renderer in any diff-mode buffer |

Inside the unified view: `n`/`p` hunks, `N`/`P` files, `TAB` folds on
headings, `RET` jumps to source, `s` toggles the side-by-side view,
`g` refreshes, `q` quits.

## Side-by-side view

`s` splits the frame into two synchronized windows — old on the left,
new on the right — with row-perfect alignment (dimmed filler bands pad
insertions and deletions), per-side line numbers, and the refinement
and syntax faces carried over from the unified view.  `n`/`p` move by
hunk in both windows, `RET` visits the source, `q` or `s` returns to
the unified view and restores the window layout.

Long lines wrap to aligned physical rows, so one side never drifts away
from the other.  Set `diffs-split-wrap-lines` to nil to use truncated
lines and horizontal scrolling instead.

Very large diffs split instantly without up-front whole-buffer
fontification (see `diffs-split-fontify-threshold`).  Refine and syntax
faces from the visible region are retained; alignment, diff colors and
line numbers are available throughout.

## Performance knobs

- `diffs-lazy-threshold` — above this many lines, decorations are
  applied per-region from jit-lock instead of eagerly.
- `diffs-split-fontify-threshold` — above this many lines, the split
  view fontifies the visible region instead of the whole buffer.
- `diffs-split-wrap-lines` — wrap long split rows with aligned fillers.

## Integrations

- **diff-hl**: `diff-hl-reference-revision` is respected, so
  `diff-hl-set-reference-rev-in-project` gives you a branch-point
  ("PR") view here too.  Bind `diffs-file-from-hunk` in
  `diff-hl-show-hunk-map` to expand the hunk popup into the file view:

  ```elisp
  (with-eval-after-load 'diff-hl-show-hunk
    (keymap-set diff-hl-show-hunk-map "o" #'diffs-file-from-hunk))
  ```

- **blame / blame-reveal**: `diffs-commit-at-line` shows the commit
  behind the line you are on.

## Modal editing (meow / evil)

The unified view is a `diff-mode` buffer; modal editors typically put
it in their normal state, shadowing the view's `s`/`n`/`p`/`q` keys
(their state keymaps sit in `emulation-mode-map-alists`, above any
minor mode).  Either invoke the commands by name (`M-x
diffs-toggle-split` etc.), or give diff buffers a passthrough state —
for meow:

```elisp
;; Read-only diffs get motion state so the view's keys work; the
;; editable staging buffer stays normal and must match first.
(add-to-list 'meow-mode-state-list '(diff-mode . motion))
(add-to-list 'meow-mode-state-list '(diff-hl-stage-diff-mode . normal))
```

The side-by-side buffers derive from `special-mode` and already get
motion state by default.

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
