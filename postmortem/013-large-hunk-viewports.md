# Large hunk viewports

## Decision

The work for one viewport of a large hunk is proportional to the viewport, not to the hunk.

- A materialized split range fontifies the unified text behind all its rows in one `font-lock-ensure` call and tells each row decoration which span is done. Decorating a single row still fontifies its own line, so direct callers are unchanged.
- Stacked decoration of a hunk larger than `diffs--hunk-checkpoint-min-size` starts at a line-number checkpoint (every 256 body lines, built on first use) and stops at the end of the requested region.
- The change blocks of a hunk are collected once and looked up by region with a binary search. `diffs--refined-blocks` still marks a block as refined, so refresh keeps its meaning.
- Both caches live in `diffs--hunk-index`, keyed by the hunk object and dropped with the scan state.

## Why

Measured on a 20,000-line added file as one hunk (byte-compiled, `make benchmark-hunk`), the first split took 795 ms and a viewport near the end 587 ms; at 50,000 lines the deep viewport took over a second. Per-call timing showed the cause: `diff-mode` fontifies source syntax per hunk, finds its hunk again on every call, and the lookup grows with the position in the hunk, so 170 rows cost 650 to 930 ms row by row and 6 ms in one call. In the stacked view every jit-lock call walked the hunk from its first line and collected every change block again, 15 to 50 ms per viewport.

The result for 20,000 lines: deep split viewport 8 ms, complete projection 162 ms, stacked viewport near the end 0.5 ms. Scan and the other profiles are unchanged within noise.

## Alternatives rejected

- Cache the unified overlays in the split rows. Rows would need invalidation whenever the source language, theme or `diff-mode` option changes.
- Skip source syntax for hunks above a size limit. It trades colors for speed in a way users would see, and the batched call already makes everything after the first split cheap.
- Split a large hunk into several paged chunks. That needs row collection and line pairing to start in the middle of a hunk, which is a separate design.

## Deferred limits

- The first split of a large hunk still pays `diff-mode`'s one-time syntax pass over the whole hunk, about 25 µs per line (500 ms for 20,000 lines). diffs.el cannot bound it; `diff-font-lock-syntax` nil skips it.
- The paged model still materializes a hunk as one chunk, about 100 ms of row collection for 20,000 lines.
- The first refinement of one very large block with lines on both sides still pairs and refines the whole block once.
