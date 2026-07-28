# Native stacked-mode key routing

## Problem

First-party stacked reviews used `diff-mode` plus
`diffs-minor-mode`.  This kept the renderer reusable, but it left the
buffer with the editing semantics of ordinary `diff-mode`.  Modal
editors therefore reasonably selected their normal/editing state, whose
emulation keymap has higher precedence than any minor- or major-mode
map.  Plain review keys such as `e`, `g`, and `q` never reached
diffs.el.

Split and index views did not have this problem because their dedicated
major modes inherit the read-only semantics of `special-mode`.  Clutch
result buffers follow the same native pattern.

## Decision

First-party stacked reviews use a dedicated `diffs-mode` derived from
`diff-mode`.

- `diffs-mode-map` inherits `diff-mode-map`, suppresses self insertion,
  and owns the stacked review bindings.
- `diffs-mode` remains derived from `diff-mode`, so source navigation,
  hunk application, outline folding, font locking, and the rest of the
  standard diff ecosystem remain available.
- `diffs-minor-mode` continues to provide rendering and commands for
  arbitrary external `diff-mode` buffers.  Such editable buffers retain
  their host mode's normal key-routing policy.
- Package-created buffers enter `diffs-mode` before revision metadata is
  installed, then enable `diffs-minor-mode` after that metadata is ready.

This is ordinary Emacs major-mode behavior.  No Meow-, Evil-, or other
modal-editor API is called.  A modal editor can infer a motion/read-only
state from the suppressed native map, while users remain free to
override that state or its keys globally.

## Alternatives

- Registering an emulation map would force diffs.el above every modal
  editor and other high-precedence package.  That is too invasive.
- Modifying `diff-mode-map` would leak review bindings into unrelated
  diff buffers and would still sit below a modal editor's normal map.
- Adding a Meow state rule in diffs.el would solve one editor rather
  than fixing the buffer's native semantics.

## Invariants

- `derived-mode-p` continues to report `diff-mode` in stacked reviews.
- `TAB` remains available to outline folding on hunk headings.
- Split and stacked commands keep the same user-facing bindings.
- Enabling `diffs-minor-mode` manually does not make an editable external
  diff buffer suppress self insertion.
