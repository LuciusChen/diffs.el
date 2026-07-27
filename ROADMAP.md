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
- Sticky file/hunk context and a toggleable changed-file index with
  per-file stats and current-file tracking.
- Lazy unified rendering and visible-region fontification for large
  diffs, with cached side-by-side buffers on repeated toggles.
- Native access to isearch, copy/yank, `diff-goto-source`,
  `diff-apply-hunk`, and the rest of the Emacs `diff-mode` ecosystem.

## P0 — large-review fundamentals

1. ~~**File index and sticky context.**~~ Completed in 0.5.0.
2. **Expandable unchanged context.**  Retain or retrieve complete file
   contents so collapsed gaps can expand by a few lines or all the way
   to the next hunk.
3. **Virtualized side-by-side rendering.**  Render only the visible
   split rows plus overscan, preserving wrapped-row measurement and
   scroll synchronization.  This is the remaining large-diff
   performance advantage of diffs.com's `CodeView`.

## P1 — review actions

4. **Line/range selection and annotations.**  Add stable file/side/line
   identities, keyboard range selection, and an annotation API suitable
   for comments or diagnostics.
5. **Accept/reject change blocks.**  Promote the existing
   `diff-apply-hunk` integration into explicit per-block actions,
   including partial hunks and clear success/failure feedback.
6. **Merge-conflict view.**  Parse conflict markers and offer
   current/incoming/both choices with an editable result preview.

## P2 — extensibility and polish

7. **Token interaction hooks.**  Expose token hover/click positions so
   Eldoc, Xref, and LSP clients can provide definitions and hover data.
8. **Asynchronous syntax work and render caching.**  Move expensive
   old-revision fontification off the command path and cache it by
   revision, file, language, and theme.
9. **Mixed file/diff items and public layout hooks.**  Support unchanged
   source-file items beside patches and make file headers, gutters, and
   hunk separators replaceable without advising internals.

The next implementation target is P0.2: expandable unchanged context.
