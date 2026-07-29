# Virtualized split rendering

## Status

Complete-text rendering was implemented and hands-on validated in v0.8; linear scaling and the paged large-review path were hands-on validated for the unreleased v0.13. Automatic size-based selection is covered by the same paged path and explicit threshold tests.

## Problem

The v0.7 benchmark scans 800 files and 22,000 patch lines in about 17 ms, but the first split takes about 332 ms. Profiling shows that most of the time is spent performing tens of thousands of individual buffer insertions and property mutations for both columns. Cached split toggles are already effectively immediate.

Large diffs also copy only the initially visible source syntax faces. Rows revealed by later scrolling keep line colors and alignment but do not acquire equivalent syntax/refinement work dynamically.

## Decision

Use complete searchable and copyable text for small split reviews, and automatically select paged rendering for eligible non-wrapping reviews at or above 5,000 estimated rows. Keep `complete` and `paged` as explicit policy overrides.

The renderer will:

1. Build paired logical rows from the unified buffer.
2. Convert them to aligned physical rows, including configurable wrapping and filler rows.
3. Store complete per-side row vectors and character-position indexes.
4. Insert each side's complete text in one bulk operation.
5. Decorate only the visible rows plus configurable overscan.
6. Decorate newly visible rows from scroll and post-command hooks.
7. Read stable row identity from the row vectors even before a row has text properties.
8. Cache decorated-row state so scrolling does not repeat completed work.

Both split columns must materialize the same row interval together so synchronized scrolling never exposes an undecorated peer.

The automatic policy estimates split size from already parsed sections, hunk ranges, expanded context, and metadata-only section line counts without collecting or aligning row text. The paged model replaces complete row construction with file-header, metadata, and hunk chunks carrying cheap non-wrapping height estimates. Each split buffer initially contains one newline per estimated physical row. Content alignment corrects a chunk and all following logical coordinates atomically when its exact height first becomes known. A Fenwick tree maps stable logical row indexes to changing buffer positions as nearby chunks are inserted or evicted. Standard isearch, copying, and review commands precompute one exact projection, bulk-install it in both columns, and then pin the pair; wrapped and decision-aware views use the complete model directly.

## Result

On the existing 800-file, 22,000-line, 536 KB benchmark, first split
construction fell from about 332 ms in v0.7 to about 266 ms. A first
jump to a previously undecorated deep viewport takes about 19 ms, and a
cached layout toggle remains about 0.7 ms.

The original 22,000-line fixture hid three ownership/indexing mistakes: physical-row construction measured the complete growing output list at every hunk, stacked hunk headers searched every section to rediscover ownership already known by their caller, and visible split rows repeated the same section search despite the existing hunk-to-gap table. At 4,000 files / 110,000 lines these costs raised first split to 6.4 seconds and a deep viewport to 172 ms.

V0.13 replaces the growing-list measurement with a row counter, passes section ownership directly into stacked header decoration, and reuses the hunk table for visible-row ownership. The same large fixture now scans in about 103 ms, prepares lazy stacked rendering in 139 ms, creates the first split in 1.08 seconds, and materializes a deep viewport in about 25 ms. Split decision rebuilds fall from 7–8 seconds to 1.3–1.5 seconds. The five-times-larger fixture is now approximately five times the default first-split cost rather than more than twenty times it.

The paged model reduces first split to about 63 ms on the 800-file / 22,000-line fixture and 181 ms on the 4,000-file / 110,000-line fixture. Both fixtures exceed the automatic threshold. Cold deep viewports take about 24 ms and 33 ms respectively. Bounded chunk eviction raises cached toggles from 0.7/2.3 ms to about 5/8 ms, still interactive but measurably slower. Exact full projection takes about 282 ms and 1.35 seconds; later search and copy operations reuse it. Decision actions remain near the complete model because their globally shifted result coordinates deliberately trigger its established rebuild path.

A real 4,000-file working tree exposed a separate entry-path failure: large-buffer policies can disable `font-lock-mode`, and the stacked renderer previously treated that as a reason to decorate every hunk eagerly. That work happened before paged split construction, obscuring its improvement. Lazy stacked scheduling now depends only on `diffs-lazy-threshold`; jit-lock remains active as diffs.el's viewport scheduler even when ordinary font lock is disabled. In a clean batch profile of the public `diffs-project` entry, presentation plus first paged split fell from 3.90 seconds to 0.54 seconds, while Git/VC diff generation remained about 0.23 seconds.

The complete model's split text is present before decoration. The paged model initially exposes only nearby chunk text, corrects underestimated content-alignment heights when revealed, then bulk-installs complete text at the standard interactive search/copy/review boundaries. Errors while building that exact projection leave the previous paired buffers and pinning policy intact. Automated coverage verifies automatic threshold transitions, explicit model overrides, static height parity and dynamic correction against the complete physical model, cold materialization and eviction, paired columns, copied offscreen text, projection rollback, row metadata lookup, syntax faces, within-line faces, wrapping, source navigation, decisions, and context rebuild behavior.

## Why this model

A strict web-style virtualizer containing only visible text makes raw Emacs buffer APIs incomplete. The paged model therefore keeps native newline structure and upgrades to a complete retained projection before standard interactive operations that require offscreen text. This preserves normal user workflows but cannot make direct `buffer-string` or programmatic `search-forward` transparent before that upgrade. Automatic selection confines that tradeoff to reviews above the size threshold, while the explicit `complete` policy preserves the prior raw-buffer contract.

Bulk text insertion is simpler and more predictable than background threads. Emacs buffer and font-lock mutation remains on the main thread, while work is bounded by the current viewport.

In the complete model, the row vector remains the stable data model. In the paged model, chunk identity plus logical row is stable; buffer positions are projections derived from its Fenwick length index. Text properties remain a cache for visible presentation in both.

## Alternatives rejected

- One tall display placeholder per chunk: point, logical line motion, and scrollbar semantics become synthetic.
- A newline skeleton without search/copy upgrade: fast, but exposes incomplete text to normal interactive workflows.
- Render everything during idle time: improves command return but still causes unbounded background work and unpredictable pauses.
- Keep the existing per-row insertion loop and only delay syntax: profiling shows insertion and property mutation, not syntax alone, is the dominant first-split cost.
- Native threads: buffer mutation is not a safe or necessary threading boundary here.

## Invariants

- Underlying unified patch text remains unchanged.
- Complete-model text is present immediately; paged text is complete before standard interactive search, copy, and review operations inspect offscreen rows.
- Old and new buffers always contain the same number of physical rows.
- Search, copying, hunk navigation, source navigation, context expansion, layout toggling, and position restoration work through stable logical identities; the paged path materializes required chunks before acting.
- Line backgrounds, gutters, fringe bars, syntax faces, and within-line emphasis have the same layering as v0.7.
- Default non-wrapping mode is the optimized primary path; wrapped rows remain row-perfect.
- Cache keys include every rendering option.

## Deferred limits

Row collection and physical-row indexing are benchmarked at both 22,000 and 110,000 lines and remain approximately linear in patch size. The paged model does not yet virtualize a single pathological hunk smaller than its chunk boundary, direct Lisp buffer-text consumers do not trigger completion automatically, wrapping uses the complete model, and decision changes still rebuild that model. Standard search and copy deliberately pay the exact full-projection cost once per cached pair.
