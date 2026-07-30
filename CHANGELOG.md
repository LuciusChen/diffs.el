# Changelog

## Unreleased (0.13.0)

- Add a standard Imenu file → hunk hierarchy to project, commit, mixed-item, and other multi-file reviews. Selecting an entry preserves stacked or split layout, paged splits materialize only the target chunk, and repeated mixed-item paths retain exact stable item identity.
- Make sticky file/hunk headers truly per-window, restore any replaced window header when diffs.el releases it, and restore the complete external diff-buffer state when `diffs-minor-mode` is disabled. Split rows now carry their exact owning section so duplicate mixed-item paths, refresh restoration, token lookup, and navigation cannot collapse onto the first file match.
- Prevent a transient source-mode fontification failure from permanently poisoning the shared render cache with unhighlighted text, version cache identities so stale live reviews retry, repaint expanded context with syntax faces when its idle render completes, and publish those faces into read-only split buffers without signaling or changing their modified state.
- Lead default file headers directly with their file-type icon instead of a decorative horizontal rule, make stacked and split sticky headers reuse the same public file-header renderer, and give collapsed unchanged-context rows compact directional Octicons chevrons with Unicode fallbacks, `up`/`down` public context, and an understated `press [e] +N` hint.
- Show the sticky file/hunk header only after the in-content file header scrolls away, reclaiming the header-line row at each visible file boundary in stacked and split views.
- Add optional, width-aware nerd-icons file-type icons to default file headers, sticky headers, renamed paths, and the changed-file index, with text-only fallback and a `diffs-file-icons` toggle.
- Preserve source-language syntax foregrounds on changed split rows instead of copying diff-mode's added/removed presentation face above them.
- Move the optional diff-hl show-hunk presentation adapter into the lazily loaded `diffs-diff-hl.el` module. Requiring `diffs` still installs the same public command autoloads, while core file/project reference handling remains available without loading presentation integration code.
- Keep stacked decoration lazy above `diffs-lazy-threshold` even when
  `font-lock-mode` was disabled by `so-long-mode` or another large-buffer
  policy, preventing project entry from eagerly decorating every hunk
  before paged split rendering starts.
- Make `auto` the default split virtualization policy: reviews below
  5,000 estimated split rows retain the complete-text model, while larger
  eligible reviews select paged rendering automatically. Explicit
  `complete` and `paged` values remain available, and wrapping or
  decision-aware views still use the complete model.
- Add a paged split model that indexes hunk heights, retains native
  newline/scrollbar structure, materializes and
  evicts viewport-adjacent chunks in both columns, and uses logical row
  coordinates plus a Fenwick length index instead of complete row
  positions. Content alignment corrects cheap chunk-height estimates
  atomically when first revealed; retained-chunk indexes keep eviction
  independent of total hunk count. Standard isearch, copying, and review
  commands precompute one exact projection before bulk-installing both
  sides, with pinning left unchanged if projection building fails.
  Wrapping and decision-aware views fall back to the complete model. First split falls
  from about 223 to 63 ms at 22,000 lines and from 1.08 seconds to about
  181 ms at 110,000 lines.
- Restore linear large-review rendering by tracking physical-row counts
  directly instead of measuring a growing row list at every hunk, carrying
  known section ownership into stacked headers, and resolving visible
  split rows through the existing hunk table. On the 4,000-file /
  110,000-line benchmark this reduces first split from 6.4 seconds to
  about 1.1 seconds, deep viewport materialization from 172 ms to about
  25 ms, and split decision rebuilds from 7–8 seconds to 1.3–1.5 seconds.
- Benchmark lazy stacked setup and first-viewport rendering explicitly,
  and add `make benchmark-large` as the reproducible 110,000-line scaling
  tier.
- Extend stacked added/removed backgrounds through the line-number
  gutter to the fringe bar, matching split rendering and retaining the
  same coverage after review decisions reproject line prefixes.
- Add `diffs-files` for comparing any two saved files in the native
  stacked or split review. Independent old/new source ownership keeps
  context expansion, token tools, `RET`, and refresh pointed at the
  correct physical file while comments and decisions retain the
  canonical target-section identity, including when the two files live
  in different directories. Default headers elide middle directories
  from long display paths without changing source identity or navigation.
