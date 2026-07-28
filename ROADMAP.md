# Roadmap

This is the current gap audit against the public
[diffs.com documentation](https://diffs.com/docs).  The products are not
identical: diffs.com is a web rendering toolkit, while diffs.el is a
native Emacs viewer built on `diff-mode`.  The roadmap therefore favors
features that improve an interactive Emacs review workflow.

## Already competitive

- Unified and aligned side-by-side views, long-line wrapping, word-level
  refinement, source syntax faces, synchronized scrolling, source
  navigation, hunk/file navigation, folding, theme-native colors, and
  full-height fringe bars.
- Native, cached `word-alt`/`word`/`char` refinement with global
  corresponding-line alignment shared by unified and split views,
  guarded by a multilingual diffs.com conformance corpus and
  randomized minimum-edit validation.
- Sticky file/hunk context and a toggleable changed-file index with
  per-file stats and current-file tracking.
- Lazy expansion of complete unchanged context in unified and
  side-by-side views without modifying the underlying patch.
- Lazy unified rendering and virtualized split presentation for large
  diffs, with complete searchable text and cached side-by-side buffers
  on repeated toggles.
- Stable old/new line-range selection and inline annotations shared by
  stacked and split layouts, including row-aligned split comments.
- Hunk-compatible review sidecars plus compact, machine-readable
  snapshots and atomic agent comment batches.
- Stable live review sessions with a no-file CLI, repository/session-id
  targeting, human/agent comment filtering, and a Codex skill.
- Diffs.com-style accept/reject previews for complete hunks or individual
  change blocks, shared across layouts with explicit unsaved source-buffer
  application.
- In-place stacked merge-conflict resolution with Current, Incoming,
  Both, Reset, diff3 Base display, stable multi-block anchors, and
  normal source-buffer undo.
- A first-class `diff-hl-show-hunk-function` adapter that renders only
  the selected hunk with diffs.el's algorithms while preserving
  diff-hl's inline, posframe, and other public display backends; hunk
  content independently follows the configured split/stacked layout.
- Native access to isearch, copy/yank, `diff-goto-source`,
  `diff-apply-hunk`, and the rest of the Emacs `diff-mode` ecosystem.

## P0 — large-review fundamentals

1. ~~**File index and sticky context.**~~ Completed in 0.5.0.
2. ~~**Expandable unchanged context.**~~ Completed in 0.6.0 with lazy
   old/new file retrieval, incremental expansion to completion, and
   shared unified/split state.
3. ~~**Native corresponding-line and token refinement.**~~ Completed in
   0.7.0 with global monotonic line alignment, diffs.com-style
   `word-alt`, bounded fallbacks, and shared unified/split results.
4. ~~**Virtualized side-by-side rendering.**~~ Completed in 0.8.0 with
   bulk complete-text construction, indexed row metadata, synchronized
   viewport-plus-overscan decoration, lazy source syntax, and lazy
   within-line emphasis.

## P1 — review actions

5. ~~**Line/range selection and annotations.**~~ Completed in 0.12.0:
   stable file/side/line identities,
   keyboard range selection, aligned inline annotations, Hunk-compatible
   sidecars, compact agent snapshots, atomic batch comments, and direct
   live-session access for coding agents.
6. ~~**Accept/reject change blocks.**~~ Completed in 0.12.0 with
   per-block and whole-hunk decisions, shared stacked/split previews,
   result line-number adjustment, reset, exact source validation, and
   explicit unsaved application.
7. ~~**Merge-conflict view.**~~ Implemented for the unreleased 0.13.0
   with an in-place source-buffer presentation,
   Current/Incoming/Both/Reset transitions, smerge-backed standard
   operations, two-way and diff3 parsing, stable multi-block anchors,
   exact stale checks, atomic rollback, and normal unsaved undo.

## P2 — extensibility and polish

8. **Token interaction hooks.**  Expose token hover/click positions so
   Eldoc, Xref, and LSP clients can provide definitions and hover data.
9. **Asynchronous syntax work and render caching.**  Move expensive
   old-revision fontification off the command path and cache it by
   revision, file, language, and theme.
10. **Mixed file/diff items and public layout hooks.**  Support unchanged
   source-file items beside patches and make file headers, gutters, and
   hunk separators replaceable without advising internals.

The next implementation target is P2.8: source-coordinate token
interaction hooks for Eldoc, Xref, and LSP clients.
