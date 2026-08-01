# Live review comment composer and attachments

## Problem

Minibuffer input is unsuitable for comments with several paragraphs. A pasted screenshot also needs to remain associated with the exact source range and be readable by a coding Agent, without turning ordinary review JSON into a large binary transport or introducing a hidden cache whose lifetime differs from the review.

## Decision

Interactive `a` opens one bottom-side `text-mode` draft owned by the live unified review buffer. The first paragraph is the summary and text after the first blank line is the rationale. Submission atomically adds the captured stable range, text, attachment metadata, and binary attachment state; cancellation changes none of them.

The draft registers Emacs's public `yank-media` protocol for supported image MIME types and remaps ordinary yank to prefer an image before falling back to text. The declared MIME must match the detected container, basic structural checks reject truncated data, and graphical sessions also decode the image once before accepting it. Images remain represented in comment text as `[Image #N]` rather than adding image display objects to diff rows or buffers.

Committed annotations retain only attachment id, label, MIME type, byte count, and SHA-256. The owner buffer separately retains the validated binary. Normal session and comment JSON never include base64. `diffs session attachment get` is the single binary boundary: it requests one id from one live session, verifies metadata after transport, refuses an existing target, and atomically writes the caller's explicit path.

Hunk version-1 sidecars have no attachment representation. Export therefore refuses any image-bearing review instead of silently dropping images or inventing an incompatible field.

## Alternatives rejected

- Growing the minibuffer or opening recursive edits would retain a cramped input model and complicate window restoration.
- Rendering thumbnails inside diff rows would change row heights, split alignment, and large-review performance for a capability that is needed only on demand.
- Writing every paste to a cache would create cleanup, privacy, stale-session, and path-sharing problems.
- Embedding base64 in normal comment JSON would inflate every Agent read even when no image is relevant.
- Treating `[Image #N]` as sufficient Agent context would invite the Agent to infer content it has not inspected.

## Lifetime and limits

Draft and committed binaries live only while their owner review is live. Killing the owner also kills its draft; removing an annotation releases attachments that no remaining annotation references. Per-image and per-session byte limits are checked before mutation. The explicit CLI output is caller-owned and is the only persistent file created by this workflow.

## Invariants

- The unified patch text remains unchanged.
- Split buffers never own duplicate attachment state.
- Normal annotation APIs return metadata, not binary strings.
- A failed validation, render projection, or CLI write leaves existing review state and output files unchanged.
- Loading `diffs.el` does not load the composer or install global paste behavior.