- Route `.diff` and `.patch` files directly through the self-contained
  `diffs-mode`, while retaining `diffs-minor-mode` only as the renderer
  boundary for externally owned diff-mode buffers. First-party
  file/project/commit producers now initialize the same major-mode
  entry instead of activating its renderer as a separate step.
- Decode live-server JSON as UTF-8 at the session CLI boundary, preserving
  CJK, emoji, and other non-ASCII text in both human and Agent comments.
- Harden within-line refinement against the current diffs.com/jsdiff
  behavior with a two-sided `word-alt` edit sequence, Unicode
  whitespace handling, fast Unicode-character `char` comparison, a
  multilingual conformance corpus, and randomized Myers validation.
- Add `diffs-conflict-mode`, an in-place stacked merge-conflict workflow
  that preserves the source buffer's language major mode, syntax, and
  language-tool state. The minor mode is the complete public entry,
  including validation and first-conflict positioning; there is no
  separate wrapper command.
- Add Current, Incoming, Both, and Reset transitions under `C-c C-d`
  plus clickable action rows. Each transition is one undoable,
  unsaved source edit; no action saves or stages the file.
- Parse two-way and diff3 conflicts, including marker widths greater
  than seven and final marker lines without a newline. Diff3 Base is
  displayed but deliberately excluded from Both.
- Keep length-changing, adjacent, and empty conflict blocks anchored
  with markers plus stable identities; leave ordinary boundary edits
  outside the blocks and route mouse actions to the clicked buffer.
- Reject malformed, nested, and orphaned input before enabling the
  mode, and prevent stale source text from being overwritten.
- Preserve existing `smerge-mode` state and roll back source text,
  choice state, modified state, and presentation if rendering fails.
- Remove conflict presentation cleanly on major-mode changes and
  reverts, with a post-command reprojection after undo or redo.
- Refine conflict presentation with full accept-action labels, quieter
  action rows, section-colored marker lines, explicit Current/Incoming
  labels, stronger marker backgrounds, and matching fringe bars while
  preserving raw marker text.
- Collapse a resolved conflict row to its result and Reset action, and
  keep descriptive Current/Incoming marker labels at normal weight.
- Consume Emacs's translated mouse-2 event on conflict action links so
  a mouse-1 choice cannot fall through to primary-selection paste.
- Delegate standard conflict matching and Current/Incoming resolution
  to smerge's public engine. Keep diffs.el's strict validation,
  persistent Reset, diff3 Both-without-Base operation, and extended
  marker fallback as the thin product-specific layer.
- Add `diffs-diff-hl-show-hunk` as a standard
  `diff-hl-show-hunk-function` adapter. Mouse and keyboard hunk entry
  render only the current hunk with diffs.el's line pairing,
  marker-free line numbers, source syntax, and word refinement while
  preserving diff-hl's inline or posframe placement and actions.
  Hunk content follows `diffs-default-view`, independently rendering
  aligned split columns or the stacked unified layout. Split previews
  omit unnecessary trailing-column padding and reserve space at the
  parent-window edge so posframe wrapping cannot create empty
  continuation rows.
- Add opt-in `diffs-diff-hl-mode` to save, use, and restore diff-hl's
  prior display backend. `diffs-diff-hl-display-function` can override
  that backend explicitly without changing diff-hl mouse maps.
- Keep saved and unsaved file diffs on the same last-revision baseline,
  preserve the source hunk when entering the default split view, use
  diff-hl's public project reference cache from non-file entry buffers,
  and surface positioning failures instead of silently ignoring them.
- Load expanded unchanged context from the review's captured repository
  root even if its buffer directory later changes, retry stale negative
  caches after a package reload, and retain old/new loader errors for
  actionable failure messages.
- Add stable stacked, split, and wrapped token coordinates plus exact
  source visits. Public source, hover, and click hooks feed
  source-buffer Eldoc and Xref backends while preserving existing live
  Eglot/lsp-mode ownership and using safe read-only historical buffers.
