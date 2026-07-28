# Agent-readable review model

## Status

Implemented and validated across the v0.9–v0.11 preview.

## Problem

diffs.el can render and navigate large changesets, but it has no stable
identity for a selected diff range and no structured place to attach
review notes. A normal Emacs region identifies transient buffer
positions, not a file, old/new side, or source-line range, and therefore
does not survive split/stacked switches or context rebuilds.

Comments that exist only as display text are also invisible to coding
agents. An agent needs a compact machine-readable review model and a
validated batch input path, without scraping decorated buffers.

## Hunk audit

Hunk uses three related layers:

1. Stable targets are current/previous file paths plus a one-based old
   or new line/range. Hunk number is a convenient alternative target,
   not the canonical line identity.
2. Sidecar annotations use `oldRange` and `newRange`, with required
   `summary` and optional `rationale`, author, source, tags, confidence,
   ids, and timestamps.
3. A live session API exports file/hunk structure separately from the
   raw patch, supports navigation, and validates single or atomic batch
   comment mutations.

The default agent workflow reads the compact review structure first and
requests patch or notes only when needed. This avoids spending agent
context on an entire patch merely to discover review targets.

## Decision

Use one owner-buffer review model for both human UI and agent access.

- A selection is a plist containing file, side, inclusive one-based
  start/end lines, and an optional active anchor.
- An annotation contains an id, file, optional old/new inclusive ranges,
  summary, rationale, author/source metadata, tags, confidence, and
  timestamps.
- Unified and split buffers derive visual overlays from these records.
  Buffer positions and display properties are never authoritative.
- Split and stacked views share the same owner state. Rebuilding a split
  reprojects selection and annotation overlays from stable identities.
- JSON import/export follows Hunk's version-1 sidecar shape where fields
  overlap: `summary`, `files[].path`, and
  `files[].annotations[].oldRange/newRange`.
- Agent batch input accepts Hunk-style `filePath`, `oldLine`, `newLine`,
  `oldRange`, and `newRange` targets. The whole batch is validated before
  the owner state changes.
- Each owner has a stable live-session id and normalized repository.
  The `diffs session` CLI resolves a session by id or repository and
  contacts the already-running Emacs server directly. It emits clean
  JSON for discovery, review, and comment operations without temporary
  files or a second daemon.
- The Codex skill reads human notes from the live session and writes
  Agent notes through one validated stdin batch.

## Why selection and annotations ship together

Selection and annotations need the same stable address. Implementing
selection first with a buffer-position model would either constrain
annotations later or require migration. Implementing the shared address
once keeps review rendering, JSON, navigation, and future accept/reject
actions aligned.

## Compatibility

The sidecar schema is intentionally a compatible subset of Hunk's
agent-context JSON. A file produced by diffs.el can be consumed by Hunk,
and diffs.el can import Hunk annotations that use the shared fields.
Unknown fields are ignored on import so newer producers remain usable.

## Deferred limits

- The live bridge uses the existing Emacs Unix socket; it does not start
  a loopback HTTP daemon. Restricted Agent sandboxes may require
  permission to access that local socket.
- Notes are local review state, not hosted PR discussions.
- Re-anchoring after arbitrary source edits is line-based. Content
  fingerprints and fuzzy relocation are deferred until watch/refresh
  workflows require them.
- Rich terminal/web markup is not imported. Plain summary and rationale
  remain the portable fallback.
