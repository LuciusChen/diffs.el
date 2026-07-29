# diffs.el Development Guide

Elisp and package-development rules adapted from the clutch development guide for diffs.el.

## Product Scope

- diffs.el is a native Emacs diff viewer and review surface built on `diff-mode`.
- The underlying unified patch is the source of truth. Rendering must not rewrite patch text or break `diff-goto-source`, isearch, copying, hunk application, or other `diff-mode` behavior.
- First-party stacked reviews use the read-only `diffs-mode`, derived
  from `diff-mode`; `diffs-minor-mode` remains the renderer integration
  for arbitrary external diff buffers.
- The unified buffer owns scan results, source revisions, expanded context, caches, the changed-file index, and derived split buffers.
- Split buffers are derived views. They must share one row/refinement model, stay synchronized, and never become a second independent parser or state owner.
- Optimize for interactive Emacs review. Do not copy unrelated pager breadth from delta when Emacs already provides the workflow.

## Core Principles

- Question every abstraction. Add layers, files, or indirection only for a current problem with clear ownership.
- A refactor must improve simplicity, robustness, performance, extensibility, test value, or code size. Renaming or moving code alone is not enough.
- Make abstractions pay for themselves by centralizing a rule, removing duplication, or simplifying callers.
- Treat stacks of tiny wrappers, one-use helpers, and repeated accessors as structural debt. Improve the state or ownership model instead of adding more glue.
- Prefer lightweight Elisp shapes: `let*`, `pcase-let`, lists, plists, vectors, and hash tables. Use `cl-defstruct` only for stable state crossing real lifecycle or module boundaries.
- Delete unused code. Do not add compatibility shims or deprecated aliases without an actual supported compatibility requirement.
- Prefer one behavior model across unified and split views. Commands may differ only at the thin presentation boundary.
- Keep experiments narrow. Prove the smallest useful workflow before expanding it.

## Diagnosis and Change Discipline

- Find the responsible layer before changing behavior. Be able to explain whether a failure belongs to scanning, row modeling, line pairing, syntax/refinement, split rendering, window synchronization, cache invalidation, or command routing.
- One failed fix narrows the hypothesis. Gather evidence before changing another layer.
- After two failed fixes on the same issue, stop speculative patching and switch to diagnosis.
- Fix ownership errors at their source. Do not compensate for a bad row model in window code or hide stale cache state in rendering code.
- Before changing a primary entry point, default layout, key binding, or review workflow, write a short design note.
- Inspect local code, tests, documentation, and relevant upstream implementations before asking questions that the repository can answer.
- Record wrong-layer compensation, broad `condition-case nil`, reparsing of displayed text, timing hacks, and silent fallbacks as design debt. Do not expand the current change merely because nearby debt was found.

## Architecture and Rendering

- Keep pure computation separate from buffer and window mutation.
- Build rendering from parsed/cached data, not by reparsing decorated display text.
- Store stable data-bearing annotations as text properties or explicit row metadata. Use overlays for ephemeral visuals such as unified within-line emphasis and selections.
- Preserve syntax faces above line backgrounds and within-line emphasis above both.
- The split row model must carry stable file, hunk, side, source-line, change-kind, and logical-row identity.
- A split cache key must include every option or state value that changes rendered output.
- Cache invalidation must be explicit when the patch tick, window width, wrapping, theme-relevant faces, source revision, context expansion, or line-diff options change.
- Large reviews must be lazy. Parse/index cheaply, render visible regions plus overscan, and cache completed work.
- Virtualization must preserve complete searchable/copyable text. Do not trade away normal Emacs search, copying, source navigation, or position restoration for a faster first frame.
- Default non-wrapping split is the primary fast path. Configurable aligned wrapping must remain correct even if it needs a separate measurement path.
- Expanded context remains display-backed and must not mutate the underlying patch.
- Source syntax work must not run mode hooks, local variables, or local eval from historical file contents.
- Do not call private symbols from external packages. If needed behavior has no public API, add a local implementation or request a public upstream API.
- Loading diffs.el must not enable modes, install editing hooks, open buffers, or otherwise change user editing behavior.
- Declarative registration at a real package boundary is allowed at load
  time, including mode associations, backend/action registrations, and
  cleanup hooks.  Runtime activation remains explicit.
- Reuse stock Emacs infrastructure: `diff-mode`, `special-mode`, jit-lock/font-lock, standard hooks, standard window APIs, and standard completion/navigation primitives.
- Keep target resolution, action definitions, and action presentation
  separate.  Menus, prefix-command UIs, and optional integrations must
  not become independent business-logic paths.

## Implementation Style