- Move source-revision fontification out of context-expansion commands
  into an idle queue. Publish generation-checked immutable line vectors
  and share them through a bounded repository/file/side/revision or
  content/language/theme render cache; theme changes retain raw source.
- Add `diffs-items` for ordered unchanged source-file and patch items in
  one searchable owner, section index, navigation model, and stacked or
  split presentation, with optional stable ids and versions.
- Add public `diffs-file-header-function`, `diffs-gutter-function`, and
  `diffs-hunk-separator-function` presentation boundaries shared by
  stacked and split views without advice or alternate parsers.

## 0.12.0 — 2026-07-28

- Add diffs.com-style accept/reject previews for individual contiguous
  change blocks, with prefix-argument whole-hunk decisions.
- Share resolution state across stacked and split layouts; collapse
  resolved split blocks to the selected result and adjust later result
  line numbers.
- Add per-block and complete-review reset actions.
- Add guarded batch application to source buffers with exact-content
  validation, leaving every changed buffer unsaved and unstaged.
- Revalidate source text after the apply confirmation prompt, reconcile
  repeated decisions after source undo, and roll back multi-buffer
  failures as one change group.
- Track applied source state independently from preview decisions, so
  resetting a decision preserves exact `RET` targets and later applies
  across length-changing blocks.
- Generate refreshes in a staging buffer so backend failures preserve
  the live session and layout; support `g` directly from split view and
  restore its side and source-row identity after success.
- Roll back failures after refresh adoption without rerunning mode
  hooks, restoring full narrowed owner state, retained split/index
  buffers, and exact window positions.
- Report explicit old/new hunk counts in review JSON and omit ranges for
  zero-count sides, matching comment-target validation.
- Synchronize split-view horizontal scrolling and paired cursor
  positions, including semantic `C-a`/`C-e` movement on unequal lines.
- Consolidate unchanged-context control on one-way `e` expansion in
  both layouts, leaving `TAB` exclusively to Emacs hunk/outline folding.
- Add a native read-only `diffs-mode` and suppressed major-mode map for
  first-party stacked views, allowing modal editors to select motion
  semantics without package-specific integration.
- Prevent source-syntax temporary buffers from prompting for save when
  unchanged context is expanded.
- Remove the context-control row once every unchanged line is visible,
  while keeping hunk navigation and resolution metadata.

- Add stable live review session ids and unambiguous selection by
  repository, working directory, or session id.
- Add the pure-Elisp-backed `diffs session` CLI for direct, no-file
  session discovery, compact review reads, human/agent comment
  filtering, atomic stdin apply, removal, and guarded clearing.
- Install durable CLI and Codex skill copies from package-manager-safe
  root Elisp assets, avoiding links that break after straight/MELPA
  rebuilds; honor `EMACS` throughout the launcher and session tests.
- Validate every Agent comment field before mutation, roll back a batch
  when UI projection fails, reject targets on zero-count hunk sides,
  and serialize pending decision state as JSON `false`.
- Validate known sidecar fields and every current-diff target before
  import while ignoring unknown fields and preserving dual old/new
  ranges for forward compatibility; make import, comment removal, and
  clearing restore prior state when projection fails.
- Preflight every Agent-tool install target and restore files,
  permissions, links, and directories after a later write failure;
  detect directory symlinks before following their referents.
- Make the bundled Codex skill use live sessions exclusively instead of
  temporary JSON exports.

- Add stable one-based file/old-or-new-side/line-range selection from
  the current line or an active region, shared by stacked and split
  layouts.
- Add inline review annotations with summary, rationale, author/source
  metadata, navigation, removal, and row-aligned peer spacers in split
  view.
- Import and export Hunk-compatible version-1 review sidecars using
  `oldRange` and `newRange`.
- Expose compact machine-readable live review snapshots with optional
  patch text and notes.
- Accept Hunk-style agent targets by line, range, or hunk through an
  atomic batch API that validates every comment before changing review
  state.
- Bundle a `diffs-review` agent skill that uses the running Emacs server
  rather than scraping the rendered UI.
