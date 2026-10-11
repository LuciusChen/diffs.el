# Sticky header release

## Decision

A sticky header is released by one function on the default value of `window-buffer-change-functions`. It walks the windows of the frame and clears the sticky header of any window whose buffer is no longer the buffer that owns the header. The review's buffer-local hook only installs and updates headers. The comment composer additionally releases the stale header of the window it displays in right away, because Lisp code can see that window before the next redisplay.

## Why

A sticky header is a window parameter set by the review buffer. Until Emacs 31, a buffer's local `window-buffer-change-functions` ran only for windows that currently show the buffer. Emacs 31 also runs it for windows that left the buffer (NEWS.31: "`window-buffer-change-functions` is run for removed buffers too"). The cleanup that depended on this therefore never ran on Emacs 29 and 30.

Measured in a terminal frame with real redisplay, on Emacs 29.4 and 30.2: switching a scrolled review window to another buffer left the review's header on it for good, `0 files · +0 −0` for a stacked review and an empty line for a split one. Reopening the comment draft in a window that had shown the review gave the composer that same header. Emacs 32 repaired both on the next redisplay through the local hook. The default value of the hook runs on every version, so one function there covers all of them.

## Alternatives rejected

- Release only in the comment composer. It fixes the window the composer uses and leaves every other buffer switch of a scrolled review window as it was.
- Register the function when the first header is installed and remove it when none is left. The function returns immediately when no window has an owner parameter, so the registration state would cost more than it saves. AGENTS.md allows cleanup hooks to be registered at load time.
- Keep the clearing branch of the local hook as well. On Emacs 31 and later both would run, and on older versions the branch never does.

## Invariants

- A window that still shows the buffer that owns its sticky header keeps it.
- A window that shows another buffer has no sticky header after the next redisplay, and the header it replaced is restored.
- The composer never shows a stale review header, even before that redisplay.

## Deferred

- Between `set-window-buffer` and the next redisplay, a window can still carry the old header. Only code that reads the window parameter in that interval sees it.