- Public names use `diffs-`; private names use `diffs--`.
- Multi-word predicate names end in `-p`.
- Prefix intentionally unused arguments with `_`.
- Use `defvar-local` for buffer state, plain `defvar` for shared state, and `defcustom` for user options.
- All `defcustom` forms must specify a precise `:type` and `:group`.
- Major modes keep their state buffer-local.  New non-editing UI modes
  normally derive from `special-mode`; modes that implement an existing
  Emacs protocol, such as the primary diff view, derive from that
  protocol's appropriate parent.
- Register mode hooks buffer-locally with the LOCAL argument set to `t`.
- Prefer flat control flow with `when-let*`, `if-let*`, `pcase`, and `pcase-let`.
- Prefer destructuring a row once over repeated `nth` or `plist-get` calls.
- Prefer `cl-loop` for non-trivial accumulation and `vconcat` for vector construction.
- Prefer idiomatic primitives over reconstructed equivalents.  Return
  predicate values directly and do not wrap them in redundant
  `(not (null ...))` forms.
- Keep interactive commands thin and route them through shared non-interactive state transitions.
- Use `user-error` for user-caused problems and `error` for violated programmer invariants.
- Catch recoverable errors only at a real boundary. Do not silently swallow internal failures.
- Do not wrap standard errors unless the wrapper adds semantics or
  behavior that its docstring explains.
- Error messages describe the current problem rather than prescribing an unrelated command.

## Completion and Emacs Protocols

- Use `completing-read` for interactive selection unless a concrete
  product requirement needs a custom reader.
- Completion-at-point functions compute bounds and candidates directly
  and return the standard CAPF shape.  Do not add a separate completion
  context model until multiple real callers share it.
- CAPFs must return quickly, use `:exclusive 'no` when they should compose
  with other sources, and avoid synchronous work that can re-enter or
  block the UI.
- Add CAPFs and similar protocol hooks buffer-locally.

## Dependencies and Module Boundaries

- Require runtime dependencies explicitly; `cl-lib` use requires
  `(require 'cl-lib)`.  Do not rely on transitive loading or
  `eval-when-compile` for runtime contracts.
- Use `declare-function` or `defvar` only for an intentionally lazy or
  cyclic boundary whose owner is not loaded during byte compilation.
  Do not duplicate declarations already supplied by a mandatory
  top-level `require`.
- A declaration that lets a lower-level module call upward, or reaches an
  external private symbol, is a boundary smell.  Move the interface to
  its owner or expose a public API.
- Optional dependencies load only at the point of use.  Document them
  separately and report a clear boundary error or warning when their
  required public API is unavailable; do not silently downgrade or call
  private APIs.
- Compatibility shims stay under the `diffs--` prefix.  When an upstream
  function exists, prefer a prefixed `defalias` over an unprefixed
  replacement that confuses package tooling.
- Avoid `with-eval-after-load` unless it registers an optional
  integration at a clear package boundary.

## UX Contracts

- New views open split by default; `diffs-default-view` may select stacked.
- In split view, `q` quits both columns and the complete diff; `s` returns to stacked.
- In stacked view, `s` enters split.
- Split long lines truncate by default; wrapping is configurable.
- `e` is the sole unchanged-context control in stacked and split views.
  Expansion is one-way and the separator disappears when complete;
  `TAB` remains available for the separate hunk/outline folding action.
- `A`, `R`, and `U` resolve or reset the change block at point; a prefix
  applies the action to the complete hunk. `C-c C-c` explicitly applies
  reviewed results to source buffers without saving or staging them.
- Merge conflicts are resolved directly in the language source buffer.
  Current, Incoming, Both, and Reset live below `C-c C-d`; each is one
  guarded undoable edit and never saves or stages the file. Both excludes
  diff3 Base, and Reset remains available after every block is resolved.
- Rebuilds preserve side, file, hunk, source line, row kind, line number, column, and visible window position when those identities still exist.
- Split scrolling remains horizontally, vertically, and pixel-synchronized;
  paired cursor motion preserves rows and display columns, while `C-a` and
  `C-e` target each side's own logical line edge.
- Word-level results are shared by stacked and split. Do not reintroduce Emacs whole-hunk refinement as a competing source of truth.
- Keep modal-editor integration generic. Do not add Meow- or Evil-specific key handling unless the package exposes a genuinely package-specific integration point.
- Native first-party review modes use suppressed, view-oriented major
  mode maps so modal editors can infer motion semantics without package
  integration; do not register diffs.el above user emulation maps.
- Theme behavior inherits standard `diff-*` and font-lock faces. Avoid fixed palette assumptions.

## Error Handling and Testing

