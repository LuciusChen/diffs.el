# In-place merge-conflict resolution

## Problem

A merge conflict is not an ordinary patch decision.  The useful
preview is the resulting source file itself, and the user must be able
to switch one block among Current, Incoming, Both, and the original
unresolved marker form.  Reusing the normal review-decision model would
introduce a second result projection, duplicate source coordinates, and
delay feedback until a separate apply step.

Replacing the source major mode with a dedicated review major mode
would also discard the language buffer's syntax, Eldoc, Xref, and LSP
state. Smerge already owns the standard conflict grammar and ordinary
Current/Incoming operations, but it has no reset operation and its
keep-all action includes the base section of a diff3 conflict.

## Decision

`diffs-conflicts` enables a source-buffer-local
`diffs-conflict-mode`.

- The source buffer remains in its language major mode.  A minor mode
  adds a stacked action row and theme-native Current, Base, Incoming,
  marker, and resolved-state overlays.
- Parsing is completed and validated before mode state or overlays are
  installed. Standard seven-character conflicts adopt
  `smerge-match-conflict` coordinates; Current and Incoming delegate to
  `smerge-keep-upper` and `smerge-keep-lower`. Wider markers and a final
  marker without a newline use the strict native fallback. Malformed
  and nested conflicts are rejected without mutation.
- Each block owns insertion-aware beginning and ending markers plus
  immutable original, Current, Base, and Incoming strings.
- Current, Incoming, Both, and Reset all use the same exact-content
  transaction. Two-way Both delegates to `smerge-keep-all`; diff3 Both
  composes smerge's upper/lower match ranges so Base is never included.
  Reset restores the complete original marker block, including labels.
  Switching an already resolved standard block restores its original
  syntax and invokes the new smerge operation inside the same atomic
  edit.
- Every transition is one atomic, undoable source-buffer edit.  It does
  not save the file, write the index, or run a VCS command.
- Before replacing a block, its live text must equal the state recorded
  by diffs.el.  Manual or external edits therefore cannot be silently
  overwritten.
- Overlay reconstruction participates in the transition boundary.  A
  rendering error restores the prior source text, choice, modified
  state, and presentation.
- Existing `smerge-mode` state is neither enabled nor disabled, and
  smerge auto-leave is suppressed during delegated operations.
  Conflict overlays owned by smerge are cleared only in the replaced
  region and its fontification is allowed to rebuild normally.

The source remains editable, so bare `c`, `i`, `b`, and `u` are not
captured.  Commands live under the package prefix `C-c C-d`; the
displayed action row also exposes mouse actions.

## Alternatives

- A copied `special-mode` preview would give review-oriented key
  routing, but it would duplicate the file, require a later apply
  transaction, and make source token/LSP coordinates indirect.
- An indirect buffer would share text but still require replacing the
  language mode's local map or adding high-precedence key routing.
- Reusing ordinary diff accept/reject decisions would couple conflict
  markers to patch hunks, split caches, and refresh regeneration even
  though none of those objects owns the conflicted source.

## Invariants

- The language major mode, file identity, buffer object, syntax state,
  and unrelated unsaved edits are preserved.
- No action saves, stages, or invokes Git.
- A block can move Current → Incoming → Both → Reset in any order.
- Base is visible for diff3 input but absent from every resolved result.
- Earlier length-changing choices cannot invalidate later block
  coordinates.
- Disabling the mode removes only diffs.el presentation state; chosen
  source edits remain normal unsaved buffer changes and remain
  undoable.
