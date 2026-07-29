# Converged review entry

## Decision

Diffs.el does not add a separate `diffs-patch` command. Opening a `.diff` or `.patch` file selects `diffs-mode`, and `diffs-mode` initializes the common renderer itself. The existing `diffs-file`, `diffs-project`, `diffs-commit`, and `diffs-items` producers pass their source and refresh context into that same major-mode initialization path.

`diffs-minor-mode` remains public only as the integration boundary for buffers owned by another package that already use `diff-mode`. It is not a second patch-review product or parser.

Conflicted source buffers retain their language major mode, so their converged entry is `diffs-conflict-mode`. The mode itself validates conflicts, installs the stacked presentation, and moves to the first block. There is no separate `diffs-conflicts` wrapper.

## Why

Patch provenance should not create parallel review workflows. File, project, commit, mixed-item, file-backed patch, and externally generated diff buffers all consume the same unified patch scanner, row model, renderer, commands, and derived split views. `diff-mode` remains the protocol parent responsible for patch navigation and application.

Making `diffs-mode` self-contained also removes an invalid intermediate state in which calling the public major mode produced a read-only buffer without diffs.el rendering until a separate minor-mode activation occurred.

Making `diffs-conflict-mode` the direct public entry likewise removes a wrapper that owned no state and differed only by moving point after mode activation.

## Alternatives rejected

- A new `diffs-patch` command would duplicate file opening and make users choose an entry based on patch provenance.
- A separate `diffs-conflicts` command would duplicate the conflict minor mode's activation lifecycle.
- Globally remapping every `diff-mode` buffer to `diffs-mode` would make process- or package-owned buffers read-only and replace their major-mode ownership.
- Installing a global `diff-mode-hook` while loading the package would mutate user behavior implicitly.
- Delaying a split with a timer or display-order assumption would make window behavior timing-dependent.

## Initial layout

First-party commands own a window presentation transaction and continue to honor `diffs-default-view`, including the default split layout and complete `q` restoration.

File mode selection runs while `find-file-noselect` may still be preparing an undisplayed buffer, so `diffs-mode` does not mutate windows from major-mode initialization. A `.diff` or `.patch` file therefore starts as the native stacked owner and uses the same `s` command to enter split view.

## Invariants

- The unified patch text remains unchanged.
- `diffs-mode` is derived from `diff-mode`.
- One unified buffer owns scan and review state.
- Split buffers remain derived views.
- External `diff-mode` buffers stay editable when using `diffs-minor-mode`.
- Conflict review stays in the source language major mode and is owned by `diffs-conflict-mode`.
