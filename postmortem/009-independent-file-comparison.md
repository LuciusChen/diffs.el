# Independent file comparison

## Problem

The renderer accepts any unified patch, but ordinary diffs.el reviews assume that the old side is a repository revision and the new side is its working-tree target. Two independently selected files violate that assumption: unchanged-context loading must read both files from disk, and source navigation from the left split must visit the first file instead of mapping onto the second file.

Creating another viewer would duplicate the scanner, row model, split rendering, refinement, comments, and refresh lifecycle.

## Decision

`diffs-files` is a thin first-party patch producer. It asks Emacs's public `diff-no-select` frontend for a synchronous unified diff, then passes that patch into the same `diffs-mode` presentation path as file, project, commit, and mixed-item reviews.

The owner records that its two sides are independent sources:

- old-side context and source tools read the first file;
- new-side context and source tools read the second file;
- split `RET` and token visits use each side's own immutable source line;
- review comments retain the second file as the canonical section identity, using old/new ranges to distinguish sides;
- refresh regenerates the comparison from the same two paths;
- the second file remains the target for optional review-decision application.

The common parent directory is the review root. This keeps absolute paths usable when the files live in different directories while preserving the existing source-path validation boundary.

Default headers abbreviate only their display strings when the paths are long, retaining suffix components on both sides. Section metadata and source coordinates keep the complete paths.

## Alternatives rejected

- A separate two-file renderer would create a second parser and presentation lifecycle.
- Opening Emacs's stock `*Diff*` buffer and requiring a second manual mode command would expose provenance as a different workflow.
- Treating the first file as a fake VC revision would break context expansion and language-tool source buffers.
- Rewriting the files into temporary repository-shaped paths would make `RET`, comments, and refresh point at synthetic sources.

## Limits

The command compares saved file contents. It does not silently substitute unsaved visiting-buffer text. The renderer remains pure Elisp; Emacs's configured external `diff-command` produces the unified patch, as it does for the built-in `diff` command.

## Invariants

- The generated unified patch remains the owner buffer's source of truth.
- `diffs-mode`, split rendering, token refinement, comments, and decisions are shared with every other review source.
- The first selected file is always the old/left source and the second is always the new/right source.
- No file is saved or staged automatically.
