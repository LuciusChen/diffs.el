# Virtualized split rendering

## Status

Implemented for v0.8; awaiting hands-on user validation.

## Problem

The v0.7 benchmark scans 800 files and 22,000 patch lines in about 17 ms, but the first split takes about 332 ms. Profiling shows that most of the time is spent performing tens of thousands of individual buffer insertions and property mutations for both columns. Cached split toggles are already effectively immediate.

Large diffs also copy only the initially visible source syntax faces. Rows revealed by later scrolling keep line colors and alignment but do not acquire equivalent syntax/refinement work dynamically.

## Decision

Keep complete searchable and copyable text in both split buffers, but virtualize expensive visual decoration.

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

## Result

On the existing 800-file, 22,000-line, 536 KB benchmark, first split
construction fell from about 332 ms in v0.7 to about 266 ms. A first
jump to a previously undecorated deep viewport takes about 19 ms, and a
cached layout toggle remains about 0.7 ms.

The complete split text is present before decoration. Automated coverage
verifies deep isearch-equivalent text access, row metadata lookup,
synchronized two-column materialization, syntax faces, within-line
faces, wrapping, source navigation, and context rebuild behavior.

## Why this model

A strict web-style virtualizer containing only visible text would make normal Emacs isearch, copying, region operations, and source-position restoration incomplete. Full text with virtual presentation keeps those workflows while removing the dominant per-row first-frame mutation cost.

Bulk text insertion is simpler and more predictable than background threads. Emacs buffer and font-lock mutation remains on the main thread, while work is bounded by the current viewport.

The row vector, not displayed text properties, becomes the stable split data model. Text properties remain a cache for visible presentation and compatibility with ordinary Emacs inspection.

## Alternatives rejected

- Visible text plus placeholder rows: faster in theory, but breaks search and copying and complicates exact scrollbar and point semantics.
- Render everything during idle time: improves command return but still causes unbounded background work and unpredictable pauses.
- Keep the existing per-row insertion loop and only delay syntax: profiling shows insertion and property mutation, not syntax alone, is the dominant first-split cost.
- Native threads: buffer mutation is not a safe or necessary threading boundary here.

## Invariants

- Underlying unified patch text remains unchanged.
- Split text is complete immediately after construction.
- Old and new buffers always contain the same number of physical rows.
- Search, copying, hunk navigation, source navigation, context expansion, layout toggling, and position restoration work on undecorated as well as decorated rows.
- Line backgrounds, gutters, fringe bars, syntax faces, and within-line emphasis have the same layering as v0.7.
- Default non-wrapping mode is the optimized primary path; wrapped rows remain row-perfect.
- Cache keys include every rendering option.

## Deferred limits

Row collection and physical-row indexing remain linear in patch size. This version virtualizes presentation rather than eliminating the lightweight full row model. If indexing becomes the dominant cost at much larger scales, a later version can chunk the logical row index without changing the split buffer contract.
