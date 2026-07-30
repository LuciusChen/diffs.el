# P2 extensibility model

## Status

Implemented for the unreleased 0.13.0.

## Problem

The review surface has stable file, side, source-line, and logical-row identities, but the remaining diffs.com gaps require public extension boundaries rather than more renderer-specific commands:

1. Token interactions need source coordinates that work in stacked and split views and can delegate to ordinary Emacs language tooling.
2. Historical syntax work must leave the first render path, then reuse results only when revision, language, and theme inputs still match.
3. Large review containers need unchanged files beside patches, while headers, gutters, and separators need supported render functions instead of advice.

## Decision

### Token coordinates and language tooling

`diffs-token-at-position` returns one stable plist for stacked and split views: repository-relative and absolute file names, old/new side, revision, one-based line, zero-based character column, token bounds, and token text. It derives coordinates from the existing scan and split-row models; decorated display text is never reparsed.

`diffs-token-source-functions` is the only override boundary for mapping that token to a live `(BUFFER . POSITION)`. The default reuses a visiting worktree buffer and otherwise creates a safe read-only source buffer without local variables, local eval, or mode hooks. Eldoc and Xref delegate through that position, so Eglot, lsp-mode, and other language clients already attached to a live source buffer remain the owners of their protocol behavior. Historical buffers expose coordinates and ordinary mode backends but are not presented as live LSP documents.

### Asynchronous syntax and render caching

Source retrieval and syntax rendering are separate states. Raw file contents become usable immediately; source-mode fontification runs from an idle queue and publishes an immutable line vector afterward. Cache identity includes an explicit renderer version, repository root, file, side revision or worktree content identity, language mode, and a theme generation. Theme changes invalidate rendered entries without discarding reusable raw source.

The cache is bounded and shared across reviews. Review buffers register generation-checked waiters; completed work may update visible context or rebuild a visible split only while the same owner generation and source identity remain current. A recoverable source-mode fontification failure keeps raw source visible but never enters the successful-render cache. Its waiter releases the failed identity, allowing a later context read to retry instead of treating the raw vector as a permanent syntax result; renderer-version changes similarly make live stale identities retry.

### Mixed items and public presentation hooks

The owner buffer remains the sole state owner. A mixed review item is either a scanned diff section or an explicit unchanged source-file item with a stable id and revision/content identity. Split and stacked presentations consume the same item sequence.

Public header, gutter, and separator functions receive immutable context plists and return strings or nil. Defaults preserve the current appearance. Hooks replace only presentation; scanning, row identity, navigation, decisions, comments, and source application continue to use the existing models.

### Standard navigation

Every review publishes the owner's file and hunk index through the standard buffer-local Imenu protocol. Split entries use Imenu's supported special-item dispatch to resolve the same stable section/hunk identity and remain in split view; paged splits materialize only the selected chunk. Duplicate mixed-item paths use their item ids for disambiguation and row ownership, so navigation does not introduce a second file lookup or view-specific index.

## Rejected alternatives

- Advising Eldoc, Xref, Eglot, lsp-mode, or diff-mode internals.
- Treating face runs or rendered strings as authoritative token coordinates.
- Running source major-mode hooks or local variables for historical contents.
- Caching rendered faces only by file name or revision while ignoring language and theme.
- Introducing a second parser or state owner for mixed items.
- Adding another package-specific file/hunk navigator instead of implementing Imenu.
- Making header, gutter, or separator callbacks responsible for navigation or mutation.

## Completion evidence

- Stacked, split, wrapped, Unicode, old-side, and new-side token coordinate tests.
- Eldoc and Xref delegation tests against a real source-buffer position.
- Deterministic idle-render tests covering expanded-overlay repainting, failure retry, cache reuse, and renderer/revision/language/theme invalidation.
- Mixed unchanged-file/diff ordering, navigation, search, exact duplicate-path identity, Imenu dispatch, and public renderer tests.
- Full ERT, byte compilation, checkdoc, package-lint, and the large-review benchmark.
