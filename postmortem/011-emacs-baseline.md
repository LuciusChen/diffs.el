# Emacs 29.4 baseline

## Decision

Diffs.el requires Emacs 29.4 or newer. `Package-Requires`, the README, AGENTS.md, and the CHANGELOG state the same version, and CI runs the full check suite on 29.4 and on the current release, 30.2.

## Why

Emacs 29.1 signals "Maximum buffer size exceeded" when `insert-file-contents` reads a pipe through `/dev/stdin`. The live-session CLI reads `diffs session comment apply --stdin` that way, so its session test failed on 29.1 and passed on 29.4 and 30.2. A line-by-line `read-string` loop does read the pipe on 29.1, but it would give a command that exchanges UTF-8 JSON a second decoding path for the sake of one old release; the `insert-file-contents` path works on every later release.

No code was kept only for 29.1. The source-cache membership shim and the optional `yank-media-autoselect-function` guard separate 29.x from 30 and later, not 29.1 from 29.4, so they stay.

Before this change nothing ran the declared baseline: no 29.1 binary was available locally and there was no CI. The baseline is now the oldest version that is actually tested.

## Alternatives rejected

- Keep 29.1 and read stdin another way, with a line-by-line `read-string` loop or a `cat` subprocess, for one old release.
- Keep 29.1 in the CI matrix as a non-blocking job. A permanently red job hides real regressions.
- Raise the baseline to 30. No Emacs 30 API is needed, so it would exclude users for no benefit.

## Consequences

- package.el refuses to install the package on Emacs 29.1 through 29.3. Versions 29.2 and 29.3 were not tested.
- New code still needs a version guard or a local compatibility path for APIs newer than 29.4.
