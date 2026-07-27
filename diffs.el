;;; diffs.el --- Fast, pretty file-level diff viewing -*- lexical-binding: t -*-

;; Copyright (C) 2026 Lucius Chen

;; Author: Lucius Chen
;; URL: https://github.com/LuciusChen/diffs.el
;; Version: 0.5.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: vc, tools

;;; Commentary:

;; A rendering layer over `diff-mode' inspired by https://diffs.com/:
;; old/new line-number columns, no +/- marker noise, styled file and
;; hunk headers, full-width line backgrounds, word-level refinement,
;; source-language syntax highlighting, and a two-window side-by-side
;; view with synchronized scrolling and aligned long-line wrapping.
;;
;; Everything is implemented with text properties on top of the
;; unmodified diff text, so `diff-goto-source', isearch, `diff-apply-hunk'
;; and the rest of the diff-mode machinery keep working.  Syntax
;; highlighting stays lazy through jit-lock, and on large diffs the
;; decorations themselves are applied lazily as well, so even huge
;; diffs open instantly.  No external processes are used for
;; rendering.
;;
;; Entry points:
;; - `diffs-file': current file against the reference revision.
;; - `diffs-project': whole project against the reference revision.
;; - `diffs-commit': show a commit.
;; - `diffs-commit-at-line': show the commit that last touched the
;;   current line (blame).
;; - `diffs-minor-mode': use the renderer in any diff-mode buffer.
;; - `i' in the view: toggle the changed-file index.
;; - `s' in the view: toggle the side-by-side (split) view.
;;
;; The reference revision integrates with diff-hl: when
;; `diff-hl-reference-revision' is set, the same base is used here.

;;; Code:

(require 'diff-mode)
(require 'vc)
(require 'cl-lib)
(require 'subr-x)
(require 'fringe)

(declare-function vc-git-command "vc-git")
(declare-function vc-git-root "vc-git")
(declare-function diff-hl-diff-buffer-with-reference "diff-hl")
(declare-function diff-hl-diff-skip-to "diff-hl")
(declare-function diff-hl-show-hunk-hide "diff-hl-show-hunk")
(defvar vc-git-program)
(defvar diff-hl-update-async)
(defvar diffs-minor-mode)
(defvar diffs--split-unified)

(defgroup diffs nil
  "Pretty file-level diff viewing."
  :group 'vc)

(defcustom diffs-line-numbers t
  "When non-nil, show old and new line numbers beside diff lines."
  :type 'boolean)

(defcustom diffs-hide-markers t
  "When non-nil, hide the leading +/-/space markers of diff lines."
  :type 'boolean)

(defcustom diffs-prettify-headers t
  "When non-nil, replace file and hunk headers with a compact form."
  :type 'boolean)

(defcustom diffs-lazy-threshold 10000
  "Decorate lazily via jit-lock when the diff has more lines than this.
Lazy decoration makes huge diffs open instantly.  Set to 0 to
always decorate lazily, or to `most-positive-fixnum' to always
decorate eagerly."
  :type 'natnum)

(defcustom diffs-split-fontify-threshold 4000
  "Fully fontify before splitting only when the diff has fewer lines.
The side-by-side view copies text from the unified buffer, so
word-level refinement and syntax highlighting must be computed for
the whole diff up front.  Beyond this many lines that would be
slow; the split is built instantly with the diff colors only."
  :type 'natnum)

(defcustom diffs-split-wrap-lines t
  "When non-nil, wrap long side-by-side rows while preserving alignment.
Both sides receive the same number of physical rows, with filler
rows added to the shorter side as necessary."
  :type 'boolean)

(defcustom diffs-fringe-bars t
  "When non-nil, show colored fringe bars on added and removed lines."
  :type 'boolean)

(defcustom diffs-fringe-bar-width 2
  "Width in pixels of added and removed line bars in the left fringe.
Values outside the range 1 through 8 are clamped."
  :type 'integer)

(defcustom diffs-split-full-width-backgrounds t
  "When non-nil, extend split-view change backgrounds across each row.
The line-number gutter receives the same theme-native background.
Word-level `diff-refine-added' and `diff-refine-removed' faces
remain layered above it."
  :type 'boolean)

(defcustom diffs-index-width 36
  "Width in columns of the changed-file index side window."
  :type 'integer)

(defcustom diffs-fullscreen t
  "When non-nil, the diffs view takes over the whole frame.
`diffs-quit' (bound to \\`q') restores the previous window layout."
  :type 'boolean)

(defcustom diffs-buffer-name "*diffs*"
  "Name of the buffer used to display diffs."
  :type 'string)

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

(defun diffs--split-line-prefix-face (change-face)
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

(defun diffs--fringe-prefix (indicator)
  "Return a fringe bar prefix for diff INDICATOR, or an empty string."
  (let ((face (pcase indicator
                (?+ 'diff-indicator-added)
                (?- 'diff-indicator-removed))))
    (if (and diffs-fringe-bars face)
        (propertize
         " " 'display `(left-fringe diffs-fringe-bar ,face))
      "")))

(defvar-local diffs--stats nil
  "List (FILES ADDED REMOVED) accumulated by the last scan.")

(defvar-local diffs--sections nil
  "List of file-section plists built by `diffs--scan'.
Each element: (:beg N :block-end N :end N :file S :adds N :dels N
:index N :width N
:hunks ((POS OLD-START NEW-START END CONTEXT) ...)).")

(defvar-local diffs--section-vector []
  "Vector form of `diffs--sections' for position lookup.")

(defvar-local diffs--revision nil
  "Reference revision this buffer was generated against, or nil.")

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

(defun diffs--file-name-from-marker (block-end)
  "Return the new pathname from a +++ marker before BLOCK-END."
  (save-excursion
    (when (re-search-forward "^\\+\\+\\+ \\(.+\\)$" block-end t)
      (let* ((text (match-string-no-properties 1))
             (path (if (string-prefix-p "\"" text)
                       (car (diffs--git-path-token text))
                     (car (split-string text "\t")))))
        (unless (equal path "/dev/null")
          (diffs--strip-git-prefix path))))))

(defun diffs--file-name-at-header (block-end)
  "Extract the file name from the header block between point and BLOCK-END."
  (save-excursion
    (let ((git-paths (diffs--git-header-paths)))
      (cond
       (git-paths (cadr git-paths))
       ((diffs--file-name-from-marker block-end))
       ((looking-at "^diff --\\(?:cc\\|combined\\) \\(.+\\)$")
        (let ((path (car (diffs--git-path-token
                          (match-string-no-properties 1)))))
          (and path (diffs--strip-git-prefix path))))
       ((looking-at "^\\(?:diff\\|Index:\\) .*?\\([^ \t/]+\\)$")
        (match-string-no-properties 1))))))

(defun diffs--scan-section (section-end)
  "Scan the file section starting at point, up to SECTION-END.
Return a section plist; see `diffs--sections'."
  (let* ((beg (point))
         (block-end (diffs--header-block-end section-end))
         (file (diffs--file-name-at-header block-end))
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
          (push (list (line-beginning-position) old new hend context)
                hunks)
          (setq max-line (max max-line (+ old oldc) (+ new newc)))
          (cl-incf adds (count-matches "^\\+" (line-end-position) hend))
          (cl-incf dels (count-matches "^-" (line-end-position) hend)))))
    (list :beg beg :block-end block-end :end section-end :file file
          :adds adds :dels dels
          :width (max 2 (length (number-to-string max-line)))
          :hunks (nreverse hunks))))

(defun diffs--scan ()
  "Scan the buffer.  Sets `diffs--sections' and `diffs--stats'."
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
      (setq diffs--sections (nreverse sections)
            diffs--section-vector (vconcat diffs--sections)
            diffs--stats (list nfiles nadds ndels)))))

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

(defun diffs--hunk-at-pos (section position)
  "Return the hunk in SECTION containing POSITION."
  (cl-find-if (lambda (hunk)
                (and (<= (car hunk) position)
                     (< position (diffs--hunk-end hunk section))))
              (plist-get section :hunks)))

;;;; Rendering

(defun diffs--put (beg end &rest props)
  "Set PROPS on BEG..END, marking them as owned by diffs."
  (add-text-properties beg end (append '(diffs t) props)))

(defun diffs--undecorate ()
  "Remove all diffs decorations from the buffer."
  (with-silent-modifications
    (let ((pos (point-min)) next)
      (while (setq pos (text-property-any pos (point-max) 'diffs t))
        (setq next (or (text-property-not-all pos (point-max) 'diffs t)
                       (point-max)))
        (remove-list-of-text-properties
         pos next '(diffs display line-prefix wrap-prefix))
        (setq pos next)))))

(defun diffs--decorate-header (sec)
  "Display the header block of section SEC as one styled line."
  (let* ((end (if (plist-get sec :hunks)
                  (plist-get sec :block-end)
                (save-excursion
                  (goto-char (plist-get sec :beg))
                  (forward-line 1)
                  (point))))
         (line (concat
                (propertize (concat "── " (or (plist-get sec :file) "?") "  ")
                            'face 'diffs-file-header)
                (propertize (format "+%d" (plist-get sec :adds))
                            'face 'diffs-file-stats-added)
                " "
                (propertize (format "−%d" (plist-get sec :dels))
                            'face 'diffs-file-stats-removed)
                "\n")))
    (diffs--put (plist-get sec :beg) end
                'display line)))

(defun diffs--hunk-end (hunk sec)
  "Return the end position of HUNK in section SEC."
  (or (nth 3 hunk) (plist-get sec :end)))

(defun diffs--decorate-hunk (hunk end width &optional rbeg rend)
  "Decorate HUNK (see `diffs--sections') ending at END.
WIDTH is the number-column width.  When RBEG and REND are
non-nil, only apply properties to lines intersecting that region."
  (save-excursion
    (goto-char (car hunk))
    (let ((old-line (nth 1 hunk))
          (new-line (nth 2 hunk))
          (fmt (format "%%%dd" width))
          (empty (make-string width ?\s)))
      (when (and diffs-prettify-headers
                 (or (null rend) (and (< (point) rend)
                                      (>= (line-end-position) (or rbeg 0))))
                 (looking-at diffs--hunk-re))
        (let ((context (string-trim (match-string 5))))
          (diffs--put (line-beginning-position) (line-end-position)
                      'display (propertize
                                (concat "⋯" (unless (string= context "")
                                              (concat " " context)))
                                'face 'diffs-hunk-separator))))
      (forward-line 1)
      (while (and (< (point) end) (not (eobp)))
        (let* ((c (char-after))
               (old (memq c '(?- ?\s ?\n)))
               (new (memq c '(?+ ?\s ?\n))))
          (when (and (memq c '(?+ ?- ?\s ?\n ?\\))
                     (not (eq c ?\\))
                     (or (null rend)
                         (and (< (point) rend)
                              (>= (1+ (line-end-position)) (or rbeg 0)))))
            (let ((fringe (diffs--fringe-prefix c)))
              (when (or diffs-line-numbers (not (string-empty-p fringe)))
                (diffs--put
                 (point) (min (point-max) (1+ (line-end-position)))
                 'line-prefix
                 (concat
                  fringe
                  (when diffs-line-numbers
                    (propertize
                     (concat (if old (format fmt old-line) empty) " "
                             (if new (format fmt new-line) empty) " ")
                     'face 'diffs-line-number)))
                 'wrap-prefix
                 (concat
                  fringe
                  (when diffs-line-numbers
                    (propertize (make-string (+ (* 2 width) 2) ?\s)
                                'face 'diffs-line-number))))))
            (when (and diffs-hide-markers (memq c '(?+ ?- ?\s)))
              (diffs--put (point) (1+ (point)) 'display "")))
          (when (memq c '(?+ ?- ?\s ?\n ?\\))
            (unless (eq c ?\\)
              (when old (cl-incf old-line))
              (when new (cl-incf new-line)))))
        (forward-line 1)))))

(defun diffs--decorate-eagerly ()
  "Decorate all content lines from the section index."
  (with-silent-modifications
    (dolist (sec diffs--sections)
      (dolist (hunk (plist-get sec :hunks))
        (diffs--decorate-hunk hunk (diffs--hunk-end hunk sec)
                              (plist-get sec :width))))))

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
              (diffs--decorate-hunk hunk hend (plist-get sec :width)
                                    beg end)))))))
  `(jit-lock-bounds ,beg . ,end))

(defun diffs--decorate ()
  "Scan and decorate the whole buffer eagerly.  Sets `diffs--stats'."
  (diffs--undecorate)
  (diffs--scan)
  (with-silent-modifications
    (when diffs-prettify-headers
      (dolist (sec diffs--sections)
        (diffs--decorate-header sec))))
  (diffs--decorate-eagerly))

(defun diffs--decorate-setup ()
  "Scan the buffer and set up eager or lazy content decoration."
  (diffs--undecorate)
  (diffs--scan)
  (with-silent-modifications
    (when diffs-prettify-headers
      (dolist (sec diffs--sections)
        (diffs--decorate-header sec))))
  (if (and font-lock-mode
           (> (count-lines (point-min) (point-max)) diffs-lazy-threshold))
      (jit-lock-register #'diffs--jit-decorate)
    (diffs--decorate-eagerly)))

;;;; Minor mode

(defvar-local diffs--window-configuration nil
  "Window layout in effect before the diffs view was shown.")

(defun diffs-quit ()
  "Quit the diffs view, restoring the previous window layout."
  (interactive)
  (diffs--index-cleanup)
  (diffs--split-cache-clear)
  (if (window-configuration-p diffs--window-configuration)
      (progn
        (bury-buffer)
        (set-window-configuration diffs--window-configuration)
        (setq diffs--window-configuration nil))
    (quit-window)))

(defvar-keymap diffs-minor-mode-map
  "q" #'diffs-quit
  "n" #'diff-hunk-next
  "p" #'diff-hunk-prev
  "N" #'diff-file-next
  "P" #'diff-file-prev
  "i" #'diffs-toggle-index
  "s" #'diffs-toggle-split
  "g" #'diffs-refresh)

(defvar-local diffs--regenerator nil
  "Function that regenerates this buffer's diff, for `diffs-refresh'.")

(defvar-local diffs--split-cache nil
  "Cached side-by-side buffers and the render key that produced them.")

(defvar-local diffs--index-buffer nil
  "Changed-file index buffer owned by this unified diff buffer.")

(defvar-local diffs--index-visible nil
  "Non-nil when this unified diff wants its file index visible.")

(defvar-local diffs--index-owner nil
  "Unified diff buffer owned by this changed-file index.")

(defvar-local diffs--index-current-overlay nil
  "Overlay highlighting the current file in a changed-file index.")

(defvar-local diffs--saved-header-line-format nil
  "Header line that was active before `diffs-minor-mode'.")

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
        (width (max 20 (buffer-local-value 'diffs-index-width owner))))
    (with-current-buffer index
      (let ((inhibit-read-only t)
            (file-width (max 8 (- width 14))))
        (erase-buffer)
        (dolist (section sections)
          (let* ((beg (point))
                 (file (or (plist-get section :file) "?"))
                 (label (diffs--index-file-label file file-width)))
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

(defun diffs--index-post-command ()
  "Sync the changed-file index after movement in a unified diff."
  (when diffs-minor-mode
    (diffs--index-sync (point))))

(defun diffs--index-scroll (window start)
  "Sync the changed-file index when WINDOW scrolls to START."
  (when (and diffs-minor-mode
             (eq (window-buffer window) (current-buffer)))
    (diffs--index-sync start)))

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
        (setq diffs--saved-header-line-format header-line-format)
        (setq header-line-format '((:eval (diffs--header-line))))
        (diffs--define-fringe-bitmap)
        (add-hook 'text-scale-mode-hook #'diffs--define-fringe-bitmap nil t)
        (add-hook 'kill-buffer-hook #'diffs--split-cache-clear nil t)
        (add-hook 'kill-buffer-hook #'diffs--index-cleanup nil t)
        (add-hook 'post-command-hook #'diffs--index-post-command nil t)
        (add-hook 'window-scroll-functions #'diffs--index-scroll nil t)
        (setq-local diff-font-lock-prettify nil)
        (when (eq diff-font-lock-syntax t)
          (setq-local diff-font-lock-syntax 'hunk-also))
        (setq-local font-lock-extra-managed-props
                    (remq 'display font-lock-extra-managed-props))
        (diffs--decorate-setup)
        (setq-local outline-minor-mode-cycle t)
        (setq-local outline-minor-mode-highlight nil)
        (outline-minor-mode 1))
    (jit-lock-unregister #'diffs--jit-decorate)
    (remove-hook 'text-scale-mode-hook #'diffs--define-fringe-bitmap t)
    (remove-hook 'kill-buffer-hook #'diffs--split-cache-clear t)
    (remove-hook 'kill-buffer-hook #'diffs--index-cleanup t)
    (remove-hook 'post-command-hook #'diffs--index-post-command t)
    (remove-hook 'window-scroll-functions #'diffs--index-scroll t)
    (diffs--index-cleanup)
    (diffs--split-cache-clear)
    (outline-minor-mode -1)
    (diffs--undecorate)
    (setq header-line-format diffs--saved-header-line-format
          diffs--saved-header-line-format nil)))

(defun diffs-refresh ()
  "Regenerate the diff shown in this buffer."
  (interactive)
  (if diffs--regenerator
      (funcall diffs--regenerator)
    (revert-buffer)))

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

(defvar diffs--split-syncing nil)

(defun diffs--split-property-at (property position)
  "Return PROPERTY at or immediately before POSITION."
  (or (get-text-property position property)
      (and (> position (point-min))
           (get-text-property (1- position) property))))

(defun diffs--split-header-line ()
  "Return the sticky header for a side-by-side buffer."
  (let* ((window (get-buffer-window (current-buffer)))
         (position (if (window-live-p window)
                       (window-start window)
                     (point)))
         (file (diffs--split-property-at 'diffs-file position))
         (hunk (diffs--split-property-at 'diffs-hunk position))
         (side (if (eq diffs--split-role 'old)
                   (or (and (buffer-live-p diffs--split-unified)
                            (buffer-local-value
                             'diffs--revision diffs--split-unified))
                       "old")
                 "new")))
    (concat
     " " side
     (when file
       (concat
        "  │  "
        (propertize file 'face 'diffs-file-header)
        (when hunk
          (let ((context (nth 4 hunk)))
            (concat
             (format "  ·  −%d +%d" (nth 1 hunk) (nth 2 hunk))
             (when (and context (not (string-empty-p context)))
               (concat "  " context))))))))))

(defun diffs--split-sync-index (position)
  "Sync the owning file index to split POSITION."
  (when (buffer-live-p diffs--split-unified)
    (when-let* ((file (diffs--split-property-at 'diffs-file position))
                (section
                 (cl-find file
                          (buffer-local-value
                           'diffs--sections diffs--split-unified)
                          :key (lambda (item) (plist-get item :file))
                          :test #'equal)))
      (diffs--index-highlight-section diffs--split-unified section))))

(defun diffs--split-cache-clear ()
  "Kill cached split buffers belonging to the current unified buffer."
  (when diffs--split-cache
    (dolist (key '(:old :new))
      (when-let* ((buffer (plist-get diffs--split-cache key)))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))
    (setq diffs--split-cache nil)))

(defun diffs--bake-overlay-faces ()
  "Copy overlay faces (refine, syntax) into text properties."
  (with-silent-modifications
    (dolist (o (overlays-in (point-min) (point-max)))
      (when-let* ((face (overlay-get o 'face)))
        (add-face-text-property (overlay-start o) (overlay-end o) face nil)))))

(defun diffs--visible-region ()
  "Return the visible buffer region, including in batch frames."
  (let ((beg (window-start)))
    (cons beg
          (or (window-end nil t)
              (save-excursion
                (goto-char beg)
                (forward-line (window-body-height))
                (point))))))

(defun diffs--split-line (pos)
  "Return the line at POS as a string, without marker, with properties."
  (save-excursion
    (goto-char pos)
    (buffer-substring (min (1+ (line-beginning-position)) (line-end-position))
                      (line-end-position))))

(defun diffs--split-collect ()
  "Collect aligned row lists from the current unified diffs buffer.
Returns (OLD-ROWS NEW-ROWS ANCHORS); each row is
\(STRING NUMBER SRC-LINE KIND FILE HUNK).  NUMBER is the side's line number
or nil (fillers, headers), SRC-LINE the target line in the file
for RET, KIND one of header, sep, ctx, del, add, filler."
  (let (old-rows new-rows anchors (row 0))
    (cl-flet ((emit (o n)
                (push o old-rows) (push n new-rows) (cl-incf row)))
      (dolist (sec diffs--sections)
        (let* ((file (plist-get sec :file))
               (header (concat
                        (propertize (concat "── " (or file "?") "  ")
                                    'face 'diffs-file-header)
                        (propertize (format "+%d" (plist-get sec :adds))
                                    'face 'diffs-file-stats-added)
                        " "
                        (propertize (format "−%d" (plist-get sec :dels))
                                    'face 'diffs-file-stats-removed))))
          (emit (list header nil nil 'header file nil)
                (list header nil nil 'header file nil))
          (unless (plist-get sec :hunks)
            (save-excursion
              (goto-char (plist-get sec :beg))
              (forward-line 1)
              (while (< (point) (plist-get sec :end))
                (let ((text (buffer-substring
                             (line-beginning-position)
                             (line-end-position))))
                  (emit (list text nil nil 'meta file nil)
                        (list text nil nil 'meta file nil)))
                (forward-line 1))))
          (dolist (hunk (plist-get sec :hunks))
            (push (1+ row) anchors)
            (let ((sep (propertize "⋯" 'face 'diffs-hunk-separator)))
              (emit (list sep nil nil 'sep file hunk)
                    (list sep nil nil 'sep file hunk)))
            (let ((end (diffs--hunk-end hunk sec))
                  (old-line (nth 1 hunk))
                  (new-line (nth 2 hunk))
                  dels adds)
              (cl-flet ((flush ()
                          (let ((d (nreverse dels)) (a (nreverse adds)))
                            (while (or d a)
                              (emit
                               (or (pop d)
                                   (list "" nil new-line 'filler file hunk))
                               (or (pop a)
                                   (list "" nil nil 'filler file hunk)))))
                          (setq dels nil adds nil)))
                (save-excursion
                  (goto-char (car hunk))
                  (forward-line 1)
                  (while (and (< (point) end) (not (eobp)))
                    (let ((c (char-after)))
                      (cond
                       ((memq c '(?\s ?\n))
                        (flush)
                        (let ((s (diffs--split-line (point))))
                          (emit (list s old-line new-line 'ctx file hunk)
                                (list s new-line new-line 'ctx file hunk)))
                        (cl-incf old-line) (cl-incf new-line))
                       ((eq c ?-)
                        (push (list (diffs--split-line (point))
                                    old-line new-line 'del file hunk)
                              dels)
                        (cl-incf old-line))
                       ((eq c ?+)
                        (push (list (diffs--split-line (point))
                                    new-line new-line 'add file hunk)
                              adds)
                        (cl-incf new-line))))
                    (forward-line 1))
                  (flush))))))))
    (list (nreverse old-rows) (nreverse new-rows) (nreverse anchors))))

(defun diffs--split-string (string width)
  "Split STRING into property-preserving chunks of display WIDTH."
  (if (or (string-empty-p string)
          ;; `string-width' treats TAB as one column, so use this fast
          ;; path only for the overwhelmingly common TAB-free case.
          (and (not (string-search "\t" string))
               (<= (string-width string) width)))
      (list string)
    (let ((start 0)
          chunks)
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
          (push (substring string start end) chunks)
          (setq start end)))
      (nreverse chunks))))

(defun diffs--split-wrap-rows (old-rows new-rows width)
  "Wrap OLD-ROWS and NEW-ROWS to WIDTH with row-perfect alignment.
Return (OLD-WRAPPED NEW-WRAPPED)."
  (let (old-wrapped new-wrapped)
    (cl-mapc
     (lambda (old new)
       (if (memq (nth 3 old) '(header sep))
           (progn
             (push old old-wrapped)
             (push new new-wrapped))
         (let* ((old-chunks (diffs--split-string (car old) width))
                (new-chunks (diffs--split-string (car new) width))
                (count (max (length old-chunks) (length new-chunks))))
           (dotimes (index count)
             (cl-labels
                 ((row (source chunks)
                    (if-let* ((chunk (nth index chunks)))
                        (list chunk
                              (and (zerop index) (nth 1 source))
                              (nth 2 source)
                              (nth 3 source)
                              (nth 4 source)
                              (nth 5 source))
                      (list "" nil nil 'filler
                            (nth 4 source) (nth 5 source)))))
               (push (row old old-chunks) old-wrapped)
               (push (row new new-chunks) new-wrapped))))))
     old-rows new-rows)
    (list (nreverse old-wrapped) (nreverse new-wrapped))))

(defun diffs--split-insert-row
    (str num src kind file width role &optional fmt empty hunk)
  "Insert one split row described by STR, NUM, SRC, KIND and FILE.
WIDTH is the number-column width; ROLE is `old' or `new'."
  (let ((fmt (or fmt (format "%%%dd " width)))
        (empty (or empty (make-string (1+ width) ?\s))))
    (let ((beg (point)))
      (insert str)
      (let ((face (pcase kind
                    ('del (and (eq role 'old)
                               (if diffs-split-full-width-backgrounds
                                   'diffs-split-removed-line
                                 'diff-removed)))
                    ('add (and (eq role 'new)
                               (if diffs-split-full-width-backgrounds
                                   'diffs-split-added-line
                                 'diff-added)))
                    ('filler 'diffs-filler))))
        (insert (if (eq kind 'filler)
                    (propertize "\n" 'face 'diffs-filler)
                  "\n"))
        (when face
          (add-face-text-property
           beg
           (if (or diffs-split-full-width-backgrounds (eq kind 'filler))
               (point)
             (max beg (1- (point))))
           face t)))
      (when (memq kind '(ctx del add filler))
        (let* ((indicator (pcase kind
                            ('del (and (eq role 'old) ?-))
                            ('add (and (eq role 'new) ?+))))
               (change-face (pcase indicator
                              (?+ (and diffs-split-full-width-backgrounds
                                       'diffs-split-added-line))
                              (?- (and diffs-split-full-width-backgrounds
                                       'diffs-split-removed-line))))
               (fringe (diffs--fringe-prefix indicator)))
          (when (or diffs-line-numbers (not (string-empty-p fringe)))
            (put-text-property
             beg (point) 'line-prefix
             (concat
              fringe
              (when diffs-line-numbers
                (propertize
                 (if num (format fmt num) empty)
                 'face (if (eq kind 'filler)
                           '(diffs-line-number diffs-filler)
                         (diffs--split-line-prefix-face
                          change-face)))))))))
      (add-text-properties
       beg (point)
       (list 'diffs-src (and src (cons file src))
             'diffs-file file
             'diffs-hunk hunk)))))

(defun diffs--split-render (rows width role)
  "Insert ROWS into the current buffer.
WIDTH is the number-column width; ROLE is `old' or `new'."
  (let ((fmt (format "%%%dd " width))
        (empty (make-string (1+ width) ?\s)))
    (pcase-dolist (`(,str ,num ,src ,kind ,file ,hunk) rows)
      (diffs--split-insert-row
       str num src kind file width role fmt empty hunk))))

(defun diffs--split-render-pair
    (old-rows new-rows width content-width old-buffer new-buffer)
  "Render OLD-ROWS and NEW-ROWS directly into their paired buffers.
WIDTH is the number-column width and CONTENT-WIDTH is the wrapping
width.  Return the rendered hunk anchor line numbers."
  (let ((fmt (format "%%%dd " width))
        (empty (make-string (1+ width) ?\s))
        (line 0)
        anchors)
    (cl-mapc
     (lambda (old new)
       (let* ((wrap (and diffs-split-wrap-lines
                         (not (memq (nth 3 old) '(header sep)))))
              (old-chunks (if wrap
                              (diffs--split-string (car old) content-width)
                            (list (car old))))
              (new-chunks (if wrap
                              (diffs--split-string (car new) content-width)
                            (list (car new))))
              (count (max (length old-chunks) (length new-chunks))))
         (when (eq (nth 3 old) 'sep)
           (push (1+ line) anchors))
         (dotimes (index count)
           (let ((old-chunk (pop old-chunks))
                 (new-chunk (pop new-chunks)))
             (with-current-buffer old-buffer
               (if old-chunk
                   (diffs--split-insert-row
                    old-chunk (and (zerop index) (nth 1 old))
                    (nth 2 old) (nth 3 old) (nth 4 old)
                    width 'old fmt empty (nth 5 old))
                 (diffs--split-insert-row
                  "" nil nil 'filler (nth 4 old)
                  width 'old fmt empty (nth 5 old))))
             (with-current-buffer new-buffer
               (if new-chunk
                   (diffs--split-insert-row
                    new-chunk (and (zerop index) (nth 1 new))
                    (nth 2 new) (nth 3 new) (nth 4 new)
                    width 'new fmt empty (nth 5 new))
                 (diffs--split-insert-row
                  "" nil nil 'filler (nth 4 new)
                  width 'new fmt empty (nth 5 new)))))
           (cl-incf line))))
     old-rows new-rows)
    (nreverse anchors)))

(defun diffs--split-sync-from (window &optional start)
  "Align the window(s) paired with WINDOW to its scroll position.
START overrides WINDOW's start position (used from
`window-scroll-functions', which runs before it is committed).
Mirrors the pixel-level vscroll as well, so pixel scrolling stays
in lockstep."
  (let* ((buf (window-buffer window))
         (other (and (buffer-live-p buf)
                     (buffer-local-value 'diffs--split-other buf))))
    (when (buffer-live-p other)
      (let* ((start (or start (window-start window)))
             (vscroll (window-vscroll window t))
             (state (cons start vscroll)))
        (unless (equal state (window-parameter window 'diffs--sync))
          (set-window-parameter window 'diffs--sync state)
          (let* ((line (with-current-buffer buf
                         (count-lines (point-min) start)))
                 (pos (with-current-buffer other
                        (save-excursion
                          (goto-char (point-min))
                          (forward-line line)
                          (point)))))
            (dolist (w (get-buffer-window-list other nil t))
              (set-window-start w pos)
              (set-window-vscroll w vscroll t)
              (set-window-parameter w 'diffs--sync (cons pos vscroll)))))))))

(defun diffs--split-scroll-hook (window start)
  "Synchronize WINDOW at START while a split view is shown."
  (unless diffs--split-syncing
    (let ((diffs--split-syncing t))
      (with-demoted-errors "diffs split sync: %S"
        (diffs--split-sync-from window start)
        (diffs--split-sync-index start)))))

(defun diffs--split-post-command ()
  "Sync the paired window after commands in a split buffer."
  (unless diffs--split-syncing
    (let ((diffs--split-syncing t)
          (w (selected-window)))
      (when (eq (window-buffer w) (current-buffer))
        (with-demoted-errors "diffs split sync: %S"
          (diffs--split-sync-from w)
          (diffs--split-sync-index (point)))))))

(defvar-keymap diffs-split-mode-map
  "n" #'diffs-split-next-hunk
  "p" #'diffs-split-prev-hunk
  "RET" #'diffs-split-goto-source
  "i" #'diffs-toggle-index
  "s" #'diffs-split-quit
  "q" #'diffs-split-quit)

(define-derived-mode diffs-split-mode special-mode "diffs-split"
  "Major mode for one side of the diffs side-by-side view."
  (diffs--define-fringe-bitmap)
  (setq truncate-lines t)
  (setq-local cursor-in-non-selected-windows nil)
  (add-hook 'text-scale-mode-hook #'diffs--define-fringe-bitmap nil t)
  (add-hook 'post-command-hook #'diffs--split-post-command nil t)
  (add-hook 'window-scroll-functions #'diffs--split-scroll-hook nil t))

(defun diffs--split-move-to-anchor (next)
  "Move point to the next hunk anchor (previous when NEXT is nil)."
  (let* ((line (line-number-at-pos))
         (target (if next
                     (cl-find-if (lambda (l) (> l line)) diffs--split-anchors)
                   (cl-find-if (lambda (l) (< l line))
                               (reverse diffs--split-anchors)))))
    (unless target (user-error "No more hunks"))
    (goto-char (point-min))
    (forward-line (1- target))
    (dolist (w (get-buffer-window-list diffs--split-other nil t))
      (set-window-point
       w (with-current-buffer diffs--split-other
           (save-excursion
             (goto-char (point-min)) (forward-line (1- target)) (point)))))
    (recenter)
    (diffs--split-sync-from (selected-window))))

(defun diffs-split-next-hunk ()
  "Move to the next hunk in the side-by-side view."
  (interactive)
  (diffs--split-move-to-anchor t))

(defun diffs-split-prev-hunk ()
  "Move to the previous hunk in the side-by-side view."
  (interactive)
  (diffs--split-move-to-anchor nil))

(defun diffs-split-goto-source ()
  "Visit the source location of the line at point."
  (interactive)
  (let ((src (get-text-property (point) 'diffs-src))
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
    ;; Keep the rendered pair alive.  The owning unified buffer kills it
    ;; when the diff changes, is refreshed, or is itself killed.
    (dolist (buffer (list old other))
      (when (buffer-live-p buffer)
        (bury-buffer buffer)))))

(defun diffs-toggle-split ()
  "Toggle between the unified and the side-by-side view."
  (interactive)
  (unless diffs-minor-mode
    (user-error "Not in a diffs buffer"))
  (let* ((unified (current-buffer))
         (line-count (count-lines (point-min) (point-max)))
         (modified-tick (buffer-chars-modified-tick))
         (wrap-lines diffs-split-wrap-lines)
         (show-line-numbers diffs-line-numbers)
         (show-fringe-bars diffs-fringe-bars)
         (fringe-bar-width diffs-fringe-bar-width)
         (full-width-backgrounds diffs-split-full-width-backgrounds)
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
        (let* ((content-width
                (max 8 (- (min (window-body-width w1)
                               (window-body-width w2))
                          width 1)))
               (key (list modified-tick
                          content-width width
                          wrap-lines
                          show-line-numbers
                          show-fringe-bars
                          fringe-bar-width
                          full-width-backgrounds
                          source-tab-width))
               anchors)
          (if (equal key (plist-get diffs--split-cache :key))
              (setq anchors (plist-get diffs--split-cache :anchors))
            (with-current-buffer unified
              (if (<= line-count diffs-split-fontify-threshold)
                  (font-lock-ensure)
                (pcase-let ((`(,beg . ,end) (diffs--visible-region)))
                  (font-lock-ensure beg end)
                  (message
                   "diffs: large diff — carrying visible refine/syntax faces")))
              (diffs--bake-overlay-faces))
            (dolist (buffer (list old-buf new-buf))
              (with-current-buffer buffer
                (let ((inhibit-read-only t))
                  (fundamental-mode)
                  (setq buffer-read-only nil)
                  (erase-buffer))))
            (let ((collected (with-current-buffer unified
                               (diffs--split-collect))))
              (let ((diffs-split-wrap-lines wrap-lines)
                    (diffs-line-numbers show-line-numbers)
                    (diffs-fringe-bars show-fringe-bars)
                    (diffs-fringe-bar-width fringe-bar-width)
                    (diffs-split-full-width-backgrounds
                     full-width-backgrounds)
                    (tab-width source-tab-width))
                (setq anchors
                      (diffs--split-render-pair
                       (nth 0 collected) (nth 1 collected)
                       width content-width old-buf new-buf))))
            (setq diffs--split-cache
                  (list :key key :anchors anchors
                        :old old-buf :new new-buf)))
          (dolist (spec (list (list old-buf 'old new-buf)
                              (list new-buf 'new old-buf)))
            (with-current-buffer (nth 0 spec)
              (goto-char (point-min))
              (unless (derived-mode-p 'diffs-split-mode)
                (diffs-split-mode))
              (setq-local diffs-split-full-width-backgrounds
                          full-width-backgrounds)
              (setq default-directory dir)
              (setq-local diffs--split-unified unified)
              (setq-local diffs--split-role (nth 1 spec))
              (setq-local diffs--split-anchors anchors)
              (setq-local diffs--split-other (nth 2 spec))
              (setq-local diffs--split-window-configuration configuration)
              (setq header-line-format
                    '((:eval (diffs--split-header-line)))))))
        (select-window w2)
        (diffs--split-sync-from w2)))))

;;;; Diff generation

(defun diffs--reference-revision ()
  "Return the reference revision to diff against, or nil for the default."
  (bound-and-true-p diff-hl-reference-revision))

(defun diffs--header-line ()
  "Return the sticky file, hunk, and summary header."
  (cl-destructuring-bind (&optional (files 0) (adds 0) (dels 0)) diffs--stats
    (let* ((window (get-buffer-window (current-buffer)))
           (position (if (window-live-p window)
                         (window-start window)
                       (point)))
           (section (diffs--section-at-pos position))
           (hunk (and section (diffs--hunk-at-pos section position))))
      (concat
       " "
       (when section
         (concat
          (propertize (or (plist-get section :file) "?")
                      'face 'diffs-file-header)
          (format "  [%d/%d]  "
                  (plist-get section :index) files)
          (propertize (format "+%d" (plist-get section :adds))
                      'face 'diffs-file-stats-added)
          " "
          (propertize (format "−%d" (plist-get section :dels))
                      'face 'diffs-file-stats-removed)
          (when hunk
            (let ((context (nth 4 hunk)))
              (concat
               (format "  ·  −%d +%d" (nth 1 hunk) (nth 2 hunk))
               (when (and context (not (string-empty-p context)))
                 (concat "  " context)))))
          "  │  "))
       (if (= files 1) "1 file" (format "%d files" files))
       " · "
       (propertize (format "+%d" adds) 'face 'diffs-file-stats-added)
       " "
       (propertize (format "−%d" dels) 'face 'diffs-file-stats-removed)
       (when diffs--revision
         (format " · vs %s" diffs--revision))))))

(defun diffs--present (buf backend rev &optional line regenerator)
  "Set up and display the diff in BUF.
BACKEND and REV are used for revision-aware syntax highlighting.
LINE, if non-nil, is the source line to move to.  REGENERATOR is
stored for `diffs-refresh'."
  (with-current-buffer buf
    (goto-char (point-min))
    (diff-mode)
    (setq-local diff-vc-backend backend)
    (when rev
      (setq-local diff-vc-revisions (list rev nil)))
    (setq buffer-read-only t)
    (setq-local diffs--revision rev)
    (setq-local diffs--regenerator regenerator)
    (diffs-minor-mode 1)
    (unless diffs--sections
      (kill-buffer buf)
      (user-error "No changes"))
    (setq header-line-format '((:eval (diffs--header-line)))))
  (unless (get-buffer-window buf)
    (let ((configuration (current-window-configuration)))
      (with-current-buffer buf
        (setq diffs--window-configuration configuration))))
  (pop-to-buffer buf)
  (when diffs-fullscreen
    (delete-other-windows))
  (when line
    (require 'diff-hl nil t)
    (when (fboundp 'diff-hl-diff-skip-to)
      (ignore-errors (diff-hl-diff-skip-to line)))))

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
(defun diffs-file ()
  "Show a pretty diff of the current file against the reference revision.
Unsaved changes are included when diff-hl is available.  The
reference is `diff-hl-reference-revision' when set, otherwise the
last revision."
  (interactive)
  (let* ((file (or (buffer-file-name)
                   (user-error "Buffer is not visiting a file")))
         (backend (or (vc-backend file)
                      (user-error "File is not under version control")))
         (rev (diffs--reference-revision))
         (line (line-number-at-pos))
         (unsaved (and (buffer-modified-p)
                       (require 'diff-hl nil t)
                       (fboundp 'diff-hl-diff-buffer-with-reference)))
         ;; The unsaved diff labels files with their base name; the
         ;; VC diff uses root-relative names.
         (buf (diffs--prepare-buffer
               (if unsaved
                   (file-name-directory file)
                 (vc-call-backend backend 'root
                                  (file-name-directory file))))))
    (if unsaved
        (let ((diff-hl-update-async nil))
          (diff-hl-diff-buffer-with-reference file buf backend 3))
      (vc-call-backend backend 'diff (list file) rev nil buf nil))
    (diffs--present buf backend rev line
                    (lambda ()
                      (if-let* ((b (find-buffer-visiting file)))
                          (with-current-buffer b (diffs-file))
                        (user-error "Source buffer was killed"))))))

;;;###autoload
(defun diffs-project ()
  "Show a pretty diff of the whole project against the reference revision."
  (interactive)
  (let* ((backend (or (ignore-errors (vc-deduce-backend))
                      (ignore-errors (vc-responsible-backend default-directory))
                      (user-error "Not in a version-controlled directory")))
         (root (vc-call-backend backend 'root default-directory))
         (rev (diffs--reference-revision))
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
                    (lambda () (diffs-commit rev file)))))

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

;;;###autoload
(defun diffs-file-from-hunk ()
  "Open the file-level diffs view from the diff-hl show-hunk popup."
  (interactive)
  (when (fboundp 'diff-hl-show-hunk-hide)
    (diff-hl-show-hunk-hide))
  (diffs-file))

(provide 'diffs)
;;; diffs.el ends here
