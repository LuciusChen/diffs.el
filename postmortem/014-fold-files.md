# Folding files

## Decision

A file can be folded to its header in both views, and files that match `diffs-collapsed-files` open folded when a review holds more than one file. The default patterns are lock files, whose diffs are long and rarely read.

- The state is outline's own. A file is folded when the first hunk header of its `diff --git` entry is hidden, which is what `outline-hide-subtree` and the folded step of `outline-cycle` do. Showing only the hunk headings, or hiding only the text before the first one, is not a folded file. A section that does not start on an outline heading or has no hunks, such as a rename or a plain unified file, cannot fold as a unit.
- The stacked view needs only one change for this. The file header display now ends before the header block's final newline. Redisplay shows the display string of hidden text when it reaches that text directly after another display string, so with the old extent the first hunk separator was drawn inside a folded file, followed by the fold ellipsis. With a real newline at the boundary the line ends with the ellipsis and nothing of the hunks is drawn. Unfolded files render exactly as before.
- The split view derives its rows from the owner. A folded file contributes its header row and one note row, `⋯ N hidden lines · press [TAB]`, and no row is built for its hunks. The note row keeps the file visible when a custom `diffs-file-header-function` returns nothing. The split cache key carries the list of folded files, because a fold changes the rows without touching the text.
- `TAB` in a split buffer folds or unfolds the file at point. It changes the owner and rebuilds the pair with the same quit, change, reopen sequence that `e` uses, and leaves point on the file's first row.
- Refresh keeps what it knew. The snapshot records, for each file that appears once, whether it was folded, and whether it was open although `diffs-collapsed-files` would fold it. The defaults apply only to files the snapshot does not mention, so a lock file opened by hand is not closed again by `g`. A failed refresh refolds from the same snapshot.
- A review of a single file never opens folded, because that file was asked for by name.
- Commands that move to a target inside a folded file show the file first: Imenu hunk entries, `[` and `]` between comments, and entering a diff at a source line when point lands inside a hunk. In the split view this rebuilds the pair.
- Disabling `diffs-minor-mode` shows the folded files and leaves other outline folds to the user.

## Why

Reviewing a large diff showed that a lock file is the common huge hunk, and the cheapest way to make it cost nothing is not to build it. Compiled code on Emacs 30.2, one generated lock file with a single hunk next to five small source files:

| Lock file lines | First split before | First split folded |
|---:|---:|---:|
| 1,000 | 45 ms | 2.6 ms |
| 5,000 | 171 ms | 2.6 ms |
| 20,000 | 646 ms | 3.0 ms |

For 4,000 files with nothing to fold, enabling the mode takes about 6 ms longer, and a cached layout toggle about 3 ms longer.

Folding by file also answers the request for it: a reviewer reads the source and skips generated output. Outline already folds the stacked view, so using it as the state keeps `TAB` on a heading, `S-TAB`, isearch, and the new commands in agreement.

## Alternatives rejected

- Mark the rows of a folded file invisible in the split buffers. Rows would still be collected and sized for the whole file, and a viewport moving past a large invisible range would decorate it.
- Keep a set of folded files with a second invisibility spec. The two views would then disagree with `TAB` on a heading, which folds through outline.
- Redraw the stacked header with a hidden-line count whenever outline changes a fold. That needs `outline-view-change-hook`, which is obsolete since Emacs 29.1, and the fold marker already shows that the file is folded. The statistics in the header say how much changed.
- Bind `TAB` in the stacked maps. `diff-mode` gives it `diff-hunk-next`, the heading keymap of outline already overrides it on headings, and `diffs-minor-mode-map` must not take it from editable diff buffers. Only the split map, which has no outline, gained a binding.
- Fold when a file is first drawn only. Without refresh memory, `g` would close a lock file the reviewer had opened.

## Consequences

- `TAB` is now bound in `diffs-split-mode-map`, so `diffs-context-bindings-expand-in-steps` allows it there and still requires `TAB` and `<backtab>` to be unbound in `diffs-minor-mode-map`.
- New code that enumerates the hunks of a section for the split must skip folded sections, as `diffs--split-collect`, `diffs--split-paged-index`, and `diffs--split-estimated-row-count` do.
- Review state in a folded file, comments and selection, has no row to be drawn on in the split view. It is kept in the owner and returns when the file is shown.

## Limits

- A file folds as a unit only when its section starts on an outline heading, which `diff-mode` gives `diff --git` lines in Git-format patches. In other patches, such as `Index:` sections or a plain unified diff, the hunks fold one by one as before. Outline may take a bare `+++` line as a file heading there, but diffs.el draws that line inside the rendered header, so the file fold does not reach the split view.
- The split view folds files, not hunks.
- The changed-file index does not mark folded files.
- Refresh matches files by name. A file that appears twice in one review, as mixed items can, takes the defaults again.
