# Review Resolution Model

## Decision

Accept/reject is a reversible review-result transformation, not an
implicit Git or filesystem action.

Each contiguous change block has a stable key derived from its file,
hunk starts, and index within the hunk. The unified owner stores
`accept` or `reject`; stacked and split layouts derive their preview
from the same decision.

- Accept keeps additions.
- Reject restores deletions.
- A prefix argument resolves every change block in the hunk.
- Reset removes one or all decisions.
- Explicit apply reconciles every decision against the current source
  text after confirmation and before changing any source buffer.
- Apply never saves or stages.

## Why

The diffs.com `diffAcceptRejectHunk` utility is a pure
`FileDiffMetadata` transformation. It converts the chosen side to
context and recalculates later coordinates, but persistence belongs to
the embedding application. The same separation is safer in Emacs:
review can remain exploratory while source mutation requires a
separate confirmation.

It also preserves diffs.el's immutable-patch contract. Stacked
resolution uses overlays, and split resolution is regenerated from
indexed rows; neither rewrites the patch text used by `diff-mode`.

## Rendering

Stacked view hides the discarded raw lines, retains the chosen lines,
and projects adjusted result line prefixes. Split view emits a decision
label followed by the chosen rows as context on both sides. Split rows
keep separate preview, immutable review, and live worktree coordinates:
resolving a block can change displayed result numbers without changing
where comments attach, while applied source edits still shift later
source navigation correctly.

When a decision is made from split view, only the two visible columns
are reprojected. The hidden stacked owner is marked stale and rebuilt
once, immediately before a real return to stacked. This keeps the
unified owner authoritative without paying for its full decision
overlay pass during every consecutive split-view `A` or `R`.

## Source application

Decisions retain the exact old/new text and new-side source start.
After the confirmation prompt, apply reconciles both accepted and
rejected results with the live source rather than trusting an
`applied` label. This keeps repeated apply and source-buffer undo safe.
Validated edits are ordered from bottom to top and committed as one
multi-buffer change group; any failure rolls back the complete batch.

Actual source actions are stored separately from visible preview
decisions. Resetting a preview therefore does not forget a
length-changing edit that was already applied, and later source
navigation and applications still use the correct worktree line.
Historical-revision reviews, narrowed or read-only source buffers, and
paths outside the canonical repository root are rejected. Successful
application leaves every changed source buffer unsaved and unstaged.

## Deferred

- Decisions are session state rather than sidecar persistence.
- Source buffers remain unsaved after apply.
- Git staging is deliberately outside this workflow.
- Merge conflicts use the same pure-result principle but need their own
  marker parser and dedicated stacked presentation.
