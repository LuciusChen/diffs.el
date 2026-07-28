;;; diffs-assets.el --- Packaged assets for diffs.el -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Lucius Chen

;; Author: Lucius Chen
;; URL: https://github.com/LuciusChen/diffs.el
;; Version: 0.12.0
;; Keywords: vc, tools

;;; Commentary:

;; Text assets that must remain available when package managers build
;; diffs.el from the default root-level `*.el' file set.

;;; Code:

(defconst diffs--review-skill-content
  "---
name: diffs-review
description: Inspect human comments and annotate a live diffs.el review through the diffs session CLI. Use when the user has a diffs.el view open, mentions Emacs diff comments, or asks an agent to work from that review.
---

# diffs.el Review

The Emacs UI belongs to the user. Do not scrape decorated buffers, read
temporary exports, or send interactive keystrokes. Use `diffs session`
to communicate directly with the user's live Emacs review.

If a local sandbox blocks the Emacs Unix socket, request permission to
rerun the same `diffs` command outside that sandbox. Do not fall back to
scraping the buffer.

## Workflow

1. Discover live reviews:

   ```sh
   diffs session list --json
   ```

2. Read the compact file/hunk structure and existing human notes:

   ```sh
   diffs session review --repo . --include-notes --json
   diffs session comment list --repo . --type user --json
   ```

   Per-file `decisions` in the review response are the user's pending
   `accept`/`reject` choices. Treat them as review intent; do not change
   the underlying source unless the user separately requests it.

3. Request raw patch text only when the compact structure and source
   files are insufficient:

   ```sh
   diffs session review --repo . --include-patch --include-notes --json
   ```

4. Navigate conceptually by `filePath` plus one-based `oldRange` or
   `newRange`. Keep findings concise and anchored to the side where the
   issue exists.

5. Apply one validated batch over stdin:

   ```sh
   printf '%s\\n' \\
     '{\"comments\":[{\"filePath\":\"src/example.el\",\"newLine\":42,\"summary\":\"This branch drops the error value.\",\"rationale\":\"The caller treats nil as success, so this can hide a failed write.\",\"author\":\"codex\"}]}' \\
     | diffs session comment apply --repo . --stdin --focus --json
   ```

6. Use the returned comment ids for cleanup when necessary:

   ```sh
   diffs session comment list --repo . --type agent --json
   diffs session comment rm --repo . <comment-id> --json
   ```

## Comment targets

Every comment needs `filePath`, `summary`, and exactly one target:

- `oldLine`
- `newLine`
- `oldRange`: `[start, end]`
- `newRange`: `[start, end]`
- `hunk` or `hunkNumber` (one-based)

Line and range targets are one-based and must fall inside one visible
diff hunk. Prefer line/range targets over hunk numbers because they are
more precise and remain meaningful outside the current UI ordering.

Optional fields are `rationale` and `author`. Use `summary` for the
finding and `rationale` for impact or reasoning.

## Review discipline

- Read the compact structure before requesting the patch.
- Do not comment on every hunk; anchor only material findings.
- Prefer one batch apply over repeated mutations.
- The batch is atomic: one invalid file, target, or comment rejects all
  comments.
- Read `--type user` notes before changing code; they are the user's
  instructions attached in Emacs.
- Treat the returned ids as session-local annotation identities.
- Do not edit the underlying patch or source unless the user separately
  asks for fixes.
"
  "Bundled contents of the diffs review agent skill.")

(provide 'diffs-assets)
;;; diffs-assets.el ends here
