# Changelog

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
