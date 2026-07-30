# diff-hl show-hunk renderer

## Problem

The first diff-hl bridge replaced four mouse bindings and then called
`diffs-file`.  It bypassed diff-hl's public renderer extension point,
gave mouse and keyboard show-hunk commands different behavior, and
computed the same file diff again after diff-hl had already prepared it.
The separate popup-to-file command added a third entry into the same
review workflow.

## Decision

`diffs-diff-hl-show-hunk` implements the public
`diff-hl-show-hunk-function` contract as a rendering adapter.  It uses
the complete patch supplied by diff-hl to run diffs.el's normal scan,
line pairing, source syntax, and word refinement, but materializes only
the narrowed current hunk back into diff-hl's buffer.  The raw unified
patch text remains unchanged, so diff-hl can still copy, revert, stage,
and navigate the hunk.

The decorated hunk is then passed to a public diff-hl display backend.
`diffs-diff-hl-display-function` can select inline or posframe
explicitly.  When it is nil, `diffs-diff-hl-mode` preserves the renderer
that it replaced; direct configuration falls back to diff-hl's inline
renderer.  Thus diffs.el owns hunk appearance while diff-hl continues
to own placement, controls, and cleanup.  No diff-hl private variable
or function is read.

Placement and content layout are independent.  The selected diff-hl
backend decides whether the hunk lives inline or in a posframe;
`diffs-default-view` decides whether that hunk is rendered stacked or
side by side.  Split hunk previews reuse the first-party aligned row
model and a private display-carrier buffer, leaving diff-hl's supplied
unified patch buffer unchanged for its lifecycle and actions.

`diffs-diff-hl-mode` is an optional global convenience mode.  It saves
and restores `diff-hl-show-hunk-function`; it does not alter a margin or
fringe keymap.  Users who prefer declarative configuration can instead
set the renderer variable directly.

The adapter does not open a file-level review, replace windows, or
change source point.  Full-file review remains the separate
`diffs-file` workflow.

The presentation implementation lives in the optional `diffs-diff-hl.el` module. The package entry file retains only public autoloads and the configuration declaration needed to preserve `require` behavior for package and manual `load-path` installations. Core diff-hl reference-revision and unsaved-file input handling remain in `diffs.el` because they are data-source behavior of `diffs-file` and `diffs-project`, not show-hunk presentation.

## Superseded alternatives

- Replacing diff-hl's four mouse bindings made a click fast to route but
  duplicated a public upstream dispatch mechanism and left
  `diff-hl-show-hunk` on a different UI.
- Opening a full diffs.el review from the show-hunk callback conflated a
  compact hunk preview with file review and discarded the user's
  inline/posframe preference.
- Ignoring the supplied buffer and calling `diffs-file` was simpler but
  repeated diff generation on every click.

## Boundaries

- Loading diffs.el changes no diff-hl state.
- Enabling `diffs-diff-hl-mode` does not enable diff-hl, its fringe
  indicators, or its mouse mode.
- The integration uses only `diff-hl-show-hunk-function`, public diff-hl
  display backends, and the buffer passed through the renderer callback.
- Diff-hl retains its normal inline/posframe controls and lifecycle.
  Full review, context expansion, comments, and resolution actions
  remain first-party diffs.el workflows.