- Avoid copying unified-view text properties into split rows, keeping
  the 800-file first-split benchmark around 280 ms despite the added
  stable review metadata and source-coordinate state.
- Extend the large-review benchmark with public split-view `A`/`R`
  decision rebuilds, and defer hidden stacked-overlay projection until
  the user returns to stacked; on the 800-file fixture this reduces
  those actions from about 943/1,016 ms to roughly 320/400 ms.

## 0.8.0 — 2026-07-27

- Virtualize side-by-side visual rendering while keeping both split
  buffers' complete text immediately searchable and copyable.
- Bulk-insert split text and use row/position vectors as the stable data
  model for scrolling, source navigation, context rebuilds, and sticky
  headers.
- Materialize line backgrounds, gutters, fringe bars, source syntax
  faces, and within-line emphasis for the viewport plus configurable
  overscan, always updating both columns together.
- Add `diffs-split-overscan` and remove the superseded
  `diffs-split-fontify-threshold`.
- Extend the large-diff benchmark with first-time deep-viewport
  materialization.
- Bind `e` in stacked and split views to reveal unchanged context
  incrementally to completion while leaving `TAB` to hunk folding.

## 0.7.0 — 2026-07-27

- Replace Emacs's whole-hunk refinement with a native, cached
  within-line renderer shared by unified and side-by-side views.
- Add monotonic global alignment of corresponding removed and added
  lines, so inserted or deleted rows do not shift every later
  word-level comparison in a change block.
- Add diffs.com-style `word-alt` rendering as the default, with
  configurable `word`, `char`, and `none` alternatives.
- Add configurable line-length, pairing-distance, block-size, and
  whitespace limits with bounded fallback behavior.

## 0.6.0 — 2026-07-27

- Add lazy, cached, source-syntax-highlighted one-way expansion of
  unchanged context with `e`, while preserving the original patch text.
- Carry expanded context into aligned side-by-side columns.
- Open in side-by-side mode by default; add `diffs-default-view` for
  selecting the unified/stacked initial layout.
- Make split-view `q` close both columns and quit the complete diff;
  keep `s` as the layout toggle.
- Truncate split-view long lines by default, with aligned wrapping
  available through `diffs-split-wrap-lines`.
- Resolve old/new file content across working-tree, commit, and rename
  views.

## 0.5.0 — 2026-07-27

- Add a toggleable changed-file index side window with per-file stats,
  current-file tracking, keyboard preview, RET navigation, and mouse
  navigation.
- Add sticky file and hunk context to unified and side-by-side headers.
- Cache section positions in a vector for fast header and index lookup.
- Preserve index visibility while entering and leaving side-by-side
  views.

## 0.4.1 — 2026-07-27

- Extend split-view added and removed backgrounds through the
  line-number gutter and to the right edge of the window.
- Keep fringe bars and word-level refinement layered above the
  full-width, theme-native change backgrounds.
- Add `diffs-split-full-width-backgrounds` to restore text-only split
  backgrounds when desired.

## 0.4.0 — 2026-07-27

- Cache side-by-side buffers so repeated toggles reuse the rendered view.
- Stream wrapped rows directly into the old/new buffers instead of
  materializing another pair of full row lists.
- Reuse short line strings and cache hunk end positions to reduce
  allocation and avoid repeated hunk-list searches.
- Add a reproducible 2,200/22,000-line benchmark and performance
  regression coverage.
- Document the prioritized feature gaps against diffs.com.

## 0.3.1 — 2026-07-27

- Add full-height, theme-native fringe bars for added and removed lines.
- Show the bars in unified and side-by-side views, including wrapped rows.
- Scale the fringe bitmap with text size and line spacing.

## 0.3.0 — 2026-07-27

- Preserve and display metadata-only changes such as renames and mode changes.
- Decode Git's quoted pathnames for correct source navigation.
- Show merge commits as first-parent two-way diffs.
- Wrap long side-by-side lines into aligned physical rows.
- Retain visible syntax and refine faces when splitting very large diffs.
- Isolate split buffers, window state, and scroll hooks per view.
- Add an ERT regression suite and build targets.

## 0.2.0

- Initial public release.
