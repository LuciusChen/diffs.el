;;; diffs.el --- Fast, pretty file-level diff viewing -*- lexical-binding: t -*-

;; Copyright (C) 2026 Lucius Chen
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Author: Lucius Chen
;; Assisted-by: OpenAI Codex:gpt-5.6-sol, Claude code:fable-5
;; URL: https://github.com/LuciusChen/diffs.el
;; Version: 0.13.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: vc, tools
;;
;; This file is part of diffs.el.
;;
;; Diffs.el is free software: you can redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by the
;; Free Software Foundation, either version 3 of the License, or (at your
;; option) any later version.
;;
;; Diffs.el is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with diffs.el.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; A native review surface built on `diff-mode' and inspired by
;; https://diffs.com/: old/new line-number columns, styled headers,
;; full-width line backgrounds, source syntax, word-level refinement,
;; inline comments, review decisions, and synchronized stacked or
;; side-by-side layouts.
;;
;; The stacked buffer retains the unmodified patch as its source of
;; truth, so `diff-goto-source', isearch, `diff-apply-hunk', and the rest
;; of the diff-mode machinery keep working.  Indexed split buffers and
;; review overlays derive from that owner state.  Syntax and decorations
;; stay viewport-bounded on large reviews.  VC, Git, or Emacs's built-in
;; diff frontend produces patches; no external renderer is required.
;; Merge-conflict actions are separate guarded edits in the original
;; language source buffer.
;;
;; Entry points:
;; - `diffs-file': current file against the reference revision.
;; - `diffs-files': compare two independently selected files.
;; - `diffs-project': whole project against the reference revision.
;; - `diffs-commit': show a commit.
;; - `diffs-commit-at-line': show the commit that last touched the
;;   current line (blame).
;; - `diffs-items': show unchanged source files and patches in one review.
;; - `diffs-mode': open .diff and .patch files as native reviews.
;; - `diffs-conflict-mode': resolve merge markers in the current source
;;   buffer with Current, Incoming, Both, and Reset actions.
;; - `diffs-minor-mode': integrate the renderer into an external
;;   diff-mode buffer.
;; - `diffs-diff-hl-mode': render diff-hl hunk previews with diffs.el.
;; - `diffs-review-install-agent-tools': install the live-session CLI
;;   and Codex skill.
;; - `i' in the view: toggle the changed-file index.
;; - `M-RET': visit the exact source token rather than only its line.
;; - `e': incrementally reveal unchanged context.
;; - `s' in the view: toggle the side-by-side (split) view.
;; - `v'/`x': select/clear a stable source range for review.
;; - `a'/`['/`]': add and navigate inline review annotations.
;; - `A'/`R'/`U': accept, reject, or reset change-block decisions.
;; - `C-c C-c': apply reviewed decisions to source buffers.
;; - `diffs session ...': expose live comments to coding agents.
;;
;; The reference revision integrates with diff-hl: when
;; `diff-hl-reference-revision' is set, the same base is used here.

;;; Code:

(require 'diff-mode)
(require 'vc)
(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'fringe)
(require 'smerge-mode)
(require 'eldoc)
(require 'xref)
(require 'imenu)

(declare-function vc-git-command "vc-git")
(declare-function vc-git-root "vc-git")
(declare-function diff-no-select "diff")
(declare-function diff-hl-diff-buffer-with-reference "diff-hl")
(declare-function diff-hl-diff-skip-to "diff-hl")
(declare-function nerd-icons-icon-for-file "nerd-icons"
                  (file &rest arg-overrides))
(declare-function nerd-icons-octicon "nerd-icons"
                  (icon-name &rest args))
(defvar vc-git-program)
(defvar diff-hl-update-async)
(defvar diff-hl-show-staged-changes)
(defvar diff-hl-reference-revision)
(defvar diff-hl-reference-revision-projects-cache)
(defvar smerge-auto-leave)
(defvar diffs-minor-mode)
(defvar diffs-diff-hl-mode nil
  "Non-nil when diffs.el renders diff-hl show-hunk previews.")
(defvar diffs-conflict-mode)
(defvar diffs--split-unified)
(defvar diffs--review-skill-content)
(defvar diffs--mode-context nil
  "Dynamically bound initialization context for `diffs-mode'.")

(defgroup diffs nil
  "Pretty file-level diff viewing."
  :group 'vc)

(autoload 'diffs-diff-hl-show-hunk "diffs-diff-hl"
  "Render diff-hl's current hunk with diffs.el." nil)
(autoload 'diffs-diff-hl-mode "diffs-diff-hl"
  "Use diffs.el as diff-hl's show-hunk renderer." t)

(defcustom diffs-line-numbers t
  "When non-nil, show old and new line numbers beside diff lines."
  :type 'boolean
  :group 'diffs)

(defcustom diffs-hide-markers t
  "When non-nil, hide the leading +/-/space markers of diff lines."
  :type 'boolean
  :group 'diffs)

(defcustom diffs-prettify-headers t
  "When non-nil, replace file and hunk headers with a compact form."
  :type 'boolean
  :group 'diffs)

(defcustom diffs-file-icons t
  "When non-nil, prefix file labels with nerd-icons file-type icons.
The integration is optional.  When nerd-icons is unavailable, diffs.el
keeps the same text-only labels without signaling an error."
  :type 'boolean
  :group 'diffs)

(defcustom diffs-lazy-threshold 10000
  "Decorate lazily via jit-lock when the diff has more lines than this.
Lazy decoration makes huge diffs open instantly.  Set to 0 to
always decorate lazily, or to `most-positive-fixnum' to always
decorate eagerly."
  :type 'natnum
  :group 'diffs)

(defcustom diffs-split-overscan 60
  "Number of extra split rows decorated above and below the viewport.
The complete model always retains its text.  The paged model also uses
this distance when retaining materialized chunks around the viewport."
  :type 'natnum
  :group 'diffs)

(defcustom diffs-split-virtualization 'auto
  "Data model used to prepare non-wrapping side-by-side views.
`auto' uses `paged' when the estimated split row count reaches
`diffs-split-virtualization-threshold', and `complete' otherwise.
`complete' always builds searchable text and row metadata before
displaying the view.  `paged' always requests the first-frame path that
indexes hunks cheaply, corrects their exact heights on first
materialization, and materializes their text when they enter the
viewport.
Standard isearch, copying, and review commands materialize and retain
the complete projection before inspecting offscreen rows.  Wrapping and
decision-aware views continue to use the complete model."
  :type '(choice (const :tag "Choose from estimated size" auto)
                 (const :tag "Complete searchable buffer" complete)
                 (const :tag "Paged visible hunks" paged))
  :group 'diffs)

(defcustom diffs-split-virtualization-threshold 5000
  "Estimated split rows at which `auto' uses paged rendering.
This threshold applies only when `diffs-split-virtualization' is
`auto'.  Set it to zero to request paged rendering for every eligible
split view.  Wrapping and decision-aware views always use the complete
model."
  :type 'natnum
  :group 'diffs)

(defcustom diffs-split-wrap-lines nil
  "When non-nil, wrap long side-by-side rows while preserving alignment.
Both sides receive the same number of physical rows, with filler
rows added to the shorter side as necessary."
  :type 'boolean
  :group 'diffs)

(defcustom diffs-default-view 'split
  "Layout used for new diffs views and diff-hl hunk previews.
Choose `split' for side-by-side columns or `stacked' for a unified diff."
  :type '(choice (const :tag "Side by side" split)
                 (const :tag "Unified/stacked" stacked))
  :group 'diffs)

(defcustom diffs-fringe-bars t
  "When non-nil, show colored fringe bars on added and removed lines."
  :type 'boolean
  :group 'diffs)

(defcustom diffs-fringe-bar-width 2
  "Width in pixels of added and removed line bars in the left fringe.
Values outside the range 1 through 8 are clamped."
  :type 'integer
  :group 'diffs)

(defcustom diffs-diff-hl-display-function nil
  "Public diff-hl backend used to display a diffs-rendered hunk.
When nil, `diffs-diff-hl-mode' preserves the backend it replaces.
Direct uses of `diffs-diff-hl-show-hunk' fall back to
`diff-hl-show-hunk-inline'."
  :type '(choice
          (const :tag "Preserve the current diff-hl backend" nil)
          (const :tag "Show inline" diff-hl-show-hunk-inline)
          (const :tag "Show using posframe" diff-hl-show-hunk-posframe)
          (function :tag "Other public diff-hl backend"))
  :group 'diffs)

(defcustom diffs-split-full-width-backgrounds t
  "When non-nil, extend split-view change backgrounds across each row.
The line-number gutter receives the same theme-native background.
Word-level `diff-refine-added' and `diff-refine-removed' faces
remain layered above it."
  :type 'boolean
  :group 'diffs)

(defcustom diffs-index-width 36
  "Width in columns of the changed-file index side window."
  :type 'integer
  :group 'diffs)

(defcustom diffs-context-step 10
  "Number of unchanged lines revealed by `diffs-expand-context'."
  :type 'natnum
  :group 'diffs)

(defcustom diffs-review-cli-install-path
  (expand-file-name "diffs" "~/.local/bin/")
  "File where `diffs-review-install-agent-tools' installs the CLI."
  :type 'file
  :group 'diffs)

(defcustom diffs-review-skill-install-directory
  (expand-file-name "diffs-review" "~/.agents/skills/")
  "Directory where `diffs-review-install-agent-tools' installs the skill."
  :type 'directory
  :group 'diffs)

(defcustom diffs-review-assets-directory
  (locate-user-emacs-file "diffs-assets/")
  "Directory for durable CLI and skill copies materialized by diffs.el.
Package-manager build directories need contain only root-level Elisp
files; these copies therefore remain usable independently of a source
checkout or package upgrade."
  :type 'directory
  :group 'diffs)

(defcustom diffs-line-diff-type 'word-alt
  "Granularity used to emphasize changes within paired lines.
`word-alt' uses word-level matching and expands tiny unchanged
separators into adjacent changed spans, matching the visual behavior
of diffs.com.  `word' keeps exact token boundaries, `char' compares
Unicode characters, and `none' disables within-line emphasis."
  :type '(choice (const :tag "Word, visually grouped" word-alt)
                 (const :tag "Exact word tokens" word)
                 (const :tag "Characters" char)
                 (const :tag "Disabled" none))
  :group 'diffs)

(defcustom diffs-max-line-diff-length 1000
  "Maximum line length eligible for within-line emphasis.
Longer lines retain their full-line added or removed background but
skip the more expensive token comparison.  Zero means no limit."
  :type 'natnum
  :group 'diffs)

(defcustom diffs-line-pair-threshold 0.6
  "Maximum normalized edit distance for pairing removed and added lines.
Zero pairs only identical lines; one allows any two lines to pair."
  :type 'float
  :group 'diffs)

(defcustom diffs-line-pair-limit 64
  "Maximum number of lines per side for global change-block alignment.
Larger blocks fall back to ordinal pairing, bounding render latency."
  :type 'natnum
  :group 'diffs)

(defcustom diffs-refine-whitespace 'show
  "Whether within-line emphasis includes whitespace changes.
`show' treats whitespace runs as tokens, like diffs.com's word diff.
`ignore' excludes whitespace tokens from matching and emphasis."
  :type '(choice (const :tag "Show whitespace changes" show)
                 (const :tag "Ignore whitespace changes" ignore))
  :group 'diffs)

(defcustom diffs-fullscreen t
  "When non-nil, the diffs view takes over the whole frame.
`diffs-quit' (bound to \\`q') restores the previous window layout."
  :type 'boolean
  :group 'diffs)

(defcustom diffs-buffer-name "*diffs*"
  "Name of the buffer used to display diffs."
  :type 'string
  :group 'diffs)

(defcustom diffs-token-interactions-on-whitespace nil
  "When non-nil, token interaction APIs include whitespace tokens.
Line and column coordinates are available on every source line either
way; this option controls whether whitespace itself is hoverable and
clickable."
  :type 'boolean
  :group 'diffs)

(defcustom diffs-token-source-functions nil
  "Functions that resolve a diffs token to a source position.
Each function receives one token plist and may return a cons
\(BUFFER . POSITION).  The first non-nil result wins.  The built-in
worktree or revision resolver runs when every function returns nil."
  :type 'hook
  :group 'diffs)

(defcustom diffs-token-hover-functions nil
  "Functions that produce documentation for a diffs token.
Each function receives one token plist.  The first non-nil result is
returned before `diffs-eldoc-function' consults the source buffer's
Eldoc providers."
  :type 'hook
  :group 'diffs)

(defcustom diffs-token-click-functions nil
  "Functions called when a token is clicked in a diffs view.
Each function receives the token plist and the input event.  When this
hook is empty, `diffs-token-click' visits the exact source position."
  :type 'hook
  :group 'diffs)

(defcustom diffs-render-cache-limit 64
  "Maximum number of syntax-rendered source revisions kept globally.
Zero disables reuse between review buffers.  Raw source remains owned
by each review and is not counted in this limit."
  :type 'natnum
  :group 'diffs)

(defcustom diffs-syntax-idle-delay 0.05
  "Idle seconds before diffs.el syntax-renders one queued source.
Source text is available immediately; only source-mode faces wait for
the idle worker."
  :type 'number
  :group 'diffs)

(defcustom diffs-file-header-function #'diffs-default-file-header
  "Function that renders a file header from one context plist.
The function returns a string or nil.  The context includes `:view',
`:section', `:file', `:old-file', `:adds', `:dels', `:item-type',
`:item-id', and `:item-version'."
  :type 'function
  :group 'diffs)

(defcustom diffs-gutter-function #'diffs-default-gutter
  "Function that renders a line-number gutter from one context plist.
The function returns a string or nil.  Context keys include `:view',
`:section', `:file', `:side', `:kind', `:width', `:old-line',
`:new-line', `:line-numbers', `:continuation', and `:face'."
  :type 'function
  :group 'diffs)

(defcustom diffs-hunk-separator-function
  #'diffs-default-hunk-separator
  "Function that renders a hunk separator from one context plist.
The function returns a string or nil.  Context keys include `:view',
`:section', `:hunk', `:file', `:item-type', `:context', `:count',
`:visible', `:hidden', `:direction', and `:context-step'."
  :type 'function
  :group 'diffs)

(defface diffs-line-number
  '((t :inherit shadow))
  "Face for the line-number columns.")

(defface diffs-file-header
  '((t :inherit diff-file-header :extend t))
  "Face for the per-file header line.")

(defface diffs-file-stats-added
  '((t :inherit diff-indicator-added))
  "Face for the \"+N\" part of a file header.")

(defface diffs-file-stats-removed
  '((t :inherit diff-indicator-removed))
  "Face for the \"−N\" part of a file header.")

(defface diffs-hunk-separator
  '((t :inherit shadow :extend t))
  "Face for the hunk separator line.")

(defface diffs-filler
  '((t :inherit hl-line :extend t))
  "Face for alignment filler lines in the side-by-side view.
Inherits `hl-line': a tint close to, but distinguishable from,
the background in any theme.")

(defface diffs-split-added-line
  '((t :inherit diff-added :extend t))
  "Full-width added-line face in the side-by-side view.")

(defface diffs-split-removed-line
  '((t :inherit diff-removed :extend t))
  "Full-width removed-line face in the side-by-side view.")

(defface diffs-index-current-file
  '((t :inherit highlight :extend t))
  "Face for the current file in the changed-file index.")

(defface diffs-review-selection
  '((t :inherit region :extend t))
  "Face for a stable selected diff-line range.")

(defface diffs-review-annotation
  '((t :inherit font-lock-doc-face))
  "Face for inline review annotation text.")

(defface diffs-review-annotation-border
  '((t :inherit shadow))
  "Face for inline review annotation borders and metadata.")

(defface diffs-review-decision
  '((t :inherit success))
  "Face for accepted and rejected change-block decision labels.")

(defface diffs-conflict-current
  '((t :inherit diff-added :extend t))
  "Face for the Current section of a merge conflict.")

(defface diffs-conflict-incoming
  '((t :inherit diff-changed :extend t))
  "Face for the Incoming section of a merge conflict.")

(defface diffs-conflict-base
  '((t :inherit shadow :extend t))
  "Face for the Base section of a diff3 merge conflict.")

(defface diffs-conflict-current-marker
  '((t :inherit (diff-refine-added diffs-conflict-current)
       :weight semi-bold :extend t))
  "Emphasized face for the Current opening marker.")

(defface diffs-conflict-incoming-marker
  '((t :inherit (diff-refine-changed diffs-conflict-incoming)
       :weight semi-bold :extend t))
  "Emphasized face for the Incoming closing marker.")

(defface diffs-conflict-marker-label
  '((t :inherit shadow :weight normal))
  "Face for the descriptive label appended to a conflict marker.")

(defface diffs-conflict-marker
  '((t :inherit diff-header :extend t))
  "Face for neutral merge-conflict marker lines.")

(defface diffs-conflict-action
  '((t :inherit diff-header :extend t))
  "Face for the action row above a merge conflict.")

(defface diffs-conflict-stale
  '((t :inherit warning :extend t))
  "Face for a merge-conflict block edited outside diffs.el.")

(defun diffs--line-prefix-face (change-face)
  "Return the line-number face, optionally layered over CHANGE-FACE."
  (if change-face
      (list 'diffs-line-number change-face)
    'diffs-line-number))

(defun diffs--define-fringe-bitmap ()
  "Define the full-height bitmap used by `diffs-fringe-bars'."
  (when (fboundp 'define-fringe-bitmap)
    (let* ((scale (if (and (boundp 'text-scale-mode-amount)
                           (boundp 'text-scale-mode-step)
                           (numberp text-scale-mode-amount))
                      (expt text-scale-mode-step text-scale-mode-amount)
                    1))
           (spacing (or (and (display-graphic-p)
                             (default-value 'line-spacing))
                        0))
           (spacing (pcase spacing
                      ((pred numberp) spacing)
                      (`(,above . ,below) (+ above below))
                      (_ 0)))
           (width (max 1 (min 8 diffs-fringe-bar-width)))
           (height (max 1
                        (+ (ceiling (* (frame-char-height) scale))
                           (if (floatp spacing)
                               (truncate (* (frame-char-height) spacing))
                             spacing))))
           (bits (1- (ash 1 width))))
      (define-fringe-bitmap
       'diffs-fringe-bar
       (make-vector height bits)
       height width 'center))))

(defun diffs--fringe-face-prefix (face)
  "Return a fringe bar prefix using FACE, or an empty string."
  (if (and diffs-fringe-bars face)
      (propertize
       " " 'display `(left-fringe diffs-fringe-bar ,face))
    ""))

(defun diffs--fringe-prefix (indicator)
  "Return a fringe bar prefix for diff INDICATOR, or an empty string."
  (let ((face (pcase indicator
                (?+ 'diff-indicator-added)
                (?- 'diff-indicator-removed))))
    (diffs--fringe-face-prefix face)))

(defvar-local diffs--stats nil
  "List (FILES ADDED REMOVED) accumulated by the last scan.")

(defvar-local diffs--sections nil
  "List of file-section plists built by `diffs--scan'.
Each element: (:beg N :block-end N :end N :file S :adds N :dels N
:index N :width N
:hunks ((POS OLD-START NEW-START END CONTEXT OLD-COUNT NEW-COUNT) ...)).")

(defvar-local diffs--section-vector []
  "Vector form of `diffs--sections' for position lookup.")

(defvar-local diffs--revision nil
  "Reference revision this buffer was generated against, or nil.")

(defvar-local diffs--target-revision nil
  "Target revision for commit views, or nil for the working tree.")

(defvar-local diffs--independent-sources nil
  "Non-nil when old and new sides are independently selected files.")

(defvar-local diffs--context-gaps nil
  "Expandable unchanged gaps preceding hunks in this diff.
A leading gap has direction `up'; a gap following an earlier hunk has
direction `down'.")

(defvar-local diffs--context-gap-table nil
  "EQ hash table mapping parsed hunks to their unchanged gaps.")

(defvar-local diffs--old-content-cache nil
  "Section-keyed cache of complete old-side file line vectors.")

(defvar-local diffs--new-content-cache nil
  "Section-keyed cache of complete new-side file line vectors.")

(defvar-local diffs--old-raw-content-cache nil
  "Section-keyed cache of unfontified old-side source vectors.")

(defvar-local diffs--new-raw-content-cache nil
  "Section-keyed cache of unfontified new-side source vectors.")

(defvar-local diffs--source-render-identities nil
  "Hash table mapping section/side pairs to pending render keys.")

(defvar-local diffs--source-render-generation 0
  "Generation used to reject stale asynchronous source rendering.")

(defvar-local diffs--intraline-cache nil
  "Cache mapping paired line contents and options to changed ranges.")

(defvar-local diffs--refined-blocks nil
  "Hash table of change blocks already refined in the unified view.")

(defvar-local diffs--minor-mode-saved-state nil
  "External buffer state saved while `diffs-minor-mode' is active.")

(defvar-local diffs--item-ranges nil
  "Source ranges and metadata supplied by `diffs-items'.")

(defvar-local diffs--token-source-buffers nil
  "Alist of historical source buffers owned by this review buffer.")

(defvar-local diffs--token-source-owner nil
  "Review owner of an internal historical source buffer.")

(defconst diffs--missing-content (make-symbol "diffs-missing-content"))

(defvar diffs--render-cache (make-hash-table :test #'equal)
  "Shared cache of syntax-rendered source line vectors.")

(defvar diffs--render-cache-order nil
  "Most-recently-used render cache keys, newest first.")

(defvar diffs--render-jobs (make-hash-table :test #'equal)
  "Queued source render jobs indexed by render key.")

(defvar diffs--render-queue nil
  "Stack of source render keys awaiting idle fontification.")

(defvar diffs--render-idle-timer nil
  "Idle timer servicing `diffs--render-queue'.")

(defvar diffs--render-theme-generation 0
  "Generation included in source render cache keys.")

(defconst diffs--source-render-version 1
  "Version of syntax-rendered source cache entries.")

(defconst diffs--file-header-path-width 72
  "Maximum display width used for paths in default file headers.")

(defconst diffs--hunk-re "^@@ -\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? \\+\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? @@\\(.*\\)$")

;;;; Scanning

(defun diffs--section-end ()
  "Return the end position of the file section starting at point."
  (save-excursion
    (forward-line 1)
    (if (re-search-forward "^diff \\|^Index: " nil t)
        (line-beginning-position)
      (point-max))))

(defun diffs--header-block-end (limit)
  "Return the end of the header block starting at point, before LIMIT."
  (save-excursion
    (forward-line 1)
    (while (and (< (point) limit)
                (looking-at "^\\(?:old mode\\|new mode\\|deleted file\\|new file\\|copy \\|rename \\|similarity \\|dissimilarity \\|index \\|--- \\|\\+\\+\\+ \\|Binary files \\|GIT binary patch\\|=\\{4,\\}\\)"))
      (forward-line 1))
    (point)))

(defun diffs--decode-git-path (path)
  "Decode PATH from Git's double-quoted pathname representation."
  (if (multibyte-string-p path)
      path
    (decode-coding-string
     path
     (or file-name-coding-system
         default-file-name-coding-system
         locale-coding-system
         'utf-8))))

(defun diffs--git-path-token (text &optional start)
  "Read one Git pathname token from TEXT at START.
Return (PATH . END), where END is the next position in TEXT."
  (when-let* ((start (string-match "[^ \t]" text (or start 0))))
    (if (eq (aref text start) ?\")
        (condition-case nil
            (pcase-let* ((`(,path . ,end) (read-from-string text start)))
              (cons (diffs--decode-git-path path) end))
          (error nil))
      (let ((end (or (string-match "[ \t]" text start) (length text))))
        (cons (substring text start end) end)))))

(defun diffs--strip-git-prefix (path)
  "Strip Git's a/ or b/ prefix from PATH."
  (if (string-match-p "\\`[ab]/" path)
      (substring path 2)
    path))

(defun diffs--git-header-paths ()
  "Return the old and new paths from a `diff --git' line at point."
  (when (looking-at "^diff --git \\(.*\\)$")
    (let* ((text (match-string-no-properties 1))
           (old (diffs--git-path-token text))
           (new (and old (diffs--git-path-token text (cdr old)))))
      (when new
        (list (diffs--strip-git-prefix (car old))
              (diffs--strip-git-prefix (car new)))))))

(defun diffs--marker-path (text)
  "Return the pathname encoded by diff marker TEXT."
  (let ((path
         (if (string-prefix-p "\"" text)
             (car (diffs--git-path-token text))
           (car (split-string text "\t")))))
    (unless (equal path "/dev/null")
      (diffs--strip-git-prefix path))))

(defun diffs--marker-header-paths (block-end)
  "Return old and new marker paths before BLOCK-END."
  (save-excursion
    (when (re-search-forward "^--- \\(.+\\)$" block-end t)
      (let ((old
             (diffs--marker-path
              (match-string-no-properties 1))))
        (when (re-search-forward "^\\+\\+\\+ \\(.+\\)$" block-end t)
          (list
           old
           (diffs--marker-path
            (match-string-no-properties 1))))))))

(defun diffs--file-name-at-header ()
  "Extract the file name from the diff header at point."
  (save-excursion
    (let ((git-paths (diffs--git-header-paths)))
      (cond
       (git-paths (cadr git-paths))
       ((looking-at "^diff --\\(?:cc\\|combined\\) \\(.+\\)$")
        (let ((path (car (diffs--git-path-token
                          (match-string-no-properties 1)))))
          (and path (diffs--strip-git-prefix path))))
       ((looking-at "^\\(?:diff\\|Index:\\) .*?\\([^ \t/]+\\)$")
        (match-string-no-properties 1))))))

(defun diffs--clear-context ()
  "Remove displayed unchanged context and its cached source content."
  (diffs--token-source-cache-clear)
  (cl-incf diffs--source-render-generation)
  (dolist (gap diffs--context-gaps)
    (when-let* ((overlay (plist-get gap :overlay))
                ((overlayp overlay)))
      (delete-overlay overlay)))
  (setq diffs--context-gaps nil
        diffs--context-gap-table nil
        diffs--old-content-cache nil
        diffs--new-content-cache nil
        diffs--old-raw-content-cache nil
        diffs--new-raw-content-cache nil
        diffs--source-render-identities nil))

(defun diffs--scan-section (section-end)
  "Scan the file section starting at point, up to SECTION-END.
Return a section plist; see `diffs--sections'."
  (let* ((beg (point))
         (block-end (diffs--header-block-end section-end))
         (git-paths (diffs--git-header-paths))
         (marker-paths (diffs--marker-header-paths block-end))
         (file (or (cadr git-paths)
                   (cadr marker-paths)
                   (car git-paths)
                   (car marker-paths)
                   (diffs--file-name-at-header)))
         (old-file (or (car git-paths)
                       (car marker-paths)
                       file))
         (adds 0) (dels 0) (max-line 1) hunks)
    (save-excursion
      (while (re-search-forward diffs--hunk-re section-end t)
        (let* ((old (string-to-number (match-string 1)))
               (oldc (if (match-string 2) (string-to-number (match-string 2)) 1))
               (new (string-to-number (match-string 3)))
               (newc (if (match-string 4) (string-to-number (match-string 4)) 1))
               (context (string-trim (match-string-no-properties 5)))
               (hend (save-excursion
                       (or (and (re-search-forward "^@@ \\|^diff \\|^Index: "
                                                   section-end t)
                                (line-beginning-position))
                           section-end))))
          (push (list (line-beginning-position) old new hend context
                      oldc newc)
                hunks)
          (setq max-line (max max-line (+ old oldc) (+ new newc)))
          (cl-incf adds (count-matches "^\\+" (line-end-position) hend))
          (cl-incf dels (count-matches "^-" (line-end-position) hend)))))
    (list :beg beg :block-end block-end :end section-end
          :file file :old-file old-file
          :adds adds :dels dels
          :width (max 2 (length (number-to-string max-line)))
          :hunks (nreverse hunks))))

(defun diffs--section-default-item-id (section)
  "Return a stable default mixed-item id for SECTION."
  (format
   "diff:%s:%s"
   (or (plist-get section :file) "?")
   (or (plist-get section :index) 0)))

(defun diffs--annotate-item-sections (sections)
  "Attach mixed-item metadata to scanned SECTIONS."
  (let ((ranges diffs--item-ranges))
    (mapcar
     (lambda (section)
       (let ((begin (plist-get section :beg)))
         (while (and ranges
                     (<= (plist-get (car ranges) :end) begin))
           (pop ranges))
         (let ((range
                (and ranges
                     (<= (plist-get (car ranges) :begin) begin)
                     (< begin (plist-get (car ranges) :end))
                     (car ranges))))
           (setq section
                 (plist-put
                  section :item-type
                  (or (plist-get range :type) 'diff)))
           (setq section
                 (plist-put
                  section :item-id
                  (or (plist-get range :id)
                      (diffs--section-default-item-id section))))
           (setq section
                 (plist-put
                  section :item-version
                  (plist-get range :version)))
           (plist-put
            section :item-lines (plist-get range :lines)))))
     sections)))

(defun diffs--build-context-gaps ()
  "Build the expandable unchanged gap preceding each parsed hunk."
  (let ((table (make-hash-table :test #'eq))
        gaps)
    (dolist (section diffs--sections)
      (let ((old-end 1)
            (new-end 1)
            (direction 'up))
        (dolist (hunk (plist-get section :hunks))
          (let* ((old-start (nth 1 hunk))
                 (new-start (nth 2 hunk))
                 (count (max 0
                             (min (- old-start old-end)
                                  (- new-start new-end)))))
            (let ((gap (list :section section :hunk hunk
                             :old-start old-end :new-start new-end
                             :count count :visible 0 :overlay nil
                             :direction direction)))
              (push gap gaps)
              (puthash hunk gap table))
            (setq old-end (+ old-start (nth 5 hunk))
                  new-end (+ new-start (nth 6 hunk))
                  direction 'down)))))
    (setq diffs--context-gaps (nreverse gaps)
          diffs--context-gap-table table
          diffs--old-content-cache (make-hash-table :test #'eq)
          diffs--new-content-cache (make-hash-table :test #'eq)
          diffs--old-raw-content-cache (make-hash-table :test #'eq)
          diffs--new-raw-content-cache (make-hash-table :test #'eq)
          diffs--source-render-identities
          (make-hash-table :test #'eq))))

(defun diffs--scan ()
  "Scan the buffer.  Sets `diffs--sections' and `diffs--stats'."
  (diffs--clear-context)
  (save-excursion
    (goto-char (point-min))
    (let (sections (nfiles 0) (nadds 0) (ndels 0))
      (while (not (eobp))
        (cond
         ((looking-at "^\\(?:diff \\|Index: \\|--- \\)")
          ;; A bare "--- " line is a header only when followed by +++.
          (if (and (looking-at "^--- ")
                   (not (save-excursion (forward-line 1)
                                        (looking-at "^\\+\\+\\+ "))))
              (forward-line 1)
            (let ((sec (diffs--scan-section (diffs--section-end))))
              (setq sec (plist-put sec :index (1+ nfiles)))
              (push sec sections)
              (cl-incf nfiles)
              (cl-incf nadds (plist-get sec :adds))
              (cl-incf ndels (plist-get sec :dels))
              (goto-char (plist-get sec :end)))))
         (t (forward-line 1))))
      (setq diffs--sections
            (diffs--annotate-item-sections (nreverse sections))
            diffs--section-vector (vconcat diffs--sections)
            diffs--stats (list nfiles nadds ndels))
      (diffs--build-context-gaps))))

(defun diffs--section-at-pos (position)
  "Return the file section containing POSITION, using binary search."
  (let ((low 0)
        (high (1- (length diffs--section-vector)))
        found)
    (while (and (not found) (<= low high))
      (let* ((middle (/ (+ low high) 2))
             (section (aref diffs--section-vector middle))
             (beg (plist-get section :beg))
             (end (plist-get section :end)))
        (cond
         ((< position beg) (setq high (1- middle)))
         ((>= position end) (setq low (1+ middle)))
         (t (setq found section)))))
    found))

(defun diffs--section-for-identity
    (item-id file &optional section-index)
  "Return the section identified by ITEM-ID, FILE, and SECTION-INDEX.
An exact stable ITEM-ID is authoritative.  A generated ordinary-diff
id may fall back to FILE only when that path is unique; mixed items and
duplicate paths are never guessed.  SECTION-INDEX is zero based."
  (let ((indexed
         (and section-index (nth section-index diffs--sections))))
    (or
     (and indexed
          (or (null item-id)
              (equal item-id (plist-get indexed :item-id)))
          indexed)
     (and item-id
          (cl-find
           item-id diffs--sections
           :key (lambda (section)
                  (plist-get section :item-id))
           :test #'equal))
     (and
      file
      (or (null item-id)
          (string-prefix-p "diff:" item-id))
      (cl-loop
       with match
       for section in diffs--sections
       when (equal file (plist-get section :file))
       if match return nil
       else do (setq match section)
       finally return match))
     (and (null item-id) indexed))))

(defun diffs--hunk-at-pos (section position)
  "Return the hunk in SECTION containing POSITION."
  (cl-find-if (lambda (hunk)
                (and (<= (car hunk) position)
                     (< position (diffs--hunk-end hunk section))))
              (plist-get section :hunks)))

(defun diffs--gap-for-hunk (hunk)
  "Return the unchanged context gap associated with HUNK."
  (and diffs--context-gap-table
       (gethash hunk diffs--context-gap-table)))

(defun diffs--context-gap-fully-visible-p (gap)
  "Return non-nil when GAP has context and all of it is visible."
  (let ((count (and gap (plist-get gap :count))))
    (and count
         (> count 0)
         (= (plist-get gap :visible) count))))

(defun diffs--string-lines (string)
  "Return STRING as a vector of lines, without a final newline entry."
  (if (string-empty-p string)
      []
    (let ((lines (split-string string "\n" nil)))
      (when (and (string-suffix-p "\n" string)
                 (equal (car (last lines)) ""))
        (setq lines (butlast lines)))
      (vconcat lines))))

(defun diffs--sanitize-synthetic-source ()
  "Make the current synthetic source safe to kill without prompting."
  (setq buffer-file-name nil
        buffer-offer-save nil)
  (setq-local kill-buffer-query-functions nil)
  (set-buffer-modified-p nil))

(defun diffs--fontified-lines-result (string file)
  "Return (LINES . SUCCESS) after syntax-fontifying STRING as FILE.
Mode hooks and file-local variables are not run.  On failure, LINES is
the original unfontified text and SUCCESS is nil."
  (condition-case nil
      (cons
       (with-temp-buffer
         (unwind-protect
             (progn
               (insert string)
               (let ((buffer-file-name
                      (and file
                           (expand-file-name file default-directory)))
                     (enable-local-variables nil)
                     (enable-local-eval nil))
                 (delay-mode-hooks
                   (set-auto-mode))
                 (font-lock-mode 1)
                 (font-lock-ensure (point-min) (point-max))
                 (diffs--string-lines
                  (buffer-substring (point-min) (point-max)))))
           ;; A source mode may leave this synthetic buffer looking like a
           ;; modified file.  Sanitize it before `with-temp-buffer' kills it
           ;; so context expansion can never ask the user to save it.
           (diffs--sanitize-synthetic-source)))
       t)
    (error (cons (diffs--string-lines string) nil))))

(defun diffs--context-source-root ()
  "Return the stable source root for unchanged context."
  (or (bound-and-true-p diffs--review-repository)
      default-directory))

(defun diffs--revision-lines (file revision)
  "Return complete unfontified FILE at REVISION as a vector of lines."
  (unless file
    (error "Diff has no source path"))
  (unless diff-vc-backend
    (error "Review has no VC backend"))
  (let* ((backend diff-vc-backend)
         (root (diffs--context-source-root))
         (absolute (expand-file-name file root)))
    (with-temp-buffer
      (setq default-directory root)
      (vc-call-backend backend 'find-revision
                       absolute revision (current-buffer))
      (diffs--string-lines
       (buffer-substring-no-properties (point-min) (point-max))))))

(defun diffs--worktree-lines (file)
  "Return complete unfontified working-tree FILE as a vector of lines.
Prefer a live visiting buffer so unsaved changes are represented."
  (unless file
    (error "Diff has no working-tree path"))
  (let ((absolute
         (expand-file-name file (diffs--context-source-root))))
    (cond
     ((find-buffer-visiting absolute)
      (with-current-buffer (find-buffer-visiting absolute)
        (diffs--string-lines
         (buffer-substring-no-properties (point-min) (point-max)))))
     ((file-readable-p absolute)
      (with-temp-buffer
        (insert-file-contents absolute)
        (diffs--string-lines
         (buffer-substring-no-properties (point-min) (point-max)))))
     (t
      (error "Working-tree file is not readable: %s" absolute)))))

(defun diffs--content-failure-p (value)
  "Return non-nil when VALUE is a cached source-loading failure."
  (and value (not (vectorp value))))

(defun diffs--section-content-error (section side)
  "Return the cached source error for SECTION on SIDE, if any."
  (let* ((cache
          (if (eq side 'old)
              diffs--old-content-cache
            diffs--new-content-cache))
         (value (gethash section cache)))
    (and (diffs--content-failure-p value)
         (if (and (consp value) (stringp (cdr value)))
             (cdr value)
           "Source was unavailable before diffs.el was reloaded"))))

(defun diffs--source-lines-string (lines)
  "Return plain source text represented by line vector LINES."
  (mapconcat
   (lambda (line)
     (substring-no-properties line))
   lines "\n"))

(defun diffs--source-language (file text)
  "Return the safely inferred major mode for FILE containing TEXT."
  (condition-case nil
      (with-temp-buffer
        (unwind-protect
            (progn
              ;; File names decide nearly every mode.  A short prefix keeps
              ;; interpreter and first-line mode cookies available without
              ;; copying a large historical source on the command path.
              (insert
               (substring text 0 (min 4096 (length text))))
              (let ((buffer-file-name file)
                    (enable-local-variables nil)
                    (enable-local-eval nil))
                (delay-mode-hooks
                  (set-auto-mode)))
              major-mode)
          (setq buffer-file-name nil
                buffer-offer-save nil)
          (setq-local kill-buffer-query-functions nil)
          (set-buffer-modified-p nil)))
    (error 'fundamental-mode)))

(defun diffs--source-render-key
    (root file side revision lines language &optional text)
  "Return a complete syntax render key.
ROOT, FILE, SIDE, REVISION, LINES, and LANGUAGE are all render inputs;
the current theme generation is included automatically.  Optional TEXT
avoids rebuilding the already available plain source string."
  (list
   :root (file-name-as-directory (expand-file-name root))
   :file file
   :side side
   :revision revision
   :renderer diffs--source-render-version
   :content
   (secure-hash
    'sha1 (or text (diffs--source-lines-string lines)))
   :language language
   :theme diffs--render-theme-generation))

(defun diffs--render-cache-get (key)
  "Return cached syntax lines for KEY and mark the entry recent."
  (if (zerop diffs-render-cache-limit)
      (progn
        (clrhash diffs--render-cache)
        (setq diffs--render-cache-order nil)
        nil)
    (when-let* ((value (gethash key diffs--render-cache)))
      (setq diffs--render-cache-order
            (cons key (delete key diffs--render-cache-order)))
      value)))

(defun diffs--render-cache-put (key lines)
  "Cache immutable syntax LINES under KEY within the configured bound."
  (if (zerop diffs-render-cache-limit)
      (diffs--render-cache-clear)
    (puthash key lines diffs--render-cache)
    (setq diffs--render-cache-order
          (cons key (delete key diffs--render-cache-order)))
    (while (> (length diffs--render-cache-order)
              diffs-render-cache-limit)
      (let ((oldest (car (last diffs--render-cache-order))))
        (setq diffs--render-cache-order
              (butlast diffs--render-cache-order))
        (remhash oldest diffs--render-cache))))
  lines)

(defun diffs--render-cache-clear ()
  "Clear shared syntax renders without touching review-owned raw text."
  (clrhash diffs--render-cache)
  (setq diffs--render-cache-order nil))

(defun diffs--source-render-identity (section side)
  "Return the pending render identity for SECTION on SIDE."
  (let ((entry (gethash section diffs--source-render-identities)))
    (if (eq side 'old) (car entry) (cdr entry))))

(defun diffs--source-render-current-p (section side)
  "Return non-nil when SECTION SIDE has a current render identity."
  (equal
   (plist-get
    (diffs--source-render-identity section side)
    :renderer)
   diffs--source-render-version))

(defun diffs--set-source-render-identity (section side key)
  "Record KEY as the pending render identity for SECTION on SIDE."
  (let ((entry (gethash section diffs--source-render-identities)))
    (puthash
     section
     (if (eq side 'old)
         (cons key (cdr entry))
       (cons (car entry) key))
     diffs--source-render-identities)))

(defun diffs--source-render-publish (key lines waiter)
  "Publish rendered LINES for KEY to a generation-checked WAITER."
  (let ((owner (plist-get waiter :owner))
        (generation (plist-get waiter :generation))
        (section (plist-get waiter :section))
        (side (plist-get waiter :side)))
    (when (buffer-live-p owner)
      (with-current-buffer owner
        (when (and (= generation diffs--source-render-generation)
                   (equal
                    key
                    (diffs--source-render-identity section side)))
          (puthash
           section lines
           (if (eq side 'old)
               diffs--old-content-cache
             diffs--new-content-cache))
          (dolist (gap diffs--context-gaps)
            (when (and (eq section (plist-get gap :section))
                       (> (plist-get gap :visible) 0))
              (diffs--render-context-gap gap)))
          (diffs--refresh-split-source-faces
           owner section side)
          (force-window-update owner))))))

(defun diffs--source-render-reject (key waiter)
  "Reject failed render KEY for WAITER so a later read can retry."
  (let ((owner (plist-get waiter :owner))
        (generation (plist-get waiter :generation))
        (section (plist-get waiter :section))
        (side (plist-get waiter :side)))
    (when (buffer-live-p owner)
      (with-current-buffer owner
        (when (and (= generation diffs--source-render-generation)
                   (equal
                    key
                    (diffs--source-render-identity section side)))
          (diffs--set-source-render-identity section side nil))))))

(defun diffs--render-ensure-timer ()
  "Ensure an idle worker is scheduled for the source render queue."
  (when (and diffs--render-queue
             (not diffs--render-idle-timer))
    (setq diffs--render-idle-timer
          (run-with-idle-timer
           diffs-syntax-idle-delay nil
           #'diffs--render-run-next))))

(defun diffs--render-run-next ()
  "Syntax-render and publish the next queued source revision."
  (setq diffs--render-idle-timer nil)
  (when-let* ((key (pop diffs--render-queue))
              (job (gethash key diffs--render-jobs)))
    (remhash key diffs--render-jobs)
    (let* ((result
            (diffs--fontified-lines-result
             (plist-get job :text)
             (plist-get job :file)))
           (lines (car result))
           (success (cdr result)))
      (if success
          (progn
            (diffs--render-cache-put key lines)
            (dolist (waiter (plist-get job :waiters))
              (diffs--source-render-publish key lines waiter)))
        (remhash key diffs--render-cache)
        (setq diffs--render-cache-order
              (delete key diffs--render-cache-order))
        (dolist (waiter (plist-get job :waiters))
          (diffs--source-render-reject key waiter)))))
  (diffs--render-ensure-timer))

(defun diffs--schedule-source-render
    (section side lines)
  "Schedule syntax rendering for SECTION SIDE using raw LINES.
Return cached rendered lines immediately when available, otherwise nil."
  (let* ((old (eq side 'old))
         (file (if old
                   (or (plist-get section :old-file)
                       (plist-get section :file))
                 (plist-get section :file)))
         (revision (if old diffs--revision diffs--target-revision))
         (root (diffs--context-source-root))
         (absolute (and file (expand-file-name file root)))
         (text (diffs--source-lines-string lines))
         (language (diffs--source-language absolute text))
         (key
          (diffs--source-render-key
           root file side revision lines language text))
         (waiter
          (list :owner (current-buffer)
                :generation diffs--source-render-generation
                :section section
                :side side))
         (cached (diffs--render-cache-get key)))
    (diffs--set-source-render-identity section side key)
    (if cached
        (progn
          (diffs--source-render-publish key cached waiter)
          cached)
      (let ((job (gethash key diffs--render-jobs)))
        (if job
            (unless
                (cl-find-if
                 (lambda (existing)
                   (and
                    (eq (plist-get existing :owner)
                        (current-buffer))
                    (eq (plist-get existing :section) section)
                    (eq (plist-get existing :side) side)
                    (= (plist-get existing :generation)
                       diffs--source-render-generation)))
                 (plist-get job :waiters))
              (setf (plist-get job :waiters)
                    (cons waiter (plist-get job :waiters))))
          (puthash
           key
           (list :text text
                 :file absolute
                 :waiters (list waiter))
           diffs--render-jobs)
          (push key diffs--render-queue))
        (diffs--render-ensure-timer)
        nil))))

(defun diffs--section-raw-lines (section side)
  "Load or return unfontified source lines for SECTION on SIDE."
  (let* ((old (eq side 'old))
         (cache
          (if old
              diffs--old-raw-content-cache
            diffs--new-raw-content-cache))
         (cached (gethash section cache diffs--missing-content)))
    (cond
     ((vectorp cached) cached)
     ((and (hash-table-contains-p section cache)
           (consp cached))
      nil)
     ((hash-table-contains-p section cache)
      (remhash section cache)
      (diffs--section-raw-lines section side))
     (t
      (condition-case error-data
          (let ((lines
                 (if (eq (plist-get section :item-type) 'file)
                     (or (plist-get section :item-lines) [])
                   (if old
                     (if diffs--independent-sources
                         (diffs--worktree-lines
                          (or (plist-get section :old-file)
                              (plist-get section :file)))
                       (diffs--revision-lines
                        (plist-get section :old-file) diffs--revision))
                   (if diffs--target-revision
                       (diffs--revision-lines
                        (plist-get section :file)
                        diffs--target-revision)
                     (diffs--worktree-lines
                      (plist-get section :file)))))))
            (unless (vectorp lines)
              (error "Source loader returned no content"))
            (puthash section lines cache)
            lines)
        (error
         (puthash
          section
          (cons diffs--missing-content
                (error-message-string error-data))
          cache)
         nil))))))

(defun diffs--section-lines (section side)
  "Return complete line vector for SECTION on SIDE (`old' or `new')."
  (let* ((old (eq side 'old))
         (cache (if old diffs--old-content-cache diffs--new-content-cache))
         (cached (gethash section cache diffs--missing-content)))
    (cond
     ((and (hash-table-contains-p section cache)
           (vectorp cached))
      (if (diffs--source-render-current-p section side)
          cached
        (or (diffs--schedule-source-render section side cached)
            cached)))
     ((and (hash-table-contains-p section cache)
           (consp cached))
      nil)
     ;; Older live reviews cached an uninterned symbol for a failed load.
     ;; Retry it once after a package reload instead of keeping that stale
     ;; negative result for the lifetime of the review.
     ((hash-table-contains-p section cache)
      (remhash section cache)
      (diffs--section-lines section side))
     (t
      (if-let* ((lines (diffs--section-raw-lines section side)))
          (progn
            (puthash section lines cache)
            (or (diffs--schedule-source-render section side lines)
                lines))
        (let* ((raw-cache
                (if old
                    diffs--old-raw-content-cache
                  diffs--new-raw-content-cache))
               (failure (gethash section raw-cache)))
          (puthash section failure cache)
          nil))))))

(defun diffs--reset-owner-source-rendering (owner)
  "Reset rendered source state in OWNER while retaining its raw text."
  (with-current-buffer owner
    (cl-incf diffs--source-render-generation)
    (clrhash diffs--source-render-identities)
    (maphash
     (lambda (section lines)
       (when (vectorp lines)
         (puthash section lines diffs--old-content-cache)))
     diffs--old-raw-content-cache)
    (maphash
     (lambda (section lines)
       (when (vectorp lines)
         (puthash section lines diffs--new-content-cache)))
     diffs--new-raw-content-cache)
    (dolist (gap diffs--context-gaps)
      (when (> (plist-get gap :visible) 0)
        (diffs--render-context-gap gap)))
    (maphash
     (lambda (section lines)
       (when (vectorp lines)
         (diffs--schedule-source-render section 'old lines)))
     diffs--old-raw-content-cache)
    (maphash
     (lambda (section lines)
       (when (vectorp lines)
         (diffs--schedule-source-render section 'new lines)))
     diffs--new-raw-content-cache)))

(defun diffs--render-theme-changed (&rest _themes)
  "Invalidate syntax renders after a theme transition.
Raw source remains reusable and active reviews enqueue fresh rendering."
  (cl-incf diffs--render-theme-generation)
  (diffs--render-cache-clear)
  (when (timerp diffs--render-idle-timer)
    (cancel-timer diffs--render-idle-timer))
  (setq diffs--render-idle-timer nil
        diffs--render-queue nil)
  (clrhash diffs--render-jobs)
  (dolist (buffer (buffer-list))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (and diffs-minor-mode
                   (hash-table-p diffs--source-render-identities))
          (diffs--reset-owner-source-rendering buffer))))))

(add-hook 'enable-theme-functions #'diffs--render-theme-changed)
(add-hook 'disable-theme-functions #'diffs--render-theme-changed)

(defun diffs--signal-context-load-error (section)
  "Signal a detailed unchanged-context loading error for SECTION."
  (let ((old-error (diffs--section-content-error section 'old))
        (new-error (diffs--section-content-error section 'new)))
    (user-error
     "Cannot load unchanged context for %s%s"
     (or (plist-get section :file) "this file")
     (if (or old-error new-error)
         (format " (old: %s; new: %s)"
                 (or old-error "unavailable")
                 (or new-error "unavailable"))
       ""))))

(defun diffs--gap-visible-rows (gap)
  "Return visible unchanged rows for GAP.
Each row is (OLD-LINE NEW-LINE OLD-TEXT NEW-TEXT)."
  (let* ((visible (plist-get gap :visible))
         (count (plist-get gap :count))
         (section (plist-get gap :section))
         (old-lines (diffs--section-lines section 'old))
         (new-lines (diffs--section-lines section 'new))
         (offset (- count visible))
         rows)
    (unless (or (zerop visible) old-lines new-lines)
      (diffs--signal-context-load-error section))
    (dotimes (index visible)
      (let* ((old-number (+ (plist-get gap :old-start) offset index))
             (new-number (+ (plist-get gap :new-start) offset index))
             (old-text (and old-lines
                            (< (1- old-number) (length old-lines))
                            (aref old-lines (1- old-number))))
             (new-text (and new-lines
                            (< (1- new-number) (length new-lines))
                            (aref new-lines (1- new-number)))))
        (push (list old-number new-number
                    (or old-text new-text "")
                    (or new-text old-text ""))
              rows)))
    (nreverse rows)))

(defun diffs--context-text (text)
  "Return a copy of TEXT with context color below its syntax faces."
  (let ((copy (copy-sequence text)))
    (add-face-text-property 0 (length copy) 'diff-context t copy)
    copy))

;;;; Within-line diffing

(defun diffs--word-character-p (character)
  "Return non-nil when CHARACTER belongs to a word-like token."
  ;; Keep this in sync with the extended word-character ranges used by
  ;; jsdiff's `diffWordsWithSpace', which powers diffs.com's word modes.
  (or (and (>= character ?a) (<= character ?z))
      (and (>= character ?A) (<= character ?Z))
      (and (>= character ?0) (<= character ?9))
      (= character ?_)
      (= character #x00ad)
      (and (>= character #x00c0) (<= character #x00d6))
      (and (>= character #x00d8) (<= character #x00f6))
      (and (>= character #x00f8) (<= character #x02c6))
      (and (>= character #x02c8) (<= character #x02d7))
      (and (>= character #x02de) (<= character #x02ff))
      (and (>= character #x1e00) (<= character #x1eff))))

(defun diffs--word-whitespace-p (character)
  "Return non-nil when CHARACTER is word-diff whitespace."
  ;; Match JavaScript's `\s' set, except for LF and CR because within-line
  ;; strings do not include their line terminators.
  (or (memq character '(?\s ?\t #x000b #x000c))
      (= character #xfeff)
      (memq (get-char-code-property character 'general-category)
            '(Zs Zl Zp))))

(defun diffs--word-tokens (string)
  "Tokenize STRING into words, whitespace runs, and punctuation.
Return a vector of [TEXT START END] records using character offsets."
  (let ((position 0)
        (length (length string))
        tokens)
    (while (< position length)
      (let* ((start position)
             (character (aref string position))
             (whitespace (diffs--word-whitespace-p character))
             (word (diffs--word-character-p character)))
        (setq position
              (cond
               (whitespace
                (while (and (< (1+ position) length)
                            (diffs--word-whitespace-p
                             (aref string (1+ position))))
                  (cl-incf position))
                (1+ position))
               (word
                (while (and (< (1+ position) length)
                            (diffs--word-character-p
                             (aref string (1+ position))))
                  (cl-incf position))
                (1+ position))
               (t (1+ position))))
        (unless (and (eq diffs-refine-whitespace 'ignore) whitespace)
          (push (vector (substring string start position)
                        start position)
                tokens))))
    (vconcat (nreverse tokens))))

(defun diffs--character-tokens (string)
  "Tokenize STRING into Unicode characters with source offsets."
  (let (tokens)
    (dotimes (position (length string))
      (let ((character (aref string position)))
        (unless (and (eq diffs-refine-whitespace 'ignore)
                     (diffs--word-whitespace-p character))
          (push (vector (char-to-string character)
                        position (1+ position))
                tokens))))
    (vconcat (nreverse tokens))))

(defun diffs--tokens (string)
  "Return comparison tokens for STRING under `diffs-line-diff-type'."
  (if (eq diffs-line-diff-type 'char)
      (diffs--character-tokens string)
    (diffs--word-tokens string)))

(defun diffs--myers-changed-tokens (old-tokens new-tokens)
  "Return changed-token vectors for OLD-TOKENS and NEW-TOKENS.
The shortest edit script is computed with Myers' algorithm.  The
return value is (OLD-CHANGED . NEW-CHANGED), with one boolean slot per
input token."
  (let* ((old-count (length old-tokens))
         (new-count (length new-tokens))
         (maximum (+ old-count new-count))
         (offset (1+ maximum))
         (frontier (make-vector (+ (* 2 maximum) 3) 0))
         trace
         final-distance)
    (aset frontier (1+ offset) 0)
    (catch 'complete
      (dotimes (edit-distance (1+ maximum))
        (let ((diagonal (- edit-distance)))
          (while (<= diagonal edit-distance)
            (let* ((index (+ offset diagonal))
                   (x
                    (if (or (= diagonal (- edit-distance))
                            (and (/= diagonal edit-distance)
                                 (< (aref frontier (1- index))
                                    (aref frontier (1+ index)))))
                        (aref frontier (1+ index))
                      (1+ (aref frontier (1- index)))))
                   (y (- x diagonal)))
              (while (and (< x old-count)
                          (< y new-count)
                          (equal (aref (aref old-tokens x) 0)
                                 (aref (aref new-tokens y) 0)))
                (cl-incf x)
                (cl-incf y))
              (aset frontier index x)
              (when (and (>= x old-count) (>= y new-count))
                (setq final-distance edit-distance)))
            (cl-incf diagonal 2)))
        (push (copy-sequence frontier) trace)
        (when final-distance
          (throw 'complete nil))))
    (let ((old-changed (make-vector old-count nil))
          (new-changed (make-vector new-count nil))
          (history (vconcat (nreverse trace)))
          (x old-count)
          (y new-count))
      (cl-loop
       for edit-distance from final-distance downto 1
       do
       (let* ((previous (aref history (1- edit-distance)))
              (diagonal (- x y))
              (index (+ offset diagonal))
              (previous-diagonal
               (if (or (= diagonal (- edit-distance))
                       (and (/= diagonal edit-distance)
                            (< (aref previous (1- index))
                               (aref previous (1+ index)))))
                   (1+ diagonal)
                 (1- diagonal)))
              (previous-x
               (aref previous (+ offset previous-diagonal)))
              (previous-y (- previous-x previous-diagonal)))
         (while (and (> x previous-x) (> y previous-y))
           (cl-decf x)
           (cl-decf y))
         (if (= x previous-x)
             (progn
               (cl-decf y)
               (aset new-changed y t))
           (cl-decf x)
           (aset old-changed x t))))
      (while (and (> x 0) (> y 0)
                  (equal (aref (aref old-tokens (1- x)) 0)
                         (aref (aref new-tokens (1- y)) 0)))
        (cl-decf x)
        (cl-decf y))
      (while (> x 0)
        (cl-decf x)
        (aset old-changed x t))
      (while (> y 0)
        (cl-decf y)
        (aset new-changed y t))
      (cons old-changed new-changed))))

(defun diffs--utf-16-length (string)
  "Return STRING's length in UTF-16 code units."
  (let ((length 0))
    (mapc (lambda (character)
            (cl-incf length (if (> character #xffff) 2 1)))
          string)
    length))

(defun diffs--word-alt-expand
    (old-tokens new-tokens old-changed new-changed)
  "Expand tiny neutral spans shared by OLD-TOKENS and NEW-TOKENS.
OLD-CHANGED and NEW-CHANGED are mutated in place.  The scan keeps
one global edit-item sequence so a one-sided edit still separates
neutral items on the other side, matching diffs.com's `word-alt'."
  (let ((old-index 0)
        (new-index 0)
        (old-count (length old-tokens))
        (new-count (length new-tokens))
        old-last-changed-p
        new-last-changed-p)
    (while (or (< old-index old-count)
               (< new-index new-count))
      (let ((old-change-start old-index)
            (new-change-start new-index))
        (while (and (< old-index old-count)
                    (aref old-changed old-index))
          (cl-incf old-index))
        (while (and (< new-index new-count)
                    (aref new-changed new-index))
          (cl-incf new-index))
        (when (> old-index old-change-start)
          (setq old-last-changed-p t))
        (when (> new-index new-change-start)
          (setq new-last-changed-p t)))
      (when (and (< old-index old-count)
                 (< new-index new-count))
        (let ((old-neutral-start old-index)
              (new-neutral-start new-index)
              (neutral-length 0))
          (while (and (< old-index old-count)
                      (< new-index new-count)
                      (not (aref old-changed old-index))
                      (not (aref new-changed new-index)))
            (let ((old-text (aref (aref old-tokens old-index) 0))
                  (new-text (aref (aref new-tokens new-index) 0)))
              (unless (equal old-text new-text)
                (error "Aligned word-diff tokens differ"))
              (cl-incf neutral-length
                       (diffs--utf-16-length old-text)))
            (cl-incf old-index)
            (cl-incf new-index))
          ;; Diffs.com appends a one-code-unit neutral item to the
          ;; preceding changed item on each side, unless it is the final
          ;; global diff item.  A side with no preceding change remains
          ;; neutral even when the other side just inserted or removed.
          (if (and (= neutral-length 1)
                   (or (< old-index old-count)
                       (< new-index new-count)))
              (progn
                (when old-last-changed-p
                  (cl-loop for index from old-neutral-start
                           below old-index
                           do (aset old-changed index t)))
                (when new-last-changed-p
                  (cl-loop for index from new-neutral-start
                           below new-index
                           do (aset new-changed index t))))
            (setq old-last-changed-p nil
                  new-last-changed-p nil)))))
    (cons old-changed new-changed)))

(defun diffs--changed-ranges (tokens changed)
  "Convert CHANGED flags for TOKENS into coalesced source ranges."
  (let (ranges start end)
    (dotimes (index (length tokens))
      (when (aref changed index)
        (let ((token-start (aref (aref tokens index) 1))
              (token-end (aref (aref tokens index) 2)))
          (if (and end (= end token-start))
              (setq end token-end)
            (when end
              (push (cons start end) ranges))
            (setq start token-start
                  end token-end)))))
    (when end
      (push (cons start end) ranges))
    (nreverse ranges)))

(defun diffs--intraline-ranges (old-string new-string)
  "Return changed ranges for paired OLD-STRING and NEW-STRING.
The value is (OLD-RANGES . NEW-RANGES), where ranges use character
offsets into the respective strings."
  (let* ((key (list diffs-line-diff-type diffs-refine-whitespace
                    diffs-max-line-diff-length old-string new-string))
         (cache (or diffs--intraline-cache
                    (setq diffs--intraline-cache
                          (make-hash-table :test #'equal))))
         (missing (make-symbol "missing"))
         (cached (gethash key cache missing)))
    (if (not (eq cached missing))
        cached
      (let ((result
             (if (or (eq diffs-line-diff-type 'none)
                     (equal old-string new-string)
                     (and (> diffs-max-line-diff-length 0)
                          (or (> (length old-string)
                                 diffs-max-line-diff-length)
                              (> (length new-string)
                                 diffs-max-line-diff-length))))
                 '(nil)
               (let* ((old-tokens (diffs--tokens old-string))
                      (new-tokens (diffs--tokens new-string))
                      (changed
                       (diffs--myers-changed-tokens
                        old-tokens new-tokens))
                      (old-changed (car changed))
                      (new-changed (cdr changed)))
                 (when (eq diffs-line-diff-type 'word-alt)
                   (diffs--word-alt-expand
                    old-tokens new-tokens old-changed new-changed))
                 (cons (diffs--changed-ranges
                        old-tokens old-changed)
                       (diffs--changed-ranges
                        new-tokens new-changed))))))
        (puthash key result cache)
        result))))

(defun diffs--line-distance (old-string new-string)
  "Return normalized edit distance between OLD-STRING and NEW-STRING."
  (let* ((limit (and (> diffs-max-line-diff-length 0)
                     diffs-max-line-diff-length))
         (old (if (and limit (> (length old-string) limit))
                  (substring old-string 0 limit)
                old-string))
         (new (if (and limit (> (length new-string) limit))
                  (substring new-string 0 limit)
                new-string))
         (old (if (eq diffs-refine-whitespace 'ignore)
                  (replace-regexp-in-string "[[:space:]]+" "" old)
                old))
         (new (if (eq diffs-refine-whitespace 'ignore)
                  (replace-regexp-in-string "[[:space:]]+" "" new)
                new))
         (denominator (max 1 (length old) (length new))))
    (/ (float (string-distance old new)) denominator)))

(defun diffs--ordinal-line-pairs (old-count new-count)
  "Return ordinal alignment for OLD-COUNT and NEW-COUNT lines."
  (let ((index 0)
        pairs)
    (while (< index (max old-count new-count))
      (push (cons (and (< index old-count) index)
                  (and (< index new-count) index))
            pairs)
      (cl-incf index))
    (nreverse pairs)))

(defun diffs--align-lines-uncached (old-strings new-strings)
  "Globally align OLD-STRINGS with NEW-STRINGS.
Return ordered pairs of old/new indexes, using nil for an unpaired
line.  Small blocks use monotonic dynamic programming; large blocks
use bounded ordinal alignment."
  (let ((old-count (length old-strings))
        (new-count (length new-strings)))
    (cond
     ((zerop old-count)
      (mapcar (lambda (index) (cons nil index))
              (number-sequence 0 (1- new-count))))
     ((zerop new-count)
      (mapcar (lambda (index) (cons index nil))
              (number-sequence 0 (1- old-count))))
     ((and (= old-count 1) (= new-count 1))
      (if (<= (diffs--line-distance
               (aref old-strings 0) (aref new-strings 0))
              diffs-line-pair-threshold)
          '((0 . 0))
        '((0) (nil . 0))))
     ((or (> old-count diffs-line-pair-limit)
          (> new-count diffs-line-pair-limit))
      (diffs--ordinal-line-pairs old-count new-count))
     (t
      (let* ((gap-cost 0.5)
             (costs (make-vector (1+ old-count) nil))
             (directions (make-vector (1+ old-count) nil)))
        (dotimes (old-index (1+ old-count))
          (aset costs old-index (make-vector (1+ new-count) 0.0))
          (aset directions old-index (make-vector (1+ new-count) nil)))
        (dotimes (old-index old-count)
          (aset (aref costs (1+ old-index)) 0
                (* (1+ old-index) gap-cost))
          (aset (aref directions (1+ old-index)) 0 'old))
        (dotimes (new-index new-count)
          (aset (aref costs 0) (1+ new-index)
                (* (1+ new-index) gap-cost))
          (aset (aref directions 0) (1+ new-index) 'new))
        (dotimes (old-offset old-count)
          (dotimes (new-offset new-count)
            (let* ((old-index (1+ old-offset))
                   (new-index (1+ new-offset))
                   (line-distance
                    (diffs--line-distance
                     (aref old-strings old-offset)
                     (aref new-strings new-offset)))
                   (paired
                    (and (<= line-distance diffs-line-pair-threshold)
                         (+ (aref (aref costs old-offset) new-offset)
                            line-distance)))
                   (old-only
                    (+ (aref (aref costs old-offset) new-index)
                       gap-cost))
                   (new-only
                    (+ (aref (aref costs old-index) new-offset)
                       gap-cost))
                   (direction
                    (cond
                     ((and paired
                           (<= paired old-only)
                           (<= paired new-only))
                      'pair)
                     ((< old-only new-only) 'old)
                     (t 'new)))
                   (cost (pcase direction
                           ('pair paired)
                           ('old old-only)
                           ('new new-only))))
              (aset (aref costs old-index) new-index cost)
              (aset (aref directions old-index) new-index direction))))
        (let ((old-index old-count)
              (new-index new-count)
              pairs)
          (while (or (> old-index 0) (> new-index 0))
            (pcase (aref (aref directions old-index) new-index)
              ('pair
               (push (cons (1- old-index) (1- new-index)) pairs)
               (cl-decf old-index)
               (cl-decf new-index))
              ('old
               (push (cons (1- old-index) nil) pairs)
               (cl-decf old-index))
              ('new
               (push (cons nil (1- new-index)) pairs)
               (cl-decf new-index))))
          pairs))))))

(defun diffs--align-lines (old-strings new-strings)
  "Return cached global alignment of OLD-STRINGS and NEW-STRINGS."
  (let* ((key (list 'alignment
                    diffs-max-line-diff-length
                    diffs-line-pair-threshold
                    diffs-line-pair-limit
                    diffs-refine-whitespace
                    old-strings new-strings))
         (cache (or diffs--intraline-cache
                    (setq diffs--intraline-cache
                          (make-hash-table :test #'equal))))
         (missing (make-symbol "missing"))
         (cached (gethash key cache missing)))
    (if (eq cached missing)
        (let ((alignment
               (diffs--align-lines-uncached old-strings new-strings)))
          (puthash key alignment cache)
          alignment)
      cached)))

(defun diffs--change-blocks (hunk end)
  "Return changed-line blocks in HUNK ending at END.
Each block is (OLD-RECORDS . NEW-RECORDS), where a record is
[CONTENT-BEGIN CONTENT-END PLAIN-TEXT]."
  (let (blocks old new)
    (cl-labels
        ((flush
          ()
          (when (and old new)
            (push (cons (nreverse old) (nreverse new)) blocks))
          (setq old nil new nil))
         (record
          ()
          (let ((begin (min (1+ (line-beginning-position))
                            (line-end-position)))
                (finish (line-end-position)))
            (vector begin finish
                    (buffer-substring-no-properties begin finish)))))
      (save-excursion
        (goto-char (car hunk))
        (forward-line 1)
        (while (and (< (point) end) (not (eobp)))
          (pcase (char-after)
            (?-
             (push (record) old))
            (?+
             (push (record) new))
            (?\\ nil)
            (_ (flush)))
          (forward-line 1))
        (flush)))
    (nreverse blocks)))

(defun diffs--block-intersects-p (block begin end)
  "Return non-nil when changed BLOCK intersects BEGIN..END."
  (let* ((records (append (car block) (cdr block)))
         (first (car records))
         (last (car (last records))))
    (and first
         (< (aref first 0) end)
         (> (aref last 1) begin))))

(defun diffs--make-intraline-overlay (begin end face)
  "Emphasize BEGIN..END with FACE in the unified view."
  (when (< begin end)
    (let ((overlay (make-overlay begin end nil nil nil)))
      (overlay-put overlay 'diffs-intraline t)
      (overlay-put overlay 'evaporate t)
      (overlay-put overlay 'face face))))

(defun diffs--refine-change-block (block)
  "Apply within-line emphasis to a unified-view change BLOCK."
  (let* ((old-records (vconcat (car block)))
         (new-records (vconcat (cdr block)))
         (old-strings
          (vconcat (mapcar (lambda (record) (aref record 2))
                           (car block))))
         (new-strings
          (vconcat (mapcar (lambda (record) (aref record 2))
                           (cdr block)))))
    (dolist (pair (diffs--align-lines old-strings new-strings))
      (when (and (car pair) (cdr pair))
        (let* ((old-record (aref old-records (car pair)))
               (new-record (aref new-records (cdr pair)))
               (ranges
                (diffs--intraline-ranges
                 (aref old-record 2) (aref new-record 2))))
          (dolist (range (car ranges))
            (diffs--make-intraline-overlay
             (+ (aref old-record 0) (car range))
             (+ (aref old-record 0) (cdr range))
             'diff-refine-removed))
          (dolist (range (cdr ranges))
            (diffs--make-intraline-overlay
             (+ (aref new-record 0) (car range))
             (+ (aref new-record 0) (cdr range))
             'diff-refine-added)))))))

(defun diffs--refine-hunk (hunk end &optional region-begin region-end)
  "Apply diffs refinement to HUNK ending at END.
When REGION-BEGIN and REGION-END are non-nil, refine only change
blocks intersecting that region."
  (unless (eq diffs-line-diff-type 'none)
    (unless diffs--refined-blocks
      (setq diffs--refined-blocks (make-hash-table :test #'eql)))
    (dolist (block (diffs--change-blocks hunk end))
      (let ((key (aref (caar block) 0)))
        (when (and (not (gethash key diffs--refined-blocks))
                   (or (null region-end)
                       (diffs--block-intersects-p
                        block region-begin region-end)))
          (diffs--refine-change-block block)
          (puthash key t diffs--refined-blocks))))))

(defun diffs--clear-intraline ()
  "Remove diffs-owned within-line emphasis and reset its caches."
  (remove-overlays (point-min) (point-max) 'diffs-intraline t)
  (setq diffs--intraline-cache (make-hash-table :test #'equal)
        diffs--refined-blocks (make-hash-table :test #'eql)))

(defun diffs--align-row-pairs (old-rows new-rows)
  "Align OLD-ROWS and NEW-ROWS for the split view.
Return a list of (OLD-ROW . NEW-ROW), with nil for an unpaired side.
Paired rows share a two-element vector containing their plain text so
within-line ranges can be computed only when the row becomes visible."
  (let* ((old-vector (vconcat old-rows))
         (new-vector (vconcat new-rows))
         (old-strings
          (vconcat (mapcar (lambda (row)
                             (substring-no-properties (car row)))
                           old-rows)))
         (new-strings
          (vconcat (mapcar (lambda (row)
                             (substring-no-properties (car row)))
                           new-rows)))
         pairs)
    (dolist (alignment (diffs--align-lines old-strings new-strings))
      (let ((old (and (car alignment)
                      (copy-sequence (aref old-vector (car alignment)))))
            (new (and (cdr alignment)
                      (copy-sequence (aref new-vector (cdr alignment))))))
        (when (and old new)
          (let ((pair
                 (vector (aref old-strings (car alignment))
                         (aref new-strings (cdr alignment)))))
            (setcar (nthcdr 7 old) pair)
            (setcar (nthcdr 7 new) pair)))
        (push (cons old new) pairs)))
    (nreverse pairs)))

;;;; Rendering

(defvar diffs--nerd-icons-state 'unknown
  "Cached availability of the optional nerd-icons integration.")

(defun diffs--nerd-icons-available-p ()
  "Return non-nil when the public nerd-icons APIs are available."
  (cond
   ((and (featurep 'nerd-icons)
         (fboundp 'nerd-icons-icon-for-file))
    (setq diffs--nerd-icons-state 'available)
    t)
   ((and (eq diffs--nerd-icons-state 'available)
         (fboundp 'nerd-icons-icon-for-file))
    t)
   ((eq diffs--nerd-icons-state 'missing) nil)
   ((and (require 'nerd-icons nil t)
         (fboundp 'nerd-icons-icon-for-file))
    (setq diffs--nerd-icons-state 'available)
    t)
   (t
    (setq diffs--nerd-icons-state 'missing)
    nil)))

(defun diffs--file-icon (file)
  "Return the optional nerd-icons prefix glyph for FILE."
  (when (and diffs-file-icons
             file
             (diffs--nerd-icons-available-p))
    (condition-case nil
        (let ((icon (nerd-icons-icon-for-file file)))
          (and (stringp icon)
               (not (string-empty-p icon))
               icon))
      (error nil))))

(defun diffs--context-direction-icon (direction)
  "Return an upward or downward context glyph for DIRECTION."
  (let* ((up (eq direction 'up))
         (fallback (if up "↑" "↓"))
         (name (if up "nf-oct-chevron_up" "nf-oct-chevron_down")))
    (if (and (diffs--nerd-icons-available-p)
             (fboundp 'nerd-icons-octicon))
        (condition-case nil
            (let ((icon
                   (nerd-icons-octicon
                    name :face 'diffs-hunk-separator)))
              (if (and (stringp icon)
                       (not (string-empty-p icon)))
                  icon
                fallback))
          (error fallback))
      fallback)))

(defun diffs--context-action-hint (amount)
  "Return a styled key hint for revealing AMOUNT unchanged lines."
  (concat
   "press "
   (propertize
    "[e]"
    'help-echo
    (format "Press e to reveal %d more unchanged line%s"
            amount (if (= amount 1) "" "s")))
   (format " +%d" amount)))

(defun diffs--string-tail-to-width (string width)
  "Return the trailing portion of STRING no wider than WIDTH."
  (let ((total (string-width string)))
    (if (<= total width)
        string
      (truncate-string-to-width
       string total (max 0 (- total width))))))

(defun diffs--short-display-path (path width)
  "Return PATH with middle directories elided to fit WIDTH."
  (if (<= (string-width path) width)
      path
    (let* ((path (abbreviate-file-name path))
           (ellipsis "…/")
           (available
            (max 1 (- width (string-width ellipsis)))))
      (if (<= (string-width path) width)
          path
        (let* ((trimmed (directory-file-name path))
               (tail (file-name-nondirectory trimmed))
               (directory (file-name-directory trimmed)))
          (when (> (string-width tail) available)
            (setq tail (diffs--string-tail-to-width tail available)
                  directory nil))
          (while directory
            (let* ((trimmed-directory
                    (directory-file-name directory))
                   (component
                    (file-name-nondirectory trimmed-directory))
                   (parent (file-name-directory trimmed-directory))
                   (candidate
                    (and (not (string-empty-p component))
                         (concat component "/" tail))))
              (if (and candidate
                       (<= (string-width candidate) available))
                  (setq tail candidate
                        directory parent)
                (setq directory nil))))
          (concat ellipsis tail))))))

(defun diffs--file-label (file width &optional truncate-function)
  "Return FILE with an optional type icon within WIDTH columns.
TRUNCATE-FUNCTION receives FILE and the columns left for its path.  It
defaults to `diffs--short-display-path'."
  (let* ((truncate-function
          (or truncate-function #'diffs--short-display-path))
         (icon (diffs--file-icon file))
         (prefix (and icon (concat icon " ")))
         (prefix-width (and prefix (string-width prefix))))
    (if (and prefix-width (< prefix-width width))
        (concat
         prefix
         (funcall truncate-function file (- width prefix-width)))
      (funcall truncate-function file width))))

(defun diffs--file-header-text (text)
  "Return TEXT with `diffs-file-header' below existing icon faces."
  (let ((copy (copy-sequence text)))
    (add-face-text-property
     0 (length copy) 'diffs-file-header t copy)
    copy))

(defun diffs--display-file-label (old-file file width)
  "Return OLD-FILE and FILE as one path label no wider than WIDTH."
  (if (equal old-file file)
      (diffs--file-label file width)
    (let* ((separator " → ")
           (available
            (max 2 (- width (string-width separator))))
           (old-width (/ available 2))
           (new-width (- available old-width)))
      (concat
       (diffs--file-label old-file old-width)
       separator
       (diffs--file-label file new-width)))))

(defun diffs--put (beg end &rest props)
  "Set PROPS on BEG..END, marking them as owned by diffs."
  (add-text-properties beg end (append '(diffs t) props)))

(defun diffs--layout-result (function context name)
  "Call layout FUNCTION with immutable CONTEXT and validate NAME."
  (let ((value (funcall function (copy-tree context))))
    (unless (or (null value) (stringp value))
      (error "%s must return a string or nil" name))
    value))

(defun diffs--public-section-context (section)
  "Return immutable scalar metadata for SECTION layout callbacks."
  (list
   :file (plist-get section :file)
   :old-file (plist-get section :old-file)
   :adds (plist-get section :adds)
   :dels (plist-get section :dels)
   :index (plist-get section :index)
   :width (plist-get section :width)
   :item-type (plist-get section :item-type)
   :item-id (plist-get section :item-id)
   :item-version (plist-get section :item-version)))

(defun diffs--file-header-context (section view)
  "Return public file-header context for SECTION in VIEW."
  (list
   :view view
   :section (diffs--public-section-context section)
   :file (plist-get section :file)
   :old-file (plist-get section :old-file)
   :adds (plist-get section :adds)
   :dels (plist-get section :dels)
   :item-type (plist-get section :item-type)
   :item-id (plist-get section :item-id)
   :item-version (plist-get section :item-version)))

;;;###autoload
(defun diffs-default-file-header (context)
  "Return the default file header for layout CONTEXT."
  (let* ((file (or (plist-get context :file) "?"))
         (old-file (or (plist-get context :old-file) file))
         (label
          (diffs--display-file-label
           old-file file diffs--file-header-path-width)))
    (if (eq (plist-get context :item-type) 'file)
        (diffs--file-header-text
         (diffs--file-label
          file diffs--file-header-path-width))
      (concat
       (diffs--file-header-text (concat label "  "))
       (propertize
        (format "+%d" (or (plist-get context :adds) 0))
        'face 'diffs-file-stats-added)
       " "
       (propertize
        (format "−%d" (or (plist-get context :dels) 0))
        'face 'diffs-file-stats-removed)))))

(defun diffs--file-header (section view)
  "Render SECTION's file header for VIEW."
  (diffs--layout-result
   diffs-file-header-function
   (diffs--file-header-context section view)
   "`diffs-file-header-function'"))

(defun diffs--sticky-file-header (section view width &optional owner)
  "Render SECTION's file header for sticky VIEW within WIDTH columns.
When OWNER is live, use its presentation configuration."
  (when section
    (let ((diffs--file-header-path-width width))
      (if (buffer-live-p owner)
          (with-current-buffer owner
            (diffs--file-header section view))
        (diffs--file-header section view)))))

(defun diffs--sticky-hunk-label (hunk)
  "Return sticky line-position and function context for HUNK."
  (when hunk
    (let ((context (nth 4 hunk)))
      (concat
       (format "  ·  −%d +%d" (nth 1 hunk) (nth 2 hunk))
       (when (and context (not (string-empty-p context)))
         (concat "  " context))))))

(defun diffs--gutter-context
    (section view kind width old-line new-line
             &optional side continuation face)
  "Return public gutter context for one rendered source row.
SECTION and VIEW identify its location.  KIND, WIDTH, OLD-LINE,
NEW-LINE, SIDE, CONTINUATION, and FACE describe its presentation."
  (list
   :view view
   :section (diffs--public-section-context section)
   :file (plist-get section :file)
   :item-type (plist-get section :item-type)
   :item-id (plist-get section :item-id)
   :side side
   :kind kind
   :width width
   :old-line old-line
   :new-line new-line
   :line-numbers diffs-line-numbers
   :continuation continuation
   :face face))

;;;###autoload
(defun diffs-default-gutter (context)
  "Return the default line-number gutter for layout CONTEXT."
  (when (plist-get context :line-numbers)
    (let* ((width (plist-get context :width))
           (fmt (format "%%%dd" width))
           (empty (make-string width ?\s))
           (view (plist-get context :view))
           (old-line (plist-get context :old-line))
           (new-line (plist-get context :new-line))
           (side (plist-get context :side))
           (face (or (plist-get context :face)
                     'diffs-line-number))
           (text
            (if (eq view 'split)
                (concat
                 (if-let* ((line
                            (if (eq side 'old)
                                old-line
                              new-line)))
                     (format fmt line)
                   empty)
                 " ")
              (concat
               (if old-line (format fmt old-line) empty)
               " "
               (if new-line (format fmt new-line) empty)
               " "))))
      (propertize text 'face face))))

(defun diffs--gutter
    (section view kind width old-line new-line
             &optional side continuation face)
  "Render a gutter for one source row.
SECTION and VIEW identify its location.  KIND, WIDTH, OLD-LINE,
NEW-LINE, SIDE, CONTINUATION, and FACE describe its presentation."
  (diffs--layout-result
   diffs-gutter-function
   (diffs--gutter-context
    section view kind width old-line new-line
    side continuation face)
   "`diffs-gutter-function'"))

(defun diffs--hunk-separator-context (section hunk view)
  "Return public hunk-separator context for HUNK in SECTION and VIEW."
  (let* ((gap (diffs--gap-for-hunk hunk))
         (count (and gap (plist-get gap :count)))
         (visible (and gap (plist-get gap :visible)))
         (hidden (and count (- count visible))))
    (list
     :view view
     :section (diffs--public-section-context section)
     :hunk
     (list
      :old-start (nth 1 hunk)
      :new-start (nth 2 hunk)
      :old-count (nth 5 hunk)
      :new-count (nth 6 hunk)
      :context (nth 4 hunk))
     :file (plist-get section :file)
     :item-type (plist-get section :item-type)
     :item-id (plist-get section :item-id)
     :context (nth 4 hunk)
     :count count
     :visible visible
     :hidden hidden
     :direction (and gap (plist-get gap :direction))
     :context-step diffs-context-step)))

;;;###autoload
(defun diffs-default-hunk-separator (context)
  "Return the default hunk separator for layout CONTEXT."
  (unless (eq (plist-get context :item-type) 'file)
    (let ((count (plist-get context :count))
          (visible (plist-get context :visible))
          (hidden (plist-get context :hidden))
          (direction (or (plist-get context :direction) 'up))
          (hunk-context (plist-get context :context))
          (step (max 1 (plist-get context :context-step))))
      (concat
       (if (and count (> count 0))
           (diffs--context-direction-icon direction)
         "⋯")
       (cond
        ((not (and count (> count 0))) "")
        ((zerop visible)
         (concat
          (format " %d unmodified lines · " count)
          (diffs--context-action-hint (min count step))))
        ((> hidden 0)
         (concat
          (format " %d more unmodified lines · %d shown · "
                  hidden visible)
          (diffs--context-action-hint (min hidden step))))
        (t ""))
       (when (and hunk-context
                  (not (string-empty-p hunk-context)))
         (concat " · " hunk-context))))))

(defun diffs--style-hunk-separator (string)
  "Apply the base separator face to STRING without hiding nested faces."
  (when string
    (let ((styled (copy-sequence string)))
      (add-face-text-property
       0 (length styled) 'diffs-hunk-separator t styled)
      styled)))

(defun diffs--hunk-separator (section hunk view)
  "Render HUNK's separator in SECTION for VIEW."
  (diffs--layout-result
   diffs-hunk-separator-function
   (diffs--hunk-separator-context section hunk view)
   "`diffs-hunk-separator-function'"))

(defun diffs--undecorate ()
  "Remove all diffs decorations from the buffer."
  (diffs--clear-intraline)
  (diffs--clear-context)
  (diffs--review-clear-view-overlays (current-buffer))
  (with-silent-modifications
    (let ((pos (point-min)) next)
      (while (setq pos (text-property-any pos (point-max) 'diffs t))
        (setq next (or (text-property-not-all pos (point-max) 'diffs t)
                       (point-max)))
        (remove-list-of-text-properties
         pos next '(diffs display line-prefix wrap-prefix))
        (setq pos next)))))

(defun diffs--section-header-end (section)
  "Return the end of SECTION's source header block."
  (if (plist-get section :hunks)
      (plist-get section :block-end)
    (save-excursion
      (goto-char (plist-get section :beg))
      (forward-line 1)
      (point))))

(defun diffs--decorate-header (sec)
  "Display the header block of section SEC as one styled line."
  (let* ((end (diffs--section-header-end sec))
         (header (diffs--file-header sec 'stacked))
         (line (and header (concat header "\n"))))
    (diffs--put (plist-get sec :beg) end
                'display (or line ""))))

(defun diffs--hunk-end (hunk sec)
  "Return the end position of HUNK in section SEC."
  (or (nth 3 hunk) (plist-get sec :end)))

(defun diffs--decorate-hunk-header (hunk section)
  "Refresh the compact header for HUNK owned by SECTION."
  (when diffs-prettify-headers
    (save-excursion
      (goto-char (car hunk))
      (when (looking-at diffs--hunk-re)
        (let ((gap (diffs--gap-for-hunk hunk)))
          (diffs--put
           (line-beginning-position) (line-end-position)
           'display
           (if (and gap (> (plist-get gap :visible) 0))
               ""
             (or
              (diffs--style-hunk-separator
               (diffs--hunk-separator section hunk 'stacked))
              ""))))))))

(defun diffs--context-before-string (gap)
  "Return a unified-view display string for visible rows of GAP."
  (let* ((section (plist-get gap :section))
         (width (plist-get section :width))
         chunks)
    (dolist (row (diffs--gap-visible-rows gap))
      (push
       (concat
        (or
         (diffs--gutter
          section 'stacked 'ctx width
          (nth 0 row) (nth 1 row))
         "")
        (diffs--context-text (nth 3 row))
        (propertize "\n" 'face 'diff-context))
       chunks))
    (apply #'concat (nreverse chunks))))

(defun diffs--render-context-gap (gap)
  "Refresh the unified overlay and hunk label for GAP."
  (let ((inhibit-read-only t))
    (with-silent-modifications
      (let ((visible (plist-get gap :visible))
            (hunk (plist-get gap :hunk))
            (overlay (plist-get gap :overlay)))
        (if (zerop visible)
            (when (overlayp overlay)
              (delete-overlay overlay)
              (setf (plist-get gap :overlay) nil))
          (unless (overlayp overlay)
            (setq overlay (make-overlay (car hunk) (car hunk) nil t nil))
            (overlay-put overlay 'diffs-context t)
            (overlay-put overlay 'evaporate t)
            (setf (plist-get gap :overlay) overlay))
          (overlay-put
           overlay 'before-string
           (let ((context
                  (string-remove-suffix
                   "\n" (diffs--context-before-string gap)))
                 (separator
                  (diffs--hunk-separator
                   (plist-get gap :section) hunk 'stacked)))
             (if (diffs--context-gap-fully-visible-p gap)
                 context
               (if (and separator
                        (not (string-empty-p separator)))
                   (concat
                    (diffs--style-hunk-separator separator)
                    "\n"
                    context)
                 context)))))
        (diffs--decorate-hunk-header
         hunk (plist-get gap :section))))))

(defun diffs--context-gap-at-point ()
  "Return the expandable unchanged gap for the hunk at point."
  (let* ((section (diffs--section-at-pos (point)))
         (hunk (and section (diffs--hunk-at-pos section (point))))
         (gap (and hunk (diffs--gap-for-hunk hunk))))
    (or gap (user-error "Point is not in a diff hunk"))))

(defun diffs--set-context-visible (gap visible)
  "Set GAP to show VISIBLE unchanged lines and refresh its display."
  (let* ((count (plist-get gap :count))
         (old-visible (plist-get gap :visible))
         (requested visible)
         (visible (max 0 (min count visible))))
    (when (and (= count 0) (> requested 0))
      (user-error "No hidden context before this hunk"))
    (unless (= visible old-visible)
      (setf (plist-get gap :visible) visible)
      (condition-case error-data
          (progn
            (diffs--render-context-gap gap)
            (diffs--split-cache-clear)
            (force-window-update (current-buffer)))
        (error
         (setf (plist-get gap :visible) old-visible)
         (signal (car error-data) (cdr error-data)))))))

(defun diffs--next-context-visible (gap)
  "Return GAP's visible count after one incremental expansion."
  (let ((visible (plist-get gap :visible))
        (count (plist-get gap :count)))
    (when (>= visible count)
      (user-error
       (if (zerop count)
           "No hidden context before this hunk"
         "All context before this hunk is already visible")))
    (min count (+ visible (max 1 diffs-context-step)))))

(defun diffs-expand-context ()
  "Reveal `diffs-context-step' more unchanged lines before this hunk."
  (interactive)
  (let ((gap (diffs--context-gap-at-point)))
    (diffs--set-context-visible gap (diffs--next-context-visible gap))))

(defun diffs--decorate-hunk (hunk end section &optional rbeg rend)
  "Decorate HUNK (see `diffs--sections') ending at END.
SECTION is its owning file section.  When RBEG and REND are
non-nil, only apply properties to lines intersecting that region."
  (save-excursion
    (goto-char (car hunk))
    (let ((width (plist-get section :width))
          (file (plist-get section :file))
          (old-line (nth 1 hunk))
          (new-line (nth 2 hunk)))
      (when (and diffs-prettify-headers
                 (or (null rend) (and (< (point) rend)
                                      (>= (line-end-position) (or rbeg 0))))
                 (looking-at diffs--hunk-re))
        (diffs--decorate-hunk-header hunk section))
      (forward-line 1)
      (while (and (< (point) end) (not (eobp)))
        (let* ((c (char-after))
               (old (memq c '(?- ?\s ?\n)))
               (new (memq c '(?+ ?\s ?\n)))
               (change-face
                (pcase c
                  (?- 'diff-removed)
                  (?+ 'diff-added)))
               (kind (pcase c
                       (?- 'del)
                       (?+ 'add)
                       ((or ?\s ?\n) 'ctx))))
          (when (and (memq c '(?+ ?- ?\s ?\n ?\\))
                     (not (eq c ?\\))
                     (or (null rend)
                         (and (< (point) rend)
                             (>= (1+ (line-end-position)) (or rbeg 0)))))
            (diffs--put
             (point) (min (point-max) (1+ (line-end-position)))
             'diffs-file file
             'diffs-hunk hunk
             'diffs-kind kind
             'diffs-old-number (and old old-line)
             'diffs-new-number (and new new-line))
            (let* ((fringe (diffs--fringe-prefix c))
                   (gutter-face
                    (diffs--line-prefix-face change-face))
                   (gutter
                    (diffs--gutter
                     section 'stacked kind width
                     (and old old-line)
                     (and new new-line)
                     nil nil
                     gutter-face))
                   (wrap-gutter
                    (diffs--gutter
                     section 'stacked kind width nil nil
                     nil t
                     gutter-face)))
              (when (or gutter (not (string-empty-p fringe)))
                (diffs--put
                 (point) (min (point-max) (1+ (line-end-position)))
                 'line-prefix
                 (concat fringe (or gutter ""))
                 'wrap-prefix
                 (concat fringe (or wrap-gutter "")))))
            (when (and diffs-hide-markers (memq c '(?+ ?- ?\s)))
              (diffs--put (point) (1+ (point)) 'display "")))
          (when (memq c '(?+ ?- ?\s ?\n ?\\))
            (unless (eq c ?\\)
              (when old (cl-incf old-line))
              (when new (cl-incf new-line)))))
        (forward-line 1))
      (diffs--refine-hunk hunk end rbeg rend))))

(defun diffs--decorate-eagerly ()
  "Decorate all content lines from the section index."
  (with-silent-modifications
    (dolist (sec diffs--sections)
      (dolist (hunk (plist-get sec :hunks))
        (diffs--decorate-hunk
         hunk (diffs--hunk-end hunk sec) sec)))))

(defun diffs--jit-decorate (beg end)
  "Lazily decorate the lines between BEG and END, from jit-lock."
  (save-excursion
    (goto-char beg) (setq beg (line-beginning-position))
    (goto-char end) (setq end (min (point-max) (1+ (line-end-position)))))
  (with-silent-modifications
    (dolist (sec diffs--sections)
      (when (and (< (plist-get sec :beg) end)
                 (> (plist-get sec :end) beg))
        (dolist (hunk (plist-get sec :hunks))
          (let ((hend (diffs--hunk-end hunk sec)))
            (when (and (< (car hunk) end) (> hend beg))
              (diffs--decorate-hunk hunk hend sec beg end)))))))
  `(jit-lock-bounds ,beg . ,end))

(defun diffs--decorate-setup ()
  "Scan the buffer and set up eager or lazy content decoration."
  (diffs--undecorate)
  (diffs--scan)
  (with-silent-modifications
    (when diffs-prettify-headers
      (dolist (sec diffs--sections)
        (diffs--decorate-header sec))))
  ;; `so-long-mode' and similar large-buffer policies may disable
  ;; `font-lock-mode'.  Jit-lock remains the viewport scheduler for our
  ;; decorator, so eager work here would defeat large-diff virtualization
  ;; before split rendering starts.
  (if (> (count-lines (point-min) (point-max)) diffs-lazy-threshold)
      (jit-lock-register #'diffs--jit-decorate)
    (diffs--decorate-eagerly)))

;;;; Minor mode

(defvar-local diffs--window-configuration nil
  "Window layout in effect before the diffs view was shown.")

(defvar-local diffs--return-marker nil
  "Source marker to restore after closing the diffs view.")

(defun diffs-quit ()
  "Quit the diffs view, restoring the previous window layout."
  (interactive)
  (diffs--index-cleanup)
  (diffs--split-cache-clear)
  (let ((configuration diffs--window-configuration)
        (return-marker diffs--return-marker))
    (setq diffs--window-configuration nil
          diffs--return-marker nil)
    (unwind-protect
        (if (window-configuration-p configuration)
            (progn
              (bury-buffer)
              (set-window-configuration configuration)
              (when (and (markerp return-marker)
                         (marker-buffer return-marker))
                (let ((buffer (marker-buffer return-marker))
                      (position (marker-position return-marker)))
                  (with-current-buffer buffer
                    (goto-char position))
                  (when-let* ((window (get-buffer-window buffer t)))
                    (set-window-point window position)))))
          (quit-window))
      (when (markerp return-marker)
        (set-marker return-marker nil)))))

(defvar-keymap diffs--review-command-map
  :doc "Bindings shared by native and minor-mode stacked reviews."
  "q" #'diffs-quit
  "n" #'diff-hunk-next
  "p" #'diff-hunk-prev
  "N" #'diff-file-next
  "P" #'diff-file-prev
  "RET" #'diff-goto-source
  "M-RET" #'diffs-token-visit-source
  "S-<mouse-1>" #'diffs-token-click
  "e" #'diffs-expand-context
  "v" #'diffs-review-select
  "x" #'diffs-review-clear-selection
  "a" #'diffs-review-add-annotation
  "[" #'diffs-review-previous-annotation
  "]" #'diffs-review-next-annotation
  "A" #'diffs-review-accept-change
  "R" #'diffs-review-reject-change
  "U" #'diffs-review-reset-change
  "C-c C-c" #'diffs-review-apply-decisions
  "i" #'diffs-toggle-index
  "s" #'diffs-toggle-split
  "g" #'diffs-refresh)

(defvar-keymap diffs-minor-mode-map
  :doc "Keymap for decorating an arbitrary external diff buffer."
  :parent diffs--review-command-map)

(defvar diffs-mode-map
  (make-composed-keymap
   (list diffs--review-command-map
         diff-mode-shared-map
         diff-mode-map)
   special-mode-map)
  "Keymap for native read-only stacked diffs reviews.")

(defvar-local diffs--regenerator nil
  "Function that regenerates this buffer's diff, for `diffs-refresh'.")

(defvar diffs--refreshing nil
  "Non-nil while `diffs-refresh' is invoking a view regenerator.")

(defvar diffs--review-defer-owner-overlay-refresh nil
  "Non-nil while an internal split rebuild may leave owner overlays stale.")

(defvar-local diffs--split-cache nil
  "Cached side-by-side buffers and the render key that produced them.")

(defvar-local diffs--review-selection nil
  "Stable selected range owned by this unified diffs buffer.")

(defvar-local diffs--review-annotations nil
  "Structured review annotations owned by this unified diffs buffer.")

(defvar-local diffs--review-decisions nil
  "Change-block resolution decisions owned by this unified diffs buffer.")

(defvar-local diffs--review-source-actions nil
  "Actions already applied to source buffers for this review.
Each alist entry maps a stable resolution key to an action plus the
patch-block fingerprint used to revalidate it across refreshes.")

(defvar-local diffs--review-session-id nil
  "Stable live-session id owned by this unified diffs buffer.")

(defvar-local diffs--review-generation 0
  "Generation of the patch backing this live review.")

(defvar-local diffs--review-repository nil
  "Normalized repository root owned by this unified diffs buffer.")

(defvar-local diffs--review-overlays nil
  "Selection and annotation overlays projected into this view buffer.")

(defvar-local diffs--review-owner-overlays-stale nil
  "Non-nil when this unified buffer needs review overlay reprojection.")

(defvar-local diffs--index-buffer nil
  "Changed-file index buffer owned by this unified diff buffer.")

(defvar-local diffs--index-visible nil
  "Non-nil when this unified diff wants its file index visible.")

(defvar-local diffs--index-owner nil
  "Unified diff buffer owned by this changed-file index.")

(defvar-local diffs--index-current-overlay nil
  "Overlay highlighting the current file in a changed-file index.")

(defconst diffs--minor-mode-owned-variables
  '(header-line-format
    diff-refine
    diff-font-lock-prettify
    diff-font-lock-syntax
    font-lock-extra-managed-props
    imenu-create-index-function
    outline-minor-mode-cycle
    outline-minor-mode-highlight)
  "Buffer variables temporarily owned by `diffs-minor-mode'.")

(defun diffs--minor-mode-state-snapshot ()
  "Return the external buffer state that diffs.el temporarily owns."
  (list
   :variables
   (mapcar
    (lambda (symbol)
      (list symbol
            (local-variable-p symbol)
            (and (boundp symbol)
                 (copy-tree (symbol-value symbol)))))
    diffs--minor-mode-owned-variables)
   :outline-minor-mode (bound-and-true-p outline-minor-mode)))

(defun diffs--minor-mode-restore-state ()
  "Restore state saved before `diffs-minor-mode' was enabled."
  (when diffs--minor-mode-saved-state
    (let ((outline-enabled
           (plist-get diffs--minor-mode-saved-state
                      :outline-minor-mode))
          (outline-active (bound-and-true-p outline-minor-mode)))
      (unless (eq (not (null outline-active))
                  (not (null outline-enabled)))
        (outline-minor-mode (if outline-enabled 1 -1))))
    (dolist (entry
             (plist-get diffs--minor-mode-saved-state :variables))
      (pcase-let ((`(,symbol ,local ,value) entry))
        (if local
            (set symbol value)
          (kill-local-variable symbol))))
    (setq diffs--minor-mode-saved-state nil)))

(defconst diffs--sticky-header-owner-parameter
  'diffs--sticky-header-owner
  "Window parameter recording the buffer that owns a sticky header.")

(defconst diffs--sticky-header-previous-parameter
  'diffs--sticky-header-previous-format
  "Window parameter storing the header replaced by a sticky header.")

(defun diffs--sticky-header-format (window split)
  "Return a header-line format specific to WINDOW.
When SPLIT is non-nil, render side-by-side header content."
  (list
   (list
    :eval
    (list (if split
              'diffs--split-header-line
            'diffs--header-line)
          (list 'quote window)))))

(defun diffs--clear-sticky-header-window (window owner)
  "Remove OWNER's sticky-header parameters from WINDOW."
  (when (and (window-live-p window)
             (eq (window-parameter
                  window diffs--sticky-header-owner-parameter)
                 owner))
    (set-window-parameter
     window 'header-line-format
     (window-parameter
      window diffs--sticky-header-previous-parameter))
    (set-window-parameter
     window diffs--sticky-header-previous-parameter nil)
    (set-window-parameter
     window diffs--sticky-header-owner-parameter nil)
    t))

(defun diffs--clear-sticky-headers ()
  "Remove sticky-header window parameters owned by the current buffer."
  (let ((owner (current-buffer)))
    (dolist (frame (frame-list))
      (dolist (window (window-list frame 'nomini))
        (when (diffs--clear-sticky-header-window window owner)
          (force-window-update window))))))

(defun diffs--sticky-header-window-buffer-change (window)
  "Update or remove the current buffer's sticky header in WINDOW."
  (if (eq (window-buffer window) (current-buffer))
      (diffs--update-sticky-header window)
    (diffs--clear-sticky-header-window window (current-buffer))))

(defun diffs--stacked-file-header-at-p (position)
  "Return non-nil when a rendered file header covers POSITION."
  (when-let* ((diffs-prettify-headers)
              (section (diffs--section-at-pos position))
              (begin (plist-get section :beg))
              ((< position (diffs--section-header-end section)))
              (display (get-text-property begin 'display))
              ((stringp display)))
    (string-match-p "[^\n]" display)))

(defun diffs--split-file-header-at-p (position)
  "Return non-nil when a rendered split file header covers POSITION."
  (when-let* ((row (diffs--split-row-at-position position))
              ((eq (nth 3 row) 'header))
              (text (car row))
              ((stringp text)))
    (string-match-p "[^\n]" text)))

(defun diffs--update-sticky-header (window &optional start)
  "Update the sticky header shown in WINDOW at START.
The sticky header yields completely while the rendered file header is
the first content row, so the same file label is never shown twice."
  (when (window-live-p window)
    (with-current-buffer (window-buffer window)
      (let* ((owner (current-buffer))
             (position (or start (window-start window)))
             (split (derived-mode-p 'diffs-split-mode))
             (supported (or split diffs-minor-mode))
             (content-header
              (and supported
                   (if split
                       (diffs--split-file-header-at-p position)
                     (diffs--stacked-file-header-at-p position))))
             (wanted
              (and supported
                   (not content-header)
                   (diffs--sticky-header-format window split)))
             (old-format
              (window-parameter window 'header-line-format))
             (old-owner
              (window-parameter
               window diffs--sticky-header-owner-parameter))
             (current-owner old-owner))
        (when (and current-owner (not (eq current-owner owner)))
          (diffs--clear-sticky-header-window window current-owner)
          (setq current-owner nil))
        (if supported
            (progn
              (unless (eq current-owner owner)
                (set-window-parameter
                 window diffs--sticky-header-previous-parameter
                 (window-parameter window 'header-line-format)))
              (set-window-parameter
               window diffs--sticky-header-owner-parameter owner)
              (set-window-parameter window 'header-line-format wanted))
          (diffs--clear-sticky-header-window window owner))
        (unless
            (and
             (equal
              old-format
              (window-parameter window 'header-line-format))
             (eq
              old-owner
              (window-parameter
               window diffs--sticky-header-owner-parameter)))
          (force-window-update window))))))

(defun diffs--update-split-sticky-headers (window &optional start)
  "Update WINDOW's sticky header at START and its paired split header."
  (when (window-live-p window)
    (let* ((buffer (window-buffer window))
           (other
            (and (buffer-live-p buffer)
                 (buffer-local-value 'diffs--split-other buffer))))
      (diffs--update-sticky-header window start)
      (when (buffer-live-p other)
        (dolist (peer (get-buffer-window-list other nil t))
          (diffs--update-sticky-header peer))))))

(defun diffs--index-buffer-name (owner)
  "Return a changed-file index buffer name for OWNER."
  (format "*diffs files: %s*" (buffer-name owner)))

(defun diffs--index-file-label (file width)
  "Return FILE truncated from the left to fit WIDTH columns."
  (let ((columns (string-width file)))
    (if (<= columns width)
        file
      (concat
       "…"
       (truncate-string-to-width
        file columns (- columns (1- width)))))))

(defun diffs--index-cleanup ()
  "Kill the changed-file index owned by the current diff buffer."
  (when (buffer-live-p diffs--index-buffer)
    (when-let* ((window (get-buffer-window diffs--index-buffer)))
      (when (window-parent window)
        (delete-window window)))
    (kill-buffer diffs--index-buffer))
  (setq diffs--index-buffer nil
        diffs--index-visible nil))

(defun diffs--index-render (owner index)
  "Render OWNER's changed files into INDEX."
  (let ((sections (buffer-local-value 'diffs--sections owner))
        (width (max 20 (buffer-local-value 'diffs-index-width owner)))
        (file-icons (buffer-local-value 'diffs-file-icons owner)))
    (with-current-buffer index
      (let ((inhibit-read-only t)
            (diffs-file-icons file-icons)
            (file-width (max 8 (- width 14))))
        (erase-buffer)
        (dolist (section sections)
          (let* ((beg (point))
                 (file (or (plist-get section :file) "?"))
                 (label
                  (diffs--file-label
                   file file-width #'diffs--index-file-label)))
            (insert "  " label)
            (insert (make-string (max 1 (- file-width
                                           (string-width label)))
                                 ?\s))
            (insert " ")
            (insert (propertize (format "+%d" (plist-get section :adds))
                                'face 'diffs-file-stats-added))
            (insert " ")
            (insert (propertize (format "−%d" (plist-get section :dels))
                                'face 'diffs-file-stats-removed))
            (insert "\n")
            (add-text-properties
             beg (point)
             `(diffs-index-section ,section
               mouse-face highlight
               help-echo "RET/mouse-1: visit file"))))
        (goto-char (point-min))
        (setq header-line-format
              (format " Changed files (%d) · n/p preview · RET visit"
                      (length sections)))))))

(defun diffs--index-section-at-point ()
  "Return the changed-file section on the current index line."
  (or (get-text-property (point) 'diffs-index-section)
      (get-text-property (line-beginning-position)
                         'diffs-index-section)))

(defun diffs--index-highlight-section (owner section)
  "Highlight SECTION in OWNER's changed-file index."
  (when-let* ((index (and (buffer-live-p owner)
                          (buffer-local-value 'diffs--index-buffer owner)))
              ((buffer-live-p index)))
    (with-current-buffer index
      (unless (overlayp diffs--index-current-overlay)
        (setq diffs--index-current-overlay
              (make-overlay (point-min) (point-min) index))
        (overlay-put diffs--index-current-overlay
                     'face 'diffs-index-current-file)
        (overlay-put diffs--index-current-overlay 'priority -10))
      (if-let* ((position
                 (and section
                      (text-property-any
                       (point-min) (point-max)
                       'diffs-index-section section))))
          (let ((beg (save-excursion
                       (goto-char position)
                       (line-beginning-position)))
                (end (save-excursion
                       (goto-char position)
                       (min (point-max) (1+ (line-end-position))))))
            (move-overlay diffs--index-current-overlay beg end index)
            (when-let* ((window (get-buffer-window index)))
              (unless (pos-visible-in-window-p beg window)
                (set-window-point window beg))))
        (delete-overlay diffs--index-current-overlay)))))

(defun diffs--index-sync (&optional position)
  "Sync the changed-file index to POSITION in the current diff buffer."
  (when (buffer-live-p diffs--index-buffer)
    (diffs--index-highlight-section
     (current-buffer)
     (diffs--section-at-pos (or position (point))))))

(defun diffs--stacked-post-command ()
  "Update stacked-view context after point movement."
  (when diffs-minor-mode
    (diffs--index-sync (point))
    (let ((window (selected-window)))
      (when (eq (window-buffer window) (current-buffer))
        (diffs--update-sticky-header window)))))

(defun diffs--stacked-scroll-hook (window start)
  "Update stacked-view context when WINDOW scrolls to START."
  (when (and diffs-minor-mode
             (eq (window-buffer window) (current-buffer)))
    (diffs--index-sync start)
    (diffs--update-sticky-header window start)))

(defun diffs--index-owner-buffer ()
  "Return the unified diff buffer related to the current view."
  (cond
   (diffs-minor-mode (current-buffer))
   ((derived-mode-p 'diffs-index-mode) diffs--index-owner)
   ((derived-mode-p 'diffs-split-mode) diffs--split-unified)))

(defun diffs--index-show-unified (owner)
  "Return a live window showing OWNER, leaving a split view if needed."
  (or (get-buffer-window owner)
      (when-let* ((window
                   (cl-find-if
                    (lambda (candidate)
                      (let ((buffer (window-buffer candidate)))
                        (and (buffer-live-p buffer)
                             (eq (buffer-local-value
                                  'diffs--split-unified buffer)
                                 owner))))
                    (window-list))))
        (with-selected-window window
          (with-current-buffer (window-buffer window)
            (diffs-split-quit)))
        (get-buffer-window owner))
      (display-buffer owner)))

(defun diffs--index-visit-section (section &optional select)
  "Show SECTION from the current index.
When SELECT is non-nil, select the unified diff window."
  (let ((owner diffs--index-owner))
    (unless (buffer-live-p owner)
      (user-error "The owning diff buffer was killed"))
    (let ((window (diffs--index-show-unified owner))
          (position (plist-get section :beg)))
      (with-selected-window window
        (goto-char position)
        (set-window-start window position)
        (diffs--index-highlight-section owner section))
      (when select
        (select-window window)))))

(defun diffs-index-visit ()
  "Visit the changed file on the current index line."
  (interactive)
  (if-let* ((section (diffs--index-section-at-point)))
      (diffs--index-visit-section section t)
    (user-error "No changed file on this line")))

(defun diffs-index-mouse-visit (event)
  "Visit the changed file clicked in EVENT."
  (interactive "e")
  (mouse-set-point event)
  (diffs-index-visit))

(defun diffs--index-move (count)
  "Move COUNT entries in the changed-file index and preview the file."
  (let ((origin (point)))
    (unless (and (zerop (forward-line count))
                 (diffs--index-section-at-point))
      (goto-char origin)
      (user-error "No more changed files"))
    (diffs--index-visit-section (diffs--index-section-at-point))))

(defun diffs-index-next-file ()
  "Preview the next changed file."
  (interactive)
  (diffs--index-move 1))

(defun diffs-index-prev-file ()
  "Preview the previous changed file."
  (interactive)
  (diffs--index-move -1))

(defun diffs--index-display-window (owner index)
  "Display INDEX as OWNER's left side window."
  (let ((window
         (display-buffer-in-side-window
          index
          `((side . left)
            (slot . -1)
            (window-width . ,(max 20
                                  (buffer-local-value
                                   'diffs-index-width owner)))))))
    (set-window-dedicated-p window t)
    (window-preserve-size window t t)
    window))

(defun diffs--index-hide (owner)
  "Hide OWNER's changed-file index without killing its buffer."
  (when (buffer-live-p owner)
    (let ((index (buffer-local-value 'diffs--index-buffer owner)))
      (with-current-buffer owner
        (setq diffs--index-visible nil))
      (when-let* ((window (and (buffer-live-p index)
                               (get-buffer-window index))))
        (delete-window window))
      (when (buffer-live-p index)
        (bury-buffer index)))))

(defun diffs-index-quit ()
  "Hide the changed-file index."
  (interactive)
  (let ((owner diffs--index-owner))
    (diffs--index-hide owner)
    (when-let* ((owner-window (and (buffer-live-p owner)
                                   (get-buffer-window owner))))
      (select-window owner-window))))

(defun diffs-toggle-index ()
  "Toggle the changed-file index for the current diffs view."
  (interactive)
  (let ((owner (diffs--index-owner-buffer)))
    (unless (buffer-live-p owner)
      (user-error "Not in a diffs view"))
    (let ((index (buffer-local-value 'diffs--index-buffer owner)))
      (if (and (buffer-live-p index)
               (get-buffer-window index))
          (diffs--index-hide owner)
        (unless (buffer-live-p index)
          (setq index
                (generate-new-buffer (diffs--index-buffer-name owner)))
          (with-current-buffer owner
            (setq diffs--index-buffer index))
          (with-current-buffer index
            (diffs-index-mode)
            (setq diffs--index-owner owner)))
        (with-current-buffer owner
          (setq diffs--index-visible t))
        (diffs--index-render owner index)
        (diffs--index-display-window owner index)
        (with-current-buffer owner
          (let ((window (get-buffer-window owner)))
            (diffs--index-sync
             (if (window-live-p window)
                 (window-start window)
               (point)))))))))

(defvar-keymap diffs-index-mode-map
  "RET" #'diffs-index-visit
  "<mouse-1>" #'diffs-index-mouse-visit
  "n" #'diffs-index-next-file
  "p" #'diffs-index-prev-file
  "i" #'diffs-index-quit
  "q" #'diffs-index-quit)

(define-derived-mode diffs-index-mode special-mode "diffs-index"
  "Major mode for the changed-file index of a diffs view."
  (setq truncate-lines t)
  (setq-local cursor-in-non-selected-windows nil))

;;;###autoload
(define-derived-mode diffs-mode diff-mode "Diffs"
  "Major mode for native read-only stacked diffs reviews.
This preserves `diff-mode' navigation and hunk commands while exposing
review commands through a suppressed, view-oriented major-mode map.
Use `diffs-minor-mode' to decorate an arbitrary external diff buffer."
  (setq buffer-read-only t)
  (when diffs--mode-context
    (setq-local diffs--item-ranges
                (plist-get diffs--mode-context :item-ranges))
    (setq-local diff-vc-backend
                (plist-get diffs--mode-context :backend))
    (let ((revision (plist-get diffs--mode-context :revision))
          (target-revision
           (plist-get diffs--mode-context :target-revision)))
      (when (or revision target-revision)
        (setq-local diff-vc-revisions
                    (list revision target-revision)))
      (setq-local diffs--revision revision)
      (setq-local diffs--target-revision target-revision))
    (setq-local diffs--independent-sources
                (plist-get diffs--mode-context :independent-sources))
    (setq-local diffs--regenerator
                (plist-get diffs--mode-context :regenerator)))
  (diffs-minor-mode 1))

;;;###autoload
(add-to-list 'auto-mode-alist
             '("\\.\\(?:diff\\|patch\\)\\'" . diffs-mode))

;;;###autoload
(define-minor-mode diffs-minor-mode
  "Pretty rendering for `diff-mode' buffers.
Adds line-number columns, hides diff markers, prettifies file and
hunk headers, and enables outline folding (TAB on headings).
\\<diffs-minor-mode-map>Type \\[diffs-toggle-split] for a side-by-side view."
  :lighter " diffs"
  (unless (derived-mode-p 'diff-mode)
    (user-error "`diffs-minor-mode' only works in diff-mode buffers"))
  (if diffs-minor-mode
      (progn
        (unless diffs--minor-mode-saved-state
          (setq diffs--minor-mode-saved-state
                (diffs--minor-mode-state-snapshot)))
        (setq-local diff-refine nil)
        (remove-overlays (point-min) (point-max) 'diff-mode 'fine)
        (when font-lock-mode
          (font-lock-flush))
        (setq header-line-format nil)
        (diffs--define-fringe-bitmap)
        (add-hook 'text-scale-mode-hook #'diffs--define-fringe-bitmap nil t)
        (add-hook 'kill-buffer-hook #'diffs--split-cache-clear nil t)
        (add-hook 'kill-buffer-hook #'diffs--index-cleanup nil t)
        (add-hook 'kill-buffer-hook #'diffs--token-source-cache-clear nil t)
        (add-hook 'kill-buffer-hook #'diffs--clear-sticky-headers nil t)
        (add-hook 'post-command-hook #'diffs--stacked-post-command nil t)
        (add-hook 'window-scroll-functions
                  #'diffs--stacked-scroll-hook nil t)
        (add-hook 'window-buffer-change-functions
                  #'diffs--sticky-header-window-buffer-change nil t)
        (add-hook 'eldoc-documentation-functions
                  #'diffs-eldoc-function nil t)
        (add-hook 'xref-backend-functions #'diffs-xref-backend nil t)
        (setq-local imenu-create-index-function
                    #'diffs--imenu-create-index)
        (setq-local diff-font-lock-prettify nil)
        (when (eq diff-font-lock-syntax t)
          (setq-local diff-font-lock-syntax 'hunk-also))
        (setq-local font-lock-extra-managed-props
                    (remq 'display font-lock-extra-managed-props))
        (add-to-invisibility-spec '(diffs-resolution))
        (diffs--review-ensure-session-state)
        (diffs--decorate-setup)
        (dolist (window (get-buffer-window-list (current-buffer) nil t))
          (diffs--update-sticky-header window))
        (setq-local outline-minor-mode-cycle t)
        (setq-local outline-minor-mode-highlight nil)
        (outline-minor-mode 1))
    (jit-lock-unregister #'diffs--jit-decorate)
    (remove-hook 'text-scale-mode-hook #'diffs--define-fringe-bitmap t)
    (remove-hook 'kill-buffer-hook #'diffs--split-cache-clear t)
    (remove-hook 'kill-buffer-hook #'diffs--index-cleanup t)
    (remove-hook 'kill-buffer-hook #'diffs--token-source-cache-clear t)
    (remove-hook 'kill-buffer-hook #'diffs--clear-sticky-headers t)
    (remove-hook 'post-command-hook #'diffs--stacked-post-command t)
    (remove-hook 'window-scroll-functions #'diffs--stacked-scroll-hook t)
    (remove-hook 'window-buffer-change-functions
                 #'diffs--sticky-header-window-buffer-change t)
    (remove-hook 'eldoc-documentation-functions
                 #'diffs-eldoc-function t)
    (remove-hook 'xref-backend-functions #'diffs-xref-backend t)
    (remove-from-invisibility-spec '(diffs-resolution))
    (diffs--index-cleanup)
    (diffs--split-cache-clear)
    (diffs--clear-sticky-headers)
    (diffs--undecorate)
    (diffs--minor-mode-restore-state)
    (when font-lock-mode
      (font-lock-flush))))

(defvar diffs--split-role nil
  "Side represented by the current split buffer.")

(defun diffs--refresh-split-state (owner)
  "Return stable visible split state for OWNER, or nil."
  (let* ((cache (buffer-local-value 'diffs--split-cache owner))
         (buffers
          (delq nil
                (list (plist-get cache :old)
                      (plist-get cache :new))))
         (selected (selected-window))
         (window
          (if (memq (window-buffer selected) buffers)
              selected
            (cl-loop
             for buffer in buffers
             thereis (and (buffer-live-p buffer)
                           (get-buffer-window buffer t))))))
    (when (window-live-p window)
      (with-current-buffer (window-buffer window)
        (save-excursion
          (goto-char (window-point window))
          (let* ((position (line-beginning-position))
                 (row (diffs--split-row-at-position position))
                 (hunk (and row (nth 5 row)))
                 (section
                  (and row (diffs--token-section-for-row owner row))))
            (list
             :role diffs--split-role
             :file (and row (nth 4 row))
             :item-id (and section (plist-get section :item-id))
             :hunk-old-start (and hunk (nth 1 hunk))
             :hunk-new-start (and hunk (nth 2 hunk))
             :source
             (diffs--split-property-at 'diffs-src position)
             :kind
             (diffs--split-property-at 'diffs-kind position)
             :number (and row (or (nth 8 row) (nth 1 row)))
             :physical-offset (and row (nth 9 row))
             :column (current-column)
             :window-line
             (count-screen-lines
              (window-start window) position))))))))

(defun diffs--refresh-context-state (owner)
  "Return expanded-context state owned by OWNER."
  (with-current-buffer owner
    (mapcar
     (lambda (gap)
       (let ((section (plist-get gap :section))
             (hunk (plist-get gap :hunk)))
         (list :file (plist-get section :file)
               :item-id (plist-get section :item-id)
               :old-start (nth 1 hunk)
               :new-start (nth 2 hunk)
               :visible (plist-get gap :visible))))
     diffs--context-gaps)))

(defun diffs--refresh-owner-window-state (owner)
  "Return exact display state for every live window showing OWNER.
Buffer replacement moves window markers, so positions are copied to
integers before refresh adoption begins."
  (cl-loop
   for window in (get-buffer-window-list owner nil t)
   for start = (window-start window)
   for point = (window-point window)
   collect
   (list
    :window window
    :start (if (markerp start) (marker-position start) start)
    :point (if (markerp point) (marker-position point) point)
    :hscroll (window-hscroll window)
    :vscroll (window-vscroll window t))))

(defun diffs--refresh-view-state (owner)
  "Return presentation state needed to adopt a refreshed OWNER."
  (with-current-buffer owner
    (let ((window (get-buffer-window owner t))
          (narrowed (buffer-narrowed-p))
          (narrow-begin (point-min))
          (narrow-end (point-max))
          (point-position (point))
          (mark-position
           (let ((position (mark t)))
             (if (markerp position)
                 (marker-position position)
               position)))
          (active-mark mark-active))
      (save-restriction
        (widen)
        (append
         (diffs--review-state-snapshot owner)
         (list
          :propertized-text
          (buffer-substring
           (point-min) (point-max))
          :default-directory default-directory
          :backend diff-vc-backend
          :vc-revisions (copy-tree diff-vc-revisions)
          :revision diffs--revision
          :target-revision diffs--target-revision
          :independent-sources diffs--independent-sources
          :regenerator diffs--regenerator
          :item-ranges (copy-tree diffs--item-ranges)
          :read-only buffer-read-only
          :modified (buffer-modified-p)
          :narrowed narrowed
          :narrow-begin narrow-begin
          :narrow-end narrow-end
          :point-position point-position
          :mark-position mark-position
          :mark-active active-mark
          :point-line (line-number-at-pos point-position)
          :point-column
          (save-excursion
            (goto-char point-position)
            (current-column))
          :window-start-line
          (and (window-live-p window)
               (line-number-at-pos (window-start window)))
          :stats diffs--stats
          :sections diffs--sections
          :section-vector diffs--section-vector
          :context-gaps diffs--context-gaps
          :context-gap-table diffs--context-gap-table
          :old-content-cache diffs--old-content-cache
          :new-content-cache diffs--new-content-cache
          :old-raw-content-cache diffs--old-raw-content-cache
          :new-raw-content-cache diffs--new-raw-content-cache
          :source-render-identities diffs--source-render-identities
          :source-render-generation diffs--source-render-generation
          :intraline-cache diffs--intraline-cache
          :refined-blocks diffs--refined-blocks
          :intraline-overlays
          (cl-loop
           for overlay in (overlays-in (point-min) (point-max))
           when (overlay-get overlay 'diffs-intraline)
           collect
           (list (overlay-start overlay)
                 (overlay-end overlay)
                 (overlay-get overlay 'face)))
          :split-cache diffs--split-cache
          :index-buffer diffs--index-buffer
          :index-visible diffs--index-visible
          :owner-overlays-stale diffs--review-owner-overlays-stale
          :context (diffs--refresh-context-state owner)
          :split (diffs--refresh-split-state owner)
          :active-window-configuration
          (current-window-configuration)
          :owner-windows
          (diffs--refresh-owner-window-state owner)
          :window-configuration diffs--window-configuration
          :return-marker diffs--return-marker))))))

(defun diffs--refresh-find-hunk (owner state)
  "Return the refreshed hunk in OWNER identified by split STATE."
  (with-current-buffer owner
    (when-let*
        ((section
          (diffs--section-for-identity
           (plist-get state :item-id)
           (plist-get state :file))))
      (cl-find-if
       (lambda (hunk)
         (and
          (equal (nth 1 hunk)
                 (plist-get state :hunk-old-start))
          (equal (nth 2 hunk)
                 (plist-get state :hunk-new-start))))
       (plist-get section :hunks)))))

(defun diffs--refresh-restore-context (owner state)
  "Restore still-valid expanded context from STATE into OWNER."
  (with-current-buffer owner
    (dolist (saved (plist-get state :context))
      (when-let* ((section
                   (diffs--section-for-identity
                    (plist-get saved :item-id)
                    (plist-get saved :file)))
                  (hunk
                   (cl-find-if
                    (lambda (item)
                      (and
                       (equal (nth 1 item)
                              (plist-get saved :old-start))
                       (equal (nth 2 item)
                              (plist-get saved :new-start))))
                    (plist-get section :hunks)))
                  (gap (diffs--gap-for-hunk hunk)))
        (diffs--set-context-visible
         gap
         (min (plist-get gap :count)
              (plist-get saved :visible)))))))

(defun diffs--refresh-copy-content-caches (source target)
  "Copy section content caches from staged SOURCE into TARGET."
  (let ((source-sections
         (buffer-local-value 'diffs--sections source))
        (source-old
         (buffer-local-value 'diffs--old-content-cache source))
        (source-new
         (buffer-local-value 'diffs--new-content-cache source))
        (source-old-raw
         (buffer-local-value
          'diffs--old-raw-content-cache source))
        (source-new-raw
         (buffer-local-value
          'diffs--new-raw-content-cache source)))
    (with-current-buffer target
      (cl-mapc
       (lambda (source-section target-section)
         (when (hash-table-contains-p
                source-section source-old)
           (puthash
            target-section
            (gethash source-section source-old)
            diffs--old-content-cache))
         (when (hash-table-contains-p
                source-section source-new)
           (puthash
            target-section
            (gethash source-section source-new)
            diffs--new-content-cache))
         (when (and
                (hash-table-p source-old-raw)
                (hash-table-contains-p
                 source-section source-old-raw))
           (let ((lines
                  (gethash source-section source-old-raw)))
             (puthash
              target-section lines
              diffs--old-raw-content-cache)
             (when (vectorp lines)
               (diffs--schedule-source-render
                target-section 'old lines))))
         (when (and
                (hash-table-p source-new-raw)
                (hash-table-contains-p
                 source-section source-new-raw))
           (let ((lines
                  (gethash source-section source-new-raw)))
             (puthash
              target-section lines
              diffs--new-raw-content-cache)
             (when (vectorp lines)
               (diffs--schedule-source-render
                target-section 'new lines)))))
       source-sections diffs--sections))))

(defun diffs--refresh-restore-point (owner state)
  "Restore OWNER's stacked point and window start from STATE."
  (with-current-buffer owner
    (goto-char (point-min))
    (forward-line (1- (or (plist-get state :point-line) 1)))
    (move-to-column (or (plist-get state :point-column) 0))
    (when-let* ((window (get-buffer-window owner t))
                (line (plist-get state :window-start-line)))
      (save-excursion
        (goto-char (point-min))
        (forward-line (1- line))
        (set-window-start window (point)))
      (set-window-point window (point)))))

(defun diffs--refresh-restore-restriction (owner state)
  "Restore OWNER's narrowing recorded in refresh STATE."
  (with-current-buffer owner
    (widen)
    (when (plist-get state :narrowed)
      (let* ((limit (point-max))
             (begin
              (max (point-min)
                   (min limit
                        (or (plist-get state :narrow-begin)
                            (point-min)))))
             (end
              (max begin
                   (min limit
                        (or (plist-get state :narrow-end)
                            limit)))))
        (narrow-to-region begin end)))))

(defun diffs--refresh-restore-owner-windows (owner state)
  "Restore exact OWNER window positions and scrolling from STATE."
  (with-current-buffer owner
    (save-restriction
      (widen)
      (let ((minimum (point-min))
            (maximum (point-max)))
        (dolist (saved (plist-get state :owner-windows))
          (when-let* ((window (plist-get saved :window))
                      ((window-live-p window))
                      ((eq (window-buffer window) owner)))
            (let ((point
                   (max minimum
                        (min maximum
                             (or (plist-get saved :point) minimum))))
                  (start
                   (max minimum
                        (min maximum
                             (or (plist-get saved :start) minimum)))))
              (set-window-point window point)
              (set-window-start window start)
              (set-window-hscroll
               window (or (plist-get saved :hscroll) 0))
              (set-window-vscroll
               window (or (plist-get saved :vscroll) 0) t))))))))

(defun diffs--refresh-restore-layout (owner state)
  "Restore OWNER's index and split layout from STATE."
  (when (plist-get state :index-visible)
    (with-current-buffer owner
      (diffs-toggle-index)))
  (when-let* ((split (plist-get state :split)))
    (unless (get-buffer-window owner t)
      (set-window-buffer (selected-window) owner))
    (when-let* ((window (get-buffer-window owner t)))
      (with-selected-window window
        (with-current-buffer owner
          (diffs-toggle-split))))
    (if-let* ((hunk (diffs--refresh-find-hunk owner split)))
        (diffs--split-restore-position
         owner
         (plist-get split :role)
         hunk
         (plist-get split :source)
         (plist-get split :kind)
         (plist-get split :number)
         (plist-get split :physical-offset)
         (plist-get split :column)
         (plist-get split :window-line))
      (let* ((cache
              (buffer-local-value 'diffs--split-cache owner))
             (buffer
              (plist-get
               cache
               (if (eq (plist-get split :role) 'old)
                   :old
                 :new)))
             (window
              (and (buffer-live-p buffer)
                   (get-buffer-window buffer t))))
        (when (window-live-p window)
          (select-window window))))))

(defun diffs--refresh-saved-view-buffers (state)
  "Return live split and index buffers retained in refresh STATE."
  (let ((cache (plist-get state :split-cache)))
    (delq
     nil
     (list (plist-get cache :old)
           (plist-get cache :new)
           (plist-get state :index-buffer)))))

(defun diffs--refresh-detach-view-buffers (owner)
  "Detach OWNER's old split and index ownership without changing windows."
  (with-current-buffer owner
    ;; Refresh may now freely clear and rebuild OWNER's caches.  The
    ;; detached buffers and their windows remain untouched for an exact
    ;; transactional rollback.
    (setq diffs--split-cache nil
          diffs--index-buffer nil
          diffs--index-visible nil)))

(defun diffs--refresh-prepare-new-layout (owner state)
  "Close STATE's retained layout before displaying refreshed OWNER."
  (setf (plist-get state :layout-touched) t)
  (diffs--refresh-leave-partial-split owner)
  (when-let* ((index (plist-get state :index-buffer))
              ((buffer-live-p index)))
    (dolist (window (get-buffer-window-list index nil t))
      (when (window-parent window)
        (delete-window window)))
    (bury-buffer index)))

(defun diffs--refresh-discard-current-view-buffers (owner state)
  "Discard OWNER's partial refreshed views, preserving buffers in STATE."
  (let ((saved (diffs--refresh-saved-view-buffers state))
        current)
    (when-let* ((window
                 (cl-find-if
                  (lambda (candidate)
                    (let ((buffer (window-buffer candidate)))
                      (and
                       (buffer-live-p buffer)
                       (not (memq buffer saved))
                       (eq
                        (buffer-local-value
                         'diffs--split-unified buffer)
                        owner))))
                  (window-list nil 'nomini))))
      (with-selected-window window
        (let ((diffs--review-defer-owner-overlay-refresh t))
          (diffs-split-quit))))
    (with-current-buffer owner
      (setq current
            (delq nil
                  (list (plist-get diffs--split-cache :old)
                        (plist-get diffs--split-cache :new)
                        diffs--index-buffer))
            diffs--split-cache nil
            diffs--index-buffer nil
            diffs--index-visible nil))
    (dolist (buffer current)
      (when (and (buffer-live-p buffer)
                 (not (memq buffer saved)))
        (kill-buffer buffer)))))

(defun diffs--refresh-release-saved-view-buffers (owner state)
  "Kill superseded view buffers retained in STATE after OWNER commits."
  (let* ((cache (buffer-local-value 'diffs--split-cache owner))
         (current
          (delq nil
                (list (plist-get cache :old)
                      (plist-get cache :new)
                      (buffer-local-value 'diffs--index-buffer owner)))))
    (dolist (buffer (diffs--refresh-saved-view-buffers state))
      (when (and (buffer-live-p buffer)
                 (not (memq buffer current)))
        ;; A derived review buffer is read-only and has no user data.
        ;; Cleanup must not turn a successfully committed refresh into a
        ;; rollback after another kill-buffer hook happens to signal.
        (ignore-errors (kill-buffer buffer))))))

(defun diffs--refresh-adopt-buffer (owner staged state)
  "Replace OWNER with successfully generated STAGED and restore STATE."
  (let ((text
         (with-current-buffer staged
           (buffer-substring-no-properties
            (point-min) (point-max))))
        (directory (buffer-local-value 'default-directory staged))
        (backend (buffer-local-value 'diff-vc-backend staged))
        (vc-revisions
         (copy-tree
          (buffer-local-value 'diff-vc-revisions staged)))
        (revision (buffer-local-value 'diffs--revision staged))
        (target (buffer-local-value 'diffs--target-revision staged))
        (independent-sources
         (buffer-local-value 'diffs--independent-sources staged))
        (item-ranges
         (copy-tree
          (buffer-local-value 'diffs--item-ranges staged)))
        (regenerator
         (buffer-local-value 'diffs--regenerator staged))
        (modified
         (with-current-buffer staged
           (buffer-modified-p))))
    (diffs--refresh-detach-view-buffers owner)
    (with-current-buffer owner
      ;; OWNER is already a fully initialized diff-mode/diffs buffer.
      ;; Replacing its model directly avoids running user mode hooks during
      ;; either adoption or rollback.
      (widen)
      (jit-lock-unregister #'diffs--jit-decorate)
      (diffs--undecorate)
      (let ((inhibit-read-only t)
            (inhibit-modification-hooks t)
            (buffer-undo-list t))
        (erase-buffer)
        (insert text))
      (setq default-directory directory
            diff-vc-backend backend
            diff-vc-revisions vc-revisions
            diffs--revision revision
            diffs--target-revision target
            diffs--independent-sources independent-sources
            diffs--regenerator regenerator
            diffs--item-ranges item-ranges
            buffer-read-only t
            header-line-format nil)
      (diffs--decorate-setup)
      (unless diffs--sections
        (user-error "No changes"))
      (set-buffer-modified-p modified))
    (diffs--refresh-copy-content-caches staged owner)
    (with-current-buffer owner
      (setq diffs--window-configuration
            (plist-get state :window-configuration)
            diffs--return-marker
            (plist-get state :return-marker)))
    (diffs--review-restore-refreshed-state owner state)
    (diffs--refresh-restore-context owner state)
    (diffs--refresh-restore-point owner state)
    (diffs--refresh-prepare-new-layout owner state)
    (diffs--refresh-restore-layout owner state)
    (diffs--refresh-restore-restriction owner state)
    (diffs--refresh-release-saved-view-buffers owner state)
    (dolist (window (get-buffer-window-list owner nil t))
      (diffs--update-sticky-header window))))

(defun diffs--refresh-leave-partial-split (owner)
  "Leave any currently displayed split derived from OWNER."
  (when-let* ((window
               (cl-find-if
                (lambda (candidate)
                  (let ((buffer (window-buffer candidate)))
                    (and
                     (buffer-live-p buffer)
                     (eq
                      (buffer-local-value
                       'diffs--split-unified buffer)
                      owner))))
                (window-list nil 'nomini))))
    (with-selected-window window
      (let ((diffs--review-defer-owner-overlay-refresh t))
        (diffs-split-quit)))))

(defun diffs--refresh-rollback-owner (owner state)
  "Restore OWNER's exact pre-refresh contents and views from STATE."
  (diffs--refresh-discard-current-view-buffers owner state)
  (with-current-buffer owner
    (widen)
    (jit-lock-unregister #'diffs--jit-decorate)
    (diffs--undecorate)
    (let ((inhibit-read-only t)
          (inhibit-modification-hooks t)
          (buffer-undo-list t))
      (erase-buffer)
      (insert (plist-get state :propertized-text)))
    (setq default-directory
          (plist-get state :default-directory)
          diff-vc-backend
          (plist-get state :backend)
          diff-vc-revisions
          (copy-tree (plist-get state :vc-revisions))
          diffs--revision
          (plist-get state :revision)
          diffs--target-revision
          (plist-get state :target-revision)
          diffs--independent-sources
          (plist-get state :independent-sources)
          diffs--regenerator
          (plist-get state :regenerator)
          diffs--item-ranges
          (copy-tree (plist-get state :item-ranges))
          diffs--window-configuration
          (plist-get state :window-configuration)
          diffs--return-marker
          (plist-get state :return-marker)
          diffs--stats
          (plist-get state :stats)
          diffs--sections
          (plist-get state :sections)
          diffs--section-vector
          (plist-get state :section-vector)
          diffs--context-gaps
          (plist-get state :context-gaps)
          diffs--context-gap-table
          (plist-get state :context-gap-table)
          diffs--old-content-cache
          (plist-get state :old-content-cache)
          diffs--new-content-cache
          (plist-get state :new-content-cache)
          diffs--old-raw-content-cache
          (plist-get state :old-raw-content-cache)
          diffs--new-raw-content-cache
          (plist-get state :new-raw-content-cache)
          diffs--source-render-identities
          (plist-get state :source-render-identities)
          diffs--source-render-generation
          (plist-get state :source-render-generation)
          diffs--intraline-cache
          (plist-get state :intraline-cache)
          diffs--refined-blocks
          (plist-get state :refined-blocks)
          diffs--review-selection
          (copy-tree (plist-get state :selection))
          diffs--review-annotations
          (copy-tree (plist-get state :annotations))
          diffs--review-decisions
          (copy-tree (plist-get state :decisions))
          diffs--review-source-actions
          (copy-tree (plist-get state :source-actions))
          diffs--review-session-id
          (plist-get state :session-id)
          diffs--review-repository
          (plist-get state :repository)
          diffs--review-generation
          (plist-get state :generation)
          diffs--split-cache
          nil
          diffs--index-buffer
          nil
          diffs--index-visible
          nil
          buffer-read-only
          (plist-get state :read-only))
    ;; The old text properties and parsed objects were retained verbatim,
    ;; so cached split rows and index entries still point at the same
    ;; sections and hunks.  Only overlay objects need to be recreated.
    (dolist (gap diffs--context-gaps)
      (setf (plist-get gap :overlay) nil)
      (when (> (plist-get gap :visible) 0)
        (diffs--render-context-gap gap)))
    (dolist (spec (plist-get state :intraline-overlays))
      (diffs--make-intraline-overlay
       (nth 0 spec) (nth 1 spec) (nth 2 spec)))
    (when (> (count-lines (point-min) (point-max))
             diffs-lazy-threshold)
      (jit-lock-register #'diffs--jit-decorate))
    (setq diffs--split-cache
          (plist-get state :split-cache)
          diffs--index-buffer
          (plist-get state :index-buffer)
          diffs--index-visible
          (plist-get state :index-visible))
    (goto-char
     (min (point-max)
          (or (plist-get state :point-position) (point-min))))
    (if-let* ((position (plist-get state :mark-position)))
        (set-marker
         (mark-marker)
         (max (point-min) (min (point-max) position))
         owner)
      (set-marker (mark-marker) nil)))
  ;; Detached split views were never mutated.  Recreate only the owner
  ;; projection when it was current before refresh; a deliberately stale
  ;; hidden owner remains stale until the real return to stacked.
  (unless (plist-get state :owner-overlays-stale)
    (diffs--review-refresh-overlays owner (list owner)))
  (with-current-buffer owner
    (setq diffs--review-owner-overlays-stale
          (plist-get state :owner-overlays-stale))
    (set-buffer-modified-p (plist-get state :modified)))
  (diffs--refresh-restore-restriction owner state)
  (when (plist-get state :layout-touched)
    (when-let* ((configuration
                 (plist-get state :active-window-configuration)))
      (set-window-configuration configuration)))
  (diffs--refresh-restore-owner-windows owner state)
  (with-current-buffer owner
    (setq mark-active (plist-get state :mark-active))))

(defun diffs-refresh ()
  "Regenerate the current diff transactionally.
Generation happens in a staging buffer.  If it fails, the live review,
its session state, and its window layout remain untouched."
  (interactive)
  (let* ((owner (or (diffs--review-owner-buffer) (current-buffer)))
         (regenerator
          (and (buffer-live-p owner)
               (buffer-local-value 'diffs--regenerator owner))))
    (if regenerator
        (let* ((state (diffs--refresh-view-state owner))
               (staging-name
                (generate-new-buffer-name
                 (format " *%s refresh*" (buffer-name owner))))
               staged)
          (unwind-protect
              (let ((diffs--refreshing t)
                    (diffs-buffer-name staging-name))
                (funcall regenerator)
                (setq staged (get-buffer staging-name))
                (unless
                    (and (buffer-live-p staged)
                         (buffer-local-value
                          'diffs-minor-mode staged)
                         (buffer-local-value
                          'diffs--sections staged))
                  (error
                   "Diff regenerator did not produce a valid review"))
                ;; Expanded context can require historical or worktree
                ;; source reads.  Validate and cache those reads while
                ;; OWNER and its windows are still completely untouched.
                (diffs--refresh-restore-context staged state)
                (condition-case error-data
                    (diffs--refresh-adopt-buffer
                     owner staged state)
                  (error
                   (condition-case rollback-error
                       (diffs--refresh-rollback-owner
                        owner state)
                     (error
                      (message
                       "diffs refresh rollback failed: %s"
                       (error-message-string rollback-error))))
                   (signal
                    (car error-data) (cdr error-data)))))
            (when (buffer-live-p staged)
              (kill-buffer staged))
            (when-let* ((buffer (get-buffer staging-name)))
              (kill-buffer buffer))))
      (revert-buffer))))

;;;; Side-by-side view

(defvar-local diffs--split-window-configuration nil
  "Window configuration saved before showing the split view.")

(defvar-local diffs--split-other nil
  "The other buffer of a split-view pair.")

(defvar-local diffs--split-unified nil
  "The unified diffs buffer this split view was created from.")

(defvar-local diffs--split-role nil
  "Side represented by this split buffer: `old' or `new'.")

(defvar-local diffs--split-anchors nil
  "Sorted list of hunk anchor line numbers in a split buffer.")

(defvar-local diffs--split-rows []
  "Vector of complete row descriptors for this split side.")

(defvar-local diffs--split-row-positions []
  "Vector mapping split row indexes to buffer positions.
The final slot is the position immediately after the last row.")

(defvar-local diffs--split-paged-p nil
  "Non-nil when this split buffer uses the paged row model.")

(defvar-local diffs--split-chunks []
  "Vector of indexed chunks shared by a paged split pair.")

(defvar-local diffs--split-materialized-chunks []
  "Boolean vector recording chunks whose text is present.")

(defvar-local diffs--split-materialized-indexes nil
  "Indexes of chunks whose text is present in this paged split side.")

(defvar-local diffs--split-paged-pinned nil
  "Non-nil when every paged chunk must remain materialized.")

(defvar-local diffs--split-paged-retained-range nil
  "Last paged split row range retained around the viewport.")

(defvar-local diffs--split-row-length-tree []
  "Fenwick tree of materialized text lengths for paged split rows.")

(defvar-local diffs--split-decorated []
  "Boolean vector recording split rows with materialized visuals.")

(defvar-local diffs--split-render-width 2
  "Line-number width used to decorate this split buffer.")

(defvar diffs--split-syncing nil)

(defun diffs--split-row-length-prefix (end)
  "Return materialized text length in paged rows before END."
  (let ((index end)
        (total 0))
    (while (> index 0)
      (cl-incf total (aref diffs--split-row-length-tree index))
      (cl-decf index (logand index (- index))))
    total))

(defun diffs--split-row-length-add (index delta)
  "Add DELTA characters to paged row INDEX."
  (let ((slot (1+ index))
        (limit (length diffs--split-row-length-tree)))
    (while (< slot limit)
      (cl-incf (aref diffs--split-row-length-tree slot) delta)
      (cl-incf slot (logand slot (- slot))))))

(defun diffs--split-row-length-rebuild ()
  "Rebuild the paged row-length tree from `diffs--split-rows'."
  (let* ((count (length diffs--split-rows))
         (tree (make-vector (1+ count) 0)))
    (dotimes (index count)
      (when-let* ((row (aref diffs--split-rows index)))
        (aset tree (1+ index) (length (car row)))))
    (let ((slot 1))
      (while (<= slot count)
        (let ((parent (+ slot (logand slot (- slot)))))
          (when (<= parent count)
            (cl-incf (aref tree parent) (aref tree slot))))
        (cl-incf slot)))
    (setq-local diffs--split-row-length-tree tree)))

(defun diffs--split-row-position (index)
  "Return the buffer position at the start of split row INDEX.
INDEX may equal the row count, in which case return `point-max'."
  (if diffs--split-paged-p
      (+ (point-min)
         index
         (diffs--split-row-length-prefix index))
    (aref diffs--split-row-positions index)))

(defun diffs--split-row-index-at-position (position)
  "Return the zero-based split row index containing POSITION."
  (let ((count (length diffs--split-rows)))
    (when (> count 0)
      (let ((low 0)
            (high count))
        (while (< low high)
          (let ((middle (/ (+ low high) 2)))
            (if (> (diffs--split-row-position middle) position)
                (setq high middle)
              (setq low (1+ middle)))))
        (max 0 (min (1- count) (1- low)))))))

(defun diffs--split-row-at-position (position)
  "Return the split row descriptor containing POSITION."
  (when-let* ((index (diffs--split-row-index-at-position position)))
    (aref diffs--split-rows index)))

(defun diffs--split-row-section (row)
  "Return the exact owning section carried by physical split ROW."
  (let ((section (nth 12 row)))
    (and (listp section)
         (plist-member section :beg)
         section)))

(defun diffs--split-row-property (row property)
  "Return data-bearing PROPERTY from split ROW."
  (pcase property
    ('diffs-src
     (diffs--split-row-source-location row))
    ('diffs-file (nth 4 row))
    ('diffs-hunk (nth 5 row))
    ('diffs-kind (nth 3 row))
    ('diffs-number (nth 1 row))
    ('diffs-section (diffs--split-row-section row))))

(defun diffs--split-row-resolution-key (row)
  "Return the review resolution key carried by split ROW."
  (when-let* ((text (car row)))
    (and (not (string-empty-p text))
         (get-text-property 0 'diffs-resolution-key text))))

(defun diffs--split-row-source-number (row)
  "Return the immutable patch-side source number represented by split ROW."
  (or (nth 8 row) (nth 1 row)))

(defun diffs--split-row-source-side (row)
  "Return the original source side represented by split ROW."
  (or (nth 10 row) diffs--split-role))

(defun diffs--split-row-target-number (row)
  "Return the current live-worktree target number represented by split ROW."
  (or (nth 11 row) (nth 2 row)))

(defun diffs--split-row-source-file (row)
  "Return the physical source file represented by split ROW."
  (let ((file (nth 4 row))
        (owner diffs--split-unified))
    (if (and (buffer-live-p owner)
             (buffer-local-value 'diffs--independent-sources owner))
        (when-let* ((section (diffs--token-section-for-row owner row)))
          (if (eq (diffs--split-row-source-side row) 'old)
              (or (plist-get section :old-file)
                  (plist-get section :file))
            (plist-get section :file)))
      file)))

(defun diffs--split-row-source-location (row)
  "Return the physical source location represented by split ROW."
  (let* ((owner diffs--split-unified)
         (independent
          (and (buffer-live-p owner)
               (buffer-local-value
                'diffs--independent-sources owner)))
         (line
          (if independent
              (diffs--split-row-source-number row)
            (diffs--split-row-target-number row))))
    (when-let* ((file (diffs--split-row-source-file row))
                (line line))
      (cons file line))))

(defun diffs--split-property-at (property position)
  "Return PROPERTY at or immediately before POSITION."
  (or (get-text-property position property)
      (and (> position (point-min))
           (get-text-property (1- position) property))
      (when-let* ((row (diffs--split-row-at-position position)))
        (diffs--split-row-property row property))))

(defun diffs--split-section-at-position (position)
  "Return the owning diff section for split POSITION."
  (when (buffer-live-p diffs--split-unified)
    (when-let* ((row (diffs--split-row-at-position position)))
      (diffs--token-section-for-row diffs--split-unified row))))

(defun diffs--split-header-line (&optional window)
  "Return the sticky header for a side-by-side WINDOW."
  (let* ((window (or window (get-buffer-window (current-buffer))))
         (position (if (window-live-p window)
                       (window-start window)
                     (point)))
         (path-width
          (if (window-live-p window)
              (max 20 (- (window-width window) 24))
            diffs--file-header-path-width))
         (section (diffs--split-section-at-position position))
         (hunk (diffs--split-property-at 'diffs-hunk position))
         (header
          (diffs--sticky-file-header
           section 'split path-width diffs--split-unified)))
    (concat
     (or header "")
     (or (diffs--sticky-hunk-label hunk) ""))))

(defun diffs--split-sync-index (position)
  "Sync the owning file index to split POSITION."
  (when (buffer-live-p diffs--split-unified)
    (when-let* ((section (diffs--split-section-at-position position)))
      (diffs--index-highlight-section diffs--split-unified section))))

(defun diffs--split-cache-clear ()
  "Kill cached split buffers belonging to the current unified buffer."
  (when diffs--split-cache
    (dolist (key '(:old :new))
      (when-let* ((buffer (plist-get diffs--split-cache key)))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))
    (setq diffs--split-cache nil)))

(defun diffs--split-line (pos)
  "Return the plain line at POS without its diff marker.
Split rows derive syntax, refinement, review identity, and display
properties from their indexed row metadata, so copying unified-view
properties here would only duplicate work."
  (save-excursion
    (goto-char pos)
    (buffer-substring-no-properties
     (min (1+ (line-beginning-position)) (line-end-position))
     (line-end-position))))

(defun diffs--split-collect-hunk (section hunk &optional separator)
  "Return aligned old/new rows for HUNK in SECTION.
The result is (OLD-ROWS NEW-ROWS).  When SEPARATOR is non-nil, include
the hunk's logical separator as the first row."
  (let* ((file (plist-get section :file))
         (end (diffs--hunk-end hunk section))
         (old-line (nth 1 hunk))
         (new-line (nth 2 hunk))
         old-rows new-rows dels adds)
    (cl-labels
        ((emit
          (old new)
          (push old old-rows)
          (push new new-rows))
         (flush
          ()
          (when (or dels adds)
            (let ((deletions (nreverse dels))
                  (additions (nreverse adds)))
              (dolist (pair
                       (diffs--align-row-pairs deletions additions))
                (let ((old (car pair))
                      (new (cdr pair)))
                  (emit
                   (or old
                       (list "" nil (nth 2 new) 'filler
                             file hunk nil nil nil nil nil section))
                   (or new
                       (list "" nil (nth 2 old) 'filler
                             file hunk nil nil nil nil nil section)))))))
          (setq dels nil
                adds nil)))
      (let* ((gap (diffs--gap-for-hunk hunk))
             (text
              (if (diffs--context-gap-fully-visible-p gap)
                  ""
                (let ((separator-text
                       (diffs--hunk-separator
                        section hunk 'split)))
                  (if separator-text
                      (diffs--style-hunk-separator separator-text)
                    "")))))
        (when separator
          ;; Keep an empty logical separator when complete context is
          ;; visible.  Resolution still needs the hunk boundary, while
          ;; `diffs--split-physical-rows' omits it from rendered views.
          (emit (list text nil nil 'sep file hunk nil nil
                      nil nil nil section)
                (list text nil nil 'sep file hunk nil nil
                      nil nil nil section)))
        (when (and gap (> (plist-get gap :visible) 0))
          (dolist (context-row (diffs--gap-visible-rows gap))
            (let ((old-number (nth 0 context-row))
                  (new-number (nth 1 context-row))
                  (old-text (diffs--context-text (nth 2 context-row)))
                  (new-text (diffs--context-text (nth 3 context-row))))
              (emit (list old-text old-number new-number
                          'ctx file hunk nil nil nil nil nil section)
                    (list new-text new-number new-number
                          'ctx file hunk nil nil nil nil nil section))))))
      (save-excursion
        (goto-char (car hunk))
        (forward-line 1)
        (while (and (< (point) end) (not (eobp)))
          (let ((character (char-after)))
            (cond
             ((memq character '(?\s ?\n))
              (flush)
              (let ((text (diffs--split-line (point)))
                    (origin
                     (min (1+ (line-beginning-position))
                          (line-end-position))))
                (emit (list text old-line new-line 'ctx file hunk
                            origin nil nil nil nil section)
                      (list text new-line new-line 'ctx file hunk
                            origin nil nil nil nil section)))
              (cl-incf old-line)
              (cl-incf new-line))
             ((eq character ?-)
              (push (list (diffs--split-line (point))
                          old-line new-line 'del file hunk
                          (min (1+ (line-beginning-position))
                               (line-end-position))
                          nil nil nil nil section)
                    dels)
              (cl-incf old-line))
             ((eq character ?+)
              (push (list (diffs--split-line (point))
                          new-line new-line 'add file hunk
                          (min (1+ (line-beginning-position))
                               (line-end-position))
                          nil nil nil nil section)
                    adds)
              (cl-incf new-line))))
          (forward-line 1))
        (flush)))
    (list (nreverse old-rows) (nreverse new-rows))))

(defun diffs--split-hunk-row-count (section hunk)
  "Return the non-wrapping physical row count for HUNK in SECTION."
  (let* ((gap (diffs--gap-for-hunk hunk))
         (separator
          (and
           (not (diffs--context-gap-fully-visible-p gap))
           (diffs--hunk-separator section hunk 'split)))
         (count
          (+ (if (and separator
                      (not (string-empty-p separator)))
                 1
               0)
             (or (and gap (plist-get gap :visible)) 0)))
         (end (diffs--hunk-end hunk section))
         (deletions 0)
         (additions 0))
    (cl-labels
        ((flush
          ()
          (cl-incf count (max deletions additions))
          (setq deletions 0
                additions 0)))
      (save-excursion
        (goto-char (car hunk))
        (forward-line 1)
        (while (and (< (point) end) (not (eobp)))
          (pcase (char-after)
            ((or ?\s ?\n)
             (flush)
             (cl-incf count))
            (?-
             (cl-incf deletions))
            (?+
             (cl-incf additions)))
          (forward-line 1))
        (flush)))
    count))

(defun diffs--split-estimated-row-count ()
  "Return a cheap approximate row count for an automatic split.
The estimate uses parsed hunk ranges instead of collecting or aligning
row text.  It is only a policy threshold; paged rendering builds its own
chunk index and corrects each chunk's exact height when materialized."
  (let ((count 0))
    (dolist (section diffs--sections)
      ;; The normal and public custom header paths may suppress a header,
      ;; but counting one keeps this policy computation hook-free and
      ;; slightly conservative around the threshold.
      (cl-incf count)
      (if-let* ((hunks (plist-get section :hunks)))
          (dolist (hunk hunks)
            (let ((gap (diffs--gap-for-hunk hunk)))
              (cl-incf count
                       (+ (max (nth 5 hunk) (nth 6 hunk))
                          (or (and gap (plist-get gap :visible)) 0)
                          (if (diffs--context-gap-fully-visible-p gap)
                              0
                            1)))))
        ;; Metadata-only sections are normally tiny, but counting their
        ;; actual lines avoids selecting the complete model for a large
        ;; binary or externally supplied patch item.
        (cl-incf count
                 (max 0
                      (1-
                       (count-lines
                        (plist-get section :beg)
                        (plist-get section :end)))))))
    count))

(defun diffs--split-paged-eligible-p (wrap-lines)
  "Return non-nil when current split state permits paging.
WRAP-LINES is the current wrapping setting."
  (and (not wrap-lines)
       (null diffs--review-selection)
       (null diffs--review-annotations)
       (null diffs--review-decisions)
       (null diffs--review-source-actions)))

(defun diffs--split-use-paged-p
    (virtualization wrap-lines threshold &optional estimated-row-count)
  "Return non-nil when this split should use paged rendering.
VIRTUALIZATION is the configured policy, WRAP-LINES is the current
wrapping setting, and THRESHOLD is the automatic row threshold.
ESTIMATED-ROW-COUNT reuses a valid cached estimate when supplied."
  (and (diffs--split-paged-eligible-p wrap-lines)
       (or (eq virtualization 'paged)
           (and (eq virtualization 'auto)
                (>= (or estimated-row-count
                        (diffs--split-estimated-row-count))
                    threshold)))))

(defun diffs--split-paged-index ()
  "Return a lightweight non-wrapping split index for the current diff.
The result is (CHUNKS ANCHORS ROW-COUNT).  Each chunk is a vector
\(KIND SECTION PAYLOAD START COUNT), where PAYLOAD is a rendered header
or hunk depending on KIND."
  (let ((row 0)
        chunks anchors)
    (dolist (section diffs--sections)
      (let ((header (diffs--file-header section 'split)))
        (when header
          (push (vector 'header section header row 1) chunks)
          (cl-incf row))
        (unless (plist-get section :hunks)
          (let ((count
                 (save-excursion
                   (goto-char (plist-get section :beg))
                   (forward-line 1)
                   (count-lines (point) (plist-get section :end)))))
            (when (> count 0)
              (push (vector 'meta section nil row count) chunks)
              (cl-incf row count))))
        (dolist (hunk (plist-get section :hunks))
          (let ((count (diffs--split-hunk-row-count section hunk)))
            (push (1+ row) anchors)
            (when (> count 0)
              (push (vector 'hunk section hunk row count) chunks)
              (cl-incf row count))))))
    (list (vconcat (nreverse chunks))
          (nreverse anchors)
          row)))

(defun diffs--split-collect ()
  "Collect aligned row lists from the current unified diffs buffer.
Returns (OLD-ROWS NEW-ROWS ANCHORS); each logical row is
\(STRING NUMBER SRC-LINE KIND FILE HUNK ORIGIN PAIR SOURCE-NUMBER
SOURCE-SIDE LIVE-TARGET SECTION).  NUMBER is the displayed preview line, or nil
for fillers and headers; SOURCE-NUMBER is its immutable old/new
patch-side line.  SRC-LINE is the original new-side target coordinate and
LIVE-TARGET is that coordinate after decisions actually applied to the
worktree.  KIND is one of header, sep, ctx, del, add, filler.  ORIGIN is
the unified-buffer position corresponding to STRING's first character.
Paired changed rows share a two-element PAIR vector."
  (let (old-rows new-rows anchors (row 0))
    (cl-flet ((emit (o n)
                (push o old-rows) (push n new-rows) (cl-incf row)))
      (dolist (sec diffs--sections)
        (let* ((file (plist-get sec :file))
               (header (diffs--file-header sec 'split)))
          (when header
            (emit (list header nil nil 'header file nil nil nil
                        nil nil nil sec)
                  (list header nil nil 'header file nil nil nil
                        nil nil nil sec)))
          (unless (plist-get sec :hunks)
            (save-excursion
              (goto-char (plist-get sec :beg))
              (forward-line 1)
              (while (< (point) (plist-get sec :end))
                (let ((text (buffer-substring
                             (line-beginning-position)
                             (line-end-position))))
                  (emit (list text nil nil 'meta file nil nil nil
                              nil nil nil sec)
                        (list text nil nil 'meta file nil nil nil
                              nil nil nil sec)))
                (forward-line 1))))
          (dolist (hunk (plist-get sec :hunks))
            (push (1+ row) anchors)
            (pcase-let ((`(,old ,new)
                         (diffs--split-collect-hunk sec hunk t)))
              (cl-mapc #'emit old new))))))
    (let ((collected
           (list (nreverse old-rows)
                 (nreverse new-rows)
                 (nreverse anchors))))
      (if (or diffs--review-decisions
              diffs--review-source-actions)
          (diffs--split-resolve-collected
           collected
           diffs--review-decisions
           diffs--review-source-actions)
        collected))))

(defun diffs--split-resolve-collected
    (collected decisions &optional source-actions)
  "Apply DECISIONS and SOURCE-ACTIONS to split rows in COLLECTED.
The normal collection path remains decision-free.  This second stage
collapses chosen blocks to context and adjusts subsequent result line
numbers when a review contains decisions or applied source actions.
A chosen row keeps its original old/new source side when mirrored into
both columns."
  (let ((old-input (nth 0 collected))
        (new-input (nth 1 collected))
        old-output new-output anchors
        (row-count 0)
        (old-shift 0)
        (new-shift 0)
        (live-shift 0)
        file hunk
        (block-index 0)
        change-pairs)
    (cl-labels
        ((emit
          (old new)
          (when (eq (nth 3 old) 'sep)
            (push (1+ row-count) anchors))
          (push old old-output)
          (push new new-output)
          (cl-incf row-count))
         (adjust
          (row display-shift target-shift)
          ;; COLLECTED is a fresh, one-shot row model.  Mutating its line
          ;; number in place avoids copying every row in a large review
          ;; merely because one decision exists.  Preserve the patch-side
          ;; source number and live target before changing preview numbers.
          (when (or (not (zerop display-shift))
                    (not (zerop target-shift)))
            (when (and (nth 1 row) (null (nth 8 row)))
              (setcar (nthcdr 8 row) (nth 1 row)))
            (when (and (nth 2 row) (null (nth 10 row)))
              (setcar (nthcdr 10 row) (nth 2 row)))
            (when (and (nth 1 row) (not (zerop display-shift)))
              (setcar (nthcdr 1 row)
                      (+ (nth 1 row) display-shift)))
            (when (nth 2 row)
              (setcar (nthcdr 10 row)
                      (+ (nth 2 row) target-shift))))
          row)
         (set-target
         (row target)
          ;; Keep display and immutable review coordinates unchanged while
          ;; recording a distinct live-worktree destination.
          (when (and (nth 1 row) (null (nth 8 row)))
            (setcar (nthcdr 8 row) (nth 1 row)))
          (setcar (nthcdr 10 row) target)
          row)
         (flush
          ()
          (when change-pairs
            (let* ((pairs (nreverse change-pairs))
                   (block-section (nth 11 (caar pairs)))
                   (key (diffs--resolution-key file hunk block-index))
                   (decision
                    (alist-get key decisions nil nil #'equal))
                   (source-state
                    (alist-get key source-actions nil nil #'equal))
                   (source-action
                    (or (plist-get source-state :action)
                        ;; Accept legacy callers that construct decisions
                        ;; directly instead of using the owner state.
                        (plist-get decision :source-action)
                        (and (plist-get decision :applied)
                             (plist-get decision :action))))
                   (deletions
                    (cl-loop
                     for pair in pairs
                     when (eq (nth 3 (car pair)) 'del)
                     collect (car pair)))
                   (additions
                    (cl-loop
                     for pair in pairs
                     when (eq (nth 3 (cdr pair)) 'add)
                     collect (cdr pair)))
                   (source-start
                    (or
                     (plist-get source-state :new-start)
                     (cl-loop
                      for row in deletions
                      when (nth 2 row)
                      minimize (nth 2 row)))))
              (if decision
                  (let* ((action (plist-get decision :action))
                         (label
                          (propertize
                           (diffs--resolution-decision-label decision)
                           'face 'diffs-review-decision
                           'diffs-resolution-key key))
                         (chosen
                          (if (eq action 'accept)
                              additions deletions))
                         (shift
                          (if (eq action 'accept)
                              new-shift old-shift)))
                    (emit
                     (list label nil nil 'decision file hunk nil nil
                           nil nil nil block-section)
                     (list label nil nil 'decision file hunk nil nil
                           nil nil nil block-section))
                    (cl-loop
                     for source in chosen
                     for source-index from 0
                     do
                      (let* ((adjusted
                              (adjust source shift live-shift))
                             (source-side
                              (if (eq action 'accept) 'new 'old))
                             (live-target
                              (if (and (eq action 'reject)
                                       (eq source-action 'reject))
                                  (+ (plist-get decision :new-start)
                                     live-shift source-index)
                                (or (nth 10 adjusted)
                                    (nth 2 adjusted))))
                             (row
                              (list
                               (nth 0 adjusted)
                               (nth 1 adjusted)
                               (nth 2 adjusted)
                               'ctx file hunk
                               (nth 6 adjusted) nil
                               (or (nth 8 adjusted) (nth 1 source))
                               source-side live-target block-section)))
                        (emit (copy-tree row) (copy-tree row))))
                    (if (eq action 'accept)
                        (cl-incf old-shift
                                 (- (length additions)
                                    (length deletions)))
                      (cl-incf new-shift
                               (- (length deletions)
                                  (length additions)))))
                (let ((old-source-index 0))
                  (dolist (pair pairs)
                    (let ((old
                           (adjust
                            (car pair) old-shift live-shift))
                          (new
                           (adjust
                            (cdr pair) new-shift live-shift)))
                      ;; With no visible decision after U, an already
                      ;; applied rejection means the old rows are the
                      ;; physical worktree block.  Unified new-side
                      ;; coordinates collapse unequal deletions onto the
                      ;; same insertion point, so assign each actual old
                      ;; row its own sequential live target.
                      (when (and (eq source-action 'reject)
                                 source-start
                                 (eq (nth 3 old) 'del))
                        (set-target
                         old
                         (+ source-start live-shift
                            old-source-index))
                        (cl-incf old-source-index))
                      (emit old new)))))
              (when (eq source-action 'reject)
                (cl-incf live-shift
                         (- (length deletions) (length additions))))
              (cl-incf block-index)
              (setq change-pairs nil)))))
      (cl-mapc
       (lambda (old new)
         (let ((old-kind (nth 3 old))
               (new-kind (nth 3 new)))
           (if (or (memq old-kind '(del filler))
                   (memq new-kind '(add filler)))
               (push (cons old new) change-pairs)
             (flush)
             (when (eq old-kind 'header)
               (setq old-shift 0
                     new-shift 0
                     live-shift 0
                     file (nth 4 old)
                     hunk nil
                     block-index 0))
             (when (eq old-kind 'sep)
               (setq file (nth 4 old)
                     hunk (nth 5 old)
                     block-index 0))
             (emit (adjust old old-shift live-shift)
                   (adjust new new-shift live-shift)))))
       old-input new-input)
      (flush))
    (list (nreverse old-output)
          (nreverse new-output)
          (nreverse anchors))))

(defun diffs--split-string-parts (string width)
  "Split STRING into property-preserving parts of display WIDTH.
Each returned element is (CHUNK . OFFSET), where OFFSET is a character
offset into STRING."
  (if (or (string-empty-p string)
          ;; `string-width' treats TAB as one column, so use this fast
          ;; path only for the overwhelmingly common TAB-free case.
          (and (not (string-search "\t" string))
               (<= (string-width string) width)))
      (list (cons string 0))
    (let ((start 0)
          parts)
      (while (< start (length string))
        (let ((end start)
              (columns 0))
          (catch 'line-full
            (while (< end (length string))
              (let* ((char (aref string end))
                     (char-width
                      (if (eq char ?\t)
                          (- tab-width (% columns tab-width))
                        (max 0 (char-width char)))))
                (when (and (> (+ columns char-width) width) (> end start))
                  (throw 'line-full nil))
                (setq columns (+ columns char-width))
                (cl-incf end))))
          (when (= end start)
            (cl-incf end))
          (push (cons (substring string start end) start) parts)
          (setq start end)))
      (nreverse parts))))

(defun diffs--split-string (string width)
  "Split STRING into property-preserving chunks of display WIDTH."
  (mapcar #'car (diffs--split-string-parts string width)))

(defun diffs--split-physical-rows
    (old-rows new-rows content-width &optional wrap-lines)
  "Build aligned physical rows from OLD-ROWS and NEW-ROWS.
CONTENT-WIDTH is used when WRAP-LINES is non-nil.  Return
\(OLD-VECTOR NEW-VECTOR ANCHORS), where ANCHORS are zero-based indexes
of rendered hunk starts.  A hidden complete-context separator anchors
its first context row.  Physical rows append the immutable patch-side
source number, source-character offset, original old/new source side,
live-worktree target number, and exact owning section."
  (let (old-physical new-physical anchors
        (physical-count 0))
    (cl-labels
        ((physical-row (source part first role paired-offset)
           (let ((offset (if part (cdr part) paired-offset)))
             (if part
                 (list (car part)
                       (and first (nth 1 source))
                       (nth 2 source)
                       (nth 3 source)
                       (nth 4 source)
                       (nth 5 source)
                       (and (nth 6 source)
                            (cons (nth 6 source) offset))
                       (nth 7 source)
                       (or (nth 8 source) (nth 1 source))
                       offset
                       (or (nth 9 source) role)
                       (or (nth 10 source) (nth 2 source))
                       (nth 11 source))
               (list "" nil (nth 2 source) 'filler
                     (nth 4 source) (nth 5 source) nil nil
                     (or (nth 8 source) (nth 1 source)) offset
                     (or (nth 9 source) role)
                     (or (nth 10 source) (nth 2 source))
                     (nth 11 source))))))
      (cl-mapc
       (lambda (old new)
         (let ((separator (eq (nth 3 old) 'sep)))
           (when separator
             (push physical-count anchors))
           (unless (and separator
                        (string-empty-p (car old))
                        (string-empty-p (car new)))
             (let* ((wrap
                     (and wrap-lines
                          (not (memq (nth 3 old) '(header sep)))))
                    (old-parts
                     (if wrap
                         (diffs--split-string-parts
                          (car old) content-width)
                       (list (cons (car old) 0))))
                    (new-parts
                     (if wrap
                         (diffs--split-string-parts
                          (car new) content-width)
                       (list (cons (car new) 0))))
                    (count (max (length old-parts) (length new-parts))))
               (dotimes (index count)
                 (let* ((old-part (pop old-parts))
                        (new-part (pop new-parts))
                        (paired-offset
                         (cdr (or old-part new-part (cons "" 0)))))
                   (push (physical-row
                          old old-part (zerop index) 'old paired-offset)
                         old-physical)
                   (push (physical-row
                          new new-part (zerop index) 'new paired-offset)
                         new-physical)
                   (cl-incf physical-count)))))))
       old-rows new-rows))
    (list (vconcat (nreverse old-physical))
          (vconcat (nreverse new-physical))
          (nreverse anchors))))

(defun diffs--split-paged-chunk-index-at-row (row)
  "Return the paged chunk index containing split ROW."
  (let ((low 0)
        (high (1- (length diffs--split-chunks)))
        found)
    (while (and (not found) (<= low high))
      (let* ((middle (/ (+ low high) 2))
             (chunk (aref diffs--split-chunks middle))
             (start (aref chunk 3))
             (end (+ start (aref chunk 4))))
        (cond
         ((< row start)
          (setq high (1- middle)))
         ((>= row end)
          (setq low (1+ middle)))
         (t
          (setq found middle)))))
    found))

(defun diffs--split-paged-pair ()
  "Return the current paged split buffers as (OLD . NEW)."
  (if (eq diffs--split-role 'old)
      (cons (current-buffer) diffs--split-other)
    (cons diffs--split-other (current-buffer))))

(defun diffs--split-paged-position-anchor (position)
  "Return a stable paged coordinate for buffer POSITION."
  (if (= position (point-max))
      'end
    (when-let* ((row (diffs--split-row-index-at-position position))
                (chunk-index
                 (diffs--split-paged-chunk-index-at-row row)))
      (let ((chunk (aref diffs--split-chunks chunk-index)))
        (vector chunk-index
                (- row (aref chunk 3))
                (- position (diffs--split-row-position row)))))))

(defun diffs--split-paged-resolve-position (anchor)
  "Resolve stable paged position ANCHOR in the current projection."
  (if (eq anchor 'end)
      (point-max)
    (if (not (vectorp anchor))
        (point-min)
      (let* ((chunk (aref diffs--split-chunks (aref anchor 0)))
             (count (aref chunk 4))
             (row
              (+ (aref chunk 3)
                 (min (aref anchor 1) (max 0 (1- count))))))
        (if (zerop count)
            (diffs--split-row-position row)
          (let ((begin (diffs--split-row-position row))
                (end (diffs--split-row-position (1+ row))))
            (min end (+ begin (aref anchor 2)))))))))

(defun diffs--split-paged-resize-side (boundary delta)
  "Resize one paged split side by DELTA rows at BOUNDARY.
Positive DELTA inserts skeleton rows.  Negative DELTA removes the
trailing overestimate immediately before BOUNDARY."
  (let* ((old-rows diffs--split-rows)
         (old-decorated diffs--split-decorated)
         (old-count (length old-rows))
         (new-count (+ old-count delta))
         (prefix-count (if (< delta 0)
                           (+ boundary delta)
                         boundary))
         (suffix-start boundary)
         (suffix-target (+ boundary delta))
         (new-rows (make-vector new-count nil))
         (new-decorated (make-bool-vector new-count nil)))
    (when (or (< new-count 0)
              (< prefix-count 0)
              (> boundary old-count))
      (error "Invalid paged split resize at %d by %d"
             boundary delta))
    (when (< delta 0)
      (cl-loop
       for index from prefix-count below boundary
       when (aref old-rows index)
       do
       (error "Cannot remove a materialized paged split row")))
    (dotimes (index prefix-count)
      (aset new-rows index (aref old-rows index))
      (when (aref old-decorated index)
        (aset new-decorated index t)))
    (dotimes (offset (- old-count suffix-start))
      (let ((old-index (+ suffix-start offset))
            (new-index (+ suffix-target offset)))
        (aset new-rows new-index (aref old-rows old-index))
        (when (aref old-decorated old-index)
          (aset new-decorated new-index t))))
    (let ((inhibit-read-only t))
      (save-excursion
        (with-silent-modifications
          (if (> delta 0)
              (progn
                (goto-char (diffs--split-row-position boundary))
                (insert (make-string delta ?\n)))
            (delete-region
             (diffs--split-row-position (+ boundary delta))
             (diffs--split-row-position boundary))))))
    (setq-local diffs--split-rows new-rows)
    (setq-local diffs--split-decorated new-decorated)
    (setq-local diffs--split-paged-retained-range nil)
    (diffs--split-row-length-rebuild)))

(defun diffs--split-paged-store-anchors
    (anchors old-buffer new-buffer)
  "Store ANCHORS for OLD-BUFFER, NEW-BUFFER, and their owner cache."
  (dolist (buffer (list old-buffer new-buffer))
    (with-current-buffer buffer
      (setq-local diffs--split-anchors anchors)))
  (when-let* ((owner
               (buffer-local-value
                'diffs--split-unified old-buffer))
              ((buffer-live-p owner)))
    (with-current-buffer owner
      (setq diffs--split-cache
            (plist-put diffs--split-cache :anchors anchors)))))

(defun diffs--split-paged-adjust-anchors
    (boundary delta old-buffer new-buffer)
  "Shift anchors after BOUNDARY by DELTA in OLD-BUFFER and NEW-BUFFER."
  (diffs--split-paged-store-anchors
   (mapcar
    (lambda (anchor)
      (if (> anchor boundary) (+ anchor delta) anchor))
    (buffer-local-value 'diffs--split-anchors old-buffer))
   old-buffer new-buffer))

(defun diffs--split-paged-correct-chunk-height
    (index actual-count old-buffer new-buffer)
  "Correct chunk INDEX to ACTUAL-COUNT in OLD-BUFFER and NEW-BUFFER.
Return the signed row-count adjustment."
  (let* ((chunks
          (buffer-local-value 'diffs--split-chunks old-buffer))
         (chunk (aref chunks index))
         (old-count (aref chunk 4))
         (delta (- actual-count old-count))
         (boundary (+ (aref chunk 3) old-count))
         (old-range
          (buffer-local-value
           'diffs--split-paged-retained-range old-buffer))
         (new-range
          (buffer-local-value
           'diffs--split-paged-retained-range new-buffer))
         old-resized)
    (unless (zerop delta)
      (when (or
             (aref
              (buffer-local-value
               'diffs--split-materialized-chunks old-buffer)
              index)
             (aref
              (buffer-local-value
               'diffs--split-materialized-chunks new-buffer)
              index))
        (error "Cannot resize a materialized paged split chunk"))
      (condition-case error-data
          (progn
            (with-current-buffer old-buffer
              (diffs--split-paged-resize-side boundary delta))
            (setq old-resized t)
            (with-current-buffer new-buffer
              (diffs--split-paged-resize-side boundary delta)))
        (error
         (when old-resized
           (with-current-buffer old-buffer
             (diffs--split-paged-resize-side
              (+ boundary delta) (- delta))
             (setq-local diffs--split-paged-retained-range old-range)))
         (with-current-buffer new-buffer
           (setq-local diffs--split-paged-retained-range new-range))
         (signal (car error-data) (cdr error-data))))
      (aset chunk 4 actual-count)
      (cl-loop
       for later from (1+ index) below (length chunks)
       do
       (let ((later-chunk (aref chunks later)))
         (aset later-chunk 3 (+ (aref later-chunk 3) delta))))
      (diffs--split-paged-adjust-anchors
       boundary delta old-buffer new-buffer))
    delta))

(defun diffs--split-paged-chunk-rows (chunk)
  "Return paired non-wrapping physical row vectors for CHUNK."
  (let ((section (aref chunk 1))
        (payload (aref chunk 2)))
    (pcase (aref chunk 0)
      ('header
       (let* ((file (plist-get section :file))
              (row (list payload nil nil 'header file nil nil nil
                         nil nil nil nil section))
              (rows (vector row)))
         (list rows (vector (copy-sequence row)))))
      ('meta
       (let ((file (plist-get section :file))
             old new)
         (save-excursion
           (goto-char (plist-get section :beg))
           (forward-line 1)
           (while (< (point) (plist-get section :end))
             (let* ((text
                     (buffer-substring
                      (line-beginning-position)
                      (line-end-position)))
                    (row
                     (list text nil nil 'meta file nil nil nil
                           nil nil nil nil section)))
               (push row old)
               (push (copy-sequence row) new))
             (forward-line 1)))
         (list (vconcat (nreverse old))
               (vconcat (nreverse new)))))
      ('hunk
       (pcase-let* ((`(,old ,new)
                      (diffs--split-collect-hunk
                       section payload t))
                    (`(,old-physical ,new-physical . ,_)
                     (diffs--split-physical-rows
                      old new nil)))
         (list old-physical new-physical))))))

(defun diffs--split-paged-complete-projection (chunks)
  "Return an exact complete projection for paged CHUNKS.
The result is \(CHUNKS ANCHORS OLD-ROWS NEW-ROWS)."
  (let ((row 0)
        exact-chunks anchors old-rows new-rows)
    (dotimes (index (length chunks))
      (let* ((chunk (aref chunks index))
             (rows (diffs--split-paged-chunk-rows chunk))
             (old (nth 0 rows))
             (new (nth 1 rows))
             (count (length old))
             (exact (copy-sequence chunk)))
        (unless (= count (length new))
          (error "Paged split sides disagree for chunk %d" index))
        (aset exact 3 row)
        (aset exact 4 count)
        (when (eq (aref exact 0) 'hunk)
          (push (1+ row) anchors))
        (dotimes (offset count)
          (push (aref old offset) old-rows)
          (push (aref new offset) new-rows))
        (push exact exact-chunks)
        (cl-incf row count)))
    (list
     (vconcat (nreverse exact-chunks))
     (nreverse anchors)
     (vconcat (nreverse old-rows))
     (vconcat (nreverse new-rows)))))

(defun diffs--split-paged-install-complete (chunks rows)
  "Bulk-install exact paged CHUNKS and one side's complete ROWS."
  (let* ((count (length rows))
         (point-anchor
          (diffs--split-paged-position-anchor (point)))
         (window-states
          (mapcar
           (lambda (window)
             (list
              window
              (diffs--split-paged-position-anchor
               (window-start window))
              (diffs--split-paged-position-anchor
               (window-point window))))
           (get-buffer-window-list (current-buffer) nil t)))
         (text
          (mapconcat
           (lambda (row) (concat (car row) "\n"))
           rows ""))
         (inhibit-read-only t))
    (with-silent-modifications
      (erase-buffer)
      (insert text))
    (setq-local diffs--split-chunks chunks)
    (setq-local diffs--split-rows rows)
    (setq-local diffs--split-row-positions [])
    (setq-local diffs--split-decorated
                (make-bool-vector count nil))
    (setq-local diffs--split-materialized-chunks
                (make-bool-vector (length chunks) t))
    (setq-local diffs--split-materialized-indexes
                (when (> (length chunks) 0)
                  (number-sequence 0 (1- (length chunks)))))
    (setq-local diffs--split-paged-retained-range nil)
    (diffs--split-row-length-rebuild)
    (goto-char
     (diffs--split-paged-resolve-position point-anchor))
    (dolist (state window-states)
      (let ((window (nth 0 state)))
        (when (and (window-live-p window)
                   (eq (window-buffer window) (current-buffer)))
          (set-window-start
           window
           (diffs--split-paged-resolve-position (nth 1 state))
           t)
          (set-window-point
           window
           (diffs--split-paged-resolve-position (nth 2 state))))))))

(defun diffs--split-install-skeleton (count chunks width)
  "Install a paged skeleton with COUNT rows indexed by CHUNKS.
WIDTH is the line-number width used to decorate visible rows."
  (let ((inhibit-read-only t))
    (insert (make-string count ?\n))
    (setq-local diffs--split-paged-p t)
    (setq-local diffs--split-chunks chunks)
    (setq-local diffs--split-materialized-chunks
                (make-bool-vector (length chunks) nil))
    (setq-local diffs--split-materialized-indexes nil)
    (setq-local diffs--split-paged-pinned nil)
    (setq-local diffs--split-paged-retained-range nil)
    (setq-local diffs--split-row-length-tree
                (make-vector (1+ count) 0))
    (setq-local diffs--split-rows (make-vector count nil))
    (setq-local diffs--split-row-positions [])
    (setq-local diffs--split-decorated
                (make-bool-vector count nil))
    (setq-local diffs--split-render-width width)
    (setq-local filter-buffer-substring-function
                #'diffs--split-filter-buffer-substring)))

(defun diffs--split-paged-insert-chunk (index rows)
  "Insert one side's ROWS for paged chunk INDEX."
  (let* ((chunk (aref diffs--split-chunks index))
         (start (aref chunk 3))
         (count (aref chunk 4)))
    (unless (= count (length rows))
      (error "Paged split chunk expected %d rows, got %d"
             count (length rows)))
    (let ((begin (diffs--split-row-position start))
          (end (diffs--split-row-position (+ start count)))
          (inhibit-read-only t)
          pieces point-anchor)
      (when (and (>= (point) begin) (< (point) end))
        (setq point-anchor
              (diffs--split-paged-position-anchor (point))))
      (dotimes (offset count)
        (let* ((row (aref rows offset))
               (text (car row)))
          (push (concat text "\n") pieces)))
      (save-excursion
        (with-silent-modifications
          (delete-region begin end)
          (goto-char begin)
          (insert (apply #'concat (nreverse pieces)))))
      (dotimes (offset count)
        (aset diffs--split-rows
              (+ start offset) (aref rows offset))
        (diffs--split-row-length-add
         (+ start offset)
         (length (car (aref rows offset)))))
      (aset diffs--split-materialized-chunks index t)
      (push index diffs--split-materialized-indexes)
      (when point-anchor
        (goto-char
         (diffs--split-paged-resolve-position point-anchor))))))

(defun diffs--split-paged-remove-chunk (index)
  "Replace materialized paged chunk INDEX with its row skeleton."
  (let* ((chunk (aref diffs--split-chunks index))
         (start (aref chunk 3))
         (count (aref chunk 4))
         (begin (diffs--split-row-position start))
         (end (diffs--split-row-position (+ start count)))
         (inhibit-read-only t)
         point-anchor)
    (when (and (>= (point) begin) (< (point) end))
      (setq point-anchor
            (diffs--split-paged-position-anchor (point))))
    (save-excursion
      (with-silent-modifications
        (delete-region begin end)
        (goto-char begin)
        (insert (make-string count ?\n))))
    (dotimes (offset count)
      (let* ((row-index (+ start offset))
             (row (aref diffs--split-rows row-index)))
        (when row
          (diffs--split-row-length-add
           row-index (- (length (car row)))))
        (aset diffs--split-rows row-index nil)
        (aset diffs--split-decorated row-index nil)))
    (aset diffs--split-materialized-chunks index nil)
    (setq-local diffs--split-materialized-indexes
                (delq index diffs--split-materialized-indexes))
    (when point-anchor
      (goto-char
       (diffs--split-paged-resolve-position point-anchor)))))

(defun diffs--split-paged-materialize-range (start end)
  "Materialize paged chunks intersecting split rows START through END.
Return (START END RESIZED), adjusting the range when exact alignment
changes a chunk's cheap indexed height."
  (let ((range-start start)
        (range-end end)
        resized)
    (when (and diffs--split-paged-p
               (< start end)
               (> (length diffs--split-chunks) 0))
      (let* ((first
              (diffs--split-paged-chunk-index-at-row
               (max 0 start)))
             (last
              (diffs--split-paged-chunk-index-at-row
               (min (1- (length diffs--split-rows))
                    (1- end))))
             (owner diffs--split-unified)
             (pair (diffs--split-paged-pair))
             (old-buffer (car pair))
             (new-buffer (cdr pair))
             (chunks diffs--split-chunks))
        (when (and first last
                   (buffer-live-p owner)
                   (buffer-live-p old-buffer)
                   (buffer-live-p new-buffer))
          (cl-loop
           for index from first to last
           do
           (let ((old-present
                  (aref
                   (buffer-local-value
                    'diffs--split-materialized-chunks old-buffer)
                   index))
                 (new-present
                  (aref
                   (buffer-local-value
                    'diffs--split-materialized-chunks new-buffer)
                   index)))
             (unless (and old-present new-present)
               ;; Repair a stale one-sided cache before replacing the pair.
               (when old-present
                 (with-current-buffer old-buffer
                   (diffs--split-paged-remove-chunk index)))
               (when new-present
                 (with-current-buffer new-buffer
                   (diffs--split-paged-remove-chunk index)))
               (let* ((chunk (aref chunks index))
                      (old-count (aref chunk 4))
                      (boundary (+ (aref chunk 3) old-count))
                      (rows
                       (with-current-buffer owner
                         (diffs--split-paged-chunk-rows chunk)))
                      (old-rows (nth 0 rows))
                      (new-rows (nth 1 rows))
                      (actual-count (length old-rows)))
                 (unless (= actual-count (length new-rows))
                   (error
                    "Paged split sides disagree for chunk %d" index))
                 (unless (= actual-count old-count)
                   (let ((delta
                          (diffs--split-paged-correct-chunk-height
                           index actual-count
                           old-buffer new-buffer)))
                     (when (>= range-start boundary)
                       (cl-incf range-start delta))
                     (when (>= range-end boundary)
                       (cl-incf range-end delta))
                     (setq resized t)))
                 (with-current-buffer old-buffer
                   (diffs--split-paged-insert-chunk index old-rows))
                 (condition-case error-data
                     (with-current-buffer new-buffer
                       (diffs--split-paged-insert-chunk index new-rows))
                   (error
                    (with-current-buffer old-buffer
                      (diffs--split-paged-remove-chunk index))
                    (signal
                     (car error-data) (cdr error-data)))))))))))
    (list range-start range-end resized)))

(defun diffs--split-paged-materialize-hunk (hunk)
  "Materialize the paged chunk that owns HUNK."
  (when (and diffs--split-paged-p hunk)
    (when-let* ((index
                 (cl-position-if
                  (lambda (chunk)
                    (and (eq (aref chunk 0) 'hunk)
                         (eq (aref chunk 2) hunk)))
                  diffs--split-chunks)))
      (let* ((chunk (aref diffs--split-chunks index))
             (start (aref chunk 3)))
        (diffs--split-paged-materialize-range
         start (+ start (aref chunk 4)))))))

(defun diffs--split-paged-retain-range (start end)
  "Retain paged chunks intersecting rows START through END.
Materialized chunks outside the range are returned to their lightweight
row skeleton in both columns."
  (unless (or diffs--split-paged-pinned
              (equal diffs--split-paged-retained-range
                     (cons start end)))
    (let* ((pair (diffs--split-paged-pair))
           (old-buffer (car pair))
           (new-buffer (cdr pair)))
      (when (and (buffer-live-p old-buffer)
                 (buffer-live-p new-buffer))
        (dolist (index
                 (copy-sequence diffs--split-materialized-indexes))
          (let* ((chunk (aref diffs--split-chunks index))
                 (chunk-start (aref chunk 3))
                 (chunk-end (+ chunk-start (aref chunk 4))))
            (when (or (<= chunk-end start)
                      (>= chunk-start end))
              (when (aref
                     (buffer-local-value
                      'diffs--split-materialized-chunks old-buffer)
                     index)
                (with-current-buffer old-buffer
                  (diffs--split-paged-remove-chunk index)))
              (when (aref
                     (buffer-local-value
                      'diffs--split-materialized-chunks new-buffer)
                     index)
                (with-current-buffer new-buffer
                  (diffs--split-paged-remove-chunk index))))))
        (dolist (buffer (list old-buffer new-buffer))
          (with-current-buffer buffer
            (setq-local diffs--split-paged-retained-range
                        (cons start end))))))))

(defun diffs--split-paged-materialize-all ()
  "Materialize and retain every chunk in the current split pair."
  (when diffs--split-paged-p
    (let* ((calling-buffer (current-buffer))
           (pair (diffs--split-paged-pair))
           (old-buffer (car pair))
           (new-buffer (cdr pair))
           (old-pinned
            (buffer-local-value
             'diffs--split-paged-pinned old-buffer))
           (new-pinned
            (buffer-local-value
             'diffs--split-paged-pinned new-buffer))
           (old-range
            (buffer-local-value
             'diffs--split-paged-retained-range old-buffer))
           (new-range
            (buffer-local-value
             'diffs--split-paged-retained-range new-buffer))
           (owner diffs--split-unified)
           (chunks diffs--split-chunks)
           projection)
      (unless
          (and
           old-pinned new-pinned
           (not
            (cl-position
             nil
             (buffer-local-value
              'diffs--split-materialized-chunks old-buffer)))
           (not
            (cl-position
             nil
             (buffer-local-value
              'diffs--split-materialized-chunks new-buffer))))
        ;; Exact alignment happens before either derived buffer changes.
        ;; A loader or renderer error therefore leaves the visible pair and
        ;; its pinning policy untouched.
        (setq projection
              (with-current-buffer owner
                (diffs--split-paged-complete-projection chunks)))
        (condition-case error-data
            (pcase-let ((`(,exact-chunks ,anchors
                          ,old-rows ,new-rows)
                         projection))
              (with-current-buffer old-buffer
                (diffs--split-paged-install-complete
                 exact-chunks old-rows))
              (with-current-buffer new-buffer
                (diffs--split-paged-install-complete
                 exact-chunks new-rows))
              (diffs--split-paged-store-anchors
               anchors old-buffer new-buffer)
              (dolist (buffer (list old-buffer new-buffer))
                (with-current-buffer buffer
                  (setq-local diffs--split-paged-pinned t)
                  (setq-local diffs--split-paged-retained-range nil)))
              (when-let* ((window
                           (get-buffer-window calling-buffer t)))
                (diffs--split-materialize-window window)))
          (error
           (with-current-buffer old-buffer
             (setq-local diffs--split-paged-pinned old-pinned)
             (setq-local diffs--split-paged-retained-range old-range))
           (with-current-buffer new-buffer
             (setq-local diffs--split-paged-pinned new-pinned)
             (setq-local diffs--split-paged-retained-range new-range))
           (signal (car error-data) (cdr error-data))))))))

(defun diffs--split-filter-buffer-substring (begin end delete)
  "Return paged split text between BEGIN and END.
Materialize the complete projection before copying so normal `kill-ring'
commands never observe skeleton rows.  Delete the range when DELETE is
non-nil."
  (let ((begin-anchor
         (diffs--split-paged-position-anchor begin))
        (end-anchor
         (diffs--split-paged-position-anchor end)))
    (diffs--split-paged-materialize-all)
    (let* ((new-begin
            (diffs--split-paged-resolve-position begin-anchor))
           (new-end
            (diffs--split-paged-resolve-position end-anchor))
           (start (min new-begin new-end))
           (finish (max new-begin new-end))
           (text (buffer-substring start finish)))
      (when delete
        (delete-region start finish))
      text)))

(defun diffs--split-pre-command ()
  "Prepare complete paged text for commands that inspect offscreen rows."
  (when (and diffs--split-paged-p
             (or
              (and
               (symbolp this-command)
               (string-prefix-p
                "isearch-" (symbol-name this-command)))
              (memq this-command
                    '(occur
                      multi-occur
                      query-replace
                      query-replace-regexp
                      diffs-review-select
                      diffs-review-add-annotation
                      diffs-review-previous-annotation
                      diffs-review-next-annotation))))
    (diffs--split-paged-materialize-all)))

(defun diffs--split-source-face-runs (row)
  "Return source face runs corresponding to split ROW.
Each run is (START END FACE), with offsets relative to ROW's text."
  (when-let* ((unified diffs--split-unified)
              ((buffer-live-p unified)))
    (let ((origin (nth 6 row))
          runs)
      (if origin
          (let* ((source-start (+ (car origin) (cdr origin)))
                 (source-end (+ source-start (length (car row)))))
            (with-current-buffer unified
              (when (< source-start source-end)
                ;; `diff-mode' needs the marker at line start to select the
                ;; source language before it creates syntax overlays.
                (font-lock-ensure
                 (save-excursion
                   (goto-char source-start)
                   (line-beginning-position))
                 (save-excursion
                   (goto-char source-end)
                   (min (point-max) (1+ (line-end-position)))))
                ;; Diff mode stores its added/removed/context presentation
                ;; in text `face' properties and deliberately materializes
                ;; source-language font-lock as overlays.  Copy only those
                ;; overlays: the split row supplies its own background, and
                ;; copying the patch face would override syntax foregrounds.
                (dolist (overlay
                         (overlays-in source-start source-end))
                  (when-let*
                      (((not
                         (overlay-get overlay 'diffs-intraline)))
                       ((not (overlay-get overlay 'diffs-review)))
                       (face (overlay-get overlay 'face)))
                    (push
                     (list
                      (- (max source-start
                              (overlay-start overlay))
                         source-start)
                      (- (min source-end (overlay-end overlay))
                         source-start)
                      face)
                     runs))))))
        (let* ((side (diffs--split-row-source-side row))
               (line (diffs--split-row-source-number row))
               (section
                (diffs--token-section-for-row unified row))
               (lines
                (and section line
                     (buffer-local-value
                      (if (eq side 'old)
                          'diffs--old-content-cache
                        'diffs--new-content-cache)
                      unified)))
               (source
                (and (hash-table-p lines)
                     (> line 0)
                     (when-let* ((vector
                                  (gethash section lines)))
                       (and (vectorp vector)
                            (<= line (length vector))
                            (aref vector (1- line))))))
               (offset (or (nth 9 row) 0))
               (limit
                (and source
                     (min (length source)
                          (+ offset (length (car row)))))))
          (when (and source limit (< offset limit))
            (let ((position offset))
              (while (< position limit)
                (let ((next
                       (min
                        limit
                        (or
                         (next-single-property-change
                          position 'face source limit)
                         limit)))
                      (face
                       (get-text-property position 'face source)))
                  (when face
                    (push
                     (list (- position offset)
                           (- next offset)
                           face)
                     runs))
                  (setq position next)))))))
      runs)))

(defun diffs--split-clear-source-faces (begin end)
  "Remove source syntax faces previously applied between BEGIN and END."
  (let ((position begin))
    (while (< position end)
      (let* ((next
              (or
               (next-single-property-change
                position 'diffs-source-face nil end)
               end))
             (face
              (get-text-property position 'diffs-source-face)))
        (when face
          (let* ((current
                  (get-text-property position 'face))
                 (remaining
                  (cond
                   ((equal current face) nil)
                   ((and (listp current)
                         (member face current))
                    (cl-remove
                     face current :test #'equal :count 1))
                   (t current))))
            (if remaining
                (put-text-property
                 position next 'face remaining)
              (remove-text-properties
               position next '(face nil)))))
        (remove-text-properties
         position next '(diffs-source-face nil))
        (setq position next)))))

(defun diffs--split-apply-source-faces (begin end row)
  "Replace source syntax faces for ROW between BEGIN and END."
  (let ((content-end
         (min end (+ begin (length (car row))))))
    (diffs--split-clear-source-faces begin content-end)
    (dolist (run (diffs--split-source-face-runs row))
      (let ((start (+ begin (nth 0 run)))
            (finish (+ begin (nth 1 run)))
            (face (nth 2 run)))
        (add-face-text-property start finish face nil)
        (put-text-property
         start finish 'diffs-source-face face)))))

(defun diffs--refresh-split-source-faces (owner section side)
  "Refresh visible split source faces for OWNER, SECTION, and SIDE."
  (let ((cache
         (buffer-local-value 'diffs--split-cache owner)))
    (dolist (buffer
             (list (plist-get cache :old)
                   (plist-get cache :new)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (let ((inhibit-read-only t))
            (with-silent-modifications
              (dotimes (index (length diffs--split-rows))
                (let ((row (aref diffs--split-rows index)))
                  (when
                      (and
                       (aref diffs--split-decorated index)
                       (null (nth 6 row))
                       (eq side
                           (diffs--split-row-source-side row))
                       (eq section
                           (diffs--token-section-for-row owner row)))
                    (diffs--split-apply-source-faces
                     (diffs--split-row-position index)
                     (diffs--split-row-position (1+ index))
                     row))))))
          (force-window-update buffer))))))

(defun diffs--split-intraline-runs (row role)
  "Return visible within-line runs for ROW on ROLE.
Runs use offsets relative to ROW's physical text."
  (when-let* ((pair (nth 7 row))
              (origin (nth 6 row))
              (unified diffs--split-unified)
              ((buffer-live-p unified)))
    (let* ((offset (cdr origin))
           (limit (+ offset (length (car row))))
           (ranges
            (with-current-buffer unified
              (diffs--intraline-ranges
               (aref pair 0) (aref pair 1))))
           (side-ranges (if (eq role 'old) (car ranges) (cdr ranges)))
           runs)
      (dolist (range side-ranges)
        (let ((start (max offset (car range)))
              (end (min limit (cdr range))))
          (when (< start end)
            (push (cons (- start offset) (- end offset)) runs))))
      (nreverse runs))))

(defun diffs--split-decorate-row (begin end row width role)
  "Materialize visual properties for ROW between BEGIN and END.
WIDTH is the number-column width and ROLE is `old' or `new'."
  (pcase-let ((`(,_str ,num ,_src ,kind ,file ,hunk . ,_) row))
    (let* ((content-end (min end (+ begin (length (car row)))))
           (face
            (pcase kind
              ('del (and (eq role 'old)
                         (if diffs-split-full-width-backgrounds
                             'diffs-split-removed-line
                           'diff-removed)))
              ('add (and (eq role 'new)
                         (if diffs-split-full-width-backgrounds
                             'diffs-split-added-line
                           'diff-added)))
              ('filler 'diffs-filler))))
      (when face
        (add-face-text-property
         begin
         (if (or diffs-split-full-width-backgrounds (eq kind 'filler))
             end
           content-end)
         face t))
      (when (memq kind '(ctx del add filler))
        (let* ((indicator
                (pcase kind
                  ('del (and (eq role 'old) ?-))
                  ('add (and (eq role 'new) ?+))))
               (change-face
                (pcase indicator
                  (?+ (and diffs-split-full-width-backgrounds
                           'diffs-split-added-line))
                  (?- (and diffs-split-full-width-backgrounds
                           'diffs-split-removed-line))))
               (fringe (diffs--fringe-prefix indicator))
               (section
                (and (buffer-live-p diffs--split-unified)
                     (diffs--token-section-for-row
                      diffs--split-unified row)))
               (gutter-face
                (if (eq kind 'filler)
                    '(diffs-line-number diffs-filler)
                  (diffs--line-prefix-face change-face)))
               (gutter
                (and section
                     (diffs--gutter
                      section 'split kind width
                      (and (eq role 'old) num)
                      (and (eq role 'new) num)
                      role
                      (and (null num)
                           (> (or (nth 9 row) 0) 0))
                      gutter-face))))
          (when (or gutter (not (string-empty-p fringe)))
            (put-text-property
             begin end 'line-prefix
             (concat fringe (or gutter ""))))))
      (add-text-properties
       begin end
       (list 'diffs-src
             (diffs--split-row-source-location row)
             'diffs-file file
             'diffs-hunk hunk
             'diffs-kind kind
             'diffs-number num))
      (diffs--split-apply-source-faces begin end row)
      (let ((refine-face
             (if (eq role 'old)
                 'diff-refine-removed
               'diff-refine-added)))
        (dolist (run (diffs--split-intraline-runs row role))
          (add-face-text-property
           (+ begin (car run)) (+ begin (cdr run))
           refine-face nil))))))

(defun diffs--split-install-rows (rows width)
  "Bulk-insert ROWS and initialize their position index.
WIDTH is retained for later incremental decoration."
  (let* ((count (length rows))
         (positions (make-vector (1+ count) 1))
         (pieces (make-vector count nil))
         (position 1)
         (inhibit-read-only t))
    (dotimes (index count)
      (aset positions index position)
      (let ((piece (concat (car (aref rows index)) "\n")))
        (aset pieces index piece)
        (cl-incf position (length piece))))
    (aset positions count position)
    (insert (mapconcat #'identity pieces ""))
    (setq-local diffs--split-paged-p nil)
    (setq-local diffs--split-chunks [])
    (setq-local diffs--split-materialized-chunks [])
    (setq-local diffs--split-materialized-indexes nil)
    (setq-local diffs--split-paged-pinned nil)
    (setq-local diffs--split-paged-retained-range nil)
    (setq-local diffs--split-row-length-tree [])
    (setq-local diffs--split-rows rows)
    (setq-local diffs--split-row-positions positions)
    (setq-local diffs--split-decorated
                (make-bool-vector count nil))
    (setq-local diffs--split-render-width width)
    (when (eq filter-buffer-substring-function
              #'diffs--split-filter-buffer-substring)
      (kill-local-variable 'filter-buffer-substring-function))))

(defun diffs--split-render-pair
    (old-rows new-rows width content-width old-buffer new-buffer)
  "Bulk-render OLD-ROWS and NEW-ROWS into their paired buffers.
WIDTH is the number-column width and CONTENT-WIDTH is the wrapping
width.  Insert the result into OLD-BUFFER and NEW-BUFFER, then return
the rendered hunk anchor line numbers."
  (pcase-let ((`(,old ,new ,anchor-indexes)
               (diffs--split-physical-rows
                old-rows new-rows content-width diffs-split-wrap-lines)))
    (with-current-buffer old-buffer
      (diffs--split-install-rows old width))
    (with-current-buffer new-buffer
      (diffs--split-install-rows new width))
    (mapcar #'1+ anchor-indexes)))

(defun diffs--split-render-paged
    (index width old-buffer new-buffer)
  "Install paged split INDEX into OLD-BUFFER and NEW-BUFFER.
WIDTH is the gutter width.  Return the indexed hunk anchor line numbers."
  (pcase-let ((`(,chunks ,anchors ,count) index))
    (with-current-buffer old-buffer
      (diffs--split-install-skeleton
       count chunks width))
    (with-current-buffer new-buffer
      (diffs--split-install-skeleton
       count chunks width))
    anchors))

(defun diffs--split-materialize-range (start end)
  "Decorate split rows in the half-open index range START..END.
Return (START END RESIZED) using corrected paged row coordinates."
  (pcase-let* ((range
                (if diffs--split-paged-p
                    (diffs--split-paged-materialize-range start end)
                  (list start end nil)))
               (`(,range-start ,range-end ,resized) range)
               (limit
                (min range-end (length diffs--split-rows)))
               (inhibit-read-only t))
    (with-silent-modifications
      (cl-loop
       for index from (max 0 range-start) below limit
       for row = (aref diffs--split-rows index)
       when (and row
                 (not (aref diffs--split-decorated index)))
       do
       (diffs--split-decorate-row
        (diffs--split-row-position index)
        (diffs--split-row-position (1+ index))
        row
        diffs--split-render-width
        diffs--split-role)
       (aset diffs--split-decorated index t)))
    (list range-start range-end resized)))

(defun diffs--split-materialize-window (window &optional start)
  "Materialize WINDOW's visible split rows plus overscan.
START overrides WINDOW's pending start during a scroll hook.  Both
columns materialize the same row interval."
  (let ((buffer (window-buffer window)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (> (length diffs--split-rows) 0)
          (let* ((position (or start (window-start window)))
                 (other diffs--split-other))
            (if (not diffs--split-paged-p)
                (let* ((first
                        (diffs--split-row-index-at-position position))
                       (visible-end
                        (save-excursion
                          (goto-char position)
                          (forward-line
                           (1+ (window-body-height window)))
                          (point)))
                       (last
                        (1+
                         (or
                          (diffs--split-row-index-at-position visible-end)
                          first)))
                       (range-start
                        (max 0 (- first diffs-split-overscan)))
                       (range-end
                        (min
                         (length diffs--split-rows)
                         (+ last diffs-split-overscan))))
                  (diffs--split-materialize-range
                   range-start range-end)
                  (when (buffer-live-p other)
                    (with-current-buffer other
                      (diffs--split-materialize-range
                       range-start range-end)))
                  position)
              (let ((position-anchor
                     (diffs--split-paged-position-anchor position))
                    (vscroll (window-vscroll window t))
                    resized
                    first range-start range-end)
                (cl-labels
                    ((visible-range
                      ()
                      (let* ((resolved
                              (diffs--split-paged-resolve-position
                               position-anchor))
                             (row
                              (diffs--split-row-index-at-position
                               resolved))
                             (visible-end
                              (save-excursion
                                (goto-char resolved)
                                ;; `window-end' may still be point-max
                                ;; before the first redisplay.
                                (forward-line
                                 (1+ (window-body-height window)))
                                (point)))
                             (last
                              (1+
                               (or
                                (diffs--split-row-index-at-position
                                 visible-end)
                                row))))
                        (list
                         row
                         (max 0 (- row diffs-split-overscan))
                         (min
                          (length diffs--split-rows)
                          (+ last diffs-split-overscan))))))
                  (setq resized t)
                  (while resized
                    (pcase-let
                        ((`(,visible-first ,desired-start ,desired-end)
                          (visible-range)))
                      (setq first visible-first)
                      (pcase-let
                          ((`(,actual-start ,actual-end ,changed)
                            (diffs--split-materialize-range
                             desired-start desired-end)))
                        (setq range-start actual-start
                              range-end actual-end
                              resized changed)
                        (when (buffer-live-p other)
                          (with-current-buffer other
                            (pcase-let
                                ((`(,peer-start ,peer-end ,peer-changed)
                                  (diffs--split-materialize-range
                                   range-start range-end)))
                              (setq range-start peer-start
                                    range-end peer-end
                                    resized
                                    (or resized peer-changed)))))))))
                  (diffs--split-paged-retain-range
                   (max 0 (- range-start diffs-split-overscan))
                   (min
                    (length diffs--split-rows)
                    (+ range-end diffs-split-overscan)))
                  (setq position
                        (diffs--split-paged-resolve-position
                         position-anchor)
                        first
                        (diffs--split-row-index-at-position position))
                  (let ((canonical
                         (diffs--split-row-position first)))
                    (set-window-start window canonical t)
                    (set-window-vscroll window vscroll t)
                    canonical)))))))))

(defun diffs--split-sync-from (window &optional start)
  "Align the window(s) paired with WINDOW to its scroll position.
START overrides WINDOW's start position (used from
`window-scroll-functions', which runs before it is committed).
Mirrors horizontal scrolling and pixel-level vscroll as well, so both
axes stay in lockstep."
  (let* ((buf (window-buffer window))
         (other (and (buffer-live-p buf)
                     (buffer-local-value 'diffs--split-other buf))))
    (when (and (buffer-live-p other)
               (> (length
                   (buffer-local-value 'diffs--split-rows buf))
                  0))
      (let* ((start (or start (window-start window)))
             (vscroll (window-vscroll window t))
             (hscroll (window-hscroll window))
             (state (list start vscroll hscroll)))
        (unless (equal state (window-parameter window 'diffs--sync))
          (set-window-parameter window 'diffs--sync state)
          (let* ((row
                 (with-current-buffer buf
                    (or (diffs--split-row-index-at-position start) 0)))
                 (pos
                  (with-current-buffer other
                    (diffs--split-row-position
                     (min row (1- (length diffs--split-rows)))))))
            (dolist (w (get-buffer-window-list other nil t))
              (set-window-start w pos)
              (set-window-vscroll w vscroll t)
              (set-window-hscroll w hscroll)
              (set-window-parameter
               w 'diffs--sync
               (list pos vscroll (window-hscroll w))))))))))

(defun diffs--split-horizontal-edge-command ()
  "Return the logical line edge requested by `this-command', if any."
  (let ((original
         (and (boundp 'this-original-command)
              this-original-command)))
    (cond
     ((or (memq this-command '(beginning-of-line move-beginning-of-line))
          (memq original '(beginning-of-line move-beginning-of-line)))
      'beginning)
     ((or (memq this-command '(end-of-line move-end-of-line))
          (memq original '(end-of-line move-end-of-line)))
      'end))))

(defun diffs--split-sync-point-from (window)
  "Align paired window points with point in WINDOW.
Both sides use the same physical split row.  Ordinary motion preserves
the display column, clamped by the peer line.  Beginning- and end-of-line
commands retain their logical meaning independently on both sides."
  (let* ((buffer (window-buffer window))
         (other (and (buffer-live-p buffer)
                     (buffer-local-value 'diffs--split-other buffer)))
         (edge (diffs--split-horizontal-edge-command)))
    (when (and (buffer-live-p other)
               (> (length
                   (buffer-local-value 'diffs--split-rows buffer))
                  0))
      (let* ((point (window-point window))
             (row
              (with-current-buffer buffer
                (or (diffs--split-row-index-at-position point) 0)))
             (column
              (with-current-buffer buffer
                (save-excursion
                  (goto-char point)
                  (current-column))))
             (peer-point
              (with-current-buffer other
                (save-excursion
                  (goto-char
                   (diffs--split-row-position
                    (min row (1- (length diffs--split-rows)))))
                  (pcase edge
                    ('beginning (line-beginning-position))
                    ('end (line-end-position))
                    (_
                     (move-to-column column)
                     (point)))))))
        (dolist (peer-window (get-buffer-window-list other nil t))
          (set-window-point peer-window peer-point))))))

(defun diffs--split-keep-point-horizontally-visible (window)
  "Adjust WINDOW's horizontal scroll enough to keep its point visible.
This makes point-driven horizontal motion deterministic before redisplay,
so the resulting offset can immediately be mirrored to the peer window."
  (with-current-buffer (window-buffer window)
    (save-excursion
      (goto-char (window-point window))
      (let* ((column (current-column))
             (hscroll (window-hscroll window))
             (width (max 2 (window-body-width window)))
             (right-edge (+ hscroll (1- width))))
        (cond
         ((eq (diffs--split-horizontal-edge-command) 'beginning)
          (set-window-hscroll window 0))
         ((< column hscroll)
          (set-window-hscroll window (max 0 (1- column))))
         ((>= column right-edge)
          (set-window-hscroll
           window
           (max 0 (- column (- width 2))))))))))

(defun diffs--split-peer-hscroll-source (window)
  "Return WINDOW's peer when its horizontal scroll changed independently.
Mouse and trackpad events can scroll a non-selected window without
running that buffer's local post-command hook.  The last synchronized
state recorded on each window lets the selected side detect that event
and treat the peer as the horizontal source of truth."
  (when-let* ((buffer (window-buffer window))
              (other
               (and (buffer-live-p buffer)
                    (buffer-local-value 'diffs--split-other buffer)))
              (peer (get-buffer-window other (window-frame window)))
              (state (window-parameter peer 'diffs--sync))
              (recorded (nth 2 state))
              ((numberp recorded))
              ((/= recorded (window-hscroll peer))))
    peer))

(defun diffs--split-scroll-hook (window start)
  "Synchronize WINDOW at START while a split view is shown."
  (let ((position start))
    (unless diffs--split-syncing
      (let ((diffs--split-syncing t))
        (with-demoted-errors "diffs split sync: %S"
          (setq position
                (or (diffs--split-materialize-window window start)
                    start))
          (diffs--split-sync-from window position)
          (diffs--split-sync-index position))))
    (diffs--update-split-sticky-headers window position)))

(defun diffs--split-post-command ()
  "Sync the paired window after commands in a split buffer."
  (unless diffs--split-syncing
    (let ((diffs--split-syncing t)
          (w (selected-window)))
      (when (eq (window-buffer w) (current-buffer))
        (let ((horizontal-source
               (diffs--split-peer-hscroll-source w)))
          (with-demoted-errors "diffs split sync: %S"
            (diffs--split-materialize-window w)
            (diffs--split-sync-point-from w)
            (diffs--split-keep-point-horizontally-visible w)
            (diffs--split-sync-from (or horizontal-source w))
            (diffs--split-sync-index (point)))))
      (when (eq (window-buffer w) (current-buffer))
        (diffs--update-split-sticky-headers w)))))

(defvar-keymap diffs-split-mode-map
  "n" #'diffs-split-next-hunk
  "p" #'diffs-split-prev-hunk
  "RET" #'diffs-split-goto-source
  "M-RET" #'diffs-token-visit-source
  "S-<mouse-1>" #'diffs-token-click
  "e" #'diffs-split-expand-context
  "v" #'diffs-review-select
  "x" #'diffs-review-clear-selection
  "a" #'diffs-review-add-annotation
  "[" #'diffs-review-previous-annotation
  "]" #'diffs-review-next-annotation
  "A" #'diffs-review-accept-change
  "R" #'diffs-review-reject-change
  "U" #'diffs-review-reset-change
  "C-c C-c" #'diffs-review-apply-decisions
  "i" #'diffs-toggle-index
  "g" #'diffs-refresh
  "s" #'diffs-split-quit
  "q" #'diffs-split-quit-all)

(define-derived-mode diffs-split-mode special-mode "diffs-split"
  "Major mode for one side of the diffs side-by-side view."
  (diffs--define-fringe-bitmap)
  (setq truncate-lines t
        header-line-format nil)
  (setq-local cursor-in-non-selected-windows nil)
  (setq-local imenu-create-index-function #'diffs--imenu-create-index)
  (add-hook 'text-scale-mode-hook #'diffs--define-fringe-bitmap nil t)
  (add-hook 'kill-buffer-hook #'diffs--clear-sticky-headers nil t)
  (add-hook 'pre-command-hook #'diffs--split-pre-command nil t)
  (add-hook 'post-command-hook #'diffs--split-post-command nil t)
  (add-hook 'window-scroll-functions #'diffs--split-scroll-hook nil t)
  (add-hook 'window-buffer-change-functions
            #'diffs--sticky-header-window-buffer-change nil t)
  (add-hook 'eldoc-documentation-functions
            #'diffs-eldoc-function nil t)
  (add-hook 'xref-backend-functions #'diffs-xref-backend nil t))

(defun diffs--split-move-to-anchor (next)
  "Move point to the next hunk anchor (previous when NEXT is nil)."
  (let* ((line (line-number-at-pos))
         (target (if next
                     (cl-find-if (lambda (l) (> l line)) diffs--split-anchors)
                   (cl-find-if (lambda (l) (< l line))
                               (reverse diffs--split-anchors)))))
    (unless target (user-error "No more hunks"))
    (goto-char (diffs--split-row-position (1- target)))
    (dolist (w (get-buffer-window-list diffs--split-other nil t))
      (set-window-point
       w (with-current-buffer diffs--split-other
           (diffs--split-row-position (1- target)))))
    (recenter)
    (diffs--split-materialize-window (selected-window))
    (diffs--split-sync-from (selected-window))))

(defun diffs-split-next-hunk ()
  "Move to the next hunk in the side-by-side view."
  (interactive)
  (diffs--split-move-to-anchor t))

(defun diffs-split-prev-hunk ()
  "Move to the previous hunk in the side-by-side view."
  (interactive)
  (diffs--split-move-to-anchor nil))

(defun diffs--imenu-create-index ()
  "Return a file-and-hunk Imenu index for the current review."
  (let* ((owner
          (if (derived-mode-p 'diffs-split-mode)
              diffs--split-unified
            (current-buffer)))
         (counts (make-hash-table :test #'equal))
         index)
    (when (buffer-live-p owner)
      (with-current-buffer owner
        (dolist (section diffs--sections)
          (cl-incf
           (gethash (or (plist-get section :file) "Patch") counts 0)))
        (cl-loop
         for section in diffs--sections
         for section-index from 0
         for file = (or (plist-get section :file) "Patch")
         for item-id = (plist-get section :item-id)
         for duplicate = (> (gethash file counts) 1)
         for suffix =
         (and duplicate
              (if (and item-id
                       (not (string-prefix-p "diff:" item-id)))
                  item-id
                (format "#%d" (1+ section-index))))
         for group = (if suffix
                         (format "%s [%s]" file suffix)
                       file)
         do
         (let ((entries
                (list
                 (list "File" 0 #'diffs--imenu-goto
                       item-id file section-index nil nil))))
           (cl-loop
            for hunk in (plist-get section :hunks)
            for hunk-index from 0
            for context = (nth 4 hunk)
            for label =
            (format
             "Hunk %d · -%d +%d%s"
             (1+ hunk-index)
             (nth 1 hunk)
             (nth 2 hunk)
             (if (string-empty-p context)
                 ""
               (format
                " · %s"
                (truncate-string-to-width context 56 nil nil t))))
            do
            (push
             (list label 0 #'diffs--imenu-goto
                   item-id file section-index
                   (nth 1 hunk) (nth 2 hunk))
             entries))
           (push (cons group (nreverse entries)) index)))))
    (nreverse index)))

(defun diffs--imenu-split-row-index (section hunk)
  "Return the split row for SECTION and optional HUNK."
  (if diffs--split-paged-p
      (cl-loop
       for chunk across diffs--split-chunks
       when (and
             (eq section (aref chunk 1))
             (or (null hunk)
                 (and (eq (aref chunk 0) 'hunk)
                      (eq hunk (aref chunk 2)))))
       return (aref chunk 3))
    (cl-loop
     for row across diffs--split-rows
     for row-index from 0
     when (and
           (eq section (diffs--split-row-section row))
           (or (null hunk) (eq hunk (nth 5 row))))
     return row-index)))

(defun diffs--imenu-goto
    (_name _position item-id file section-index old-start new-start)
  "Jump to an Imenu review target.
ITEM-ID, FILE, and SECTION-INDEX identify the file.  OLD-START and
NEW-START identify an optional hunk."
  (let* ((split (derived-mode-p 'diffs-split-mode))
         (owner (if split diffs--split-unified (current-buffer))))
    (unless (buffer-live-p owner)
      (user-error "The review buffer no longer exists"))
    (let* ((section
            (with-current-buffer owner
              (or
               (diffs--section-for-identity
                item-id file section-index)
               (user-error
                "The selected file is no longer in this review"))))
           (hunks (plist-get section :hunks))
           (hunk
            (and
             old-start
             new-start
             (or
              (cl-find-if
               (lambda (candidate)
                 (and (= old-start (nth 1 candidate))
                      (= new-start (nth 2 candidate))))
               hunks)
              (user-error
               "The selected hunk is no longer in this review")))))
      (if (not split)
          (goto-char
           (if hunk (car hunk) (plist-get section :beg)))
        (let ((row-index
               (diffs--imenu-split-row-index section hunk)))
          (unless row-index
            (user-error "The selected target is not in the split view"))
          (when diffs--split-paged-p
            (diffs--split-materialize-range row-index (1+ row-index))
            (setq row-index
                  (diffs--imenu-split-row-index section hunk)))
          (goto-char (diffs--split-row-position row-index))
          (dolist
              (peer
               (get-buffer-window-list diffs--split-other nil t))
            (set-window-point
             peer
             (with-current-buffer diffs--split-other
               (diffs--split-row-position row-index))))
          (diffs--split-sync-index (point))
          (when-let*
              ((window
                (if (eq (window-buffer (selected-window))
                        (current-buffer))
                    (selected-window)
                  (get-buffer-window (current-buffer) t))))
            (set-window-point window (point))
            (with-selected-window window
              (recenter)
              (diffs--split-materialize-window window)
              (diffs--split-sync-from window)
              (diffs--update-split-sticky-headers window))))))))

(defun diffs--split-find-row
    (hunk source kind number physical-offset)
  "Find a split row matching HUNK, SOURCE, KIND and NUMBER.
PHYSICAL-OFFSET identifies the exact wrapped chunk within the logical
row.  Fall back to the logical row, then the hunk, if a resize means
that exact chunk no longer exists."
  (diffs--split-paged-materialize-hunk hunk)
  (let (fallback logical-fallback found)
    (cl-loop
     for row across diffs--split-rows
     for index from 0
     for logical-match =
     (and (eq (nth 5 row) hunk)
          (equal (diffs--split-row-property row 'diffs-src) source)
          (eq (nth 3 row) kind)
          (equal (diffs--split-row-source-number row) number))
     when (and (not fallback) (eq (nth 5 row) hunk))
     do (setq fallback (diffs--split-row-position index))
     when logical-match
     do
     (unless logical-fallback
       (setq logical-fallback (diffs--split-row-position index)))
     when (and logical-match
               (equal (nth 9 row) physical-offset))
     do (setq found (diffs--split-row-position index))
     and return found)
    (or found logical-fallback fallback)))

(defun diffs--split-restore-position
    (unified role hunk source kind number physical-offset column window-line)
  "Restore a rebuilt UNIFIED split to its prior logical position.
ROLE, HUNK, SOURCE, KIND, NUMBER, PHYSICAL-OFFSET, COLUMN, and
WINDOW-LINE identify the side, wrapped row, and visual placement to
restore."
  (let* ((cache (buffer-local-value 'diffs--split-cache unified))
         (buffer (plist-get cache (if (eq role 'old) :old :new)))
         (window (and (buffer-live-p buffer) (get-buffer-window buffer))))
    (when (window-live-p window)
      (select-window window)
      (when-let* ((position
                   (diffs--split-find-row
                    hunk source kind number physical-offset)))
        (goto-char position)
        (move-to-column column)
        (set-window-point window (point))
        (let ((start
               (save-excursion
                 (forward-line (- (max 0 window-line)))
                 (line-beginning-position))))
          (set-window-start window start))
        (when (buffer-live-p diffs--split-other)
          (let ((row (diffs--split-row-index-at-position (point))))
            (dolist (other-window
                     (get-buffer-window-list diffs--split-other nil t))
              (set-window-point
               other-window
               (with-current-buffer diffs--split-other
                 (diffs--split-row-position row))))))
        (diffs--split-materialize-window window)
        (diffs--split-sync-from window)))))

(defun diffs--split-entry-anchor ()
  "Return a split anchor for the current unified diff position.
The anchor is derived from raw hunk coordinates, so lazy decoration is
not required and opening a file does not collect the full split twice."
  (let* ((position (line-beginning-position))
         (section (diffs--section-at-pos position))
         (hunk (and section (diffs--hunk-at-pos section position))))
    (when hunk
      (let ((file (plist-get section :file))
            (end (diffs--hunk-end hunk section))
            (old-line (nth 1 hunk))
            (new-line (nth 2 hunk))
            anchor)
        (save-excursion
          (goto-char (car hunk))
          (forward-line 1)
          ;; A hunk-header landing means "its first source row".
          (when (= position (car hunk))
            (setq position (line-beginning-position)))
          (while (and (not anchor) (< (point) end) (not (eobp)))
            (let ((kind
                   (pcase (char-after)
                     (?- 'del)
                     (?+ 'add)
                     ((or ?\s ?\n) 'ctx))))
              (when (and kind (= (line-beginning-position) position))
                (let* ((role (if (eq kind 'del) 'old 'new))
                       (number (if (eq role 'old) old-line new-line)))
                  (setq anchor
                        (list :role role
                              :hunk hunk
                              :source (cons file new-line)
                              :kind kind
                              :number number))))
              (pcase kind
                ('del (cl-incf old-line))
                ('add (cl-incf new-line))
                ('ctx
                 (cl-incf old-line)
                 (cl-incf new-line))))
            (forward-line 1)))
        anchor))))

(defun diffs--split-restore-entry-anchor (unified anchor)
  "Restore UNIFIED's new split view to entry ANCHOR."
  (when anchor
    (diffs--split-restore-position
     unified
     (plist-get anchor :role)
     (plist-get anchor :hunk)
     (plist-get anchor :source)
     (plist-get anchor :kind)
     (plist-get anchor :number)
     0 0 0)))

(defun diffs--split-expand-context ()
  "Expand context at the split hunk at point, then rebuild.
Validation and source loading happen before leaving the split, so an
error never strands the user in the unified view."
  (let* ((row-position (line-beginning-position))
         (row (diffs--split-row-at-position row-position))
         (hunk (diffs--split-property-at 'diffs-hunk row-position))
         (unified diffs--split-unified)
         (role diffs--split-role)
         (source (diffs--split-property-at 'diffs-src row-position))
         (kind (diffs--split-property-at 'diffs-kind row-position))
         (number (and row (or (nth 8 row) (nth 1 row))))
         (physical-offset (and row (nth 9 row)))
         (column (current-column))
         (window-line
          (if-let* ((window (get-buffer-window (current-buffer))))
              (count-screen-lines (window-start window)
                                  (line-beginning-position))
            0))
         gap target)
    (unless (and hunk (buffer-live-p unified))
      (user-error "Point is not in a diff hunk"))
    (with-current-buffer unified
      (setq gap (diffs--gap-for-hunk hunk)
            target (and gap (diffs--next-context-visible gap)))
      (unless gap
        (user-error "No context information for this hunk"))
      ;; Prime the lazy full-file caches before changing the layout.
      (when (> target 0)
        (let ((section (plist-get gap :section)))
          (unless (or (diffs--section-lines section 'old)
                      (diffs--section-lines section 'new))
            (diffs--signal-context-load-error section)))))
    (diffs-split-quit)
    (set-buffer unified)
    (goto-char (car hunk))
    (cl-labels
        ((reopen ()
           (diffs-toggle-split)
           (diffs--split-restore-position
            unified role hunk source kind number physical-offset
            column window-line)))
      (condition-case error-data
          (diffs--set-context-visible gap target)
        (error
         ;; Rendering failed after validation.  Restore the split before
         ;; reporting the error so layout changes remain transactional.
         (reopen)
         (signal (car error-data) (cdr error-data))))
      (reopen))))

(defun diffs-split-expand-context ()
  "Reveal more unchanged context before the current split hunk."
  (interactive)
  (diffs--split-expand-context))

(defun diffs-split-goto-source ()
  "Visit the source location of the line at point."
  (interactive)
  (let ((src (diffs--split-property-at 'diffs-src (point)))
        (dir default-directory))
    (unless src (user-error "No source location on this line"))
    (diffs-split-quit)
    (let ((default-directory dir))
      (find-file (car src)))
    (goto-char (point-min))
    (forward-line (1- (cdr src)))))

(defun diffs-split-quit ()
  "Leave the side-by-side view and return to the unified view."
  (interactive)
  (let ((old (current-buffer))
        (other diffs--split-other)
        (unified diffs--split-unified)
        (configuration diffs--split-window-configuration))
    ;; Decision commands return through the unified buffer only as an
    ;; implementation detail before immediately rebuilding split.  Defer
    ;; this expensive projection in that path; a real return to stacked
    ;; refreshes the owner before restoring its window configuration.
    (when (and (buffer-live-p unified)
               (not diffs--review-defer-owner-overlay-refresh)
               (buffer-local-value
                'diffs--review-owner-overlays-stale unified))
      (diffs--review-refresh-overlays unified (list unified)))
    (when (window-configuration-p configuration)
      (set-window-configuration configuration))
    ;; The index may have been toggled after the split configuration was
    ;; captured, so reconcile the restored layout with its desired state.
    (when (buffer-live-p unified)
      (with-current-buffer unified
        (let ((index diffs--index-buffer))
          (cond
           ((and diffs--index-visible
                 (buffer-live-p index)
                 (not (get-buffer-window index)))
            (diffs--index-display-window unified index))
           ((and (not diffs--index-visible)
                 (buffer-live-p index)
                 (get-buffer-window index))
            (delete-window (get-buffer-window index)))))))
    (when (buffer-live-p unified)
      (dolist (window (get-buffer-window-list unified nil t))
        (diffs--update-sticky-header window)))
    ;; Keep the rendered pair alive.  The owning unified buffer kills it
    ;; when the diff changes, is refreshed, or is itself killed.
    (dolist (buffer (list old other))
      (when (buffer-live-p buffer)
        (bury-buffer buffer)))))

(defun diffs-split-quit-all ()
  "Close both split columns and quit their owning diffs view."
  (interactive)
  (let ((unified diffs--split-unified))
    (diffs-split-quit)
    (when (buffer-live-p unified)
      (with-current-buffer unified
        (diffs-quit)))))

(defun diffs-toggle-split ()
  "Toggle between the unified and the side-by-side view."
  (interactive)
  (unless diffs-minor-mode
    (user-error "Not in a diffs buffer"))
  (let* ((unified (current-buffer))
         (modified-tick (buffer-chars-modified-tick))
         (wrap-lines diffs-split-wrap-lines)
         (show-line-numbers diffs-line-numbers)
         (show-file-icons diffs-file-icons)
         (show-fringe-bars diffs-fringe-bars)
         (fringe-bar-width diffs-fringe-bar-width)
         (full-width-backgrounds diffs-split-full-width-backgrounds)
         (virtualization diffs-split-virtualization)
         (virtualization-threshold
          diffs-split-virtualization-threshold)
         (overscan diffs-split-overscan)
         (source-tab-width tab-width))
    (let* ((cached diffs--split-cache)
           (old-buf (plist-get cached :old))
           (new-buf (plist-get cached :new)))
      (unless (and (buffer-live-p old-buf) (buffer-live-p new-buf))
        (diffs--split-cache-clear)
        (setq old-buf
              (generate-new-buffer (concat (buffer-name unified) ":old"))
              new-buf
              (generate-new-buffer (concat (buffer-name unified) ":new"))
              diffs--split-cache
              (list :old old-buf :new new-buf)))
      (let* ((width
              (apply #'max 2
                     (mapcar (lambda (s) (plist-get s :width))
                             diffs--sections)))
             (dir default-directory)
             (configuration (current-window-configuration))
             (w1 (or (get-buffer-window unified) (selected-window)))
             (w2 (progn
                   (set-window-buffer w1 old-buf)
                   (split-window w1 nil 'right))))
        (set-window-buffer w2 new-buf)
        (let* ((paged-eligible
                (with-current-buffer unified
                  (diffs--split-paged-eligible-p wrap-lines)))
               (cached-estimate
                (and
                 paged-eligible
                 (eq virtualization 'auto)
                 (equal modified-tick
                        (plist-get diffs--split-cache
                                   :estimate-tick))
                 (plist-get diffs--split-cache
                            :estimated-row-count)))
               (estimated-row-count
                (and
                 paged-eligible
                 (eq virtualization 'auto)
                 (or cached-estimate
                     (with-current-buffer unified
                       (diffs--split-estimated-row-count)))))
               (paged
                (with-current-buffer unified
                  (diffs--split-use-paged-p
                   virtualization wrap-lines
                   virtualization-threshold
                   estimated-row-count)))
               (content-width
                (max 8 (- (min (window-body-width w1)
                               (window-body-width w2))
                          width 1)))
               (key (list modified-tick
                          content-width width
                          wrap-lines
                          paged
                          show-line-numbers
                          show-file-icons
                          show-fringe-bars
                          fringe-bar-width
                          full-width-backgrounds
                          source-tab-width
                          diffs--independent-sources
                          diffs-line-diff-type
                          diffs-max-line-diff-length
                          diffs-line-pair-threshold
                          diffs-line-pair-limit
                          diffs-refine-whitespace
                          diffs--review-decisions
                          diffs--review-source-actions))
               anchors)
          (if (equal key (plist-get diffs--split-cache :key))
              (setq anchors (plist-get diffs--split-cache :anchors))
            (dolist (buffer (list old-buf new-buf))
              (with-current-buffer buffer
                (let ((inhibit-read-only t))
                  (fundamental-mode)
                  (setq buffer-read-only nil)
                  (erase-buffer)
                  (diffs-split-mode))))
            (let ((diffs-split-wrap-lines wrap-lines)
                  (diffs-line-numbers show-line-numbers)
                  (diffs-file-icons show-file-icons)
                  (diffs-fringe-bars show-fringe-bars)
                  (diffs-fringe-bar-width fringe-bar-width)
                  (diffs-split-full-width-backgrounds
                   full-width-backgrounds)
                  (tab-width source-tab-width))
              (if paged
                  (setq anchors
                        (diffs--split-render-paged
                         (with-current-buffer unified
                           (diffs--split-paged-index))
                         width old-buf new-buf))
                (let ((collected
                       (with-current-buffer unified
                         (diffs--split-collect))))
                  (setq anchors
                        (diffs--split-render-pair
                         (nth 0 collected) (nth 1 collected)
                         width content-width old-buf new-buf)))))
            (setq diffs--split-cache
                  (list :key key :anchors anchors
                        :old old-buf :new new-buf)))
          (when estimated-row-count
            (setq diffs--split-cache
                  (plist-put
                   (plist-put
                    diffs--split-cache
                    :estimated-row-count estimated-row-count)
                   :estimate-tick modified-tick)))
          (dolist (spec (list (list old-buf 'old new-buf)
                              (list new-buf 'new old-buf)))
            (with-current-buffer (nth 0 spec)
              (goto-char (point-min))
              (unless (derived-mode-p 'diffs-split-mode)
                (diffs-split-mode))
              (setq-local diffs-split-full-width-backgrounds
                          full-width-backgrounds)
              (setq-local diffs-line-numbers show-line-numbers)
              (setq-local diffs-file-icons show-file-icons)
              (setq-local diffs-fringe-bars show-fringe-bars)
              (setq-local diffs-fringe-bar-width fringe-bar-width)
              (setq-local diffs-split-virtualization virtualization)
              (setq-local diffs-split-overscan overscan)
              (setq-local tab-width source-tab-width)
              (setq default-directory dir)
              (setq-local diffs--split-unified unified)
              (setq-local diffs--split-role (nth 1 spec))
              (setq-local diffs--split-anchors anchors)
              (setq-local diffs--split-other (nth 2 spec))
              (setq-local diffs--split-window-configuration configuration)
              (setq header-line-format nil))))
        (select-window w2)
        (diffs--split-materialize-window w2)
        (diffs--split-sync-from w2)
        (diffs--update-split-sticky-headers w2)
        ;; The unified owner was already current when split was entered.
        ;; Project only the two newly rendered views; decision rebuilds may
        ;; intentionally leave the now-hidden owner stale until stacked is
        ;; requested again.
        (diffs--review-refresh-overlays
         unified (list old-buf new-buf))))))

;;;; Review selection and annotations

(defun diffs--review-normalize-directory (directory)
  "Return DIRECTORY as an absolute directory name."
  (file-name-as-directory (expand-file-name directory)))

(defun diffs--review-current-repository ()
  "Return the normalized repository root for the current buffer."
  (diffs--review-normalize-directory
   (or (ignore-errors (vc-root-dir))
       default-directory)))

(defun diffs--review-new-session-id ()
  "Return a locally unique live review session id."
  (concat
   "diffs-session:"
   (substring
    (secure-hash
     'sha1
     (format "%s:%s:%s:%s"
             (float-time) (emacs-pid) (random) (buffer-name)))
    0 16)))

(defun diffs--review-ensure-session-state (&optional owner)
  "Initialize live-session identity for OWNER or the current buffer."
  (with-current-buffer (or owner (current-buffer))
    (unless diffs--review-session-id
      (setq diffs--review-session-id
            (diffs--review-new-session-id)))
    (unless diffs--review-repository
      (setq diffs--review-repository
            (diffs--review-current-repository)))))

(defun diffs--review-state-snapshot (owner)
  "Return the user-owned live review state in OWNER."
  (with-current-buffer owner
    (list :selection (copy-tree diffs--review-selection)
          :annotations (copy-tree diffs--review-annotations)
          :decisions (copy-tree diffs--review-decisions)
          :source-actions (copy-tree diffs--review-source-actions)
          :session-id diffs--review-session-id
          :repository diffs--review-repository
          :generation diffs--review-generation)))

(defun diffs--review-owner-buffer (&optional buffer)
  "Return the unified diffs owner for BUFFER or the current buffer."
  (with-current-buffer (or buffer (current-buffer))
    (cond
     ((derived-mode-p 'diffs-split-mode)
      (and (buffer-live-p diffs--split-unified)
           diffs--split-unified))
     (diffs-minor-mode (current-buffer)))))

;;;; Token interaction

(defun diffs--token-section-for-row (owner row)
  "Return the section in OWNER that contains split ROW."
  (let ((section (diffs--split-row-section row))
        (hunk (nth 5 row))
        (origin (nth 6 row))
        (file (nth 4 row)))
    (with-current-buffer owner
      (or
       section
       (and hunk
            (when-let* ((gap (diffs--gap-for-hunk hunk)))
              (plist-get gap :section)))
       (and origin
            (diffs--section-at-pos
             (if (consp origin) (car origin) origin)))
       (cl-find-if
        (lambda (section)
          (equal file (plist-get section :file)))
        diffs--sections)))))

(defun diffs--token-stacked-line (owner position)
  "Return source-line metadata for POSITION in stacked OWNER."
  (with-current-buffer owner
    (save-excursion
      (goto-char (max (point-min) (min position (point-max))))
      (let* ((line-begin (line-beginning-position))
             (line-end (line-end-position))
             (section (diffs--section-at-pos line-begin))
             (hunk (and section (diffs--hunk-at-pos section line-begin)))
             (marker (char-after line-begin))
             (side (pcase marker
                     (?- 'old)
                     (?+ 'new)
                     ((or ?\s ?\n) 'new))))
        (when (and hunk (> line-begin (car hunk)))
          (let ((line
                 (get-text-property
                  line-begin
                  (if (eq side 'old)
                      'diffs-old-number
                    'diffs-new-number))))
            ;; Lazy decoration normally provides the number in O(1).
            ;; Retain a model-based fallback for callers before jit-lock.
            (unless line
              (let ((old-line (nth 1 hunk))
                    (new-line (nth 2 hunk)))
                (goto-char (car hunk))
                (forward-line 1)
                (while (< (line-beginning-position) line-begin)
                  (pcase (char-after)
                    (?- (cl-incf old-line))
                    (?+ (cl-incf new-line))
                    ((or ?\s ?\n)
                     (cl-incf old-line)
                     (cl-incf new-line)))
                  (forward-line 1))
                (setq line
                      (if (eq side 'old)
                          old-line
                        new-line))))
            (when (and side line)
              (let ((content-begin
                     (min (1+ line-begin) line-end)))
                (list
                 :owner owner :section section :side side :line line
                 :text
                 (buffer-substring-no-properties
                  content-begin line-end)
                 :column
                 (max 0
                      (min (- line-end content-begin)
                           (- position content-begin)))
                 :logical-base 0)))))))))

(defun diffs--token-split-line (buffer position)
  "Return source-line metadata for POSITION in split BUFFER."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (max (point-min) (min position (point-max))))
      (let* ((line-begin (line-beginning-position))
             (line-end (line-end-position))
             (row (diffs--split-row-at-position line-begin))
             (kind (and row (nth 3 row)))
             (owner (and row diffs--split-unified))
             (side (and row (diffs--split-row-source-side row)))
             (line (and row (diffs--split-row-source-number row)))
             (offset (or (and row (nth 9 row)) 0)))
        (when (and row
                   (buffer-live-p owner)
                   line
                   side
                   (memq kind '(ctx del add)))
          (let* ((section (diffs--token-section-for-row owner row))
                 (origin (nth 6 row))
                 (unified-position
                  (if (consp origin) (car origin) origin))
                 text
                 (logical-base 0))
            (cond
             (unified-position
              (setq text
                    (with-current-buffer owner
                      (save-excursion
                        (goto-char unified-position)
                        (buffer-substring-no-properties
                         (point) (line-end-position))))))
             (section
              (let ((lines
                     (with-current-buffer owner
                       (diffs--section-lines section side))))
                (when (and (vectorp lines)
                           (> line 0)
                           (<= line (length lines)))
                  (setq text
                        (substring-no-properties
                         (aref lines (1- line)))))))
             (t
              (setq text (substring-no-properties (car row))
                    logical-base offset)))
            (when text
              (list
               :owner owner
               :section section
               :side side
               :line line
               :text text
               :column
               (+ offset
                  (max 0
                       (min (- line-end line-begin)
                            (- position line-begin))))
               :logical-base logical-base))))))))

(defun diffs--token-line-at-position (position buffer)
  "Return logical source-line metadata for POSITION in BUFFER."
  (with-current-buffer buffer
    (cond
     ((derived-mode-p 'diffs-split-mode)
      (diffs--token-split-line buffer position))
     ((diffs--review-owner-buffer buffer)
      (diffs--token-stacked-line buffer position)))))

(defun diffs--token-record-at-column (text column)
  "Return the word token in TEXT containing character COLUMN."
  (let ((diffs-refine-whitespace 'show)
        found)
    (cl-loop
     for token across (diffs--word-tokens text)
     until found
     when (and (<= (aref token 1) column)
               (< column (aref token 2)))
     do (setq found token))
    (when (and found
               (or diffs-token-interactions-on-whitespace
                   (not
                    (cl-every
                     #'diffs--word-whitespace-p
                     (string-to-list (aref found 0))))))
      found)))

;;;###autoload
(defun diffs-token-at-position (position &optional buffer)
  "Return the source token at POSITION in BUFFER as a plist.
BUFFER defaults to the current buffer.  `:line' is one-based;
`:column', `:start-column', and `:end-column' are zero-based character
offsets, with the end excluded.  The plist also records `:file',
`:absolute-file', `:side', `:revision', and `:review-buffer'."
  (let* ((buffer (or buffer (current-buffer)))
         (line-data (diffs--token-line-at-position position buffer))
         (text (plist-get line-data :text))
         (column (plist-get line-data :column))
         (logical-base (or (plist-get line-data :logical-base) 0))
         (local-column (and column (- column logical-base)))
         (owner (plist-get line-data :owner))
         (record
          (and text
               local-column
               (>= local-column 0)
               (let
                   ((diffs-token-interactions-on-whitespace
                     (and
                      (buffer-live-p owner)
                      (buffer-local-value
                       'diffs-token-interactions-on-whitespace
                       owner))))
                 (diffs--token-record-at-column
                  text local-column)))))
    (when record
      (let* ((section (plist-get line-data :section))
             (side (plist-get line-data :side))
             (file
              (if (eq side 'old)
                  (or (plist-get section :old-file)
                      (plist-get section :file))
                (plist-get section :file)))
             (root
              (with-current-buffer owner
                (diffs--context-source-root)))
             (revision
              (with-current-buffer owner
                (if (eq side 'old)
                    diffs--revision
                  diffs--target-revision))))
        (list
         :text (substring-no-properties (aref record 0))
         :file file
         :absolute-file (and file (expand-file-name file root))
         :side side
         :revision revision
         :line (plist-get line-data :line)
         :column column
         :start-column (+ logical-base (aref record 1))
         :end-column (+ logical-base (aref record 2))
         :review-buffer owner
         :buffer buffer
         :position position
         :section section)))))

;;;###autoload
(defun diffs-token-at-point ()
  "Return the source token at point, or nil."
  (diffs-token-at-position (point) (current-buffer)))

(defun diffs--token-source-cache-clear ()
  "Kill historical source buffers owned by the current review."
  (dolist (entry diffs--token-source-buffers)
    (when-let* ((buffer (cdr entry))
                ((buffer-live-p buffer)))
      (with-current-buffer buffer
        (diffs--sanitize-synthetic-source))
      (kill-buffer buffer)))
  (setq diffs--token-source-buffers nil))

(defun diffs--token-live-source-buffer (absolute)
  "Return a non-synthetic buffer visiting ABSOLUTE, if one exists."
  (cl-find-if
   (lambda (buffer)
     (with-current-buffer buffer
       (and buffer-file-name
            (not diffs--token-source-owner)
            (condition-case nil
                (file-equal-p buffer-file-name absolute)
              (error
               (equal (expand-file-name buffer-file-name)
                      (expand-file-name absolute)))))))
   (buffer-list)))

(defun diffs--token-historical-source-buffer (token owner)
  "Return a safe historical source buffer for TOKEN owned by OWNER."
  (let* ((side (plist-get token :side))
         (absolute (plist-get token :absolute-file))
         (revision (plist-get token :revision))
         (key (list side absolute revision))
         (cached (alist-get key
                           (buffer-local-value
                            'diffs--token-source-buffers owner)
                           nil nil #'equal)))
    (if (buffer-live-p cached)
        cached
      (when-let* ((section (plist-get token :section))
                  (lines
                   (with-current-buffer owner
                     (diffs--section-lines section side))))
        (let ((buffer
               (generate-new-buffer
                (format " *diffs-source:%s:%s*"
                        (or revision "worktree")
                        (file-name-nondirectory
                         (or absolute "source"))))))
          (condition-case error-data
              (progn
                (with-current-buffer buffer
                  (setq default-directory
                        (with-current-buffer owner
                          (diffs--context-source-root)))
                  (insert
                   (mapconcat
                    (lambda (line)
                      (substring-no-properties line))
                    lines "\n"))
                  (setq buffer-file-name absolute
                        buffer-offer-save nil)
                  (setq-local diffs--token-source-owner owner)
                  (let ((enable-local-variables nil)
                        (enable-local-eval nil))
                    (delay-mode-hooks
                      (set-auto-mode)))
                  (setq-local delayed-mode-hooks nil)
                  (setq buffer-read-only t)
                  (setq-local kill-buffer-query-functions nil)
                  (set-buffer-modified-p nil))
                (with-current-buffer owner
                  (push (cons key buffer)
                        diffs--token-source-buffers))
                buffer)
            (error
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (diffs--sanitize-synthetic-source))
               (kill-buffer buffer))
             (message "diffs token source: %s"
                      (error-message-string error-data))
             nil)))))))

(defun diffs--token-default-source-position (token)
  "Resolve TOKEN to a built-in source buffer position."
  (when-let* ((owner (plist-get token :review-buffer))
              ((buffer-live-p owner))
              (absolute (plist-get token :absolute-file))
              (line (plist-get token :line))
              (column (plist-get token :column))
              (worktree
               (and (null (plist-get token :revision))
                    (or (eq (plist-get token :side) 'new)
                        (buffer-local-value
                         'diffs--independent-sources owner))
                    (not
                     (eq
                      (plist-get
                       (plist-get token :section)
                       :item-type)
                      'file))))
              (buffer
               (or (and worktree
                        (diffs--token-live-source-buffer absolute))
                   (diffs--token-historical-source-buffer token owner))))
    (cons
     buffer
     (with-current-buffer buffer
       (save-restriction
         (widen)
         (save-excursion
           (goto-char (point-min))
           (forward-line (max 0 (1- line)))
           (forward-char
            (min column
                 (- (line-end-position) (line-beginning-position))))
           (point)))))))

;;;###autoload
(defun diffs-token-source-position (&optional token)
  "Return (BUFFER . POSITION) for TOKEN or the token at point.
Functions in `diffs-token-source-functions' get the first chance to
resolve the token.  The built-in resolver then uses a live worktree
buffer when possible, or a read-only historical source buffer."
  (let* ((token (or token (diffs-token-at-point)))
         (owner (and token (plist-get token :review-buffer)))
         (custom
          (and (buffer-live-p owner)
               (with-current-buffer owner
                 (run-hook-with-args-until-success
                  'diffs-token-source-functions token)))))
    (cond
     ((and (consp custom)
           (buffer-live-p (car custom))
           (integer-or-marker-p (cdr custom)))
      custom)
     (token
      (diffs--token-default-source-position token)))))

;;;###autoload
(defun diffs-token-visit-source (&optional token)
  "Visit the exact source position represented by TOKEN."
  (interactive)
  (unless token
    (setq token (diffs-token-at-point)))
  (unless token
    (user-error "Point is not on a source token"))
  (let ((source (diffs-token-source-position token)))
    (unless source
      (user-error "Cannot load source for %s"
                  (or (plist-get token :file) "this token")))
    (pop-to-buffer (car source))
    (goto-char (cdr source))))

;;;###autoload
(defun diffs-token-click (event)
  "Run token click hooks for mouse EVENT, or visit its source."
  (interactive "e")
  (posn-set-point (event-end event))
  (let ((token (diffs-token-at-point)))
    (unless token
      (user-error "No source token at this position"))
    (let ((owner (plist-get token :review-buffer)))
      (if (and (buffer-live-p owner)
               (buffer-local-value
                'diffs-token-click-functions owner))
          (with-current-buffer owner
            (run-hook-with-args
             'diffs-token-click-functions token event))
        (diffs-token-visit-source token)))))

(defun diffs--token-hover-documentation (token)
  "Return the first custom hover result for TOKEN."
  (when-let* ((owner (plist-get token :review-buffer))
              ((buffer-live-p owner)))
    (with-current-buffer owner
      (run-hook-with-args-until-success
       'diffs-token-hover-functions token))))

(defun diffs--token-source-eldoc (source callback arguments)
  "Run Eldoc providers at SOURCE with CALLBACK and ARGUMENTS."
  (with-current-buffer (car source)
    (save-excursion
      (goto-char (cdr source))
      (let ((eldoc-documentation-functions
             (remove
              #'diffs-eldoc-function
              eldoc-documentation-functions)))
        (apply
         #'run-hook-with-args-until-success
         'eldoc-documentation-functions
         callback arguments)))))

;;;###autoload
(defun diffs-eldoc-function (callback &rest arguments)
  "Provide source-language Eldoc for the token at point.
CALLBACK and ARGUMENTS follow `eldoc-documentation-functions'."
  (when-let* ((token (diffs-token-at-point)))
    (or (diffs--token-hover-documentation token)
        (when-let* ((source (diffs-token-source-position token)))
          (diffs--token-source-eldoc source callback arguments)))))

(defun diffs--token-source-xref-context ()
  "Return (SOURCE . BACKEND) for the token at point."
  (when-let* ((token (diffs-token-at-point))
              (source (diffs-token-source-position token)))
    (with-current-buffer (car source)
      (save-excursion
        (goto-char (cdr source))
        (when-let* ((backend (xref-find-backend))
                    ((not (eq backend 'diffs))))
          (cons source backend))))))

(defun diffs--token-source-xref (function &rest arguments)
  "Call Xref FUNCTION with ARGUMENTS in the token's source buffer."
  (when-let* ((context (diffs--token-source-xref-context))
              (source (car context))
              (backend (cdr context)))
    (with-current-buffer (car source)
      (save-excursion
        (goto-char (cdr source))
        (apply function backend arguments)))))

;;;###autoload
(defun diffs-xref-backend ()
  "Return the diffs Xref backend when the token has a source backend."
  (and (diffs--token-source-xref-context) 'diffs))

(cl-defmethod xref-backend-identifier-at-point
  ((_backend (eql diffs)))
  "Return the source-buffer identifier represented at point."
  (diffs--token-source-xref #'xref-backend-identifier-at-point))

(cl-defmethod xref-backend-identifier-completion-table
  ((_backend (eql diffs)))
  "Return the source backend's identifier completion table."
  (diffs--token-source-xref
   #'xref-backend-identifier-completion-table))

(cl-defmethod xref-backend-definitions
  ((_backend (eql diffs)) identifier)
  "Return source definitions for IDENTIFIER."
  (diffs--token-source-xref
   #'xref-backend-definitions identifier))

(cl-defmethod xref-backend-references
  ((_backend (eql diffs)) identifier)
  "Return source references for IDENTIFIER."
  (diffs--token-source-xref
   #'xref-backend-references identifier))

(cl-defmethod xref-backend-apropos
  ((_backend (eql diffs)) pattern)
  "Return source identifiers matching PATTERN."
  (diffs--token-source-xref #'xref-backend-apropos pattern))

(defun diffs--resolution-key (file hunk index)
  "Return a stable key for change block INDEX in HUNK of FILE."
  (list file (nth 1 hunk) (nth 2 hunk) index))

(defun diffs--resolution-decision (key &optional owner)
  "Return the decision for change-block KEY in OWNER."
  (alist-get key
             (buffer-local-value
              'diffs--review-decisions
              (or owner (diffs--review-owner-buffer)))
             nil nil #'equal))

(defun diffs--resolution-blocks (section hunk)
  "Return structured change blocks in HUNK of SECTION.
Each result records its stable key, raw unified positions, old/new
line starts, source text, and no-final-newline state."
  (let ((file (plist-get section :file))
        (end (diffs--hunk-end hunk section))
        (old-line
         (if (zerop (nth 5 hunk))
             (1+ (nth 1 hunk))
           (nth 1 hunk)))
        (new-line
         (if (zerop (nth 6 hunk))
             (1+ (nth 2 hunk))
           (nth 2 hunk)))
        (index 0)
        blocks begin old-start new-start old-lines new-lines
        old-positions new-positions marker-positions
        old-no-newline new-no-newline
        last-side)
    (cl-labels
        ((flush
          ()
          (when begin
            (push
             (list
              :key (diffs--resolution-key file hunk index)
              :file file :hunk hunk :index index
              :begin begin :end (point)
              :old-start old-start :new-start new-start
              :old-lines (nreverse old-lines)
              :new-lines (nreverse new-lines)
              :old-positions (nreverse old-positions)
              :new-positions (nreverse new-positions)
              :marker-positions (nreverse marker-positions)
              :old-no-newline old-no-newline
              :new-no-newline new-no-newline)
             blocks)
            (cl-incf index))
          (setq begin nil
                old-start nil new-start nil
                old-lines nil new-lines nil
                old-positions nil new-positions nil
                marker-positions nil
                old-no-newline nil new-no-newline nil
                last-side nil))
         (start
          ()
          (unless begin
            (setq begin (line-beginning-position)
                  old-start old-line
                  new-start new-line)))
         (record
          (side)
          (start)
          (let ((line-begin (line-beginning-position))
                (line-end (line-end-position))
                (next (save-excursion (forward-line 1) (point))))
            (if (eq side 'old)
                (progn
                  (push (buffer-substring-no-properties
                         (min (1+ line-begin) line-end) line-end)
                        old-lines)
                  (push (cons line-begin next) old-positions)
                  (cl-incf old-line))
              (push (buffer-substring-no-properties
                     (min (1+ line-begin) line-end) line-end)
                    new-lines)
              (push (cons line-begin next) new-positions)
              (cl-incf new-line)))
            (setq last-side side)))
      (save-excursion
        (goto-char (car hunk))
        (forward-line 1)
        (while (and (< (point) end) (not (eobp)))
          (pcase (char-after)
            (?- (record 'old))
            (?+ (record 'new))
            (?\\
             (push
              (cons (line-beginning-position)
                    (save-excursion (forward-line 1) (point)))
              marker-positions)
             (pcase last-side
               ('old (setq old-no-newline t))
               ('new (setq new-no-newline t))))
            (_
             (flush)
             (when (memq (char-after) '(?\s ?\n))
               (cl-incf old-line)
               (cl-incf new-line))))
          (forward-line 1))
        (flush)))
    (nreverse blocks)))

(defun diffs--resolution-all-blocks (owner)
  "Return every structured change block owned by OWNER."
  (with-current-buffer owner
    (cl-loop
     for section in diffs--sections
     append
     (cl-loop
      for hunk in (plist-get section :hunks)
      append (diffs--resolution-blocks section hunk)))))

(defun diffs--resolution-block-for-key (owner key)
  "Return OWNER's current change block identified by KEY."
  (cl-find key (diffs--resolution-all-blocks owner)
           :key (lambda (block) (plist-get block :key))
           :test #'equal))

(defun diffs--review-range-valid-p (owner file side range)
  "Return non-nil when RANGE for FILE and SIDE still exists in OWNER."
  (and (stringp file)
       (memq side '(old new))
       (listp range)
       (= (length range) 2)
       (cl-every #'integerp range)
       (with-current-buffer owner
         (and (diffs--review-unified-line-position
               file side (car range))
              (diffs--review-unified-line-position
               file side (cadr range))))))

(defun diffs--review-selection-valid-p (owner selection)
  "Return non-nil when SELECTION still maps into OWNER."
  (and selection
       (diffs--review-range-valid-p
        owner
        (plist-get selection :file)
        (plist-get selection :side)
        (list (plist-get selection :start)
              (plist-get selection :end)))))

(defun diffs--review-revalidate-annotation (owner annotation)
  "Return ANNOTATION with only ranges that still map into OWNER.
Return nil when neither its old nor new range survives.  Dual-range
annotations are validated independently so a replacement that becomes
a pure addition or deletion retains its still-addressable side."
  (let* ((file (plist-get annotation :file))
         (old-range (plist-get annotation :old-range))
         (new-range (plist-get annotation :new-range))
         (old-valid
          (and old-range
               (diffs--review-range-valid-p
                owner file 'old old-range)))
         (new-valid
          (and new-range
               (diffs--review-range-valid-p
                owner file 'new new-range)))
         (copy (copy-tree annotation)))
    (cl-labels
        ((without
          (property plist)
          (cl-loop
           for (key value) on plist by #'cddr
           unless (eq key property)
           append (list key value))))
      (unless old-valid
        (setq copy (without :old-range copy)))
      (unless new-valid
        (setq copy (without :new-range copy))))
    (and (or old-valid new-valid) copy)))

(defun diffs--resolution-same-block-p (old current)
  "Return non-nil when OLD and CURRENT describe the same patch block."
  (cl-every
   (lambda (property)
     (equal (plist-get old property)
            (plist-get current property)))
   '(:key :file :old-start :new-start
     :old-lines :new-lines :old-no-newline :new-no-newline)))

(defun diffs--review-restore-refreshed-state (owner state)
  "Restore still-valid STATE into regenerated OWNER.
Stale source locations, decisions, and source actions are discarded.
Retained entries are rebound to the newly scanned patch generation."
  (with-current-buffer owner
    (let* ((generation
            (1+ (or (plist-get state :generation) 0)))
           (selection (plist-get state :selection))
           (annotations (plist-get state :annotations))
           (blocks (diffs--resolution-all-blocks owner))
           (block-table (make-hash-table :test #'equal))
           source-actions
           decisions)
      (dolist (block blocks)
        (puthash (plist-get block :key) block block-table))
      (dolist (entry (plist-get state :source-actions))
        (when-let* ((old (cdr entry))
                    (current (gethash (car entry) block-table))
                    ((diffs--resolution-same-block-p old current)))
          (push
           (cons
            (car entry)
            (append
             (list :action (plist-get old :action)
                   :generation generation)
             (copy-tree current)))
           source-actions)))
      ;; Reviews created before source actions became owner-local stored
      ;; the applied action on the visible decision.  Adopt that state
      ;; during a same-process package reload instead of losing it.
      (dolist (entry (plist-get state :decisions))
        (unless (alist-get
                 (car entry) source-actions nil nil #'equal)
          (when-let* ((old (cdr entry))
                      (action
                       (or (plist-get old :source-action)
                           (and (plist-get old :applied)
                                (plist-get old :action))))
                      (current (gethash (car entry) block-table))
                      ((diffs--resolution-same-block-p old current)))
            (push
             (cons
              (car entry)
              (append
               (list :action action :generation generation)
               (copy-tree current)))
             source-actions))))
      (setq source-actions (nreverse source-actions))
      (dolist (entry (plist-get state :decisions))
        (when-let* ((old (cdr entry))
                    (current (gethash (car entry) block-table))
                    ((diffs--resolution-same-block-p old current)))
          (let ((source-action
                 (plist-get
                  (alist-get
                   (car entry) source-actions nil nil #'equal)
                  :action)))
            (push
             (cons
              (car entry)
              (append
               (list :action (plist-get old :action)
                     :applied
                     (and source-action
                          (eq source-action
                              (plist-get old :action)))
                     :source-action source-action
                     :generation generation)
               (copy-tree current)))
             decisions))))
      (setq diffs--review-generation generation
            diffs--review-session-id (plist-get state :session-id)
            diffs--review-repository (plist-get state :repository)
            diffs--review-selection
            (and (diffs--review-selection-valid-p owner selection)
                 selection)
            diffs--review-annotations
            (delq
             nil
             (mapcar
              (lambda (annotation)
                (diffs--review-revalidate-annotation
                 owner annotation))
              annotations))
            diffs--review-decisions (nreverse decisions)
            diffs--review-source-actions source-actions)
      (diffs--review-ensure-session-state owner)
      (diffs--split-cache-clear)
      (diffs--review-refresh-overlays owner))))

(defun diffs--resolution-block-at-point (owner)
  "Return OWNER's change block represented at point in the current view."
  (if (derived-mode-p 'diffs-split-mode)
      (let* ((index (diffs--split-row-index-at-position (point)))
             (row (and index (aref diffs--split-rows index)))
             (key (and row
                       (diffs--split-row-resolution-key row)))
             (origin (and row (nth 6 row))))
        (unless origin
          (when (and index (buffer-live-p diffs--split-other))
            (setq origin
                  (with-current-buffer diffs--split-other
                    (and (< index (length diffs--split-rows))
                         (nth 6 (aref diffs--split-rows index)))))))
        (or
         (and key (diffs--resolution-block-for-key owner key))
         (and origin
              (let* ((hunk (nth 5 row))
                     (section
                      (with-current-buffer owner
                        (diffs--section-at-pos (car hunk))))
                     (position (car origin)))
                (with-current-buffer owner
                  (cl-find-if
                   (lambda (block)
                     (and (<= (plist-get block :begin) position)
                          (< position (plist-get block :end))))
                   (diffs--resolution-blocks section hunk)))))
         (user-error "Point is not in a changed block")))
    (let* ((section (diffs--section-at-pos (point)))
           (hunk (and section
                      (diffs--hunk-at-pos section (point)))))
      (or
       (and hunk
            (cl-find-if
             (lambda (block)
               (and (<= (plist-get block :begin) (point))
                    (< (point) (plist-get block :end))))
             (diffs--resolution-blocks section hunk)))
       (user-error "Point is not in a changed block")))))

(defun diffs--resolution-side-string (block side)
  "Return BLOCK's source text for SIDE, including line endings."
  (let* ((lines (plist-get block
                           (if (eq side 'old) :old-lines :new-lines)))
         (no-newline
          (plist-get block
                     (if (eq side 'old)
                         :old-no-newline
                       :new-no-newline)))
         (text (mapconcat (lambda (line) (concat line "\n")) lines "")))
    (if (and no-newline (not (string-empty-p text)))
        (string-remove-suffix "\n" text)
      text)))

(defun diffs--resolution-decision-label (decision)
  "Return a compact display label for DECISION."
  (concat
   (if (eq (plist-get decision :action) 'accept)
       "✓ Kept change"
     "↶ Rejected change")
   (when (plist-get decision :applied)
     " · applied to source buffer")))

(defun diffs--resolution-set-decisions (owner blocks action)
  "Record ACTION for BLOCKS in OWNER."
  (with-current-buffer owner
    (dolist (block blocks)
      (let* ((key (plist-get block :key))
             (previous
              (alist-get key diffs--review-decisions
                         nil nil #'equal))
             (source-state
              (alist-get key diffs--review-source-actions
                         nil nil #'equal))
             (source-action
              (or (plist-get source-state :action)
                  (plist-get previous :source-action)
                  (and (plist-get previous :applied)
                       (plist-get previous :action))))
             (decision
              (append
               (list :action action
                     :applied (and source-action
                                   (eq action source-action))
                     :source-action source-action
                     :generation diffs--review-generation)
               (copy-tree block))))
        (setf (alist-get key diffs--review-decisions
                        nil nil #'equal)
              decision)))))

(defun diffs--resolution-remove-decisions (owner keys)
  "Remove decisions identified by KEYS from OWNER."
  (with-current-buffer owner
    (setq diffs--review-decisions
          (cl-remove-if
           (lambda (entry) (member (car entry) keys))
           diffs--review-decisions))))

(defun diffs--resolution-split-anchor (owner &optional block)
  "Capture the stable split row at point for OWNER.
BLOCK supplies the original change block when point is on a synthetic
decision row.  The returned anchor separates its displayed split ROLE
from its immutable patch SIDE and source LINE."
  (when (derived-mode-p 'diffs-split-mode)
    (let* ((index (diffs--split-row-index-at-position (point)))
           (row (and index (aref diffs--split-rows index)))
           (key (and row (diffs--split-row-resolution-key row)))
           (block
            (or block
                (and key (diffs--resolution-block-for-key owner key))))
           (role diffs--split-role)
           (row-line (and row (diffs--split-row-source-number row)))
           (row-side (and row-line
                          (diffs--split-row-source-side row)))
           (old-lines (and block (plist-get block :old-lines)))
           (new-lines (and block (plist-get block :new-lines)))
           (side
            (or row-side
                (cond
                 ((and (eq role 'old) old-lines) 'old)
                 ((and (eq role 'new) new-lines) 'new)
                 (old-lines 'old)
                 (new-lines 'new))))
           (line
            (or row-line
                (and block
                     (plist-get
                      block
                      (if (eq side 'old) :old-start :new-start)))))
           (positions
            (and block
                 (plist-get
                  block
                  (if (eq side 'old)
                      :old-positions
                    :new-positions))))
           (row-origin (and row (nth 6 row)))
           (window (get-buffer-window (current-buffer)))
           (window-line
            (if (window-live-p window)
                (count-screen-lines
                 (window-start window) (line-beginning-position))
              0)))
      (list :role role
            :file (or (and row (nth 4 row))
                      (and block (plist-get block :file)))
            :hunk (or (and row (nth 5 row))
                      (and block (plist-get block :hunk)))
            :side side
            :line line
            :kind (if row-line
                      (nth 3 row)
                    (and side (if (eq side 'old) 'del 'add)))
            :origin (or (and row-origin (car row-origin))
                        (and positions (caar positions)))
            :physical-offset (and row (nth 9 row))
            :row-index index
            :column (current-column)
            :window-line window-line))))

(defun diffs--resolution-anchor-row-index (anchor)
  "Return the rebuilt split row index best matching ANCHOR.
Both columns are searched because a pure insertion or deletion is a
filler in the column whose display role is preserved."
  (diffs--split-paged-materialize-hunk
   (plist-get anchor :hunk))
  (let ((other-rows
         (and (buffer-live-p diffs--split-other)
              (buffer-local-value
               'diffs--split-rows diffs--split-other)))
        (count (length diffs--split-rows)))
    (cl-labels
        ((rows-at
          (index)
          (delq nil
                (list
                 (aref diffs--split-rows index)
                 (and other-rows
                      (< index (length other-rows))
                      (aref other-rows index)))))
         (same-container-p
          (row)
          (and (equal (nth 4 row) (plist-get anchor :file))
               (equal (nth 5 row) (plist-get anchor :hunk))))
         (same-source-p
          (row)
          (and (same-container-p row)
               (eq (diffs--split-row-source-side row)
                   (plist-get anchor :side))
               (equal (diffs--split-row-source-number row)
                      (plist-get anchor :line))))
         (row-origin
          (row)
          (when-let* ((origin (nth 6 row)))
            (car origin)))
         (find-first
          (predicate)
          (catch 'found
            (dotimes (index count)
              (dolist (row (rows-at index))
                (when (funcall predicate row)
                  (throw 'found index)))))))
      (or
       (and (plist-get anchor :line)
            (find-first
             (lambda (row)
               (and (same-source-p row)
                    (equal (nth 9 row)
                           (plist-get anchor :physical-offset))))))
       (and (plist-get anchor :line)
            (find-first #'same-source-p))
       (when-let* ((origin (plist-get anchor :origin)))
         (find-first
          (lambda (row)
            (and (same-container-p row)
                 (equal (row-origin row) origin)))))
       (let ((target (or (plist-get anchor :row-index) 0))
             best best-distance)
         (dotimes (index count)
           (when (cl-some
                  (lambda (row)
                    (and (same-container-p row)
                         (memq (nth 3 row) '(ctx del add filler))))
                  (rows-at index))
             (let ((distance (abs (- index target))))
               (when (or (null best-distance)
                         (< distance best-distance))
                 (setq best index
                       best-distance distance)))))
         best)))))

(defun diffs--resolution-restore-split-anchor (owner anchor)
  "Restore OWNER's rebuilt split view to stable row ANCHOR."
  (let* ((role (plist-get anchor :role))
         (cache (buffer-local-value 'diffs--split-cache owner))
         (buffer (plist-get cache (if (eq role 'old) :old :new)))
         (window (and (buffer-live-p buffer)
                      (get-buffer-window buffer))))
    (when (window-live-p window)
      (select-window window)
      (with-current-buffer buffer
        (when-let* ((index (diffs--resolution-anchor-row-index anchor)))
          (goto-char (diffs--split-row-position index))
          (move-to-column (or (plist-get anchor :column) 0))
          (set-window-point window (point))
          (let ((start
                 (save-excursion
                   (forward-line
                    (- (max 0 (or (plist-get anchor :window-line) 0))))
                   (line-beginning-position))))
            (set-window-start window start))
          (when (buffer-live-p diffs--split-other)
            (dolist (other-window
                     (get-buffer-window-list diffs--split-other nil t))
              (set-window-point
               other-window
               (with-current-buffer diffs--split-other
                 (diffs--split-row-position index)))))
          (diffs--split-materialize-window window)
          (diffs--split-sync-from window)
          t)))))

(defun diffs--resolution-rebuild-view
    (owner key split-role &optional anchor)
  "Refresh OWNER after a decision and return to KEY on SPLIT-ROLE.
When KEY disappears after reset, restore the stable split row ANCHOR."
  (with-current-buffer owner
    (diffs--split-cache-clear)
    (if split-role
        ;; The owner is hidden again as soon as the decision-aware split is
        ;; rebuilt.  Preserve its old projection and refresh it only when
        ;; the user actually returns to stacked.
        (setq diffs--review-owner-overlays-stale t)
      (diffs--review-refresh-overlays owner (list owner))))
  (when split-role
    (condition-case error-data
        (progn
          (pop-to-buffer owner)
          (with-current-buffer owner
            (diffs-toggle-split)))
      (error
       ;; A failed split rebuild leaves the owner visible, so restore its
       ;; projection before propagating the rendering error.
       (diffs--review-refresh-overlays owner (list owner))
       (signal (car error-data) (cdr error-data))))
    (let* ((cache (buffer-local-value 'diffs--split-cache owner))
           (buffer (plist-get cache
                              (if (eq split-role 'old) :old :new)))
           (window (and (buffer-live-p buffer)
                        (get-buffer-window buffer)))
           restored)
      (when (window-live-p window)
        (select-window window)
        (with-current-buffer buffer
          (when-let* ((index
                       (and
                        key
                       (cl-loop
                        for row across diffs--split-rows
                        for row-index from 0
                        when (equal
                              key
                              (diffs--split-row-resolution-key row))
                        return row-index))))
            (goto-char (diffs--split-row-position index))
            (diffs--split-materialize-window window)
            (setq restored t))))
      (unless restored
        (when anchor
          (diffs--resolution-restore-split-anchor owner anchor))))))

(defun diffs--resolution-rollback-view (owner split-role anchor)
  "Restore OWNER's projection and SPLIT-ROLE after a failed transition.
ANCHOR identifies the pre-transition split row.  Reopening split is
best-effort because the original rendering error may still be present."
  (with-current-buffer owner
    ;; A failed rebuild can leave newly allocated or partially rendered
    ;; derived buffers in the cache.  Recreate them from restored decisions.
    (diffs--split-cache-clear)
    (diffs--review-refresh-overlays owner (list owner)))
  (when split-role
    (pop-to-buffer owner)
    (with-current-buffer owner
      (diffs-toggle-split))
    (when anchor
      (diffs--resolution-restore-split-anchor owner anchor))))

(defun diffs--resolution-transition
    (owner key split-role anchor mutation)
  "Run MUTATION and rebuild OWNER as one review-state transition.
KEY, SPLIT-ROLE, and ANCHOR describe the view to restore.  If mutation
or rendering fails, restore the previous decisions and best-effort
recreate the pre-transition visible view before re-signalling."
  (let ((previous
         (copy-tree
          (buffer-local-value 'diffs--review-decisions owner))))
    (condition-case error-data
        (progn
          (when split-role
            (let ((diffs--review-defer-owner-overlay-refresh t))
              (diffs-split-quit)))
          (funcall mutation)
          (diffs--resolution-rebuild-view
           owner key split-role anchor))
      (error
       (with-current-buffer owner
         (setq diffs--review-decisions previous))
       (condition-case rollback-error
           (diffs--resolution-rollback-view
            owner split-role anchor)
         (error
          (message "diffs decision rollback failed: %s"
                   (error-message-string rollback-error))))
       (signal (car error-data) (cdr error-data))))))

(defun diffs--resolution-decide (action whole-hunk)
  "Resolve the block at point with ACTION.
When WHOLE-HUNK is non-nil, resolve every change block in its hunk."
  (let* ((owner (or (diffs--review-owner-buffer)
                    (user-error "Not in a diffs review view")))
         (split-role
          (and (derived-mode-p 'diffs-split-mode) diffs--split-role))
         (block (diffs--resolution-block-at-point owner))
         (key (plist-get block :key))
         (hunk (plist-get block :hunk))
         (section
          (with-current-buffer owner
            (diffs--section-at-pos (car hunk))))
         (blocks
          (if whole-hunk
              (with-current-buffer owner
                (diffs--resolution-blocks section hunk))
            (list block)))
         (anchor
          (and split-role
               (diffs--resolution-split-anchor owner block))))
    (diffs--resolution-transition
     owner key split-role anchor
     (lambda ()
       (diffs--resolution-set-decisions owner blocks action)))
    (message "%s %d change block%s%s"
             (if (eq action 'accept) "Kept" "Rejected")
             (length blocks)
             (if (= (length blocks) 1) "" "s")
             (if whole-hunk " in this hunk" ""))))

(defun diffs-review-accept-change (&optional whole-hunk)
  "Keep the new version of the change block at point.
With prefix argument WHOLE-HUNK, keep every change block in the hunk.
This updates the review preview only; use
`diffs-review-apply-decisions' to apply the result to source buffers."
  (interactive "P")
  (diffs--resolution-decide 'accept whole-hunk))

(defun diffs-review-reject-change (&optional whole-hunk)
  "Restore the old version of the change block at point.
With prefix argument WHOLE-HUNK, reject every change block in the hunk.
This updates the review preview only; use
`diffs-review-apply-decisions' to apply the result to source buffers."
  (interactive "P")
  (diffs--resolution-decide 'reject whole-hunk))

(defun diffs-review-reset-change (&optional all)
  "Reset the change-block decision at point.
With prefix argument ALL, reset every decision in the review."
  (interactive "P")
  (let* ((owner (or (diffs--review-owner-buffer)
                    (user-error "Not in a diffs review view")))
         (split-role
          (and (derived-mode-p 'diffs-split-mode) diffs--split-role))
         (block (unless all (diffs--resolution-block-at-point owner)))
         (key (and block (plist-get block :key)))
         (anchor
          (and split-role
               (diffs--resolution-split-anchor owner block))))
    (unless (or all (diffs--resolution-decision key owner))
      (user-error "This change block has no decision"))
    (diffs--resolution-transition
     owner key split-role anchor
     (lambda ()
       (if all
           (with-current-buffer owner
             (setq diffs--review-decisions nil))
         (diffs--resolution-remove-decisions owner (list key)))))
    (message "%s" (if all
                      "Reset all change decisions"
                    "Reset change decision"))))

(defun diffs--resolution-source-region (buffer start count &optional noerror)
  "Return BUFFER positions for COUNT lines beginning at line START.
When NOERROR is non-nil, return nil instead of signalling if the
requested source range no longer exists."
  (with-current-buffer buffer
    (save-restriction
      (widen)
      (save-excursion
        (goto-char (point-min))
        (if (not (zerop (forward-line (1- start))))
            (unless noerror
              (user-error "Source file no longer contains line %d" start))
          (let ((begin (point)))
            (if (zerop (forward-line count))
                (cons begin (point))
              (unless noerror
                (user-error
                 "Source file no longer contains the reviewed block")))))))))

(defun diffs--resolution-source-string (decision side buffer)
  "Return DECISION's SIDE text in BUFFER's internal EOL form."
  (let ((text (diffs--resolution-side-string decision side)))
    (with-current-buffer buffer
      (if (eq (coding-system-eol-type buffer-file-coding-system) 1)
          (replace-regexp-in-string
           "\r\\(?:\n\\|\\'\\)"
           (lambda (match)
             (if (string-suffix-p "\n" match) "\n" ""))
           text t t)
        text))))

(defun diffs--resolution-source-path (owner file)
  "Return FILE's validated local path confined to OWNER's repository."
  (unless (and (stringp file) (not (string-empty-p file))
               (not (equal file "/dev/null")))
    (user-error "The reviewed change has no writable source file"))
  (with-current-buffer owner
    (diffs--review-ensure-session-state owner)
    (let* ((root (expand-file-name diffs--review-repository))
           (expanded (expand-file-name file root)))
      (when (or (file-remote-p root) (file-remote-p file)
                (file-remote-p expanded))
        (user-error "Applying review decisions requires local source files"))
      (unless (file-directory-p root)
        (user-error "Review repository no longer exists: %s" root))
      (let* ((canonical-root
              (file-name-as-directory (file-truename root)))
             (parent (file-name-directory expanded)))
        (unless (file-directory-p parent)
          (user-error "Source directory no longer exists: %s" parent))
        (let ((canonical
               (if (file-exists-p expanded)
                   (file-truename expanded)
                 (expand-file-name
                  (file-name-nondirectory expanded)
                  (file-truename parent)))))
          (unless (file-in-directory-p canonical canonical-root)
            (user-error
             "Source path escapes the review repository: %s" file))
          expanded)))))

(defun diffs--resolution-actual-side
    (decision old-match new-match)
  "Return DECISION's current source side.
OLD-MATCH and NEW-MATCH say which reviewed side matches source text."
  (cond
   ((and old-match new-match)
    (cond
     ((equal (diffs--resolution-side-string decision 'old)
             (diffs--resolution-side-string decision 'new))
      'new)
     ((null (plist-get decision :old-lines)) 'new)
     ((null (plist-get decision :new-lines)) 'old)
     ((eq (plist-get decision :action) 'reject) 'old)
     (t 'new)))
   (old-match 'old)
   (new-match 'new)))

(defun diffs--resolution-prepare-edits (owner)
  "Validate OWNER's decisions against source and return required edits.
Both accepted and rejected results are reconciled with the current
source text.  This makes applying idempotent and allows a later action
or source-buffer undo to be applied correctly."
  (when (buffer-local-value 'diffs--target-revision owner)
    (user-error
     "Cannot apply decisions from a historical commit review"))
  (let* ((decisions
          (buffer-local-value 'diffs--review-decisions owner))
         (source-actions
          (buffer-local-value 'diffs--review-source-actions owner))
         (decision-files
          (delete-dups
           (mapcar
            (lambda (entry)
              (plist-get (cdr entry) :file))
            decisions)))
         (decision-keys (make-hash-table :test #'equal))
         candidates edits current-file current-buffer (offset 0))
    (dolist (entry decisions)
      (puthash (car entry) t decision-keys)
      (let ((decision (cdr entry)))
        (unless
            (= (or (plist-get decision :generation)
                   (buffer-local-value 'diffs--review-generation owner))
               (buffer-local-value 'diffs--review-generation owner))
          (user-error
           "A decision belongs to an older review generation; refresh it"))
        (let* ((file
                (diffs--resolution-source-path
                 owner (plist-get decision :file)))
               (buffer (find-file-noselect file)))
          (push (list file buffer decision decision) candidates))))
    ;; A reset decision is intentionally absent from DECISIONS, but its
    ;; already-applied source action still changes the physical line at
    ;; which later blocks begin.  Validate those preceding coordinates
    ;; while applying another decision in the same file.
    (dolist (entry source-actions)
      (let ((source-state (cdr entry)))
        (when (and
               (not (gethash (car entry) decision-keys))
               (member (plist-get source-state :file) decision-files))
          (unless
              (= (or (plist-get source-state :generation)
                     (buffer-local-value
                      'diffs--review-generation owner))
                 (buffer-local-value
                  'diffs--review-generation owner))
            (user-error
             "Applied source state belongs to an older review generation; refresh it"))
          (let* ((file
                  (diffs--resolution-source-path
                   owner (plist-get source-state :file)))
                 (buffer (find-file-noselect file)))
            (push
             (list file buffer source-state nil)
             candidates)))))
    (setq candidates
          (cl-stable-sort
           candidates
           (lambda (left right)
             (if (equal (car left) (car right))
                 (let ((left-start
                        (plist-get (nth 2 left) :new-start))
                       (right-start
                        (plist-get (nth 2 right) :new-start)))
                   (if (= left-start right-start)
                       (< (or (plist-get (nth 2 left) :index) 0)
                          (or (plist-get (nth 2 right) :index) 0))
                     (< left-start right-start)))
               (string-lessp (car left) (car right))))))
    (dolist (candidate candidates)
      (pcase-let ((`(,file ,buffer ,record ,decision) candidate))
        (unless (equal file current-file)
          (setq current-file file
                current-buffer buffer
                offset 0))
        (with-current-buffer current-buffer
          (when buffer-read-only
            (user-error "Source buffer is read-only: %s" file))
          (when (buffer-narrowed-p)
            (user-error "Source buffer is narrowed: %s" file)))
        (let* ((start (+ (plist-get record :new-start) offset))
               (old-lines (plist-get record :old-lines))
               (new-lines (plist-get record :new-lines))
               (old-region
                (diffs--resolution-source-region
                 current-buffer start (length old-lines) t))
               (new-region
                (diffs--resolution-source-region
                 current-buffer start (length new-lines) t))
               (old-text
                (diffs--resolution-source-string
                 record 'old current-buffer))
               (new-text
                (diffs--resolution-source-string
                 record 'new current-buffer))
               (old-match
                (and old-region
                     (with-current-buffer current-buffer
                  (equal old-text
                         (buffer-substring-no-properties
                           (car old-region) (cdr old-region))))))
               (new-match
                (and new-region
                     (with-current-buffer current-buffer
                  (equal new-text
                         (buffer-substring-no-properties
                           (car new-region) (cdr new-region))))))
               (actual-side
                (diffs--resolution-actual-side
                 record old-match new-match))
               (desired-side
                (if (eq (plist-get record :action) 'accept)
                    'new
                  'old))
               (actual-region
                (if (eq actual-side 'old) old-region new-region)))
          (unless actual-side
            (user-error
             "Source changed near %s:%d; reset or refresh the review"
             (plist-get record :file)
             (plist-get record :new-start)))
          (when (eq actual-side 'old)
            (cl-incf offset (- (length old-lines)
                               (length new-lines))))
          (when (and decision
                     (not (eq actual-side desired-side)))
            (push
             (list :decision decision :buffer current-buffer
                   :begin (car actual-region) :end (cdr actual-region)
                   :replacement
                   (if (eq desired-side 'old) old-text new-text))
             edits)))))
    (sort edits
          (lambda (left right)
            (if (eq (plist-get left :buffer)
                    (plist-get right :buffer))
                (> (plist-get left :begin)
                   (plist-get right :begin))
              (string-lessp
               (buffer-name (plist-get left :buffer))
               (buffer-name (plist-get right :buffer))))))))

(defun diffs-review-apply-decisions ()
  "Apply reviewed results to source buffers without saving them.
Accepted blocks already match the new-side source and require no edit.
Rejected blocks are restored from the old side after every target is
validated.  No source buffer is saved or staged automatically."
  (interactive)
  (let* ((owner (or (diffs--review-owner-buffer)
                    (user-error "Not in a diffs review view")))
         (split-role
          (and (derived-mode-p 'diffs-split-mode) diffs--split-role))
         (key
          (and split-role
               (when-let* ((row
                            (diffs--split-row-at-position (point))))
                 (diffs--split-row-resolution-key row))))
         (anchor
          (and split-role
               (diffs--resolution-split-anchor owner)))
         (decisions
          (buffer-local-value 'diffs--review-decisions owner)))
    (unless decisions
      (user-error "No change decisions to apply"))
    (when (buffer-local-value 'diffs--target-revision owner)
      (user-error
       "Cannot apply decisions from a historical commit review"))
    (unless (yes-or-no-p
             (format "Apply %d reviewed decision%s to source buffers? "
                     (length decisions)
                     (if (= (length decisions) 1) "" "s")))
      (user-error "Apply cancelled"))
    ;; Validate after confirmation.  A process, timer, or formatter can
    ;; change a source buffer while the minibuffer is active; preparing
    ;; integer regions before the prompt would then apply stale edits.
    (let ((edits (diffs--resolution-prepare-edits owner))
          buffers)
      (dolist (edit edits)
        (cl-pushnew (plist-get edit :buffer) buffers))
      (when buffers
        (let ((change-group
               (cl-loop
                for buffer in buffers
                nconc (prepare-change-group buffer)))
              accepted)
          (unwind-protect
              (progn
                (activate-change-group change-group)
                (dolist (edit edits)
                  (with-current-buffer (plist-get edit :buffer)
                    (delete-region (plist-get edit :begin)
                                   (plist-get edit :end))
                    (goto-char (plist-get edit :begin))
                    (insert (plist-get edit :replacement))))
                (accept-change-group change-group)
                (setq accepted t))
            (unless accepted
              (cancel-change-group change-group)))))
      (with-current-buffer owner
        (dolist (entry diffs--review-decisions)
          (let* ((key (car entry))
                 (decision (cdr entry))
                 (action (plist-get decision :action))
                 (source-state
                  (append
                   (list :action action
                         :generation diffs--review-generation)
                   (copy-tree decision))))
            (setf (plist-get decision :applied) t
                  (plist-get decision :source-action) action
                  (alist-get key diffs--review-source-actions
                             nil nil #'equal)
                  source-state))))
      (when split-role
        (let ((diffs--review-defer-owner-overlay-refresh t))
          (diffs-split-quit)))
      (diffs--resolution-rebuild-view owner key split-role anchor)
      (if buffers
          (message
           "Applied review result to %d source buffer%s; changes are unsaved"
           (length buffers)
           (if (= (length buffers) 1) "" "s"))
        (message
         "Kept changes already match the source; no source edits were needed")))))

(defun diffs--review-location-at (position)
  "Return the stable review location represented by POSITION.
The result is a plist containing `:file', `:side', and `:line'."
  (if (derived-mode-p 'diffs-split-mode)
      (when-let* ((row (diffs--split-row-at-position position))
                  (file (nth 4 row))
                  (line (diffs--split-row-source-number row))
                  (side (diffs--split-row-source-side row)))
        (list :file file :side side :line line))
    (save-excursion
      (goto-char position)
      (let ((begin (line-beginning-position))
            (end (min (point-max) (1+ (line-end-position)))))
        (unless (get-text-property begin 'diffs-file)
          (diffs--jit-decorate begin end))
        (when-let* ((file (get-text-property begin 'diffs-file))
                    (kind (get-text-property begin 'diffs-kind))
                    (side (if (eq kind 'del) 'old 'new))
                    (line
                     (get-text-property
                      begin
                      (if (eq side 'old)
                          'diffs-old-number
                        'diffs-new-number))))
          (list :file file :side side :line line))))))

(defun diffs--review-range-at-point ()
  "Return a stable review range for point or the active region."
  (let* ((region (use-region-p))
         (begin (if region (region-beginning) (point)))
         (end
          (if region
              (max begin (1- (region-end)))
            begin))
         locations)
    (save-excursion
      (goto-char begin)
      (beginning-of-line)
      (while (<= (point) end)
        (when-let* ((location (diffs--review-location-at (point))))
          (push location locations))
        (forward-line 1)))
    (unless locations
      (user-error "Point or region does not contain selectable diff lines"))
    (setq locations (nreverse locations))
    (let* ((first (car locations))
           (file (plist-get first :file))
           (side (plist-get first :side))
           (lines
            (mapcar
             (lambda (location)
               (unless (and (equal file (plist-get location :file))
                            (eq side (plist-get location :side)))
                 (user-error
                  "A review selection cannot cross files or old/new sides"))
               (plist-get location :line))
             locations)))
      (list :file file
            :side side
            :start (apply #'min lines)
            :end (apply #'max lines)))))

(defun diffs--review-clear-view-overlays (buffer)
  "Delete review overlays projected into BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (mapc #'delete-overlay diffs--review-overlays)
      (setq diffs--review-overlays nil))))

(defun diffs--review-add-selection-overlay (begin end)
  "Highlight BEGIN through END as a stable review selection."
  (let ((overlay (make-overlay begin end nil nil nil)))
    (overlay-put overlay 'diffs-review t)
    (overlay-put overlay 'face 'diffs-review-selection)
    (overlay-put overlay 'priority 20)
    (push overlay diffs--review-overlays)))

(defun diffs--review-project-unified-selection (selection)
  "Project SELECTION into the current unified diff buffer."
  (let ((file (plist-get selection :file))
        (side (plist-get selection :side))
        (start (plist-get selection :start))
        (finish (plist-get selection :end)))
    (dolist (section diffs--sections)
      (when (equal file (plist-get section :file))
        (dolist (hunk (plist-get section :hunks))
          (let ((old-line (nth 1 hunk))
                (new-line (nth 2 hunk))
                (end (diffs--hunk-end hunk section)))
            (save-excursion
              (goto-char (car hunk))
              (forward-line 1)
              (while (and (< (point) end) (not (eobp)))
                (let* ((marker (char-after))
                       (old (memq marker '(?- ?\s ?\n)))
                       (new (memq marker '(?+ ?\s ?\n)))
                       (line
                        (if (eq side 'old)
                            (and old old-line)
                          (and new new-line))))
                  (when (and line (<= start line) (<= line finish))
                    (diffs--review-add-selection-overlay
                     (line-beginning-position)
                     (min (point-max) (1+ (line-end-position)))))
                  (when old (cl-incf old-line))
                  (when new (cl-incf new-line)))
                (forward-line 1)))))))))

(defun diffs--review-project-split-selection (selection)
  "Project SELECTION into the current split buffer."
  (let ((file (plist-get selection :file))
        (side (plist-get selection :side))
        (start (plist-get selection :start))
        (finish (plist-get selection :end)))
    (cl-loop
     for row across diffs--split-rows
     for index from 0
     for line = (diffs--split-row-source-number row)
     when (and line
               (eq side (diffs--split-row-source-side row))
               (equal file (nth 4 row))
               (<= start line)
               (<= line finish))
     do
     (diffs--review-add-selection-overlay
      (diffs--split-row-position index)
      (diffs--split-row-position (1+ index))))))

(defun diffs--review-unified-line-position (file side target-line)
  "Return unified buffer position for FILE, SIDE, and TARGET-LINE."
  (catch 'found
    (dolist (section diffs--sections)
      (when (equal file (plist-get section :file))
        (dolist (hunk (plist-get section :hunks))
          (let ((old-line (nth 1 hunk))
                (new-line (nth 2 hunk))
                (end (diffs--hunk-end hunk section)))
            (save-excursion
              (goto-char (car hunk))
              (forward-line 1)
              (while (and (< (point) end) (not (eobp)))
                (let ((marker (char-after)))
                  (when (and (if (eq side 'old)
                                 (memq marker '(?- ?\s ?\n))
                               (memq marker '(?+ ?\s ?\n)))
                             (= target-line
                                (if (eq side 'old)
                                    old-line
                                  new-line)))
                    (throw 'found (line-beginning-position)))
                  (when (memq marker '(?- ?\s ?\n))
                    (cl-incf old-line))
                  (when (memq marker '(?+ ?\s ?\n))
                    (cl-incf new-line)))
                (forward-line 1)))))))))

(defun diffs--review-split-row-index (file side target-line)
  "Return split row index for FILE, SIDE, and TARGET-LINE."
  (cl-loop
   for row across diffs--split-rows
   for index from 0
   when (and (eq side (diffs--split-row-source-side row))
             (equal file (nth 4 row))
             (equal target-line
                    (diffs--split-row-source-number row)))
   return index))

(defun diffs--review-annotation-target (annotation)
  "Return preferred (SIDE . LINE) display target for ANNOTATION."
  (let ((new-range (plist-get annotation :new-range))
        (old-range (plist-get annotation :old-range)))
    (cond
     (new-range (cons 'new (cadr new-range)))
     (old-range (cons 'old (cadr old-range))))))

(defun diffs--review-annotation-display (annotation)
  "Return (STRING . HEIGHT) for inline ANNOTATION display."
  (let* ((author (or (plist-get annotation :author)
                     (plist-get annotation :source)
                     "review"))
         (summary (plist-get annotation :summary))
         (rationale (plist-get annotation :rationale))
         (lines
          (append
           (list
            (concat
             (propertize (format "  ╰─ [%s] " author)
                         'face 'diffs-review-annotation-border)
             (propertize summary 'face 'diffs-review-annotation)))
           (when (and rationale (not (string-empty-p rationale)))
             (mapcar
              (lambda (line)
                (concat
                 (propertize "     │ " 'face
                             'diffs-review-annotation-border)
                 (propertize line 'face 'diffs-review-annotation)))
              (split-string rationale "\n")))))
         (display (concat "\n" (string-join lines "\n"))))
    ;; Count rendered lines rather than logical fields: imported or Agent
    ;; text may itself contain newlines, and the peer split column needs an
    ;; exactly equal-height spacer to preserve row alignment.
    (cons display (cl-count ?\n display))))

(defun diffs--review-add-annotation-overlay (position string)
  "Display annotation STRING after the line at POSITION."
  (save-excursion
    (goto-char position)
    (let ((overlay
           (make-overlay (line-end-position) (line-end-position)
                         nil nil nil)))
      (overlay-put overlay 'diffs-review t)
      (overlay-put overlay 'after-string string)
      (overlay-put overlay 'priority 15)
      (push overlay diffs--review-overlays))))

(defun diffs--review-project-unified-annotations (annotations)
  "Project ANNOTATIONS into the current unified buffer."
  (dolist (annotation annotations)
    (when-let* ((target (diffs--review-annotation-target annotation))
                (position
                 (diffs--review-unified-line-position
                  (plist-get annotation :file)
                  (car target)
                  (cdr target))))
      (diffs--review-add-annotation-overlay
       position
       (car (diffs--review-annotation-display annotation))))))

(defun diffs--review-project-split-annotations (owner annotations)
  "Project OWNER's ANNOTATIONS into the current split buffer."
  (let* ((cache (buffer-local-value 'diffs--split-cache owner))
         (role diffs--split-role))
    (dolist (annotation annotations)
      (when-let* ((target (diffs--review-annotation-target annotation))
                  (target-buffer
                   (plist-get cache
                              (if (eq (car target) 'old) :old :new)))
                  ((buffer-live-p target-buffer))
                  (index
                   (with-current-buffer target-buffer
                     (diffs--review-split-row-index
                      (plist-get annotation :file)
                      (car target)
                      (cdr target))))
                  ((< index (length diffs--split-rows))))
        (pcase-let* ((`(,display . ,height)
                      (diffs--review-annotation-display annotation))
                     (string
                      (if (eq role (car target))
                          display
                        (propertize
                         (make-string height ?\n)
                         'face 'diffs-filler))))
          (diffs--review-add-annotation-overlay
           (diffs--split-row-position index)
           string))))))

(defun diffs--review-add-decision-overlay (begin end &rest properties)
  "Add a decision overlay from BEGIN to END with PROPERTIES."
  (let ((overlay (make-overlay begin end nil nil nil)))
    (overlay-put overlay 'diffs-review t)
    (overlay-put overlay 'priority 10)
    (while properties
      (overlay-put overlay (pop properties) (pop properties)))
    (push overlay diffs--review-overlays)))

(defun diffs--review-resolution-prefix
    (section marker old-number new-number resolved)
  "Return a decision-aware line prefix for SECTION.
MARKER is the raw diff marker.  OLD-NUMBER and NEW-NUMBER are the
preview result numbers.  RESOLVED suppresses the change fringe."
  (let* ((width (plist-get section :width))
         (kind (pcase marker
                 (?- 'del)
                 (?+ 'add)
                 (_ 'ctx)))
         (change-face
          (pcase marker
            (?- 'diff-removed)
            (?+ 'diff-added)))
         (fringe
          (if resolved "" (diffs--fringe-prefix marker))))
    (concat
     fringe
     (or
      (diffs--gutter
       section 'stacked kind width old-number new-number
       nil nil
       (diffs--line-prefix-face change-face))
      ""))))

(defun diffs--review-project-unified-result-numbers
    (owner decisions)
  "Project decision-adjusted line numbers for OWNER and DECISIONS."
  (with-current-buffer owner
    (dolist (section diffs--sections)
      (let ((old-shift 0)
            (new-shift 0))
        (dolist (hunk (plist-get section :hunks))
          (let ((old-line (nth 1 hunk))
                (new-line (nth 2 hunk))
                (blocks (diffs--resolution-blocks section hunk))
                current)
            (save-excursion
              (goto-char (car hunk))
              (forward-line 1)
              (while (and (< (point) (diffs--hunk-end hunk section))
                          (not (eobp)))
                (while (and blocks
                            (>= (point) (plist-get (car blocks) :end)))
                  (let* ((block (pop blocks))
                         (decision
                          (alist-get
                           (plist-get block :key)
                           decisions nil nil #'equal)))
                    (when decision
                      (if (eq (plist-get decision :action) 'accept)
                          (cl-incf
                           old-shift
                           (- (length (plist-get block :new-lines))
                              (length (plist-get block :old-lines))))
                        (cl-incf
                         new-shift
                         (- (length (plist-get block :old-lines))
                            (length (plist-get block :new-lines))))))))
                (setq current
                      (and blocks
                           (<= (plist-get (car blocks) :begin) (point))
                           (< (point) (plist-get (car blocks) :end))
                           (car blocks)))
                (let* ((marker (char-after))
                       (decision
                        (and current
                             (alist-get
                              (plist-get current :key)
                              decisions nil nil #'equal)))
                       (action (and decision
                                    (plist-get decision :action)))
                       (old-p (memq marker '(?- ?\s ?\n)))
                       (new-p (memq marker '(?+ ?\s ?\n)))
                       (resolved-number
                        (pcase action
                          ('accept
                           (and (eq marker ?+)
                                (+ new-line new-shift)))
                          ('reject
                           (and (eq marker ?-)
                                (+ old-line old-shift)))))
                       (old-number
                        (if resolved-number
                            resolved-number
                          (and old-p (+ old-line old-shift))))
                       (new-number
                        (if resolved-number
                            resolved-number
                          (and new-p (+ new-line new-shift)))))
                  (when (memq marker '(?+ ?- ?\s ?\n))
                    (diffs--review-add-decision-overlay
                     (line-beginning-position)
                     (min (point-max) (1+ (line-end-position)))
                     'line-prefix
                     (diffs--review-resolution-prefix
                      section marker old-number new-number
                      resolved-number)
                     'wrap-prefix
                     (diffs--review-resolution-prefix
                      section marker nil nil resolved-number)))
                  (when old-p (cl-incf old-line))
                  (when new-p (cl-incf new-line)))
                (forward-line 1)))
            ;; A change block can end at the hunk boundary rather than
            ;; at a following context line.
            (dolist (block blocks)
              (when-let* ((decision
                           (alist-get
                            (plist-get block :key)
                            decisions nil nil #'equal)))
                (if (eq (plist-get decision :action) 'accept)
                    (cl-incf
                     old-shift
                     (- (length (plist-get block :new-lines))
                        (length (plist-get block :old-lines))))
                  (cl-incf
                   new-shift
                   (- (length (plist-get block :old-lines))
                      (length (plist-get block :new-lines)))))))))))))

(defun diffs--review-project-unified-decisions (owner decisions)
  "Project OWNER's DECISIONS into the current unified view."
  (dolist (block (diffs--resolution-all-blocks owner))
    (when-let* ((decision
                 (alist-get (plist-get block :key)
                            decisions nil nil #'equal)))
      (let* ((action (plist-get decision :action))
             (chosen
              (plist-get block
                         (if (eq action 'accept)
                             :new-positions
                           :old-positions)))
             (discarded
              (plist-get block
                         (if (eq action 'accept)
                             :old-positions
                           :new-positions)))
             (label
              (concat
               (propertize
                (format "  %s  "
                        (diffs--resolution-decision-label decision))
                'face 'diffs-review-decision)
               "\n")))
        (dolist (position discarded)
          (diffs--review-add-decision-overlay
           (car position) (cdr position)
           'invisible 'diffs-resolution))
        (dolist (position (plist-get block :marker-positions))
          (diffs--review-add-decision-overlay
           (car position) (cdr position)
           'invisible 'diffs-resolution))
        (dolist (position chosen)
          (diffs--review-add-decision-overlay
           (car position) (cdr position)
           'diffs-resolution-chosen t))
        (diffs--review-add-decision-overlay
         (plist-get block :begin) (plist-get block :begin)
         'before-string label))))
  (diffs--review-project-unified-result-numbers owner decisions))

(defun diffs--review-refresh-overlays (owner &optional views)
  "Reproject OWNER's stable review state into live view buffers.
When VIEWS is non-nil, refresh only those buffers instead of OWNER and
both cached split views."
  (when (buffer-live-p owner)
    (let* ((cache (buffer-local-value 'diffs--split-cache owner))
           (buffers
            (or views
                (delq nil
                      (list owner
                            (plist-get cache :old)
                            (plist-get cache :new)))))
           (owner-requested (memq owner buffers))
           (selection
            (buffer-local-value 'diffs--review-selection owner))
           (annotations
            (buffer-local-value 'diffs--review-annotations owner))
           (decisions
            (buffer-local-value 'diffs--review-decisions owner)))
      (when owner-requested
        (with-current-buffer owner
          ;; Leave this set if projection fails, so the next real return to
          ;; stacked retries instead of displaying a partial view.
          (setq diffs--review-owner-overlays-stale t)))
      (dolist (buffer buffers)
        (diffs--review-clear-view-overlays buffer)
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (when (and decisions
                       (not (derived-mode-p 'diffs-split-mode)))
              (diffs--review-project-unified-decisions
               owner decisions))
            (when selection
              (if (derived-mode-p 'diffs-split-mode)
                  (diffs--review-project-split-selection selection)
                (diffs--review-project-unified-selection selection)))
            (when annotations
              (if (derived-mode-p 'diffs-split-mode)
                (diffs--review-project-split-annotations
                   owner annotations)
                (diffs--review-project-unified-annotations
                 annotations))))))
      (when owner-requested
        (with-current-buffer owner
          (setq diffs--review-owner-overlays-stale nil))))))

(defun diffs-review-select ()
  "Select the current diff line or active region by stable source identity."
  (interactive)
  (let ((owner (diffs--review-owner-buffer))
        (selection (diffs--review-range-at-point)))
    (unless (buffer-live-p owner)
      (user-error "Not in a diffs review view"))
    (with-current-buffer owner
      (setq diffs--review-selection selection))
    (deactivate-mark)
    (diffs--review-refresh-overlays owner)
    (message "Selected %s %s lines %d–%d"
             (plist-get selection :file)
             (plist-get selection :side)
             (plist-get selection :start)
             (plist-get selection :end))))

(defun diffs-review-selected-range ()
  "Return the current stable review selection, or nil."
  (when-let* ((owner (diffs--review-owner-buffer)))
    (copy-tree
     (buffer-local-value 'diffs--review-selection owner))))

(defun diffs-review-clear-selection ()
  "Clear the stable review selection."
  (interactive)
  (let ((owner (diffs--review-owner-buffer)))
    (unless (buffer-live-p owner)
      (user-error "Not in a diffs review view"))
    (with-current-buffer owner
      (setq diffs--review-selection nil))
    (diffs--review-refresh-overlays owner)
    (message "Review selection cleared")))

(defun diffs--review-new-id ()
  "Return a locally unique review annotation id."
  (concat
   "diffs:"
   (substring
    (secure-hash
     'sha1
     (format "%s:%s:%s:%s"
             (float-time) (emacs-pid) (random) (buffer-name)))
    0 16)))

(defun diffs--review-range (start end)
  "Validate and return inclusive one-based range START through END."
  (unless (and (integerp start) (integerp end)
               (> start 0) (>= end start))
    (error "Review ranges must be positive ordered line numbers"))
  (list start end))

(defun diffs--review-annotation-from-selection
    (selection summary &optional rationale author source)
  "Build an annotation from SELECTION with SUMMARY.
RATIONALE, AUTHOR, and SOURCE provide optional review metadata."
  (let ((side (plist-get selection :side))
        (range
         (diffs--review-range
          (plist-get selection :start)
          (plist-get selection :end))))
    (list :id (diffs--review-new-id)
          :file (plist-get selection :file)
          :old-range (and (eq side 'old) range)
          :new-range (and (eq side 'new) range)
          :summary summary
          :rationale rationale
          :author author
          :source (or source "user")
          :created-at (format-time-string "%FT%TZ" nil t))))

(defun diffs-review-add-annotation (summary rationale)
  "Attach a review annotation with SUMMARY and RATIONALE.
Use the stable selection when present, otherwise select the current
diff line first."
  (interactive
   (list (read-string "Review comment: ")
         (read-string "Rationale (optional): ")))
  (when (string-empty-p summary)
    (user-error "A review comment requires a summary"))
  (let* ((owner (diffs--review-owner-buffer))
         (selection
          (or (and owner
                   (buffer-local-value 'diffs--review-selection owner))
              (diffs--review-range-at-point)))
         (annotation
          (diffs--review-annotation-from-selection
           selection summary
           (unless (string-empty-p rationale) rationale)
           (or user-full-name user-login-name)
           "user")))
    (unless (buffer-live-p owner)
      (user-error "Not in a diffs review view"))
    (with-current-buffer owner
      (unless diffs--review-selection
        (setq diffs--review-selection selection))
      (setq diffs--review-annotations
            (append diffs--review-annotations (list annotation))))
    (diffs--review-refresh-overlays owner)
    (message "Added review comment %s" (plist-get annotation :id))
    annotation))

(defun diffs-review-annotations ()
  "Return a copy of annotations in the current diffs review."
  (when-let* ((owner (diffs--review-owner-buffer)))
    (copy-tree
     (buffer-local-value 'diffs--review-annotations owner))))

(defun diffs--review-replace-annotations (owner annotations)
  "Replace OWNER's annotations with ANNOTATIONS atomically.
Restore the prior state when view projection fails."
  (let ((before
         (buffer-local-value 'diffs--review-annotations owner)))
    (condition-case error-data
        (progn
          (with-current-buffer owner
            (setq diffs--review-annotations annotations))
          (diffs--review-refresh-overlays owner)
          annotations)
      (error
       (with-current-buffer owner
         (setq diffs--review-annotations before))
       (condition-case nil
           (diffs--review-refresh-overlays owner)
         (error nil))
       (signal (car error-data) (cdr error-data))))))

(defun diffs--review-remove-annotation (owner id)
  "Remove annotation ID from OWNER and return non-nil when found."
  (let* ((annotations
          (buffer-local-value 'diffs--review-annotations owner))
         (retained
          (cl-remove id annotations
                     :key (lambda (item) (plist-get item :id))
                     :test #'equal))
         (removed (< (length retained) (length annotations))))
    (when removed
      (diffs--review-replace-annotations owner retained))
    removed))

(defun diffs-review-remove-annotation (id)
  "Remove the current review annotation identified by ID."
  (interactive
   (let* ((annotations (or (diffs-review-annotations)
                           (user-error "No review annotations")))
          (ids (mapcar (lambda (item) (plist-get item :id))
                       annotations)))
     (list (completing-read "Remove annotation: " ids nil t))))
  (let ((owner (diffs--review-owner-buffer)))
    (unless (buffer-live-p owner)
      (user-error "Not in a diffs review view"))
    (unless (diffs--review-remove-annotation owner id)
      (user-error "No annotation matches %s" id))
    t))

(defun diffs-review-clear-annotations ()
  "Remove all annotations from the current diffs review."
  (interactive)
  (let ((owner (diffs--review-owner-buffer)))
    (unless (buffer-live-p owner)
      (user-error "Not in a diffs review view"))
    (diffs--review-replace-annotations owner nil)
    (message "Review annotations cleared")))

(defun diffs--review-file-order (owner file)
  "Return FILE's review order in OWNER."
  (or
   (cl-position file
                (buffer-local-value 'diffs--sections owner)
                :key (lambda (section) (plist-get section :file))
                :test #'equal)
   most-positive-fixnum))

(defun diffs--review-annotation-key (owner annotation)
  "Return sortable navigation key for ANNOTATION in OWNER."
  (let ((target (diffs--review-annotation-target annotation)))
    (list (diffs--review-file-order
           owner (plist-get annotation :file))
          (or (cdr target) 0))))

(defun diffs--review-key-less-p (left right)
  "Return non-nil when navigation key LEFT precedes RIGHT."
  (or (< (car left) (car right))
      (and (= (car left) (car right))
           (< (cadr left) (cadr right)))))

(defun diffs--review-goto-annotation (owner annotation)
  "Move OWNER's visible review to ANNOTATION."
  (when-let* ((target (diffs--review-annotation-target annotation)))
    (let* ((cache (buffer-local-value 'diffs--split-cache owner))
           (split
            (plist-get cache (if (eq (car target) 'old) :old :new)))
           (split-window (and (buffer-live-p split)
                              (get-buffer-window split))))
      (if (window-live-p split-window)
          (progn
            (select-window split-window)
            (with-current-buffer split
              (when-let* ((index
                           (diffs--review-split-row-index
                            (plist-get annotation :file)
                            (car target)
                            (cdr target))))
                (goto-char (diffs--split-row-position index))
                (recenter))))
        (when-let* ((position
                     (with-current-buffer owner
                       (diffs--review-unified-line-position
                        (plist-get annotation :file)
                        (car target)
                        (cdr target)))))
          (pop-to-buffer owner)
          (goto-char position)
          (recenter))))))

(defun diffs--review-move-annotation (next)
  "Move to the next annotation, or previous when NEXT is nil."
  (let* ((owner (diffs--review-owner-buffer))
         (annotations
          (and owner
               (buffer-local-value 'diffs--review-annotations owner)))
         (location (diffs--review-location-at (point)))
         (current-key
          (and location
               (list (diffs--review-file-order
                      owner (plist-get location :file))
                     (plist-get location :line))))
         (ordered
          (sort (copy-sequence annotations)
                (lambda (left right)
                  (diffs--review-key-less-p
                   (diffs--review-annotation-key owner left)
                   (diffs--review-annotation-key owner right)))))
         target)
    (unless annotations
      (user-error "No review annotations"))
    (setq target
          (if next
              (if current-key
                  (cl-find-if
                   (lambda (annotation)
                     (diffs--review-key-less-p
                      current-key
                      (diffs--review-annotation-key owner annotation)))
                   ordered)
                (car ordered))
            (if current-key
                (cl-find-if
                 (lambda (annotation)
                   (diffs--review-key-less-p
                    (diffs--review-annotation-key owner annotation)
                    current-key))
                 (reverse ordered))
              (car (last ordered)))))
    (unless target
      (user-error "No more review annotations"))
    (diffs--review-goto-annotation owner target)))

(defun diffs-review-next-annotation ()
  "Move to the next inline review annotation."
  (interactive)
  (diffs--review-move-annotation t))

(defun diffs-review-previous-annotation ()
  "Move to the previous inline review annotation."
  (interactive)
  (diffs--review-move-annotation nil))

(defun diffs--review-json-value (object key)
  "Return KEY from parsed JSON alist OBJECT."
  (or (cdr (assoc key object))
      (cdr (assq (intern key) object))))

(defun diffs--review-symbolize-json-keys (value)
  "Return VALUE with JSON object keys converted to symbols.
`json-serialize' requires symbol keys for alist objects, while keeping
string keys in the intermediate representation makes Hunk field names
easier to audit."
  (cond
   ((vectorp value)
    (vconcat (mapcar #'diffs--review-symbolize-json-keys value)))
   ((and (listp value)
         (cl-every
          (lambda (entry)
            (and (consp entry)
                 (or (stringp (car entry))
                     (symbolp (car entry)))))
          value))
    (mapcar
     (lambda (entry)
       (cons
        (if (stringp (car entry))
            (intern (car entry))
          (car entry))
        (diffs--review-symbolize-json-keys (cdr entry))))
     value))
   (t value)))

(defun diffs--review-json-serialize (object)
  "Serialize review JSON OBJECT with valid Emacs object keys."
  (json-serialize
   (diffs--review-symbolize-json-keys object)
   :false-object :false))

(defun diffs--review-normalize-json-range (value)
  "Validate JSON range VALUE and return an internal range."
  (when value
    (unless (or (listp value) (vectorp value))
      (error "Annotation ranges must be JSON arrays"))
    (let ((range (append value nil)))
      (unless (= (length range) 2)
        (error "Annotation ranges must contain two line numbers"))
      (diffs--review-range (nth 0 range) (nth 1 range)))))

(defconst diffs--review-sidecar-root-fields
  '("version" "summary" "files")
  "Accepted fields in a review sidecar root object.")

(defconst diffs--review-sidecar-file-fields
  '("path" "annotations")
  "Accepted fields in a review sidecar file object.")

(defconst diffs--review-sidecar-annotation-fields
  '("id" "oldRange" "newRange" "summary" "rationale" "author"
    "source" "tags" "confidence" "createdAt" "updatedAt")
  "Accepted fields in a review sidecar annotation object.")

(defun diffs--review-validate-optional-string (object field context)
  "Validate optional FIELD in OBJECT as a string for CONTEXT."
  (when (diffs--review-json-field-present-p object field)
    (unless (stringp (diffs--review-json-value object field))
      (error "%s field %s must be a string" context field))))

(defun diffs--review-parse-annotation
    (file object &optional source section)
  "Parse annotation OBJECT for FILE, defaulting SOURCE when absent.
When SECTION is non-nil, require the annotation target to belong to it."
  (diffs--review-validate-json-object
   object diffs--review-sidecar-annotation-fields "annotation" t)
  (let ((summary (diffs--review-json-value object "summary")))
    (unless (and (stringp summary) (not (string-empty-p summary)))
      (error "Each review annotation requires a summary"))
    (dolist (field
             '("rationale" "author" "source" "createdAt" "updatedAt"))
      (diffs--review-validate-optional-string object field "annotation"))
    (when (diffs--review-json-field-present-p object "id")
      (let ((id (diffs--review-json-value object "id")))
        (unless (and (stringp id) (not (string-empty-p id)))
          (error "Annotation field id must be a non-empty string"))))
    (when (diffs--review-json-field-present-p object "tags")
      (let ((tags (diffs--review-json-value object "tags")))
        (unless (and (vectorp tags)
                     (cl-every #'stringp (append tags nil)))
          (error "Annotation field tags must be an array of strings"))))
    (when (diffs--review-json-field-present-p object "confidence")
      (let ((confidence
             (diffs--review-json-value object "confidence")))
        (unless (and (numberp confidence)
                     (<= 0 confidence) (<= confidence 1))
          (error "Annotation field confidence must be between 0 and 1"))))
    (unless (cl-some
             (lambda (field)
               (diffs--review-json-field-present-p object field))
             '("oldRange" "newRange"))
      (error "Each review annotation requires a target range"))
    (let ((old-range
           (diffs--review-normalize-json-range
            (diffs--review-json-value object "oldRange")))
          (new-range
           (diffs--review-normalize-json-range
            (diffs--review-json-value object "newRange"))))
      (when section
        (when (and old-range
                   (not
                    (diffs--review-range-in-section-p
                     section 'old old-range)))
          (error "Old annotation target is outside the current diff for %s"
                 file))
        (when (and new-range
                   (not
                    (diffs--review-range-in-section-p
                     section 'new new-range)))
          (error "New annotation target is outside the current diff for %s"
                 file)))
      (list
       :id (or (diffs--review-json-value object "id")
               (diffs--review-new-id))
       :file (if section (plist-get section :file) file)
       :old-range old-range
       :new-range new-range
       :summary summary
       :rationale (diffs--review-json-value object "rationale")
       :author (diffs--review-json-value object "author")
       :source (or (diffs--review-json-value object "source")
                   source "agent-context")
       :tags (append (diffs--review-json-value object "tags") nil)
       :confidence (diffs--review-json-value object "confidence")
       :created-at (diffs--review-json-value object "createdAt")
       :updated-at (diffs--review-json-value object "updatedAt")))))

(defun diffs--review-parse-sidecar (json owner)
  "Parse Hunk-compatible sidecar JSON for review OWNER."
  (let* ((root
          (json-parse-string
           json :object-type 'alist :array-type 'array
           :null-object :null :false-object :false))
         (files (diffs--review-json-value root "files"))
         annotations)
    (diffs--review-validate-json-object
     root diffs--review-sidecar-root-fields "review sidecar" t)
    (unless (and (integerp (diffs--review-json-value root "version"))
                 (= (diffs--review-json-value root "version") 1))
      (error "Review sidecar version must be 1"))
    (diffs--review-validate-optional-string root "summary" "sidecar")
    (unless (vectorp files)
      (error "Review sidecar files must be an array"))
    (dolist (file (append files nil))
      (diffs--review-validate-json-object
       file diffs--review-sidecar-file-fields "sidecar file" t)
      (let* ((path (diffs--review-json-value file "path"))
             (items (diffs--review-json-value file "annotations"))
             (section
              (and (stringp path)
                   (diffs--review-section-for-file owner path))))
        (unless (and (stringp path) (not (string-empty-p path)))
          (error "Review sidecar file entries require a path"))
        (unless section
          (error "No current diff file matches %s" path))
        (unless (vectorp items)
          (error "Sidecar file annotations must be an array"))
        (dolist (annotation (append items nil))
          (push
           (diffs--review-parse-annotation
            path annotation "agent-context" section)
           annotations))))
    (nreverse annotations)))

(defun diffs--review-annotation-json-object (annotation)
  "Return an alist JSON object for ANNOTATION."
  (delq
   nil
   (list
    (cons "id" (plist-get annotation :id))
    (and (plist-get annotation :old-range)
         (cons "oldRange"
               (vconcat (plist-get annotation :old-range))))
    (and (plist-get annotation :new-range)
         (cons "newRange"
               (vconcat (plist-get annotation :new-range))))
    (cons "summary" (plist-get annotation :summary))
    (and (plist-get annotation :rationale)
         (cons "rationale" (plist-get annotation :rationale)))
    (and (plist-get annotation :author)
         (cons "author" (plist-get annotation :author)))
    (and (plist-get annotation :source)
         (cons "source" (plist-get annotation :source)))
    (and (plist-get annotation :tags)
         (cons "tags" (vconcat (plist-get annotation :tags))))
    (and (plist-get annotation :confidence)
         (cons "confidence" (plist-get annotation :confidence)))
    (and (plist-get annotation :created-at)
         (cons "createdAt" (plist-get annotation :created-at)))
    (and (plist-get annotation :updated-at)
         (cons "updatedAt" (plist-get annotation :updated-at))))))

(defun diffs-review-sidecar-json ()
  "Return Hunk-compatible JSON for the current review annotations."
  (let ((owner (diffs--review-owner-buffer)))
    (unless (buffer-live-p owner)
      (user-error "Not in a diffs review view"))
    (with-current-buffer owner
      (let (files)
        (dolist (section diffs--sections)
          (let* ((path (plist-get section :file))
                 (annotations
                  (cl-remove-if-not
                   (lambda (annotation)
                     (equal path (plist-get annotation :file)))
                   diffs--review-annotations)))
            (when annotations
              (push
               (list
                (cons "path" path)
                (cons
                 "annotations"
                 (vconcat
                  (mapcar #'diffs--review-annotation-json-object
                          annotations))))
               files))))
        (diffs--review-json-serialize
         (list
          (cons "version" 1)
          (cons "summary" "Review annotations exported by diffs.el")
          (cons "files" (vconcat (nreverse files)))))))))

(defun diffs-review-export (file)
  "Export review annotations to Hunk-compatible JSON FILE."
  (interactive "FExport review JSON: ")
  (write-region
   (concat (diffs-review-sidecar-json) "\n")
   nil file nil 'silent)
  (message "Exported review annotations to %s" file))

(defun diffs-review-import (file &optional append)
  "Import Hunk-compatible annotations from FILE.
With prefix argument APPEND, retain existing annotations."
  (interactive (list (read-file-name "Import review JSON: ") current-prefix-arg))
  (let ((owner (diffs--review-owner-buffer)))
    (unless (buffer-live-p owner)
      (user-error "Not in a diffs review view"))
    (let ((annotations
           (diffs--review-parse-sidecar
            (with-temp-buffer
              (insert-file-contents file)
              (buffer-string))
            owner)))
      (dolist (annotation annotations)
        (diffs--review-annotation-display annotation))
      (diffs--review-replace-annotations
       owner
       (if append
           (append
            (buffer-local-value 'diffs--review-annotations owner)
            annotations)
         annotations))
      (message "Imported %d review annotations" (length annotations))
      annotations)))

(defun diffs--review-live-owners ()
  "Return all live unified review owner buffers."
  (cl-remove-if-not
   (lambda (buffer)
     (buffer-local-value 'diffs-minor-mode buffer))
   (buffer-list)))

(defun diffs--review-owner-matches-selector-p (owner selector)
  "Return non-nil when OWNER matches session SELECTOR.
SELECTOR may be a session id, repository, or working directory."
  (with-current-buffer owner
    (diffs--review-ensure-session-state)
    (or (null selector)
        (equal selector diffs--review-session-id)
        (let ((target
               (diffs--review-normalize-directory selector)))
          (or (equal target
                     (diffs--review-normalize-directory
                      default-directory))
              (equal target diffs--review-repository))))))

(defun diffs--review-resolve-owner (&optional selector)
  "Return the live unified review owner matching SELECTOR.
SELECTOR may be a session id, repository, or working directory.  The
current review is preferred when it matches.  Signal an error rather
than choosing silently when multiple sessions match."
  (let ((current (diffs--review-owner-buffer)))
    (if (and current
             (diffs--review-owner-matches-selector-p
              current selector))
        current
      (let ((matches
             (cl-remove-if-not
              (lambda (owner)
                (diffs--review-owner-matches-selector-p
                 owner selector))
              (diffs--review-live-owners))))
        (pcase matches
          (`(,owner) owner)
          ('nil
           (user-error "No live diffs review matches %s"
                       (or selector "the current context")))
          (_
           (user-error
            "Multiple live diffs reviews match %s; use a session id"
            (or selector "the current context"))))))))

(defun diffs--review-session-json-object (owner)
  "Return compact live-session JSON metadata for OWNER."
  (with-current-buffer owner
    (diffs--review-ensure-session-state)
    (delq
     nil
     (list
      (cons "id" diffs--review-session-id)
      (cons "buffer" (buffer-name))
      (cons "directory" (expand-file-name default-directory))
      (cons "repository" diffs--review-repository)
      (and diffs--revision
           (cons "revision" diffs--revision))
      (cons "files" (length diffs--sections))
      (cons "annotations" (length diffs--review-annotations))
      (cons "decisions" (length diffs--review-decisions))
      (and diffs--review-selection
           (cons
            "selection"
            (list
             (cons "filePath"
                   (plist-get diffs--review-selection :file))
             (cons "side"
                   (symbol-name
                    (plist-get diffs--review-selection :side)))
             (cons
              "range"
              (vector
               (plist-get diffs--review-selection :start)
               (plist-get diffs--review-selection :end))))))))))

(defun diffs-review-sessions-json ()
  "Return compact JSON describing all live diffs review sessions."
  (diffs--review-json-serialize
   (vconcat
    (mapcar
     #'diffs--review-session-json-object
     (diffs--review-live-owners)))))

(defun diffs--review-comment-type (type)
  "Normalize and validate comment TYPE."
  (let ((type
         (cond
          ((null type) 'all)
          ((symbolp type) type)
          ((stringp type) (intern type))
          (t (user-error "Invalid review comment type %S" type)))))
    (unless (memq type '(all user agent))
      (user-error "Comment type must be all, user, or agent"))
    type))

(defun diffs--review-comment-matches-p (annotation type file)
  "Return non-nil when ANNOTATION matches TYPE and FILE."
  (and
   (or (null file)
       (equal file (plist-get annotation :file)))
   (pcase (diffs--review-comment-type type)
     ('all t)
     ('user
      (equal "user" (plist-get annotation :source)))
     ('agent
      (not (equal "user" (plist-get annotation :source)))))))

(defun diffs--review-comment-json-object (annotation)
  "Return machine-readable comment JSON for ANNOTATION."
  (append
   (list (cons "filePath" (plist-get annotation :file)))
   (diffs--review-annotation-json-object annotation)))

(defun diffs-review-comments-json (&optional selector type file)
  "Return comments from the live review selected by SELECTOR.
TYPE is all, user, or agent.  FILE optionally limits the result to one
current file path."
  (let ((owner (diffs--review-resolve-owner selector)))
    (with-current-buffer owner
      (let ((comments
             (cl-remove-if-not
              (lambda (annotation)
                (diffs--review-comment-matches-p
                 annotation type file))
              diffs--review-annotations)))
        (diffs--review-json-serialize
         (list
          (cons "version" 1)
          (cons "sessionId" diffs--review-session-id)
          (cons
           "comments"
           (vconcat
            (mapcar #'diffs--review-comment-json-object
                    comments)))))))))

(defun diffs-review-remove-comment-json (selector id)
  "Remove comment ID from the live review selected by SELECTOR.
Return a machine-readable result."
  (let ((owner (diffs--review-resolve-owner selector)))
    (unless (diffs--review-remove-annotation owner id)
      (user-error "No annotation matches %s" id))
    (with-current-buffer owner
      (diffs--review-json-serialize
       (list
        (cons "sessionId" diffs--review-session-id)
        (cons "removed" id))))))

(defun diffs-review-clear-comments-json
    (&optional selector file type)
  "Clear comments from the live review selected by SELECTOR.
FILE optionally limits the current file path and TYPE is all, user, or
agent.  Return a machine-readable result."
  (let ((owner (diffs--review-resolve-owner selector))
        removed retained)
    (dolist
        (annotation
         (buffer-local-value 'diffs--review-annotations owner))
      (if (diffs--review-comment-matches-p annotation type file)
          (push (plist-get annotation :id) removed)
        (push annotation retained)))
    (setq retained (nreverse retained))
    (diffs--review-replace-annotations owner retained)
    (with-current-buffer owner
      (diffs--review-json-serialize
       (list
        (cons "sessionId" diffs--review-session-id)
        (cons "removed" (vconcat (nreverse removed))))))))

(defun diffs--review-hunk-json-object (hunk)
  "Return compact JSON metadata for HUNK."
  (let ((old-count (nth 5 hunk))
        (new-count (nth 6 hunk)))
    (delq
     nil
     (list
      (cons "oldCount" old-count)
      (cons "newCount" new-count)
      (and
       (> old-count 0)
       (cons
        "oldRange"
        (vector (nth 1 hunk)
                (1- (+ (nth 1 hunk) old-count)))))
      (and
       (> new-count 0)
       (cons
        "newRange"
        (vector (nth 2 hunk)
                (1- (+ (nth 2 hunk) new-count)))))
      (cons "context" (or (nth 4 hunk) ""))))))

(defun diffs--review-decision-json-object (decision)
  "Return compact machine-readable JSON for DECISION."
  (list
   (cons "id"
         (substring
          (secure-hash
           'sha1
           (prin1-to-string (plist-get decision :key)))
          0 16))
   (cons "action" (symbol-name (plist-get decision :action)))
   (cons "applied"
         (if (plist-get decision :applied) t :false))
   (cons "oldStart" (plist-get decision :old-start))
   (cons "oldCount" (length (plist-get decision :old-lines)))
   (cons "newStart" (plist-get decision :new-start))
   (cons "newCount" (length (plist-get decision :new-lines)))))

(defun diffs-review-json
    (&optional selector include-patch include-notes)
  "Return machine-readable JSON for a live diffs review.
SELECTOR is a session id, repository, or working directory.
INCLUDE-PATCH includes unified patch text; INCLUDE-NOTES includes
annotations."
  (let ((owner (diffs--review-resolve-owner selector)))
    (with-current-buffer owner
      (let (files)
        (dolist (section diffs--sections)
          (let ((path (plist-get section :file))
                object)
            (setq object
                  (list
                   (cons "path" path)
                   (cons "previousPath" (plist-get section :old-file))
                   (cons "additions" (plist-get section :adds))
                   (cons "deletions" (plist-get section :dels))
                   (cons
                    "decisions"
                    (vconcat
                     (mapcar
                      (lambda (entry)
                        (diffs--review-decision-json-object
                         (cdr entry)))
                      (cl-remove-if-not
                       (lambda (entry)
                         (equal path
                                (plist-get (cdr entry) :file)))
                       diffs--review-decisions))))
                   (cons
                    "hunks"
                    (vconcat
                     (mapcar #'diffs--review-hunk-json-object
                             (plist-get section :hunks))))))
            (when include-patch
              (setq object
                    (append
                     object
                     (list
                      (cons
                       "patch"
                       (buffer-substring-no-properties
                        (plist-get section :beg)
                        (plist-get section :end)))))))
            (when include-notes
              (setq object
                    (append
                     object
                     (list
                      (cons
                       "annotations"
                       (vconcat
                        (mapcar
                         #'diffs--review-annotation-json-object
                         (cl-remove-if-not
                          (lambda (annotation)
                            (equal path
                                   (plist-get annotation :file)))
                          diffs--review-annotations))))))))
            (push object files)))
        (diffs--review-json-serialize
         (delq
          nil
          (list
           (cons "version" 1)
           (cons "id" diffs--review-session-id)
           (cons "buffer" (buffer-name))
           (cons "directory" (expand-file-name default-directory))
           (cons "repository" diffs--review-repository)
           (cons "files" (vconcat (nreverse files)))
           (and diffs--review-selection
                (cons
                 "selection"
                 (list
                  (cons "filePath"
                        (plist-get diffs--review-selection :file))
                  (cons "side"
                        (symbol-name
                         (plist-get diffs--review-selection :side)))
                  (cons
                   "range"
                   (vector
                    (plist-get diffs--review-selection :start)
                    (plist-get diffs--review-selection :end)))))))))))))

(defun diffs-review-write-json
    (file &optional selector include-patch include-notes)
  "Write a live review snapshot to FILE.
SELECTOR, INCLUDE-PATCH, and INCLUDE-NOTES are passed to
`diffs-review-json'."
  (write-region
   (concat
    (diffs-review-json selector include-patch include-notes)
    "\n")
   nil file nil 'silent)
  file)

(defun diffs--review-section-for-file (owner file)
  "Return OWNER's section matching current or previous FILE."
  (with-current-buffer owner
    (cl-find-if
     (lambda (section)
       (or (equal file (plist-get section :file))
           (equal file (plist-get section :old-file))))
     diffs--sections)))

(defun diffs--review-hunk-comment-target (section number)
  "Return a stable target for one-based hunk NUMBER in SECTION."
  (unless (and (integerp number) (> number 0))
    (error "Hunk targets must use positive one-based numbers"))
  (let ((hunk (nth (1- number) (plist-get section :hunks))))
    (unless hunk
      (error "No hunk %d exists in %s"
             number (plist-get section :file)))
    (let ((old-line (nth 1 hunk))
          (new-line (nth 2 hunk))
          (end (diffs--hunk-end hunk section))
          first-old)
      (save-excursion
        (goto-char (car hunk))
        (forward-line 1)
        (catch 'target
          (while (and (< (point) end) (not (eobp)))
            (pcase (char-after)
              (?+
               (throw 'target (list 'new new-line new-line)))
              (?-
               (unless first-old
                 (setq first-old old-line))))
            (when (memq (char-after) '(?- ?\s ?\n))
              (cl-incf old-line))
            (when (memq (char-after) '(?+ ?\s ?\n))
              (cl-incf new-line))
            (forward-line 1))
          (if first-old
              (list 'old first-old first-old)
            (list 'new (nth 2 hunk) (nth 2 hunk))))))))

(defun diffs--review-range-in-section-p (section side range)
  "Return non-nil when SECTION contains SIDE RANGE in one hunk."
  (cl-some
   (lambda (hunk)
     (let* ((start (if (eq side 'old) (nth 1 hunk) (nth 2 hunk)))
            (count (if (eq side 'old) (nth 5 hunk) (nth 6 hunk)))
            (end (1- (+ start count))))
       (and (> count 0)
            (<= start (car range))
            (<= (cadr range) end))))
   (plist-get section :hunks)))

(defconst diffs--review-comment-fields
  '("filePath" "summary" "rationale" "author"
    "oldLine" "newLine" "oldRange" "newRange"
    "hunk" "hunkNumber")
  "Accepted fields in one Agent comment object.")

(defun diffs--review-validate-json-object
    (object allowed context &optional ignore-unknown)
  "Validate OBJECT keys against ALLOWED fields for CONTEXT.
When IGNORE-UNKNOWN is non-nil, permit fields outside ALLOWED."
  (unless (listp object)
    (error "%s must be a JSON object" context))
  (let (seen)
    (dolist (entry object)
      (unless (and (consp entry)
                   (or (stringp (car entry)) (symbolp (car entry))))
        (error "%s must be a JSON object" context))
      (let ((key (if (symbolp (car entry))
                     (symbol-name (car entry))
                   (car entry))))
        (unless (or ignore-unknown (member key allowed))
          (error "Unknown %s field %s" context key))
        (when (member key allowed)
          (when (member key seen)
            (error "Duplicate %s field %s" context key))
          (push key seen))))))

(defun diffs--review-json-field-present-p (object key)
  "Return non-nil when JSON OBJECT contains KEY."
  (or (assoc key object) (assq (intern key) object)))

(defun diffs--review-validate-comment-schema (comment)
  "Validate every supported field in Agent COMMENT."
  (diffs--review-validate-json-object
   comment diffs--review-comment-fields "comment")
  (dolist (field '("filePath" "summary"))
    (let ((value (diffs--review-json-value comment field)))
      (unless (and (stringp value) (not (string-empty-p value)))
        (error "Comment field %s must be a non-empty string" field))))
  (dolist (field '("rationale" "author"))
    (when (diffs--review-json-field-present-p comment field)
      (unless (stringp (diffs--review-json-value comment field))
        (error "Comment field %s must be a string" field))))
  (dolist (field '("oldLine" "newLine" "hunk" "hunkNumber"))
    (when (diffs--review-json-field-present-p comment field)
      (let ((value (diffs--review-json-value comment field)))
        (unless (and (integerp value) (> value 0))
          (error "Comment field %s must be a positive integer" field)))))
  (dolist (field '("oldRange" "newRange"))
    (when (diffs--review-json-field-present-p comment field)
      (diffs--review-normalize-json-range
       (diffs--review-json-value comment field))))
  (let ((targets
         (cl-count-if
          (lambda (field)
            (diffs--review-json-field-present-p comment field))
          '("oldLine" "newLine" "oldRange" "newRange"
            "hunk" "hunkNumber"))))
    (unless (= targets 1)
      (error "Each comment requires exactly one line, range, or hunk target"))))

(defun diffs--review-parse-comment-batch (owner json)
  "Validate agent comment batch JSON for OWNER."
  (let* ((root
          (json-parse-string
           json :object-type 'alist :array-type 'array
           :null-object :null :false-object :false))
         (comments (diffs--review-json-value root "comments"))
         annotations)
    (diffs--review-validate-json-object root '("comments") "comment batch")
    (unless (and (vectorp comments) (> (length comments) 0))
      (error "Comment batch requires a non-empty comments array"))
    (setq comments (append comments nil))
    (dolist (comment comments)
      (diffs--review-validate-comment-schema comment))
    (dolist (comment comments)
      (let* ((file (diffs--review-json-value comment "filePath"))
             (summary (diffs--review-json-value comment "summary"))
             (section
              (and (stringp file)
                   (diffs--review-section-for-file owner file)))
             (old-line (diffs--review-json-value comment "oldLine"))
             (new-line (diffs--review-json-value comment "newLine"))
             (old-range-value
              (diffs--review-json-value comment "oldRange"))
             (new-range-value
              (diffs--review-json-value comment "newRange"))
             (hunk-number
              (or (diffs--review-json-value comment "hunk")
                  (diffs--review-json-value comment "hunkNumber")))
             old-range new-range)
        (unless section
          (error "No diff file matches %s" file))
        (cond
         (old-line
          (setq old-range (diffs--review-range old-line old-line)))
         (new-line
          (setq new-range (diffs--review-range new-line new-line)))
         (old-range-value
          (setq old-range
                (diffs--review-normalize-json-range old-range-value)))
         (new-range-value
          (setq new-range
                (diffs--review-normalize-json-range new-range-value)))
         (hunk-number
         (pcase (with-current-buffer owner
                   (diffs--review-hunk-comment-target
                    section hunk-number))
            (`(old ,start ,end)
             (setq old-range (list start end)))
            (`(new ,start ,end)
             (setq new-range (list start end))))))
        (unless
            (if old-range
                (diffs--review-range-in-section-p
                 section 'old old-range)
              (diffs--review-range-in-section-p
               section 'new new-range))
          (error "Comment target is outside a visible diff hunk in %s"
                 file))
        (push
         (list
          :id (diffs--review-new-id)
          :file (plist-get section :file)
          :old-range old-range
          :new-range new-range
          :summary summary
          :rationale (diffs--review-json-value comment "rationale")
          :author (diffs--review-json-value comment "author")
          :source "agent"
          :created-at (format-time-string "%FT%TZ" nil t))
         annotations)))
    (nreverse annotations)))

(defun diffs-review-apply-comments-json
    (json &optional selector focus)
  "Atomically apply agent comments from JSON.
SELECTOR is a session id, repository, or working directory.  When
FOCUS is non-nil, navigate to the first applied comment."
  (let* ((owner (diffs--review-resolve-owner selector))
         (annotations
          (diffs--review-parse-comment-batch owner json))
         (before
          (buffer-local-value 'diffs--review-annotations owner))
         (result
          (diffs--review-json-serialize
           (list
            (cons
             "sessionId"
             (buffer-local-value 'diffs--review-session-id owner))
            (cons
             "applied"
             (vconcat
              (mapcar
               (lambda (annotation)
                 (list
                  (cons "id" (plist-get annotation :id))
                  (cons "filePath" (plist-get annotation :file))))
               annotations)))))))
    ;; Validate display data before changing the live review.  Keep the
    ;; rollback below because projection can still fail at a UI boundary.
    (dolist (annotation annotations)
      (diffs--review-annotation-display annotation))
    (condition-case error-data
        (progn
          (with-current-buffer owner
            (setq diffs--review-annotations
                  (append diffs--review-annotations annotations)))
          (diffs--review-refresh-overlays owner)
          (when focus
            (diffs--review-goto-annotation owner (car annotations)))
          result)
      (error
       (with-current-buffer owner
         (setq diffs--review-annotations before))
       (condition-case nil
           (diffs--review-refresh-overlays owner)
         (error nil))
       (signal (car error-data) (cdr error-data))))))

(defun diffs-review-apply-comments-file
    (file &optional selector focus)
  "Atomically apply agent comments from JSON FILE.
SELECTOR is a session id, repository, or working directory.  FOCUS
navigates to the first applied comment."
  (diffs-review-apply-comments-json
   (with-temp-buffer
     (insert-file-contents file)
     (buffer-string))
   selector focus))

(defconst diffs--review-cli-launcher
  "#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- \"$(dirname -- \"$0\")\" && pwd)
exec \"${EMACS:-emacs}\" -Q --script \"$script_dir/diffs-cli.el\" -- \"$@\"
"
  "Shell launcher installed for the live diffs review CLI.")

(defun diffs--review-file-contents (file)
  "Return FILE contents without decoding or text properties."
  (with-temp-buffer
    (let ((coding-system-for-read 'no-conversion))
      (insert-file-contents file))
    (buffer-string)))

(defun diffs--review-write-asset (file contents &optional executable)
  "Atomically write CONTENTS to FILE when they differ.
When EXECUTABLE is non-nil, also make FILE executable.  Return FILE."
  (make-directory (file-name-directory file) t)
  (unless (and (file-regular-p file)
               (equal contents (diffs--review-file-contents file)))
    (let ((temporary
           (make-temp-file
            (expand-file-name ".diffs-asset-" (file-name-directory file)))))
      (unwind-protect
          (progn
            (let ((coding-system-for-write 'no-conversion))
              (write-region contents nil temporary nil 'silent))
            (set-file-modes temporary (if executable #o755 #o644))
            (rename-file temporary file t))
        (when (file-exists-p temporary)
          (delete-file temporary)))))
  (when executable
    (set-file-modes file #o755))
  file)

(defun diffs--review-packaged-library (library)
  "Return the exact source file for packaged Elisp LIBRARY."
  (or (locate-library (concat library ".el") t)
      (user-error
       "The installed diffs package is missing %s.el; reinstall it"
       library)))

;;;###autoload
(defun diffs-review-skill-path ()
  "Return and display a durable path to the agent review skill."
  (interactive)
  (require 'diffs-assets)
  (let* ((library (or (locate-library "diffs")
                      (user-error "Cannot locate diffs.el")))
         (bundled
          (expand-file-name
           "skills/diffs-review/SKILL.md"
           (file-name-directory library)))
         (path
          (if (file-regular-p bundled)
              bundled
            (diffs--review-write-asset
             (expand-file-name
              "skills/diffs-review/SKILL.md"
              diffs-review-assets-directory)
             diffs--review-skill-content))))
    (when (called-interactively-p 'interactive)
      (kill-new path)
      (message "Copied diffs review skill path: %s" path))
    path))

;;;###autoload
(defun diffs-review-cli-path ()
  "Return and display a durable path to the live review CLI."
  (interactive)
  (let* ((directory
          (expand-file-name "bin/" diffs-review-assets-directory))
         (cli-library (diffs--review-packaged-library "diffs-cli"))
         (script
          (diffs--review-write-asset
           (expand-file-name "diffs-cli.el" directory)
           (diffs--review-file-contents cli-library)))
         (path
          (diffs--review-write-asset
           (expand-file-name "diffs" directory)
           diffs--review-cli-launcher t)))
    (ignore script)
    (when (called-interactively-p 'interactive)
      (kill-new path)
      (message "Copied diffs live-session CLI path: %s" path))
    path))

(defun diffs--review-install-parent-valid-p (target)
  "Validate the nearest existing parent directory of TARGET."
  (let ((directory (file-name-directory target)))
    (while (and directory
                (not (file-exists-p directory))
                (not (file-symlink-p directory)))
      (setq directory
            (file-name-directory (directory-file-name directory))))
    (unless (and directory (file-directory-p directory))
      (user-error "Install parent is not a directory for %s" target)))
  t)

(defun diffs--review-install-file-state (target &optional absent)
  "Return restorable state for TARGET, or absent state when ABSENT."
  (cond
   (absent (list :kind 'absent))
   ((file-symlink-p target)
    (list :kind 'symlink :link (file-symlink-p target)))
   ((file-regular-p target)
    (list :kind 'file
          :contents (diffs--review-file-contents target)
          :mode (file-modes target)))
   ((file-exists-p target)
    (user-error "Refusing to replace non-regular file %s" target))
   (t (list :kind 'absent))))

(defun diffs--review-install-file-plan
    (source target overwrite executable &optional assume-absent)
  "Preflight installing SOURCE at TARGET and return a write plan.
OVERWRITE allows replacement, EXECUTABLE requests executable mode, and
ASSUME-ABSENT ignores a target currently reached through a directory
that the transaction will replace."
  (unless (file-regular-p source)
    (user-error "Install source is missing: %s" source))
  (unless assume-absent
    (diffs--review-install-parent-valid-p target))
  (let* ((contents (diffs--review-file-contents source))
         (state (diffs--review-install-file-state target assume-absent))
         (kind (plist-get state :kind)))
    (when (and (eq kind 'symlink) (not overwrite))
      (user-error
       "%s is a symbolic link; use a prefix argument to replace it"
       target))
    (when (and (eq kind 'file)
               (not overwrite)
               (not (equal contents (plist-get state :contents))))
      (user-error "%s already exists; use a prefix argument to replace it"
                  target))
    (list :target target :contents contents :executable executable
          :state state :assume-absent assume-absent)))

(defun diffs--review-install-directory-state (directory overwrite)
  "Preflight install DIRECTORY and return its restorable state.
OVERWRITE permits replacing a symbolic link, never a real file."
  (let ((target (directory-file-name directory)))
    (diffs--review-install-parent-valid-p target)
    (cond
     ((file-symlink-p target)
      (unless overwrite
        (user-error
         "%s is a symbolic link; use a prefix argument to replace it"
         target))
      (list :kind 'symlink :link (file-symlink-p target)))
     ((file-directory-p target) (list :kind 'directory))
     ((file-exists-p target)
      (user-error "Refusing to replace existing file %s" target))
     (t (list :kind 'absent)))))

(defun diffs--review-install-write-plan (plan)
  "Apply one preflighted file PLAN."
  (let ((target (plist-get plan :target)))
    (when (file-symlink-p target)
      (delete-file target))
    (diffs--review-write-asset
     target
     (plist-get plan :contents)
     (plist-get plan :executable))))

(defun diffs--review-install-remove-file (file)
  "Remove FILE when it is a non-directory install target."
  (cond
   ((file-symlink-p file) (delete-file file))
   ((and (file-exists-p file) (not (file-directory-p file)))
    (delete-file file))))

(defun diffs--review-install-restore-file (plan)
  "Restore the original target recorded in file PLAN."
  (let* ((target (plist-get plan :target))
         (state (plist-get plan :state)))
    (diffs--review-install-remove-file target)
    (pcase (plist-get state :kind)
      ('file
       (diffs--review-write-asset
        target (plist-get state :contents))
       (set-file-modes target (plist-get state :mode)))
      ('symlink
       (make-directory (file-name-directory target) t)
       (make-symbolic-link (plist-get state :link) target))
      ('absent nil))))

(defun diffs--review-install-missing-directories (targets)
  "Return missing parent directories needed by TARGETS, deepest first."
  (let (directories)
    (dolist (target targets)
      (let ((directory (file-name-directory target)))
        (while (and directory
                    (not (file-exists-p directory))
                    (not (file-symlink-p directory)))
          (push directory directories)
          (setq directory
                (file-name-directory
                 (directory-file-name directory))))))
    (sort (delete-dups directories)
          (lambda (left right) (> (length left) (length right))))))

(defun diffs--review-install-restore-directory (directory state)
  "Restore install DIRECTORY from STATE."
  (let ((target (directory-file-name directory))
        (kind (plist-get state :kind))
        (current-link
         (file-symlink-p (directory-file-name directory))))
    (pcase kind
      ('directory nil)
      ('absent
       (cond
        (current-link (delete-file target))
        ((file-directory-p directory) (delete-directory directory))))
      ('symlink
       (unless (and current-link
                    (equal current-link (plist-get state :link)))
         (cond
          (current-link (delete-file target))
          ((file-directory-p directory) (delete-directory directory)))
         (make-symbolic-link (plist-get state :link) target))))))

(defun diffs--review-install-rollback
    (plans skill-directory skill-state missing-directories)
  "Roll back installation PLANS and SKILL-DIRECTORY from SKILL-STATE.
Then remove MISSING-DIRECTORIES that the failed transaction created."
  (let (failure)
    (dolist (plan (reverse plans))
      (condition-case error-data
          (diffs--review-install-restore-file plan)
        (error (unless failure (setq failure error-data)))))
    (condition-case error-data
        (diffs--review-install-restore-directory
         skill-directory skill-state)
      (error (unless failure (setq failure error-data))))
    (dolist (directory missing-directories)
      (condition-case error-data
          (when (file-directory-p directory)
            (delete-directory directory))
        (error (unless failure (setq failure error-data)))))
    (when failure
      (display-warning
       'diffs
       (format "Agent tool install rollback was incomplete: %s"
               (error-message-string failure))
       :error))))

;;;###autoload
(defun diffs-review-install-agent-tools (&optional overwrite)
  "Install durable copies of the live review CLI and Codex skill.
With prefix argument OVERWRITE, replace existing files or symbolic
links.  Real directories are retained and never replaced."
  (interactive "P")
  (let* ((cli (diffs-review-cli-path))
         (cli-library
          (expand-file-name "diffs-cli.el" (file-name-directory cli)))
         (skill-file (diffs-review-skill-path))
         (skill-directory
          (file-name-as-directory
           (expand-file-name diffs-review-skill-install-directory)))
         (installed-cli
          (expand-file-name diffs-review-cli-install-path))
         (installed-cli-library
          (expand-file-name
           "diffs-cli.el"
           (file-name-directory installed-cli)))
         (installed-skill
          (expand-file-name
           "SKILL.md" skill-directory))
         (targets
          (list installed-cli installed-cli-library installed-skill)))
    (unless (= (length targets)
               (length (delete-dups (copy-sequence targets))))
      (user-error "Agent tool install targets must be distinct"))
    (let* ((skill-state
            (diffs--review-install-directory-state
             skill-directory overwrite))
           (replace-skill-directory
            (memq (plist-get skill-state :kind) '(symlink absent)))
           (plans
            (list
             (diffs--review-install-file-plan
              cli installed-cli overwrite t)
             (diffs--review-install-file-plan
              cli-library installed-cli-library overwrite nil)
             (diffs--review-install-file-plan
              skill-file installed-skill overwrite nil
              replace-skill-directory)))
           (missing-directories
            (diffs--review-install-missing-directories
             (list installed-cli installed-cli-library
                   (directory-file-name skill-directory))))
           (directory-mutated nil))
      (condition-case error-data
          (progn
            (pcase (plist-get skill-state :kind)
              ('symlink
               (delete-file (directory-file-name skill-directory))
               (setq directory-mutated t)
               (make-directory skill-directory t))
              ('absent
               (make-directory skill-directory t)
               (setq directory-mutated t)))
            (dolist (plan plans)
              (diffs--review-install-write-plan plan)))
        (error
         ;; A future skill file plan must not follow an original
         ;; directory symlink unless that directory was replaced.
         (when (and replace-skill-directory (not directory-mutated))
           (setq plans (butlast plans)))
         (diffs--review-install-rollback
          plans skill-directory skill-state missing-directories)
         (signal (car error-data) (cdr error-data)))))
    (message "Installed diffs CLI at %s and skill at %s"
             installed-cli skill-directory)))

;;;; Merge-conflict resolution

(defvar-local diffs--conflict-blocks nil
  "Live merge-conflict blocks owned by the current source buffer.")

(defvar-local diffs--conflict-overlays nil
  "Presentation overlays owned by `diffs-conflict-mode'.")

(defvar-local diffs--conflict-current-id nil
  "Identity of the conflict selected for keyboard actions.")

(defvar-local diffs--conflict-saved-header-line-format nil
  "Header line in effect before `diffs-conflict-mode' was enabled.")

(defvar-local diffs--conflict-initial-text nil
  "Complete source text from when conflict resolution began.")

(defvar-local diffs--conflict-initial-modified nil
  "Whether the source buffer was modified when resolution began.")

(defvar-local diffs--conflict-saved-during-session nil
  "Non-nil when the source was saved during conflict resolution.")

(defvar-local diffs--conflict-changing nil
  "Non-nil while diffs.el is replacing one conflict block.")

(defvar-local diffs--conflict-refresh-pending nil
  "Non-nil when undo or redo needs one post-command reprojection.")

(defvar diffs--conflict-rendering-overlays nil
  "Overlays allocated by the current conflict rendering transaction.")

(defvar-keymap diffs--conflict-button-map
  ;; With `follow-link' non-nil, Emacs normally translates mouse-1 on a
  ;; link into mouse-2.  Own both events so the translated click cannot
  ;; fall through to the global mouse-2 primary-selection yank.
  "<mouse-1>" #'diffs-conflict-mouse-action
  "<mouse-2>" #'diffs-conflict-mouse-action)

(defvar-keymap diffs--conflict-command-map
  :doc "Commands used below the `C-c C-d' merge-conflict prefix."
  "c" #'diffs-conflict-current
  "i" #'diffs-conflict-incoming
  "b" #'diffs-conflict-both
  "u" #'diffs-conflict-reset
  "n" #'diffs-conflict-next
  "p" #'diffs-conflict-previous
  "q" #'diffs-conflict-quit)

(defvar-keymap diffs-conflict-mode-map
  :doc "Keymap for in-place merge-conflict resolution."
  "C-c C-d" diffs--conflict-command-map)

(defun diffs--conflict-line-after ()
  "Return the position immediately after the current physical line."
  (let ((end (line-end-position)))
    (if (< end (point-max)) (1+ end) end)))

(defun diffs--conflict-marker-at-line ()
  "Return merge-marker metadata for the current physical line.
The result is a plist containing `:kind', `:width', and `:label',
or nil when the line is not a merge marker."
  (let ((line
         (buffer-substring-no-properties
          (line-beginning-position) (line-end-position))))
    (cond
     ((string-match
       "\\`\\(<\\{7,\\}\\)\\(?:[ \t]+\\([^\r]*\\)\\)?\r?\\'" line)
      (list :kind 'start
            :width (length (match-string 1 line))
            :label (or (match-string 2 line) "")))
     ((string-match
       "\\`\\(|\\{7,\\}\\)\\(?:[ \t]+\\([^\r]*\\)\\)?\r?\\'" line)
      (list :kind 'base
            :width (length (match-string 1 line))
            :label (or (match-string 2 line) "")))
     ((string-match "\\`\\(=\\{7,\\}\\)[ \t]*\r?\\'" line)
      (list :kind 'separator
            :width (length (match-string 1 line))
            :label ""))
     ((string-match
       "\\`\\(>\\{7,\\}\\)\\(?:[ \t]+\\([^\r]*\\)\\)?\r?\\'" line)
      (list :kind 'end
            :width (length (match-string 1 line))
            :label (or (match-string 2 line) ""))))))

(defun diffs--conflict-check-marker-width (marker width)
  "Require MARKER to use conflict marker WIDTH."
  (unless (= (plist-get marker :width) width)
    (user-error "Merge marker width mismatch at line %d"
                (line-number-at-pos))))

(defun diffs--parse-conflict-block (id start-marker)
  "Parse conflict ID beginning at START-MARKER in the current buffer.
Point must be at the beginning marker.  Return an immutable block plist
and leave point immediately after its ending marker."
  (let* ((start (line-beginning-position))
         (width (plist-get start-marker :width))
         (start-end (diffs--conflict-line-after))
         (current-begin start-end)
         current-end
         base-marker-begin
         base-marker-end
         base-begin
         base-end
         base-label
         separator-begin
         separator-end
         incoming-begin
         incoming-end
         end-marker-begin
         end-marker-end
         incoming-label
         (phase 'current)
         done)
    (goto-char start-end)
    (while (and (not done) (< (point) (point-max)))
      (let* ((line-begin (line-beginning-position))
             (line-after (diffs--conflict-line-after))
             (marker (diffs--conflict-marker-at-line))
             (kind (plist-get marker :kind)))
        (pcase kind
          ('start
           (user-error "Nested merge conflict at line %d"
                       (line-number-at-pos)))
          ('base
           (diffs--conflict-check-marker-width marker width)
           (unless (eq phase 'current)
             (user-error "Unexpected Base marker at line %d"
                         (line-number-at-pos)))
           (setq current-end line-begin
                 base-marker-begin line-begin
                 base-marker-end line-after
                 base-begin line-after
                 base-label (plist-get marker :label)
                 phase 'base)
           (goto-char line-after))
          ('separator
           (diffs--conflict-check-marker-width marker width)
           (unless (memq phase '(current base))
             (user-error "Unexpected separator marker at line %d"
                         (line-number-at-pos)))
           (if (eq phase 'current)
               (setq current-end line-begin)
             (setq base-end line-begin))
           (setq separator-begin line-begin
                 separator-end line-after
                 incoming-begin line-after
                 phase 'incoming)
           (goto-char line-after))
          ('end
           (diffs--conflict-check-marker-width marker width)
           (unless (eq phase 'incoming)
             (user-error "Ending merge marker precedes its separator at line %d"
                         (line-number-at-pos)))
           (setq incoming-end line-begin
                 end-marker-begin line-begin
                 end-marker-end line-after
                 incoming-label (plist-get marker :label)
                 done t)
           (goto-char line-after))
          (_ (goto-char line-after)))))
    (unless done
      (user-error "Unterminated merge conflict beginning at line %d"
                  (line-number-at-pos start)))
    (let ((original
           (buffer-substring-no-properties start end-marker-end))
          (current
           (buffer-substring-no-properties current-begin current-end))
          (base
           (and base-begin
                (buffer-substring-no-properties base-begin base-end)))
          (incoming
           (buffer-substring-no-properties incoming-begin incoming-end)))
      (list
       :id id
       :begin start
       :end end-marker-end
       :original original
       :current current
       :base base
       :incoming incoming
       :current-label (plist-get start-marker :label)
       :base-label base-label
       :incoming-label incoming-label
       :start-marker-range (cons 0 (- start-end start))
       :current-range
       (cons (- current-begin start) (- current-end start))
       :base-marker-range
       (and base-marker-begin
            (cons (- base-marker-begin start)
                  (- base-marker-end start)))
       :base-range
       (and base-begin
            (cons (- base-begin start) (- base-end start)))
       :separator-range
       (cons (- separator-begin start) (- separator-end start))
       :incoming-range
       (cons (- incoming-begin start) (- incoming-end start))
       :end-marker-range
       (cons (- end-marker-begin start) (- end-marker-end start))))))

(defun diffs--conflict-standard-smerge-p (block)
  "Return non-nil when smerge can parse BLOCK without losing syntax.
Stock smerge accepts the standard seven-character marker form and
requires the closing marker to end in a newline.  Diffs.el's native
fallback deliberately retains support for wider markers and EOF
without a final newline."
  (let ((original (plist-get block :original)))
    (and (string-match-p "\\`<<<<<<< [^\n]*\n" original)
         (string-match-p "\n>>>>>>> [^\n]*\n\\'" original))))

(defun diffs--conflict-adopt-smerge-data (block)
  "Use smerge's match model for standard conflict BLOCK.
Return a copy tagged with `:engine' set to `smerge'.  Extended marker
forms remain unchanged for the native fallback."
  (if (not (diffs--conflict-standard-smerge-p block))
      block
    (save-excursion
      (goto-char (plist-get block :begin))
      (smerge-match-conflict)
      (let ((start (match-beginning 0))
            (end (match-end 0))
            (expected-start (plist-get block :begin))
            (expected-end (plist-get block :end))
            (current-begin (match-beginning 1))
            (current-end (match-end 1))
            (base-begin (match-beginning 2))
            (base-end (match-end 2))
            (incoming-begin (match-beginning 3))
            (incoming-end (match-end 3))
            (adopted (copy-tree block)))
        (unless (and (= start expected-start) (= end expected-end))
          (error "Smerge matched a different conflict range"))
        (setf (plist-get adopted :engine) 'smerge
              (plist-get adopted :current)
              (buffer-substring-no-properties current-begin current-end)
              (plist-get adopted :base)
              (and base-begin
                   (buffer-substring-no-properties base-begin base-end))
              (plist-get adopted :incoming)
              (buffer-substring-no-properties incoming-begin incoming-end)
              (plist-get adopted :current-range)
              (cons (- current-begin start) (- current-end start))
              (plist-get adopted :base-range)
              (and base-begin
                   (cons (- base-begin start) (- base-end start)))
              (plist-get adopted :incoming-range)
              (cons (- incoming-begin start) (- incoming-end start)))
        adopted))))

(defun diffs--parse-conflicts (text)
  "Parse every merge-conflict block in TEXT.
Return block plists with positions relative to a buffer containing TEXT.
Malformed, nested, and inconsistent markers signal `user-error'."
  (with-temp-buffer
    (insert text)
    (goto-char (point-min))
    (let ((id 0)
          stray-marker-line
          blocks)
      (while (< (point) (point-max))
        (let ((marker (diffs--conflict-marker-at-line)))
          (cond
           ((eq (plist-get marker :kind) 'start)
            (cl-incf id)
            (push
             (diffs--conflict-adopt-smerge-data
              (diffs--parse-conflict-block id marker))
             blocks))
           (marker
            (unless stray-marker-line
              (setq stray-marker-line (line-number-at-pos)))
            (forward-line 1))
           (t (forward-line 1)))))
      (when (and blocks stray-marker-line)
        (user-error "Unexpected merge marker at line %d"
                    stray-marker-line))
      (nreverse blocks))))

(defun diffs--conflict-live-block (block)
  "Return a source-buffer-owned live copy of parsed BLOCK."
  (let ((live (copy-tree block)))
    ;; These insertion types let replace/undo grow a collapsed range back
    ;; around its contents.  The after-change boundary guard moves ordinary
    ;; user insertions back outside the range.
    (setf (plist-get live :begin)
          (copy-marker (plist-get block :begin) nil)
          (plist-get live :end)
          (copy-marker (plist-get block :end) t)
          (plist-get live :choice) nil
          (plist-get live :expected) (plist-get block :original)
          (plist-get live :stale) nil)
    live))

(defun diffs--conflict-delete-overlays (overlays)
  "Delete every live overlay in OVERLAYS."
  (dolist (overlay overlays)
    (when (overlayp overlay)
      (delete-overlay overlay))))

(defun diffs--conflict-clear-state ()
  "Remove conflict presentation and release its source markers."
  (remove-hook 'after-change-functions #'diffs--conflict-after-change t)
  (remove-hook 'after-save-hook #'diffs--conflict-after-save t)
  (remove-hook 'post-command-hook #'diffs--conflict-post-command t)
  (remove-hook 'change-major-mode-hook #'diffs--conflict-clear-state t)
  (remove-hook 'before-revert-hook #'diffs--conflict-clear-state t)
  (diffs--conflict-delete-overlays diffs--conflict-overlays)
  (setq diffs--conflict-overlays nil)
  (when (or diffs--conflict-blocks
            diffs--conflict-initial-text
            diffs--conflict-saved-header-line-format)
    (setq header-line-format diffs--conflict-saved-header-line-format))
  (dolist (block diffs--conflict-blocks)
    (set-marker (plist-get block :begin) nil)
    (set-marker (plist-get block :end) nil))
  (setq diffs--conflict-blocks nil
        diffs--conflict-current-id nil
        diffs--conflict-initial-text nil
        diffs--conflict-initial-modified nil
        diffs--conflict-saved-during-session nil
        diffs--conflict-refresh-pending nil
        diffs--conflict-saved-header-line-format nil
        diffs-conflict-mode nil))

(defun diffs--conflict-setup ()
  "Parse the current source buffer and install conflict presentation."
  (when buffer-read-only
    (user-error "Cannot resolve conflicts in a read-only buffer"))
  (when (buffer-narrowed-p)
    (user-error "Widen the buffer before resolving merge conflicts"))
  (let* ((text
          (buffer-substring-no-properties (point-min) (point-max)))
         (parsed (diffs--parse-conflicts text)))
    (unless parsed
      (user-error "No merge conflicts in this buffer"))
    (setq diffs--conflict-saved-header-line-format header-line-format
          diffs--conflict-initial-text text
          diffs--conflict-initial-modified (buffer-modified-p)
          diffs--conflict-saved-during-session nil
          diffs--conflict-blocks
          (mapcar #'diffs--conflict-live-block parsed))
    (setq diffs--conflict-current-id
          (plist-get (car diffs--conflict-blocks) :id))
    (add-hook 'after-change-functions #'diffs--conflict-after-change nil t)
    (add-hook 'after-save-hook #'diffs--conflict-after-save nil t)
    (add-hook 'post-command-hook #'diffs--conflict-post-command nil t)
    (add-hook
     'change-major-mode-hook #'diffs--conflict-clear-state nil t)
    (add-hook 'before-revert-hook #'diffs--conflict-clear-state nil t)
    (diffs--define-fringe-bitmap)
    (diffs--conflict-refresh-overlays)))

(defun diffs--conflict-choice-text (block action)
  "Return BLOCK's replacement text for ACTION."
  (pcase action
    ('current (plist-get block :current))
    ('incoming (plist-get block :incoming))
    ('both
     (concat (plist-get block :current)
             (plist-get block :incoming)))
    ('reset (plist-get block :original))
    (_ (error "Unknown conflict action: %S" action))))

(defun diffs--conflict-choice-from-action (action)
  "Return the stored choice represented by ACTION."
  (unless (memq action '(current incoming both reset))
    (error "Unknown conflict action: %S" action))
  (unless (eq action 'reset) action))

(defun diffs--conflict-observed-choice (block actual)
  "Return BLOCK's choice matching ACTUAL, or `stale'."
  (let ((choice (plist-get block :choice))
        (expected (plist-get block :expected)))
    (cond
     ((equal actual expected) choice)
     ((equal actual (plist-get block :original)) nil)
     ((equal actual (plist-get block :current)) 'current)
     ((equal actual (plist-get block :incoming)) 'incoming)
     ((equal actual
             (concat (plist-get block :current)
                     (plist-get block :incoming)))
      'both)
     (t 'stale))))

(defun diffs--conflict-block-status (block)
  "Synchronize BLOCK with its live text and return its status."
  (let* ((begin (marker-position (plist-get block :begin)))
         (end (marker-position (plist-get block :end)))
         (actual
          (buffer-substring-no-properties begin end))
         (choice (diffs--conflict-observed-choice block actual)))
    (setf (plist-get block :stale) (eq choice 'stale))
    (unless (eq choice 'stale)
      (setf (plist-get block :choice) choice
            (plist-get block :expected) actual))
    choice))

(defun diffs--conflict-block-by-id (id)
  "Return the live conflict block identified by ID."
  (cl-find id diffs--conflict-blocks
           :key (lambda (block) (plist-get block :id))))

(defun diffs--conflict-block-contains-point-p (block)
  "Return non-nil when BLOCK contains point or owns its empty anchor."
  (let ((begin (marker-position (plist-get block :begin)))
        (end (marker-position (plist-get block :end))))
    (or (and (< begin end)
             (<= begin (point))
             (< (point) end))
        (= begin (point)))))

(defun diffs--conflict-block-at-point ()
  "Return the live conflict block containing point."
  (or
   (when-let* ((current
                (diffs--conflict-block-by-id
                 diffs--conflict-current-id))
               ((diffs--conflict-block-contains-point-p current)))
     current)
   (cl-loop
    for overlay in (overlays-at (point))
    for id = (overlay-get overlay 'diffs-conflict-id)
    when id return (diffs--conflict-block-by-id id))
   (cl-find-if
    #'diffs--conflict-block-contains-point-p
    diffs--conflict-blocks)
   (user-error "No merge conflict at point")))

(defun diffs--conflict-make-overlay
    (begin end face block &optional priority)
  "Create a conflict overlay from BEGIN to END with FACE for BLOCK.
PRIORITY defaults to a low underlay-like priority so language syntax
faces remain visible above section backgrounds."
  (let ((overlay (make-overlay begin end nil nil nil)))
    (overlay-put overlay 'face face)
    (overlay-put overlay 'priority (or priority -50))
    (overlay-put overlay 'evaporate nil)
    (overlay-put overlay 'diffs-conflict-id (plist-get block :id))
    (when-let* ((fringe-face
                 (pcase face
                   ((or 'diffs-conflict-current
                        'diffs-conflict-current-marker)
                    'diff-indicator-added)
                   ((or 'diffs-conflict-incoming
                        'diffs-conflict-incoming-marker)
                    'diff-indicator-changed)))
                (prefix (diffs--fringe-face-prefix fringe-face))
                ((not (string-empty-p prefix))))
      (overlay-put overlay 'line-prefix prefix))
    (push overlay diffs--conflict-rendering-overlays)
    overlay))

(defun diffs--conflict-paint-relative (block range face)
  "Paint BLOCK's relative RANGE with FACE."
  (when (and range (< (car range) (cdr range)))
    (let ((begin (marker-position (plist-get block :begin))))
      (diffs--conflict-make-overlay
       (+ begin (car range)) (+ begin (cdr range)) face block))))

(defun diffs--conflict-button (block action label disabled)
  "Return a LABEL button for BLOCK's ACTION.
When DISABLED is non-nil, return a non-interactive dimmed label."
  (if disabled
      (propertize label 'face 'shadow)
    (propertize
     label
     'face 'link
     'mouse-face 'highlight
     'help-echo (format "%s this conflict" label)
     'keymap diffs--conflict-button-map
     'follow-link t
     'diffs-conflict-id (plist-get block :id)
     'diffs-conflict-action action)))

(defun diffs--conflict-paint-marker
    (block range face description)
  "Paint BLOCK's marker RANGE with FACE and append DESCRIPTION visually."
  (when-let* ((overlay
               (diffs--conflict-paint-relative block range face)))
    (let* ((begin (marker-position (plist-get block :begin)))
           (text
            (buffer-substring-no-properties
             (+ begin (car range)) (+ begin (cdr range))))
           (newline (string-suffix-p "\n" text))
           (marker (if newline (substring text 0 -1) text)))
      (overlay-put
       overlay 'display
       (concat
        marker
        (when description
          (concat
           "  "
           (propertize
            (format "(%s)" description)
            'face 'diffs-conflict-marker-label)))
        (and newline "\n"))))
    overlay))

(defun diffs--conflict-choice-name (choice)
  "Return a display name for CHOICE."
  (pcase choice
    ('current "Current")
    ('incoming "Incoming")
    ('both "Both")
    (_ "Unresolved")))

(defun diffs--conflict-action-string (block status)
  "Return the displayed action row for BLOCK in STATUS."
  (let* ((state
          (cond
           ((eq status 'stale)
            (propertize
             "Edited outside diffs.el; undo before choosing"
             'face 'diffs-conflict-stale))
           (status
            (concat
             (propertize
              (format "Resolved: %s"
                      (diffs--conflict-choice-name status))
              'face 'success)
             "  |  "))
           (t "")))
         (actions
          (unless (eq status 'stale)
            (if status
                (list
                 (diffs--conflict-button
                  block 'reset "Reset" nil))
              (list
               (diffs--conflict-button
                block 'current "Accept current change" nil)
               (diffs--conflict-button
                block 'incoming "Accept incoming change" nil)
               (diffs--conflict-button
                block 'both "Accept both" nil)))))
         (string
          (concat
           "  "
           state
           (mapconcat #'identity actions "  |  ")
           "\n")))
    (add-face-text-property
     0 (length string) 'diffs-conflict-action t string)
    string))

(defun diffs--conflict-render-block (block)
  "Create stacked presentation overlays for BLOCK."
  (let* ((begin (marker-position (plist-get block :begin)))
         (end (marker-position (plist-get block :end)))
         (status (diffs--conflict-block-status block))
         (action
          (diffs--conflict-make-overlay begin begin nil block 50)))
    (overlay-put action 'before-string
                 (diffs--conflict-action-string block status))
    (pcase status
      ('stale
       (when (< begin end)
         (diffs--conflict-make-overlay
          begin end 'diffs-conflict-stale block -40)))
      ('current
       (when (< begin end)
         (diffs--conflict-make-overlay
          begin end 'diffs-conflict-current block)))
      ('incoming
       (when (< begin end)
         (diffs--conflict-make-overlay
          begin end 'diffs-conflict-incoming block)))
      ('both
       (let ((middle (+ begin (length (plist-get block :current)))))
         (when (< begin middle)
           (diffs--conflict-make-overlay
            begin middle 'diffs-conflict-current block))
         (when (< middle end)
           (diffs--conflict-make-overlay
            middle end 'diffs-conflict-incoming block))))
      (_
       (diffs--conflict-paint-marker
        block (plist-get block :start-marker-range)
        'diffs-conflict-current-marker "Current Change")
       (diffs--conflict-paint-relative
        block (plist-get block :current-range)
        'diffs-conflict-current)
       (diffs--conflict-paint-marker
        block (plist-get block :base-marker-range)
        'diffs-conflict-base "Base")
       (diffs--conflict-paint-relative
        block (plist-get block :base-range)
        'diffs-conflict-base)
       (diffs--conflict-paint-relative
        block (plist-get block :separator-range)
        'diffs-conflict-marker)
       (diffs--conflict-paint-relative
        block (plist-get block :incoming-range)
        'diffs-conflict-incoming)
       (diffs--conflict-paint-marker
        block (plist-get block :end-marker-range)
        'diffs-conflict-incoming-marker "Incoming Change")))))

(defun diffs--conflict-header-line ()
  "Return the merge-conflict status header for the current buffer."
  (let* ((count (length diffs--conflict-blocks))
         (unresolved
          (cl-count-if
           (lambda (block)
             (or (plist-get block :stale)
                 (null (plist-get block :choice))))
           diffs--conflict-blocks)))
    (format " %s  ·  %d conflict%s  ·  %d unresolved  ·  C-c C-d"
            (or (and buffer-file-name
                     (file-name-nondirectory buffer-file-name))
                (buffer-name))
            count (if (= count 1) "" "s") unresolved)))

(defun diffs--conflict-refresh-overlays ()
  "Rebuild every conflict overlay transactionally."
  (let ((old-overlays diffs--conflict-overlays)
        (old-header header-line-format)
        diffs--conflict-rendering-overlays)
    (condition-case error-data
        (progn
          (dolist (block diffs--conflict-blocks)
            (diffs--conflict-render-block block))
          (setq header-line-format (diffs--conflict-header-line))
          (diffs--conflict-delete-overlays old-overlays)
          (setq diffs--conflict-overlays
                (nreverse diffs--conflict-rendering-overlays)))
      (error
       (diffs--conflict-delete-overlays
        diffs--conflict-rendering-overlays)
       (setq header-line-format old-header)
       (signal (car error-data) (cdr error-data))))))

(defun diffs--conflict-exclude-boundary-insertion
    (change-begin change-end old-length)
  "Keep an external insertion outside adjacent conflict boundaries.
CHANGE-BEGIN, CHANGE-END, and OLD-LENGTH are the standard
`after-change-functions' arguments."
  (when (and (zerop old-length)
             (< change-begin change-end)
             (not (bound-and-true-p undo-in-progress)))
    (dolist (block diffs--conflict-blocks)
      (let* ((begin-marker (plist-get block :begin))
             (end-marker (plist-get block :end))
             (begin (marker-position begin-marker))
             (end (marker-position end-marker)))
        (if (and (string-empty-p (plist-get block :expected))
                 (= begin change-begin)
                 (= end change-end))
            ;; A resolved empty block has both logical boundaries at the
            ;; insertion point.  Keep its action anchor before new text.
            (set-marker end-marker change-begin)
          (when (= begin change-begin)
            (set-marker begin-marker change-end))
          (when (= end change-end)
            (set-marker end-marker change-begin)))))))

(defun diffs--conflict-after-change (begin end old-length)
  "Refresh conflict presentation after a source edit.
BEGIN, END, and OLD-LENGTH describe the changed region."
  (when (and diffs-conflict-mode
             (not diffs--conflict-changing))
    (when (bound-and-true-p undo-in-progress)
      (setq diffs--conflict-refresh-pending t))
    (diffs--conflict-exclude-boundary-insertion
     begin end old-length)
    (diffs--conflict-refresh-overlays)))

(defun diffs--conflict-post-command ()
  "Reproject conflict overlays after an interactive undo or redo."
  (when (and diffs-conflict-mode diffs--conflict-refresh-pending)
    (setq diffs--conflict-refresh-pending nil)
    (diffs--conflict-refresh-overlays)))

(defun diffs--conflict-after-save ()
  "Remember that the visited file changed during conflict resolution."
  (setq diffs--conflict-saved-during-session t))

(defun diffs--conflict-window-state ()
  "Return restorable starts for windows displaying the source buffer."
  (mapcar
   (lambda (window)
     (list window
           (copy-marker (window-start window) nil)
           (window-vscroll window t)))
   (get-buffer-window-list (current-buffer) nil t)))

(defun diffs--conflict-restore-window-state (state)
  "Restore window starts and vertical scroll from STATE."
  (dolist (entry state)
    (pcase-let ((`(,window ,marker ,vscroll) entry))
      (when (and (window-live-p window)
                 (eq (window-buffer window) (current-buffer))
                 (marker-position marker))
        (set-window-start window (marker-position marker) t)
        (set-window-vscroll window vscroll t))
      (set-marker marker nil))))

(defun diffs--conflict-maybe-restore-modified ()
  "Restore the initial unmodified state after an exact complete reset."
  (when (and (not diffs--conflict-initial-modified)
             (not diffs--conflict-saved-during-session)
             (cl-every
              (lambda (block)
                (and (null (plist-get block :choice))
                     (not (plist-get block :stale))))
              diffs--conflict-blocks)
             (equal
              diffs--conflict-initial-text
              (buffer-substring-no-properties
               (point-min) (point-max))))
    (set-buffer-modified-p nil)))

(defun diffs--conflict-smerge-keep-both ()
  "Keep Current followed by Incoming at the smerge conflict at point.
Unlike `smerge-keep-all', this deliberately omits a diff3 Base."
  (smerge-match-conflict)
  (let ((begin (match-beginning 0))
        (end (match-end 0))
        (current
         (buffer-substring-no-properties
          (match-beginning 1) (match-end 1)))
        (incoming
         (buffer-substring-no-properties
          (match-beginning 3) (match-end 3))))
    (smerge-remove-props begin end)
    (replace-region-contents begin end
                             (lambda () (concat current incoming)))))

(defun diffs--conflict-apply-engine (block action replacement)
  "Apply ACTION and REPLACEMENT to live conflict BLOCK.
Standard unresolved syntax delegates matching and ordinary choices to
smerge.  Reset and extended marker forms use diffs.el's persistent
range, which is also what makes post-resolution Reset possible."
  (let* ((begin-marker (plist-get block :begin))
         (end-marker (plist-get block :end))
         (begin (marker-position begin-marker))
         (end (marker-position end-marker))
         (smerge-engine (eq (plist-get block :engine) 'smerge)))
    (cond
     ((or (eq action 'reset) (not smerge-engine))
      (when (bound-and-true-p smerge-mode)
        (smerge-remove-props begin end))
      (replace-region-contents begin end (lambda () replacement)))
     (t
      ;; A previous choice has removed the marker syntax.  Restore it
      ;; inside the same atomic change group before asking smerge to
      ;; perform the newly selected standard operation.
      (unless (equal
               (buffer-substring-no-properties begin end)
               (plist-get block :original))
        (when (bound-and-true-p smerge-mode)
          (smerge-remove-props begin end))
        (replace-region-contents
         begin end (lambda () (plist-get block :original)))
        (set-marker end-marker
                    (+ begin (length (plist-get block :original)))))
      (goto-char begin)
      (let ((smerge-auto-leave nil))
        (pcase action
          ('current (smerge-keep-upper))
          ('incoming (smerge-keep-lower))
          ('both
           (if (plist-get block :base)
               (diffs--conflict-smerge-keep-both)
             (smerge-keep-all)))
          (_ (error "Unknown smerge conflict action: %S" action))))))
    ;; smerge intentionally preserves markers heuristically.  Our live
    ;; range instead identifies the exact persistent Reset target.
    (set-marker begin-marker begin)
    (set-marker end-marker (+ begin (length replacement)))))

(defun diffs--conflict-transition (action &optional block)
  "Apply ACTION to conflict BLOCK as one guarded source transition.
When BLOCK is nil, use the conflict at point."
  (unless diffs-conflict-mode
    (user-error "Merge-conflict resolution is not active"))
  (when buffer-read-only
    (user-error "Cannot resolve conflicts in a read-only buffer"))
  (when (buffer-narrowed-p)
    (user-error "Widen the buffer before resolving merge conflicts"))
  (let* ((block (or block (diffs--conflict-block-at-point)))
         (begin-marker (plist-get block :begin))
         (end-marker (plist-get block :end))
         (begin (marker-position begin-marker))
         (end (marker-position end-marker))
         (actual (buffer-substring-no-properties begin end))
         (expected (plist-get block :expected))
         (choice (diffs--conflict-choice-from-action action))
         (replacement (diffs--conflict-choice-text block action))
         (old-choice (plist-get block :choice))
         (old-expected expected)
         (old-stale (plist-get block :stale))
         (old-modified (buffer-modified-p)))
    (unless (equal actual expected)
      (user-error
       "Conflict %d was edited outside diffs.el; undo that edit first"
       (plist-get block :id)))
    (when (and (eq choice old-choice)
               (equal replacement actual))
      (user-error "Conflict %d already shows %s"
                  (plist-get block :id)
                  (diffs--conflict-choice-name choice)))
    (let ((old-point (copy-marker (point) nil))
          (window-state (diffs--conflict-window-state)))
      (unwind-protect
          (progn
            (condition-case error-data
                (atomic-change-group
                  (let ((diffs--conflict-changing t))
                    (diffs--conflict-apply-engine
                     block action replacement)
                    (setf (plist-get block :choice) choice
                          (plist-get block :expected) replacement
                          (plist-get block :stale) nil)
                    (when font-lock-mode
                      (font-lock-flush
                       (marker-position begin-marker)
                       (marker-position end-marker)))
                    (diffs--conflict-refresh-overlays)))
              (error
               (set-marker begin-marker begin)
               (set-marker end-marker end)
               (setf (plist-get block :choice) old-choice
                     (plist-get block :expected) old-expected
                     (plist-get block :stale) old-stale)
               (set-buffer-modified-p old-modified)
               (goto-char old-point)
               (condition-case rollback-error
                   (progn
                     (when font-lock-mode
                       (font-lock-flush
                        (marker-position begin-marker)
                        (marker-position end-marker)))
                     (diffs--conflict-refresh-overlays))
                 (error
                  (display-warning
                   'diffs
                   (format "Conflict presentation rollback failed: %s"
                           (error-message-string rollback-error))
                   :error)))
               (diffs--conflict-restore-window-state window-state)
               (signal (car error-data) (cdr error-data))))
            (goto-char (marker-position begin-marker))
            (setq diffs--conflict-current-id
                  (plist-get block :id))
            (diffs--conflict-maybe-restore-modified)
            (diffs--conflict-restore-window-state window-state)
            (message "Conflict %d: %s"
                     (plist-get block :id)
                     (diffs--conflict-choice-name choice)))
        (set-marker old-point nil)
        (dolist (entry window-state)
          (set-marker (nth 1 entry) nil))))))

;;;###autoload
(define-minor-mode diffs-conflict-mode
  "Resolve merge conflicts in place while preserving the source major mode.
Enabling validates every block and moves to the first conflict.
\\<diffs-conflict-mode-map>
Use \\[diffs-conflict-current], \\[diffs-conflict-incoming],
\\[diffs-conflict-both], and \\[diffs-conflict-reset] to choose or reset
a result.  Every choice is an undoable, unsaved source-buffer edit; no
command saves or stages the file."
  :lighter " Conflicts"
  :keymap diffs-conflict-mode-map
  (if diffs-conflict-mode
      (unless diffs--conflict-blocks
        (condition-case error-data
            (progn
              (diffs--conflict-setup)
              (goto-char
               (marker-position
                (plist-get (car diffs--conflict-blocks) :begin))))
          (error
           (setq diffs-conflict-mode nil)
           (diffs--conflict-clear-state)
           (signal (car error-data) (cdr error-data)))))
    (diffs--conflict-clear-state)))

(defun diffs-conflict-current ()
  "Replace the conflict at point with its Current section."
  (interactive)
  (diffs--conflict-transition 'current))

(defun diffs-conflict-incoming ()
  "Replace the conflict at point with its Incoming section."
  (interactive)
  (diffs--conflict-transition 'incoming))

(defun diffs-conflict-both ()
  "Replace the conflict at point with Current followed by Incoming."
  (interactive)
  (diffs--conflict-transition 'both))

(defun diffs-conflict-reset ()
  "Restore the complete original marker block at point."
  (interactive)
  (diffs--conflict-transition 'reset))

(defun diffs-conflict-next ()
  "Move to the next merge-conflict action row."
  (interactive)
  (unless diffs-conflict-mode
    (user-error "Merge-conflict resolution is not active"))
  (let* ((position (point))
         (current
          (condition-case nil
              (diffs--conflict-block-at-point)
            (user-error nil)))
         (block
          (if current
              (cadr (memq current diffs--conflict-blocks))
            (cl-find-if
             (lambda (candidate)
               (> (marker-position
                   (plist-get candidate :begin))
                  position))
             diffs--conflict-blocks))))
    (if block
        (progn
          (setq diffs--conflict-current-id
                (plist-get block :id))
          (goto-char (marker-position (plist-get block :begin))))
      (user-error "No next merge conflict"))))

(defun diffs-conflict-previous ()
  "Move to the previous merge-conflict action row."
  (interactive)
  (unless diffs-conflict-mode
    (user-error "Merge-conflict resolution is not active"))
  (let* ((position (point))
         (current
          (condition-case nil
              (diffs--conflict-block-at-point)
            (user-error nil)))
         previous)
    (if current
        (catch 'found
          (dolist (block diffs--conflict-blocks)
            (when (eq block current)
              (throw 'found previous))
            (setq previous block)))
      (dolist (block diffs--conflict-blocks)
        (when (< (marker-position (plist-get block :begin)) position)
          (setq previous block))))
    (if previous
        (progn
          (setq diffs--conflict-current-id
                (plist-get previous :id))
          (goto-char (marker-position (plist-get previous :begin))))
      (user-error "No previous merge conflict"))))

(defun diffs-conflict-mouse-action (event)
  "Apply the conflict action represented by mouse EVENT."
  (interactive "e")
  (let* ((position (event-start event))
         (window (posn-window position))
         (string-position (posn-string position))
         (string (car-safe string-position))
         (index (cdr-safe string-position))
         (id (and (stringp string)
                  (integerp index)
                  (get-text-property index 'diffs-conflict-id string)))
         (action
          (and (stringp string)
               (integerp index)
               (get-text-property
                index 'diffs-conflict-action string))))
    (unless (window-live-p window)
      (user-error "No merge-conflict action at that position"))
    (posn-set-point position)
    (let ((block (and id (diffs--conflict-block-by-id id))))
      (unless (and diffs-conflict-mode block action)
        (user-error "No merge-conflict action at that position"))
      (setq diffs--conflict-current-id id)
      (goto-char (marker-position (plist-get block :begin)))
      (diffs--conflict-transition action block))))

(defun diffs-conflict-quit ()
  "Remove conflict presentation, leaving source edits unsaved."
  (interactive)
  (unless diffs-conflict-mode
    (user-error "Merge-conflict resolution is not active"))
  (diffs-conflict-mode -1)
  (message "Left conflict resolution; source edits remain unsaved"))

;;;; Diff generation

(defun diffs--common-parent-directory (files)
  "Return the deepest common parent directory containing FILES."
  (let ((directory (file-name-directory (car files))))
    (while
        (and directory
             (not
              (cl-every
               (lambda (file)
                 (file-in-directory-p file directory))
               files)))
      (let ((parent
             (file-name-directory
              (directory-file-name directory))))
        (setq directory
              (unless (equal parent directory) parent))))
    (or directory (file-name-directory (car files)))))

(defun diffs--cached-reference-revision (directory)
  "Return diff-hl's most specific cached revision for DIRECTORY."
  (when (and directory
             (boundp 'diff-hl-reference-revision-projects-cache))
    (let ((directory
           (file-name-as-directory (expand-file-name directory)))
          best
          (best-length -1))
      (dolist (entry diff-hl-reference-revision-projects-cache)
        (let ((root
               (file-name-as-directory
                (expand-file-name (car entry)))))
          (when (and (string-prefix-p root directory)
                     (> (length root) best-length))
            (setq best (cdr entry)
                  best-length (length root)))))
      best)))

(defun diffs--reference-revision (&optional directory)
  "Return the diff-hl reference revision for DIRECTORY.
A buffer-local value wins.  Otherwise use the most specific public
project-cache entry before falling back to diff-hl's global default."
  (cond
   ((local-variable-p 'diff-hl-reference-revision)
    diff-hl-reference-revision)
   ((diffs--cached-reference-revision
     (or directory default-directory)))
   ((boundp 'diff-hl-reference-revision)
    (default-value 'diff-hl-reference-revision))))

(defun diffs--header-line (&optional window)
  "Return the sticky file, hunk, and summary header for WINDOW."
  (cl-destructuring-bind (&optional (files 0) (adds 0) (dels 0)) diffs--stats
    (let* ((window (or window (get-buffer-window (current-buffer))))
           (position (if (window-live-p window)
                         (window-start window)
                       (point)))
           (path-width
            (if (window-live-p window)
                (max 20 (- (window-width window) 48))
              diffs--file-header-path-width))
           (section (diffs--section-at-pos position))
           (hunk (and section (diffs--hunk-at-pos section position)))
           (header
            (diffs--sticky-file-header
             section 'stacked path-width)))
      (concat
       (when section
         (concat
          (or header "")
          (format "  [%d/%d]"
                  (plist-get section :index) files)
          (or (diffs--sticky-hunk-label hunk) "")
          "  │  "))
       (if (= files 1) "1 file" (format "%d files" files))
       " · "
       (propertize (format "+%d" adds) 'face 'diffs-file-stats-added)
       " "
       (propertize (format "−%d" dels) 'face 'diffs-file-stats-removed)
       (when diffs--revision
         (format " · vs %s" diffs--revision))))))

(defun diffs--present
    (buf backend rev &optional line regenerator target-revision
         entry-restorer return-marker item-ranges independent-sources)
  "Set up and display the diff in BUF.
BACKEND and REV are used for revision-aware syntax highlighting.
LINE, if non-nil, is the source line to move to.  REGENERATOR is
stored for `diffs-refresh'.  TARGET-REVISION is the new side of a
commit diff; nil means the working tree.  ENTRY-RESTORER, when
non-nil, restores source state after review initialization.
RETURN-MARKER independently preserves the source point for quit.
ITEM-RANGES carries mixed-item identity from `diffs-items'.
INDEPENDENT-SOURCES means the old and new paths are separate files."
  (with-current-buffer buf
    (goto-char (point-min))
    (let ((diffs--mode-context
           (list :item-ranges item-ranges
                 :backend backend
                 :revision rev
                 :target-revision target-revision
                 :independent-sources independent-sources
                 :regenerator regenerator)))
      (diffs-mode))
    (unless diffs--sections
      (kill-buffer buf)
      (user-error "No changes"))
    (setq header-line-format nil))
  (when entry-restorer
    (funcall entry-restorer))
  (unless diffs--refreshing
    (let (entry-anchor)
      (unless (get-buffer-window buf)
        (let ((configuration (current-window-configuration)))
          (with-current-buffer buf
            (setq diffs--window-configuration configuration
                  diffs--return-marker return-marker))))
      (pop-to-buffer buf)
      (when diffs-fullscreen
        (delete-other-windows))
      (when line
        (require 'diff-hl nil t)
        (when (fboundp 'diff-hl-diff-skip-to)
          (condition-case error-data
              (diff-hl-diff-skip-to line)
            (error
             (display-warning
              'diffs
              (format "Cannot position diff at source line %d: %s"
                      line (error-message-string error-data))
              :warning))))
        (setq entry-anchor
              (with-current-buffer buf
                (diffs--split-entry-anchor))))
      (when (eq diffs-default-view 'split)
        (unless (eq (current-buffer) buf)
          (set-buffer buf))
        (diffs-toggle-split)
        (diffs--split-restore-entry-anchor buf entry-anchor))
      (when-let* ((window (get-buffer-window buf t)))
        (diffs--update-sticky-header window))))
  buf)

(defun diffs--mixed-item-id (item index payload)
  "Return stable id for ITEM at INDEX with PAYLOAD."
  (or (plist-get item :id)
      (format
       "item:%d:%s"
       index
       (substring (secure-hash 'sha1 payload) 0 12))))

(defun diffs--mixed-item-file (item)
  "Validate and return ITEM's repository-relative file name."
  (let ((file (or (plist-get item :file)
                  (plist-get item :path))))
    (unless (and (stringp file)
                 (not (string-empty-p file))
                 (not (file-name-absolute-p file))
                 (not (string-match-p "[\n\r]" file))
                 (not
                  (string-match-p
                   "\\(?:\\`\\|[/\\\\]\\)\\.\\.\\(?:[/\\\\]\\|\\'\\)"
                   file)))
      (user-error
       "File items need a safe repository-relative :file"))
    file))

(defun diffs--mixed-item-quoted-path (prefix file)
  "Return a Git-compatible quoted PREFIX/FILE token."
  (prin1-to-string (concat prefix "/" file)))

(defun diffs--mixed-file-patch (file lines)
  "Return a synthetic unchanged patch for FILE containing LINES."
  (let ((count (length lines)))
    (concat
     "diff --git "
     (diffs--mixed-item-quoted-path "a" file)
     " "
     (diffs--mixed-item-quoted-path "b" file)
     "\n--- "
     (diffs--mixed-item-quoted-path "a" file)
     "\n+++ "
     (diffs--mixed-item-quoted-path "b" file)
     "\n"
     (format
      "@@ -%d,%d +%d,%d @@\n"
      (if (zerop count) 0 1) count
      (if (zerop count) 0 1) count)
     (mapconcat
      (lambda (line)
        (concat " " (substring-no-properties line) "\n"))
      lines ""))))

(defun diffs--normalize-mixed-item (item index)
  "Validate ITEM at INDEX and return its normalized representation."
  (unless (listp item)
    (user-error "Each mixed item must be a plist"))
  (pcase (plist-get item :type)
    ('file
     (let* ((file (diffs--mixed-item-file item))
            (content (plist-get item :content)))
       (unless (stringp content)
         (user-error "File item %s needs string :content" file))
       (let* ((lines (diffs--string-lines content))
              (version
               (or (plist-get item :version)
                   (secure-hash 'sha1 content))))
         (list
          :type 'file
          :id (diffs--mixed-item-id item index content)
          :version version
          :lines lines
          :patch (diffs--mixed-file-patch file lines)))))
    ('diff
     (let ((patch (or (plist-get item :patch)
                      (plist-get item :content))))
       (unless (and (stringp patch)
                    (string-match-p
                     "^\\(?:diff \\|Index: \\|--- \\)" patch))
         (user-error
          "Diff item %d needs a valid string :patch" (1+ index)))
       (list
        :type 'diff
        :id (diffs--mixed-item-id item index patch)
        :version
        (or (plist-get item :version)
            (secure-hash 'sha1 patch))
        :patch patch)))
    (_
     (user-error "Mixed item %d has unknown :type" (1+ index)))))

(defun diffs--normalize-mixed-items (items)
  "Validate ITEMS before a mixed review mutates its destination buffer."
  (unless (and (listp items) items)
    (user-error "ITEMS must be a non-empty list"))
  (cl-loop
   for item in items
   for index from 0
   collect (diffs--normalize-mixed-item item index)))

(defun diffs--insert-mixed-items (buffer items)
  "Insert normalized ITEMS into BUFFER and return their source ranges."
  (with-current-buffer buffer
    (let (ranges)
      (dolist (item items)
        (let ((begin (point))
              (patch (plist-get item :patch)))
          (insert patch)
          (unless (bolp)
            (insert "\n"))
          (push
           (list
            :begin begin
            :end (point)
            :type (plist-get item :type)
            :id (plist-get item :id)
            :version (plist-get item :version)
            :lines (plist-get item :lines))
           ranges)))
      (nreverse ranges))))

;;;###autoload
(defun diffs-items (items &optional options)
  "Show mixed source-file and diff ITEMS in one native review.
Each file item is `(:type file :file PATH :content STRING)' and each
diff item is `(:type diff :patch STRING)'.  Both accept stable `:id'
and `:version' values.

OPTIONS is a plist accepting `:directory', `:buffer-name', `:backend',
`:revision', and `:target-revision'.  File items are represented as
unchanged source in the same owner/index/navigation model as diffs."
  (let* ((normalized (diffs--normalize-mixed-items items))
         (options
          (progn
            (unless (or (null options) (listp options))
              (user-error "OPTIONS must be a plist"))
            options))
         (directory
          (file-name-as-directory
           (expand-file-name
            (or (plist-get options :directory)
                default-directory))))
         (backend (plist-get options :backend))
         (revision (plist-get options :revision))
         (target-revision
          (plist-get options :target-revision))
         (buffer-name
          (if diffs--refreshing
              diffs-buffer-name
            (or (plist-get options :buffer-name)
                diffs-buffer-name)))
         (diffs-buffer-name buffer-name)
         (buffer (diffs--prepare-buffer directory))
         (ranges (diffs--insert-mixed-items buffer normalized))
         (items-copy (copy-tree items))
         (options-copy (copy-tree options)))
    (diffs--present
     buffer backend revision nil
     (lambda ()
       (diffs-items items-copy options-copy))
     target-revision nil nil ranges)))

(defun diffs--prepare-buffer (dir)
  "Return the diffs buffer, emptied, with `default-directory' DIR."
  (let ((buf (get-buffer-create diffs-buffer-name)))
    (with-current-buffer buf
      (when diffs-minor-mode (diffs-minor-mode -1))
      (fundamental-mode)
      (setq buffer-read-only nil)
      (erase-buffer)
      (setq default-directory dir))
    buf))

;;;###autoload
(defun diffs-files (old new)
  "Compare saved files OLD and NEW in one native review.
OLD is the left side and NEW is the right side.  Refresh rereads both
paths.  Review decisions, when applied explicitly, target NEW."
  (interactive
   (let* ((current
           (and buffer-file-name
                (file-regular-p buffer-file-name)
                buffer-file-name))
          (old
           (read-file-name
            (format-prompt
             "Old file"
             (and current (file-name-nondirectory current)))
            nil current t))
          (new
           (read-file-name
            "New file: " (file-name-directory old) nil t)))
     (list old new)))
  (setq old (expand-file-name old)
        new (expand-file-name new))
  (dolist (file (list old new))
    (unless (and (file-regular-p file) (file-readable-p file))
      (user-error "Comparison source is not a readable file: %s" file)))
  (when (file-equal-p old new)
    (user-error "Choose two different files"))
  (require 'diff)
  (let* ((entry-marker (copy-marker (point)))
         (directory (diffs--common-parent-directory (list old new)))
         (buffer (diffs--prepare-buffer directory))
         (default-directory directory))
    (condition-case error-data
        (progn
          (diff-no-select old new '("-u") t buffer)
          (with-current-buffer buffer
            (let ((case-fold-search nil)
                  (inhibit-read-only t))
              (goto-char (point-min))
              (if (re-search-forward "^--- " nil t)
                  (progn
                    (delete-region
                     (point-min) (line-beginning-position))
                    (goto-char (point-max))
                    (when (re-search-backward "^Diff finished" nil t)
                      (delete-region
                       (line-beginning-position) (point-max))))
                (when (save-excursion
                        (goto-char (point-min))
                        (search-forward
                         "Diff finished (diff error)" nil t))
                  (user-error "File comparison command failed"))
                (erase-buffer))))
          (diffs--present
           buffer nil nil nil
           (lambda () (diffs-files old new))
           nil nil entry-marker nil t))
      (error
       (set-marker entry-marker nil)
       (when (buffer-live-p buffer)
         (kill-buffer buffer))
       (signal (car error-data) (cdr error-data))))))

;;;###autoload
(defun diffs-file ()
  "Show a pretty diff of the current file against the reference revision.
Unsaved changes are included when diff-hl is available.  The
reference is `diff-hl-reference-revision' when set, otherwise the
last revision."
  (interactive)
  (let* ((entry-buffer (current-buffer))
         (entry-marker (copy-marker (point)))
         (entry-window
          (and (eq (window-buffer (selected-window)) entry-buffer)
               (selected-window)))
         (entry-window-point
          (and entry-window (window-point entry-window)))
         (file (or (buffer-file-name)
                   (user-error "Buffer is not visiting a file")))
         (backend (or (vc-backend file)
                      (user-error "File is not under version control")))
         (rev (diffs--reference-revision (file-name-directory file)))
         (line (line-number-at-pos))
         (unsaved (and (buffer-modified-p)
                       (require 'diff-hl nil t)
                       (fboundp 'diff-hl-diff-buffer-with-reference)))
         buf)
    (save-excursion
      (save-window-excursion
        ;; The unsaved diff labels files with their base name; the
        ;; VC diff uses root-relative names.
        (setq buf
              (diffs--prepare-buffer
               (if unsaved
                   (file-name-directory file)
                 (vc-call-backend backend 'root
                                  (file-name-directory file)))))
        (if unsaved
            (let ((diff-hl-update-async nil)
                  ;; Diffs.el promises the same reference for saved and
                  ;; unsaved buffers.  Include staged Git changes so nil
                  ;; means HEAD/last revision here, not the index.
                  (diff-hl-show-staged-changes t))
                  (diff-hl-diff-buffer-with-reference file buf backend 3))
          (vc-call-backend backend 'diff (list file) rev nil buf nil))))
    (cl-labels
        ((restore-entry ()
           (when (buffer-live-p entry-buffer)
             (with-current-buffer entry-buffer
               (goto-char entry-marker)))
           (when (and (window-live-p entry-window)
                      (eq (window-buffer entry-window) entry-buffer))
             (set-window-point entry-window entry-window-point))))
      (restore-entry)
      (diffs--present
       buf backend rev line
       (lambda ()
         (if-let* ((b (find-buffer-visiting file)))
           (with-current-buffer b (diffs-file))
           (user-error "Source buffer was killed")))
       nil #'restore-entry entry-marker))))

;;;###autoload
(defun diffs-project ()
  "Show a pretty diff of the whole project against the reference revision."
  (interactive)
  (let* ((backend (or (ignore-errors (vc-deduce-backend))
                      (ignore-errors (vc-responsible-backend default-directory))
                      (user-error "Not in a version-controlled directory")))
         (root (vc-call-backend backend 'root default-directory))
         (rev (diffs--reference-revision root))
         (buf (diffs--prepare-buffer root))
         (default-directory root))
    (vc-call-backend backend 'diff nil rev nil buf nil)
    (diffs--present buf backend rev nil #'diffs-project)))

;;;###autoload
(defun diffs-commit (rev &optional file)
  "Show a pretty diff of commit REV, limited to FILE when non-nil.
Only supports Git."
  (interactive (list (read-string "Commit: " nil nil
                                  (thing-at-point 'symbol t))))
  (require 'vc-git)
  (let* ((default-directory
          (or (vc-git-root default-directory)
              (user-error "Not in a Git repository")))
         (buf (diffs--prepare-buffer default-directory)))
    (apply #'vc-git-command buf 1 nil
           `("show" "--first-parent" ,rev "--"
             ,@(and file (list (file-relative-name file)))))
    (diffs--present buf 'Git (format "%s^" rev) nil
                    (lambda () (diffs-commit rev file))
                    rev)))

;;;###autoload
(defun diffs-commit-at-line (&optional file-only)
  "Show the commit that last modified the current line.
With prefix argument FILE-ONLY, limit the diff to the current file.
Blames the saved file, so save first for accurate results."
  (interactive "P")
  (require 'vc-git)
  (let* ((file (or (buffer-file-name)
                   (user-error "Buffer is not visiting a file")))
         (line (line-number-at-pos))
         (default-directory (file-name-directory file))
         (sha
          (with-temp-buffer
            (unless (zerop (call-process vc-git-program nil t nil
                                         "blame" "-L" (format "%d,%d" line line)
                                         "--porcelain" "--"
                                         (file-name-nondirectory file)))
              (user-error "Git blame failed (file not committed?)"))
            (goto-char (point-min))
            (car (split-string (buffer-substring-no-properties
                                (point) (line-end-position)))))))
    (when (or (null sha) (string-match-p "\\`0+\\'" sha))
      (user-error "Line is not committed yet"))
    (diffs-commit sha (and file-only file))))

(provide 'diffs)
;;; diffs.el ends here