- Tests must fail when the behavior under test is broken. Assert specific identities, ranges, faces, alignment, or state transitions.
- Test public/installed dispatch paths for command routing, hooks, scrolling, context expansion, and layout restoration bugs. Helper tests supplement but do not replace workflow tests.
- Match test weight to change size. Do not create heavy tests for cosmetic copy or padding unless it is a product contract or a known regression.
- Keep tests that prove public workflows, invariants, meaningful boundaries, and prior regressions. Avoid tests that merely mirror implementation details.
- Use diverse inputs: unequal line counts, reordered candidates, whitespace, punctuation, camelCase, CJK, emoji/combining text, long lines, metadata-only changes, renames, commits, and large diffs.
- For algorithm work, include boundary or randomized validation when a hard-coded implementation could satisfy a small fixture set.
- For a user-visible bug, reproduce it with a failing test before fixing it unless an existing test already exercises the real path.
- Performance work must report the baseline, identify the measured layer, and run `make benchmark`. Do not optimize only a synthetic cache hit; benchmark inputs should contain distinct replacements.

## Performance Budgets

- Keep scanning linear in patch size.
- Avoid one buffer mutation per offscreen row when bulk insertion or cached metadata can express the same state.
- First split is the primary performance target; cached layout toggles must remain effectively immediate.
- Large-diff syntax and within-line rendering must remain visible-region bounded.
- Any material regression in the 800-file/22,000-line benchmark requires an explanation and explicit user-value tradeoff.
- Optimize user-perceived first frame before total background completion, without making later scrolling unpredictable.

## Version and Compatibility Baseline

- diffs.el targets Emacs 29.1+.
- Do not use Emacs 30+ APIs without a version guard or local compatibility path.
- Do not silently raise the Emacs baseline. Update package metadata, README, changelog, and a design record when a higher baseline is justified.
- Keep the package pure Elisp. Git/VC may produce source input, but rendering must not require an external renderer subprocess.

## MELPA and Documentation Discipline

- The package entry file owns package metadata and must retain lexical binding, author, URL, version, requirements, keywords, and a proper footer.
- User-facing commands and modes need `;;;###autoload`; private helpers do not.
- Do not autoload variables, internal helpers, or private modes.
- Every public function, macro, option, variable, and face needs a useful docstring.
- Docstring first lines are complete sentences; argument names are uppercase.
- Every distributable Elisp file enables lexical binding, provides its
  feature, and ends with the matching `;;; file.el ends here` footer.
- The main file's short package description stays under 60 characters
  and does not repeat the package name or say “for Emacs.”
- Main-file `Package-Requires` lists every direct runtime dependency,
  including the Emacs baseline, with its minimum supported version.
- Split implementation files do not duplicate `Package-Requires`; they
  retain formal license metadata, preferably an SPDX identifier.
- Configure package-lint with the main package file when checking split
  implementation files.
- Keep required package attribution such as `Assisted-by` in the main
  package file when tooling materially assisted the package.
- Every key-binding, default, configuration, performance, or user-workflow change updates `README.md` in the same change.
- Every release-relevant feature, bug fix, default, or public behavior change updates `CHANGELOG.md`.
- Use `Unreleased` while a version is still being tested. Date it only when intentionally cutting the version.
- Code is the source of truth when docs diverge; update docs immediately.
- Keep each semantic Markdown paragraph on one source line and let the renderer wrap it. Do not rewrap unchanged prose merely to fit a source-width column.
- Fix information structure before line breaks: prefer focused headings, tables, short lists, and local rewrites over cosmetic source reflow.
- For substantial README changes, make the opening explain what diffs.el is, who it serves, what problem it solves, and what the reader should do next. Keep Installation and Quick Start easy to find.
- Lead with concrete user outcomes before implementation details. Avoid vague promotional claims, feature dumping, unnecessary badges, and calls to action.
- Verify every documented command, capability, compatibility claim, metric, benchmark, and trust signal against code, metadata, tests, workflows, or release records. Clearly mark anything that remains unverified.
- Keep documentation-only work documentation-only. Do not change product code, configuration, CI, or dependencies merely to make a documentation claim true unless the user explicitly requests it.
- Significant workflow or architecture decisions should have a short record under `postmortem/` explaining why, alternatives, tradeoffs, deferred limits, and superseding decisions.

## Required Checks Before Commit

1. Read the complete diff:

   ```bash
   git diff HEAD
   git diff --check
   ```

2. Run the full automated checks:

   ```bash
   make check
   ```

3. For rendering, caching, alignment, scrolling, or large-review changes:

   ```bash
   make benchmark
   ```

4. Byte-compile every distributable Elisp file with zero warnings.

5. Run checkdoc across every distributable Elisp file with zero warnings.

6. Run package-lint with zero warnings for distributable package files.

7. Confirm no external package private APIs were introduced and no generated `.elc` or temporary artifacts entered the worktree.

8. Update tests, README, changelog, and any required design record in the same change.

9. Do not commit or push until the user has completed the requested hands-on version test and explicitly approved it.
